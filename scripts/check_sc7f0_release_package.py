#!/usr/bin/env python3
"""Release-package gate for the SC7F0 VCU card, plus the negative tests.

The rule this enforces: only a release whose own bytes, own gates and own identity
all agree may reach a card. Everything is re-derived from the release directory at
check time; nothing is taken from a log line that some earlier script printed.

evaluate(release) checks

  members     the upgrade tar is strict ustar with exactly BOOT.BIN, image.ub,
              boot.scr, manifest.sha256, and the manifest hashes match the payload
              bytes *and* the release directory copies;
  identity    VERSION, release.json, release-provenance.json and the bitstream's
              stamped version-identity.json all name the same version, and the
              worktree fingerprint stored there is the one that was recorded for
              this release;
  pl/ps match hardware.xsa carries the release bitstream byte for byte, the PS
              build log's imported-xsa.sha256 is that same XSA, and BOOT.BIN really
              carries the release bitstream;
  gates       the strict timing/CDC gate JSON passes *and* check_sc7f0_timing.py
              re-run over the release's own reports agrees (a JSON that claims
              pass while its reports say otherwise is a false gate, not a pass);
  unit tests  the three unit-test gate JSONs (preflight / after-fpga / at-package)
              exist, passed, executed the suites the stages require, and were
              computed over the fingerprints this release names - so an old round's
              green JSON cannot be reused; tolerated entries must belong to a
              documented out-of-scope subsystem (the MCU image audit) and are
              reported as scope, never as evidence;
  sources     SOURCE.sha256 / SOURCE_FPGA.sha256 / SOURCE_VALIDATION.sha256 exist,
              cover every declared required input, and match the bytes inside the
              shipped source-snapshot.tar.gz;
  runtimes    every PS runtime the image must carry has a resolved byte source
              (cross-build sha256, or OE packagedata size + in-binary literal);
              `@present` is never acceptable;
  self claim  release.json `deployable` agrees with gates/package.ok and
              NOT_DEPLOYABLE, and nothing in the release claims hardware or
              deployment acceptance, which no package gate can know;
  runtime     the runtime checklist (sc7f0_vcud, qpcie_debugd, the OpenMAX
              libraries, the enabled units) is read out of image.ub itself.

--self-test then proves the gate actually bites, by mutating copies of the release
and requiring each mutant to be rejected: missing runtime member, missing or wrong
manifest, mismatched bitstream/XSA, absent gate record, forged gate record.

Offline. Never flashes, never touches a card.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import check_sc7f0_timing  # noqa: E402
from check_sc7f0_upgrade_tar import read_members  # noqa: E402

MEMBERS = ("BOOT.BIN", "image.ub", "boot.scr", "manifest.sha256")

# The unit-test evidence a release must carry, and which scope fingerprint each run
# is required to have been computed over.  "the suite printed OK" is not evidence
# until you can say which bytes it was OK about, and which stage ran it.
UNIT_TEST_EVIDENCE = (
    # path, scope whose fingerprint must equal the release's, what it proves
    ("gates/unit-tests.json", "source_fingerprint_sha256",
     "preflight: the whole suite over the sources this release froze"),
    ("gates/unit-tests-after-fpga.json", "fpga_scope_fingerprint_sha256",
     "fpga: device-tree/IP checks against this build's generated IP"),
    ("gates/unit-tests-at-package.json", "ps_scope_fingerprint_sha256",
     "package: packaging/rootfs/release-gate checks over the PS sources shipped"),
)
# Subsystems that are knowingly not exercised by this release path.  Listing one is
# a scope statement, never a safety statement: scripts/tests
# /RELEASE_TEST_BASELINE.json records that the NUC1262 image audit is currently
# unable to run at all, so its tolerated tests prove nothing about the MCU.
OUT_OF_SCOPE_TOLERATED_PREFIXES = ("test_sc7f0_mcu_app_image", "test_sc7f0_mcu_flash")
HARDWARE_ACCEPTANCE_NOTE = (
    "package/deployment acceptance is not a package gate: the card-side steps live "
    "in docs/sc7f0_release_deploy_acceptance_runbook.md and are only true after they "
    "were performed on hardware with this release's version and boot id")
# Keys that would assert hardware/deployment acceptance.  None of them may be true
# in a packaged release, because no card has run it yet.
ACCEPTANCE_CLAIM_KEYS = ("hardware_accepted", "deployment_accepted", "board_accepted",
                        "field_accepted", "system_accepted", "video0_verified",
                        "gstreamer_verified", "flashed_ok")


def _acceptance_claims(node, path="release.json") -> list[str]:
    """Find fields that would claim the card was verified. Deployment acceptance is
    a hardware act; a packaging script writing it true is a false PASS."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}"
            if isinstance(value, bool) and value and key.lower() in ACCEPTANCE_CLAIM_KEYS:
                found.append(here)
            found += _acceptance_claims(value, here)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            found += _acceptance_claims(value, f"{path}[{i}]")
    return found


