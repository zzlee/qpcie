# Coordinator → KMS driver: frozen candidate 0x26112407

`26112405` and `26112406` were withdrawn before Vivado started; neither is a
hardware acceptance image. The normative register map is
`sc7f0_direct_pull_v1.md`. Register offsets and capability `0x44500101` have
not moved. On 26112403 this optional block is absent.

| Boundary | What driver may rely on |
|---|---|
| Normal disable | Stop accepting descriptor writes, quiesce new reads, wait through any already presented RQ header and its completion. `CTRL=0, STATUS=1, ACTIVE=PENDING=0`, expected `ADMITTED`, matching capability together prove clean DMA drain. |
| Soft reset / unexpected ingress failure during use | `FAULT=1`, `DRAINED=0` sticky. Do not post a success event or unmap on timeout. No soft reset, mode toggle, IRQ or zero cookie clears the fault. |
| PCIe-only reset after *any* admission | `pcie_user_rst_n = pcie_user_lnk_up && !pcie_user_reset` resets the working scheduler and epoch-ready latch. It does **not** reset the configuration-initialized `ADMITTED` high-water register. Once PCIe clocks resume, `FAULT=1`, `DRAINED=0` even if the prior session had drained. Delayed output SOFs cannot promote anything. Both old and new submits are rejected. A zero or inaccessible BAR during reset is not a fence. |
| PCIe-only reset before first admission | No admitted source or PCIe read exists for this ABI. After reset, valid idle must still be verified. |
| Driver reload, no HW reset | Clean drained idle only: next cookie strictly greater than `ADMITTED`. Never wrap, never infer acceptance by reusing the previous cookie. |
| Physical recovery | Quarantine mappings until the host establishes device teardown and bus-master quiescence. Full PL reconfiguration starts the next cookie namespace and flushes video-side state. A fresh zero high-water mark is not proof that an old mapping was released. |

Reproducible simulation logs in `build/rgb-vcu-flip-26112407/logs/`:
`reset_active.log` (old active, replacement pending, late ACK),
`reset_drained.log` (lost PCIe epoch after clean disable), and `cadence.log`
(soft reset, sticky fault, retained serial, refused rearm; 600 replay frames).
`tb/sc7f0_flip_rq_drain_tb.sv` additionally drives actual ingress and RQ
encoder backpressure while disabling.

No candidate routed timing, boot/readback or hardware KMS validation is implied
by this handoff. Validate the matching bit/XSA, then the actual booted PL
version/capability before binding the KMS test.
