"""Enforce actual binary sizes, including linker orphan sections."""
from pathlib import Path

for name, limit in (("stage0.bin", 2048), ("app.bin", 8192),
                    ("app_v5.bin", 8192), ("ldrom.bin", 4096)):
    size = Path(__file__).with_name(name).stat().st_size
    if size > limit:
        raise SystemExit(f"{name}: {size} exceeds {limit}-byte budget")