def check_unit_test_evidence(release: Path, identity: dict, notes: dict) -> list[str]:
    errors: list[str] = []
    summary = {}
    for rel, field, purpose in UNIT_TEST_EVIDENCE:
        path = release / rel
        if not path.is_file():
            errors.append(f"{rel} is missing: {purpose} was never executed as part of "
                          "this release (a release cannot inherit another round's "
                          "unit-test JSON)")
            continue
        try:
            doc = json.loads(path.read_text())
        except ValueError as exc:
            errors.append(f"{rel} is not readable JSON: {exc}")
            continue
        label = rel
        if doc.get("verdict") != "UNIT_TESTS_GATE_PASS":
            errors.append(f"{label} verdict is {doc.get('verdict')!r}: "
                          + "; ".join(str(x) for x in
                                      (doc.get('unexpected_failures') or [])[:3]))
        for key, want in (("unexpected_failures", []), ("stale_baseline_entries", []),
                          ("required_tests_not_executed", [])):
            if doc.get(key):
                errors.append(f"{label} has {key}={doc[key][:4]}")
        if not doc.get("require_run"):
            errors.append(f"{label} named no required suite, so a skipped gate would "
                          "have counted as a pass")
        if doc.get("returncode") != 0:
            errors.append(f"{label} ran on a suite that exited "
                          f"{doc.get('returncode')!r}")
        sources = doc.get("sources") or {}
        want = (identity or {}).get(field)
        got = sources.get(field)
        if want is None or got is None:
            errors.append(f"{label} does not record {field}, so this unit-test evidence "
                          "cannot be attributed to the sources this release names")
        elif want != got:
            errors.append(f"{label} was computed over a different tree: "
                          f"{field} {str(got)[:12]} there vs {str(want)[:12]} here "
                          "(a green suite from another round is not this release's gate)")
        tolerated = doc.get("tolerated") or []
        out_of_scope = [t for t in tolerated if t.startswith(OUT_OF_SCOPE_TOLERATED_PREFIXES)]
        other = [t for t in tolerated if t not in out_of_scope]
        if other:
            errors.append(f"{label} tolerates tests outside the documented "
                          f"out-of-scope subsystems: {other[:4]}")
        summary[rel] = {"verdict": doc.get("verdict"),
                        "ran": len(doc.get("ran") or []),
                        "skipped": len(doc.get("skipped") or []),
                        "required": doc.get("require_run"),
                        "tolerated": tolerated,
                        "tolerated_reasons": doc.get("baseline_reasons") or {},
                        "purpose": purpose}
    notes["unit_tests"] = summary
    mcu = sorted({t for doc in summary.values() for t in doc["tolerated"]
                  if t.startswith(OUT_OF_SCOPE_TOLERATED_PREFIXES)})
    if mcu:
        notes["tolerated_not_evidence"] = {
            "tests": mcu,
            "meaning": "the NUC1262 MCU image audit is out of scope for this release "
                       "path and (per scripts/tests/RELEASE_TEST_BASELINE.json) cannot "
                       "currently run; these tolerated entries are a scope statement "
                       "and must never be quoted as MCU safety evidence"}
    return errors


def check_source_manifests(release: Path) -> tuple[list[str], dict]:
    """Every declared input must be recoverable from the shipped snapshot.

    Role manifests are how a release says "these are the bitstream inputs" and "these
    are the evidence sources". The failure this closes is subtler than a missing
    file: leaving a real build/checker input out of every role manifest makes later
    edits to it look like harmless tooling drift to scripts/sc7f0_source_drift.py.
    So the check is (a) the required set is covered, and (b) the snapshot really
    contains those names with those digests - i.e. the claim is not just complete,
    it is backed by bytes that ship with the release.
    """
    errors: list[str] = []
    notes: dict[str, object] = {}
    sys.path.insert(0, str(REPO / "scripts"))
    import sc7f0_release_id as rid
    snapshot = release / "source-snapshot.tar.gz"
    if not snapshot.is_file():
        return [f"{snapshot} is missing: the release ships no source snapshot"], notes
    from tarfile import open as tar_open
    with tar_open(snapshot, "r:gz") as tar:
        packed = {}
        for member in tar:
            if member.isfile():
                digest = hashlib.sha256(tar.extractfile(member).read()).hexdigest()
                packed[member.name.lstrip("./")] = digest
    tables = {}
    for manifest in ("SOURCE.sha256", "SOURCE_FPGA.sha256", "SOURCE_VALIDATION.sha256"):
        path = release / manifest
        if not path.is_file():
            errors.append(f"{manifest} is missing from the release")
            continue
        table = {}
        for line in path.read_text().splitlines():
            digest, _, name = line.partition("  ")
            if name.strip():
                table[name.strip().lstrip("*")] = digest.strip()
        if not table:
            errors.append(f"{manifest} lists no files")
            continue
        tables[manifest] = table
        for name, digest in sorted(table.items()):
            if packed.get(name) != digest:
                errors.append(f"{manifest} names {name}, which the shipped "
                              "source-snapshot.tar.gz does not contain with that digest "
                              "(the manifest is not the build's input list)")
                break
    if len(tables) == 3:
        for scope in ("fpga", "ps", "validation"):
            for name in rid.REQUIRED_SOURCE_FILES.get(scope, ()):
                if name not in tables["SOURCE.sha256"]:
                    errors.append(f"required {scope} input {name} is not in SOURCE.sha256")
                elif name not in tables["SOURCE_FPGA.sha256"] and \
                        name not in tables["SOURCE_VALIDATION.sha256"]:
                    errors.append(f"required {scope} input {name} is in the snapshot but "
                                  "in no role manifest, so editing it after the freeze "
                                  "would read as tooling drift")
        notes["source_manifests"] = {k: len(v) for k, v in tables.items()}
    return errors, notes


def check_runtime_byte_sources(release: Path) -> tuple[list[str], dict]:
    """Every runtime the image must carry has an identified byte source.

    `@present` used to be the fallback whenever `find ... | head -1` came up empty,
    which was always, because OE deletes the recipe's $D after packaging. So nothing
    was ever compared and a stale qpcie_debugd (the pre-0x800 mailbox one) passed.
    """
    errors: list[str] = []
    notes: dict[str, object] = {}
    sources_path = release / "ps" / "rootfs-binary-sources.json"
    report_path = release / "ps" / "rootfs-runtime-content.json"
    if not sources_path.is_file():
        return (["ps/rootfs-binary-sources.json is missing: the image runtimes have no "
                 "recorded byte source (scripts/resolve_recipe_install_output.py "
                 "produces it in the PS stage)"], notes)
    try:
        sources = json.loads(sources_path.read_text())
        report = json.loads(report_path.read_text()) if report_path.is_file() else {}
    except ValueError as exc:
        return [f"runtime byte sources cannot be read: {exc}"], notes
    if sources.get("presence_only"):
        errors.append("the PS stage documented presence-only runtimes "
                      f"{sources['presence_only']}: a runtime this release names must "
                      "have a byte source (cross-build sha256 or OE packagedata size)")
    per_binary = {}
    for rec in sources.get("binaries", []):
        name = rec.get("binary")
        if rec.get("status") != "RESOLVED":
            errors.append(f"runtime {name} has no resolved byte source "
                          f"({rec.get('status')}): {str(rec.get('reason'))[:120]}")
            continue
        entry = (report.get("binaries") or {}).get(name) or {}
        if rec.get("kind") == "cross-build":
            if entry.get("byte_exact_vs_build_tree") is not True:
                errors.append(f"image {name} is not byte-identical to the cross-build "
                              f"this PS run recorded ({rec.get('source')})")
            per_binary[name] = {"kind": "cross-build", "sha256": rec.get("sha256"),
                                "size": rec.get("size"), "byte_exact": True}
        else:
            path = rec.get("install_path")
            size_check = (report.get("sizes") or {}).get(path) or {}
            if not size_check.get("match"):
                errors.append(f"image {path} does not match the OE packagedata size "
                              f"{rec.get('size')} for recipe {rec.get('recipe')}")
            if name not in (report.get("binaries") or {}):
                errors.append(f"recipe runtime {name} is not in the verified image")
            per_binary[name] = {"kind": "recipe-packagedata",
                                "packagedata": rec.get("packagedata"),
                                "install_path": path, "size": rec.get("size"),
                                "byte_exact": "packagedata size + in-binary literals"}
    notes["runtime_byte_sources"] = per_binary
    return errors, notes


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _read_json(path: Path):
    return json.loads(path.read_text())


def evaluate(release: Path, expect_runtime: list[str] | None = None) -> dict:
    errors: list[str] = []
    notes: dict[str, object] = {}
    version_file = release / "VERSION"
    if not version_file.is_file():
        return {"verdict": "RELEASE_GATE_FAIL", "errors": ["VERSION missing"]}
    version = version_file.read_text().strip()

    # ---- members and manifest ------------------------------------------------
    bundle = release / "release" / f"upgrade-{version}.tar"
    images = release / "images"
    if not bundle.is_file():
        errors.append(f"{bundle} is missing")
        members = []
    else:
        try:
            members = read_members(bundle.read_bytes())
        except ValueError as exc:
            errors.append(f"upgrade tar structure: {exc}")
            members = []
        names = [m["name"] for m in members]
        if names != list(MEMBERS):
            errors.append(f"tar members {names} != required order {list(MEMBERS)}")
        manifest = {m["name"]: m for m in members if m["name"] == "manifest.sha256"}
        table = {}
        if manifest:
            for line in manifest["manifest.sha256"]["data"].decode().splitlines():
                digest, _, name = line.partition("  ")
                table[name.strip()] = digest.strip()
        else:
            errors.append("manifest.sha256 is absent from the tar")
        for name in MEMBERS[:-1]:
            member = next((m for m in members if m["name"] == name), None)
            if member is None:
                errors.append(f"{name} is not in the upgrade tar")
                continue
            if table.get(name) != member["sha256"]:
                errors.append(f"manifest.sha256 does not match {name} in the tar")
            on_disk = images / name
            if not on_disk.is_file():
                errors.append(f"{name} is not in {images}")
            elif sha(on_disk) != member["sha256"]:
                errors.append(f"{images}/{name} differs from the packaged bytes")
    if not any(images.joinpath(n).is_file() for n in MEMBERS[:-1]):
        errors.append("no boot images at all")

    # ---- identity ------------------------------------------------------------
    provenance_path = release / "release-provenance.json"
    identity_path = release / "identity.json"
    stamped_path = release / "fpga" / "version-identity.json"
    for p in (provenance_path, identity_path, stamped_path):
        if not p.is_file():
            errors.append(f"{p.name} is missing: the release cannot state what it is")
    ident: dict = {}
    if provenance_path.is_file() and identity_path.is_file() and stamped_path.is_file():
        prov, ident, stamped = _read_json(provenance_path), _read_json(identity_path), _read_json(stamped_path)
        want = "0x" + version
        if stamped.get("c_version") != want:
            errors.append(f"bitstream reports {stamped.get('c_version')}, release VERSION is {want}")
        if ident.get("version") != version:
            errors.append(f"identity.json version {ident.get('version')} != VERSION {version}")
        if prov.get("version") != version:
            errors.append(f"release-provenance.json version {prov.get('version')} != VERSION")
        if prov.get("source_fingerprint_sha256") != ident.get("source_fingerprint_sha256"):
            errors.append("provenance and identity disagree on the source fingerprint")
        if stamped.get("source_fingerprint_sha256") != ident.get("source_fingerprint_sha256"):
            errors.append("the bitstream was stamped from a different source fingerprint")
        if prov.get("git_head") != ident.get("git_head"):
            errors.append("provenance git_head differs from the recorded git_head")
        notes["identity"] = {"version": version, "c_version": stamped.get("c_version"),
                             "git_register": stamped.get("git_commit_hash_register"),
                             "git_register_source": stamped.get("git_register_source"),
                             "worktree_dirty": stamped.get("worktree_dirty"),
                             "build_timestamp": stamped.get("build_timestamp_register")}

    # ---- unit-test evidence for THIS round ---------------------------------
    errors += check_unit_test_evidence(release, ident if identity_path.is_file() else {}, notes)

    # ---- source manifests vs the shipped snapshot --------------------------
    manifest_errors, manifest_notes = check_source_manifests(release)
    errors += manifest_errors
    notes.update(manifest_notes)

    # ---- runtime byte sources (no @present anywhere) -----------------------
    runtime_errors, runtime_notes = check_runtime_byte_sources(release)
    errors += runtime_errors
    notes.update(runtime_notes)

    # ---- PL/PS match ---------------------------------------------------------
    xsa, bit = release / "fpga" / "hardware.xsa", release / "fpga" / "zu4ev_pcie_card_top.bit"
    if not xsa.is_file() or not bit.is_file():
        errors.append("fpga/hardware.xsa and the release bitstream are required")
    else:
        from zipfile import ZipFile
        with ZipFile(xsa) as z:
            names = [n for n in z.namelist() if n.endswith(".bit")]
            if len(names) != 1:
                errors.append(f"hardware.xsa holds {len(names)} bitstreams")
            else:
                with ZipFile(xsa) as z:
                    if hashlib.sha256(z.read(names[0])).hexdigest() != sha(bit):
                        errors.append("hardware.xsa does not carry the release bitstream")
    ps_match = release / "PS_IMAGE_MATCH.json"
    if not ps_match.is_file():
        errors.append("PS_IMAGE_MATCH.json is missing: the PS image is not tied to this XSA")
    else:
        m = _read_json(ps_match)
        if m.get("ps_image_built_from_this_xsa_sha256") != sha(xsa):
            errors.append("PS image was imported from a different hardware XSA")
        if m.get("ps_image_pl_base_version") != "0x" + version:
            errors.append(f"PS image declares {m.get('ps_image_pl_base_version')}, not 0x{version}")

    # ---- gates, re-derived ---------------------------------------------------
    gate_path = release / "gates" / "timing-gate-record.json"
    recheck = release / "gates" / "timing-gate-recheck.json"
    if not gate_path.is_file() or not recheck.is_file():
        errors.append("strict timing/CDC gate record is missing")
    else:
        recorded, again = _read_json(gate_path), _read_json(recheck)
        for label, rec in (("recorded", recorded), ("recheck", again)):
            if rec.get("pass_gate") is not True or rec.get("errors"):
                errors.append(f"{label} gate JSON does not pass: {rec.get('errors')}")
    # The two-layer verdict is only reproducible with the review policy that
    # produced it. Re-grading archived reports with whatever scripts/gates says
    # today would let a later, looser ledger turn an unreviewed round into a pass,
    # so the release must carry its own snapshot and that snapshot must hash-match.
    snapshot = release / "gates" / "policy"
    policy_files = ("sc7f0_cdc_review.json", "sc7f0_drc_review.json",
                    "sc7f0_clock_pair_review.json", "sc7f0_review_policy.py")
    missing = [name for name in policy_files if not (snapshot / name).is_file()]
    if missing:
        errors.append("release carries no review policy snapshot in gates/policy "
                      "(missing " + ", ".join(missing) + "): the Layer B review verdict "
                      "cannot be re-derived from the release itself")
    else:
        hashes = release / "gates" / "policy.sha256"
        if not hashes.is_file():
            errors.append("gates/policy.sha256 is missing: nothing binds the review "
                          "policy snapshot to the bytes that were actually reviewed")
        else:
            for line in hashes.read_text().splitlines():
                fields = line.split()
                if len(fields) < 2:
                    errors.append(f"gates/policy.sha256 has a malformed line: {line}")
                    continue
                want, name = fields[0], fields[1].lstrip("*")
                target = snapshot / name
                if not target.is_file():
                    errors.append(f"policy snapshot file {name} is hashed but absent")
                elif sha(target) != want:
                    errors.append(f"policy snapshot {name} does not match "
                                  "gates/policy.sha256 (the review policy was edited "
                                  "after the verdict)")
    # Re-derive the verdict from the release's own reports: a JSON that claims
    # success while its reports say otherwise is rejected as a false gate.
    try:
        fresh = check_sc7f0_timing.check(str(release / "fpga"),
                                         None if missing else str(snapshot))
    except (OSError, ValueError, IndexError) as exc:
        errors.append(f"timing reports cannot be re-checked: {exc}")
        fresh = None
    if fresh is not None:
        notes["recomputed_gate"] = {"pass_gate": fresh["pass_gate"],
                                    "pass_layer_a": fresh["pass_layer_a"],
                                    "pass_layer_b": fresh["pass_layer_b"],
                                    "margins_ns": fresh["margins_ns"],
                                    "errors": fresh["errors"][:6]}
        if not fresh["pass_layer_a"]:
            errors.append("FALSE GATE: check_sc7f0_timing.py Layer A over this release's "
                          "reports fails: " + "; ".join(fresh["layer_a_errors"][:4]))
        elif not fresh["pass_gate"]:
            errors.append("FALSE GATE: the review ledger (Layer B) over this release's "
                          "reports fails: " + "; ".join(fresh["layer_b_errors"][:4]))
    for name in ("rootfs-runtime-content.json",):
        p = release / "ps" / name
        if not p.is_file():
            errors.append(f"ps/{name} is missing: the image runtime was never proven")
        elif _read_json(p).get("verdict") != "ROOTFS_RUNTIME_CONTENT_PASS":
            errors.append(f"ps/{name} is not a pass")
    bootbin_check = release / "gates" / "bootbin-payload.json"
    if not bootbin_check.is_file():
        errors.append("gates/bootbin-payload.json is missing: BOOT.BIN payload was never proven")
    elif _read_json(bootbin_check).get("verdict") != "BOOTBIN_PAYLOAD_MATCH":
        errors.append("BOOT.BIN does not provably carry this release's bitstream")

    # ---- runtime components inside image.ub ----------------------------------
    if expect_runtime is not None:
        for entry in expect_runtime:
            if not images.joinpath("image.ub").is_file():
                break
            proc = subprocess.run(
                [sys.executable, str(REPO / "scripts/package_sc7f0_rootfs.py"), "verify",
                 "--image-ub", str(images / "image.ub"), "--expect-binary", entry],
                cwd=REPO, capture_output=True, text=True)
            if proc.returncode != 0:
                errors.append("runtime check failed for " + entry + ": "
                              + proc.stderr.strip().splitlines()[-1])

    release_json = release / "release.json"
    if not release_json.is_file():
        errors.append("release.json is missing")
    else:
        rj = _read_json(release_json)
        if rj.get("version") != version:
            errors.append("release.json version does not match VERSION")
        for name, digest in rj.get("sha256", {}).items():
            f = release / name
            if not f.is_file():
                errors.append(f"release.json lists {name}, which is not in the release")
            elif sha(f) != digest:
                errors.append(f"{name} does not match release.json")
        # deployable must agree with the other two ways this directory says yes/no.
        # It used to be written false unconditionally while gates/package.ok said the
        # gate had passed, and the reason string promised a write-back that never
        # happened - a reader could not tell "failed" from "not yet graded".
        ok = (release / "gates" / "package.ok").is_file()
        failed = (release / "NOT_DEPLOYABLE").is_file()
        if bool(rj.get("deployable")) != ok:
            errors.append(f"release.json deployable={rj.get('deployable')!r} but "
                          f"gates/package.ok is {'present' if ok else 'absent'}: the "
                          "release contradicts itself about whether it may be deployed")
        if bool(rj.get("deployable")) and failed:
            errors.append("release.json claims deployable while NOT_DEPLOYABLE exists")
        claims = _acceptance_claims(rj) + _acceptance_claims(
            _read_json(provenance_path) if provenance_path.is_file() else {}, "provenance")
        if claims:
            errors.append("the release asserts hardware/deployment acceptance "
                          "(" + ", ".join(claims) + "), which no package gate can know: "
                          + HARDWARE_ACCEPTANCE_NOTE)
    # A release is only deployable if nothing above failed.
    return {"verdict": "RELEASE_GATE_PASS" if not errors else "RELEASE_GATE_FAIL",
            "version": version, "errors": errors, "notes": notes,
            "deployable": not errors,
            "hardware_acceptance": HARDWARE_ACCEPTANCE_NOTE}


def self_test(release: Path) -> int:
    """Every mutant must be rejected. A gate that passes a mutant is not a gate."""
    cases = []
    work = Path(tempfile.mkdtemp(prefix="sc7f0-release-mutation-", dir=str(REPO / "build")))
    try:
        def clone(name: str) -> Path:
            dst = work / name
            shutil.copytree(release, dst, symlinks=True,
                            ignore=shutil.ignore_patterns("fpga/project", "fpga/project-logs"))
            return dst

        v = (release / "VERSION").read_text().strip()

        # 1. a required runtime member is gone from the package
        d = clone("missing-runtime")
        (d / "images" / "image.ub").unlink()
        cases.append(("missing image.ub member", d))

        # 2. the manifest no longer matches the payload
        d = clone("bad-manifest")
        tar = d / "release" / f"upgrade-{v}.tar"
        data = bytearray(tar.read_bytes())
        data[512 + 200] ^= 0xFF           # flip one payload byte of BOOT.BIN
        tar.write_bytes(bytes(data))
        cases.append(("payload changed under an unchanged manifest", d))

        # 3. manifest deleted
        d = clone("no-manifest")
        import io
        import tarfile
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as a:
            for m in read_members((d / "release" / f"upgrade-{v}.tar").read_bytes()):
                if m["name"] == "manifest.sha256":
                    continue
                info = tarfile.TarInfo(m["name"]); info.size = len(m["data"]); info.mode = 0o644
                a.addfile(info, io.BytesIO(m["data"]))
        (d / "release" / f"upgrade-{v}.tar").write_bytes(buf.getvalue() + bytes(10240 - len(buf.getvalue()) % 10240))
        cases.append(("manifest.sha256 removed from the tar", d))

        # 4. the bitstream is not the one the XSA carries (version/bit/XSA mismatch)
        d = clone("bit-mismatch")
        (d / "fpga" / "zu4ev_pcie_card_top.bit").write_bytes(b"not the built bitstream")
        cases.append(("bitstream does not match hardware.xsa", d))

        # 5. the PS image was built from a different XSA
        d = clone("ps-xsa-mismatch")
        m = _read_json(d / "PS_IMAGE_MATCH.json")
        m["ps_image_built_from_this_xsa_sha256"] = "0" * 64
        (d / "PS_IMAGE_MATCH.json").write_text(json.dumps(m, indent=2))
        cases.append(("PS image imported from another XSA", d))

        # 6. the strict gate record is absent
        d = clone("no-gate")
        (d / "gates" / "timing-gate-record.json").unlink()
        cases.append(("strict gate record missing", d))

        # 7. a forged gate record: claims pass, reports say otherwise
        d = clone("false-gate")
        (d / "gates" / "timing-gate-record.json").write_text(json.dumps(
            {"pass_gate": True, "errors": [], "margins_ns": {"WNS": 1, "WHS": 1, "WPWS": 1}}))
        (d / "gates" / "timing-gate-recheck.json").write_text(
            (d / "gates" / "timing-gate-record.json").read_text())
        (d / "fpga" / "timing_summary.rpt").write_text(
            "Design state: routed out of context\n"
            "WNS(ns) WHS(ns) TPWS(ns) TNS(ns) THS(ns) TPUA(ns) TNS LP TPWS LP\n"
            "-0.500 -0.250 -0.100 -12.000 -3.000 -1.000 40 20 10\n")
        cases.append(("forged gate record against failing reports", d))

        # 8. the runtime daemon is not really inside image.ub
        cases.append(("runtime binary missing from image.ub", release))
        failures = []
        for label, target in cases:
            expect = _read_json(target / "release.json") if (target / "release.json").is_file() else None
            if label.startswith("runtime binary"):
                # A runtime binary that the image does not contain must be reported,
                # exactly as sc7f0_vcud would have been if the recipe had not landed.
                result = evaluate(release, expect_runtime=["sc7f0_release_gate_probe=@present"])
                rejected = result["verdict"] != "RELEASE_GATE_PASS"
            else:
                result = evaluate(target)
                rejected = result["verdict"] != "RELEASE_GATE_PASS" and not result["deployable"]
            print(("REJECTED " if rejected else "ACCEPTED ") + "| " + label +
                  ("  " + result["errors"][0][:110] if result["errors"] else ""))
            if not rejected:
                failures.append(label)
        # and the untouched release must pass, or the mutants prove nothing
        baseline = evaluate(release)
        print(("BASELINE_PASS " if baseline["deployable"] else "BASELINE_FAIL ") +
              str(release) + ("  " + "; ".join(baseline["errors"][:3]) if baseline["errors"] else ""))
        if failures or not baseline["deployable"]:
            for f in failures:
                print("MUTANT_NOT_REJECTED " + f, file=sys.stderr)
            return 1
        print("RELEASE_NEGATIVE_TESTS_PASS " + str(len(cases)) + " mutants rejected")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--expect-runtime", action="append", default=None,
                        metavar="NAME=PATH|@present")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    if args.self_test:
        return self_test(args.release.resolve())
    result = evaluate(args.release.resolve(), args.expect_runtime)
    text = json.dumps(result, indent=2) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(text)
    for err in result["errors"]:
        print("FAIL " + err, file=sys.stderr)
    print(result["verdict"])
    return 0 if result["verdict"] == "RELEASE_GATE_PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
