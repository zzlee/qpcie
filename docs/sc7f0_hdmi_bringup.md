# SC7F0 HDMI V11: full-profile05 bring-up candidate

**Experimental, not a release. No board flash or HDMI signal test performed.**
Validated debug04 is preserved. The existing full profile instantiated HDMI IP
but tied off its CPU ports, left TX DDC undriven, and had a separate EDID engine
on the RX pads. This change makes those control connections usable candidates;
it does not claim working V4L2/ALSA HDMI capture.

## Primary source and ownership

`~/llm-wiki/raw/SC7F0_N1_HDMI2_V11/SC7F0 N1 HDMI2 V11.pdf`, 36 sheets,
2024-01-23. Pin map checked against sheet11 image and text; sheets14/16 define
HDMI signal paths; sheets28/29 define the clock sources. Wiki summaries are
cross-references, not authoritative substitutes for the schematic.

```
HDMI2 input -> IT6663 RX -> P1TX TMDS -> Quad226 GTH RX -> HDMI RX SS
                                                    -> AXIS video -> async FIFO -> PCIe DMA
                                                    -> AXIS audio -> bridge -> PCIe DMA

PCIe H2C -> video/audio bridges -> HDMI TX SS -> Quad226 GTH TX
                             + AH6/AJ6 TMDS clock -> IT66318 -> HDMI1 output

PS I2C1 (ff030000) -> NUC1262 I2C0 slave -> MCU I2C1 -> IT6663 control
```

The MCU still must initialise IT6663 through its **PCSCL/PCSDA control bus**.
PL RX DDC is the **sink/slave** of IT6663 P1TX, not an alternate control-master
path to the splitter. TX DDC is the **source/master** through IT66318 to the
display. Use the DDC engines built into the AMD subsystems, not a second AXI IIC
master on the same pads. No fly wires or MCU bypass are assumed.

Audio is embedded in TMDS, extracted/inserted by the HDMI subsystems. It is not
the board's separate analog ADC/DAC I2S path.

## Schematic pin audit

| Signal | FPGA pins | Source/meaning |
|---|---|---|
| RX TMDS data D0/1/2 | D2/D1, C4/C3, B2/B1 | U11-10, GTH RX Quad226 |
| TX TMDS data D0/1/2 | D6/D5, C8/C7, B6/B5 | U11-10, GTH TX Quad226 |
| RX TMDS reference | B10/B9 | X0_HRX0_CK, Quad226 MGTREFCLK1 |
| TX PHY reference | D10/D9 | X0_H0_REFCK0, Si5319 via Si53102 buffer |
| DRU reference | F10/F9 | X0_HDMI_DRU_CK, **Quad225 MGTREFCLK1**, sheet28 156.25 MHz |
| TX forwarded TMDS clock | AH6/AJ6 | X0_HTX0_CK, bank65 1.8V LVDS |
| RX DDC SCL/SDA | D14/C13 | X0_HRX, IT6663 P1TX |
| RX HPD / input detect | B12 / A12 | X0_HRX_HPD / X0_HRX_DET |
| TX DDC SCL/SDA | F12/E12 | X0_HTX0, IT66318 RX DDC |
| TX HPD / reference status | G14 / G13 | X0_HTX0_HPD / X0_5319_LOL |

G13 is **loss-of-lock**, not active-high ready. Existing PHY inversion
`C_Txrefclk_Rdy_Invert=true` is retained. Reference frequencies in XDC are
design assumptions; RX/TX line rates change with video mode and require PHY
software programming. DRU comes from Si5341 OUT4; sheet29 shows Si5319 XA/XB
fed from Si5341 and an optional FPGA recovered-clock input CKIN1. Genlock via
X0_H0_RECKO is not implemented by this change.

## New PS control path

Full profile enables PS **HPM1_FPD**, AXI4 -> AXI4-Lite conversion (40-bit
address, 32-bit data, 16-bit IDs), and a 1x3 crossbar. All register ports run
on `pl_clk0` (~100 MHz), reset from PS, without needing PCIe link/video clocks.
HDMI sideband clock is also `pl_clk0`; data streams retain their native clocks.

| PS physical address | Size decoded by crossbar | Target |
|---|---|---|
| `0xB0000000` | 4 KiB | Video PHY, low 10 address bits |
| `0xB0010000` | 64 KiB | HDMI RX SS, low 9 address bits |
| `0xB0020000` | 128 KiB | HDMI TX SS, low 17 address bits |

The PS HPM1 low-address aperture starts at **B0000000**, not the HPM0 A0000000
aperture used by debug/upgrade CSRs. BD validation enforces this. Unmapped
crossbar holes return DECERR. Inside decoded windows, offsets above each IP's
real register range can alias: use only the actual AMD driver-defined offsets.
The old BAR0 debug/upgrade mapping is unchanged; new HDMI registers are **PS-only**
(Host access is intended through the existing PS debug RPC, not PCIe BAR1).

Full-profile C_VERSION is overridden to **26101505** before target generation.
Default debug profile remains **26101504**, with no HPM1/HDMI external pins.
This does not change either profile's existing generic channel-count choices.

## RTL changes

- Connect PHY/RX/TX AXI CPU ports to the PS control crossbar.
- One RX DDC pad owner: RX SS controls physical EDID/DDC and HPD. Legacy BAR1
  EDID aperture no longer drives a RAM onto the bus; reads return zero.
- RX/TX IOBUF wrappers never drive a logic high (open-drain + readback).
- Synchronise reset release into RX/TX video/link clocks.
- Gate FIFO handshakes during reset/reset-busy and TX-disable; use FWFT output.
- Remove fabricated RX 48kHz/24-bit telemetry and fabricated TX PLL-lock status.
- Constrain the six TMDS data lane pairs explicitly; remove blanket asynchronous
  clock-group exceptions so remaining CDC/timing problems stay visible.

## Build / tests

```sh
make fpga-zu4ev-hdmi-ip
make fpga-zu4ev-hdmi-synth
make test-sc7f0-hdmi
source /opt/Xilinx/Vivado/2023.2/settings64.sh
vivado -mode batch -source scripts/sim_sc7f0_hdmi_control.tcl
vivado -mode batch -source scripts/check_sc7f0_hdmi_bd.tcl
# Re-use generated IP for RTL/XDC rebuild and route-only review (no bitstream):
SC7F0_HDMI_ROUTE=1 vivado -mode batch -source scripts/continue_sc7f0_hdmi.tcl
```

Full project: `build/qpcie_zu4ev_hdmi_proj/`; debug project remains
`build/qpcie_zu4ev_proj/`. Build wrapper no longer deletes the debug directory
when asked to build a full candidate. IP-only/synthesis-only stages cannot flash,
repackage PS images or export an XSA. Even a full bitstream run deliberately
withholds XSA publication until full-profile timing/CDC and software are reviewed.

Test scopes:
- Tcl pin-map regression: sheet11 pin assignments and lane order.
- Icarus DDC pads: release/low/clock-stretch/readback, no push-pull high.
- Real XPM bridge simulation: independent video/audio/PCIe clocks, packing,
  ordering, backpressure, reset gating, disabled TX rejecting DMA input.
- Real production crossbar simulation with dummy register banks: three banks,
  split AW/W, response stalls, TX upper range, holes returning DECERR.
- PS BD validation: HPM1 address aperture and inferred active-low reset.

None of these simulates HDMI TMDS lock, encrypted-IP protocol behaviour, the PS
hard block, real MCU firmware, or end-to-end V4L2/ALSA operation.

### Validation progress (2026-10-15)

- All four `make test-sc7f0-hdmi` suites: TB_PASS.
- Full PS BD validation: HDMI_BD_PASS (HPM1 B0000000 aperture; active-low reset).
- Debug04 preprocessed top is token-identical to HEAD before this HDMI change.
- Initial full top synthesis: 0 errors; 43,494 LUTs (49.52%), 68 BRAM tiles
  (53.13%), 9 DSPs. One critical warning rejected an XDC `foreach`; replaced
  by explicit per-port pin assignments and started a fresh synthesis/route review.
- Latest synthesis/route results are pending. `continue_sc7f0_hdmi.tcl` refuses
  implementation if synthesis reports a critical warning, and never writes a
  bitstream or exports an XSA. Successful routing alone is not timing closure.
- Existing DMA 128/256-bit width warnings remain a separate end-to-end capture
  review item; HDMI bridge tests do not validate those downstream DMA paths.

### Validation progress (2026-10-16)

- **MCU Firmware v1.1.7 (`0x12620107`) Brought Up & Flashed Over PCIe**:
  - Full In-System Programming over PCIe using `scripts/sc7f0_mcu_flash.py`:
    APROM flashed in 1.71s via slave `0x2A` without external hardware or JTAG.
  - IT6663 chip detected: Vendor ID `0x54 0x49` ("IT"), Device ID `0x63 0x66`, Rev `0xA0`.
  - All internal sub-devices configured and ACK on I2C1:
    - `0x2C`: Main Switch / Control
    - `0x38`: RXP0 (HDMI RX Port 0 core)
    - `0x4B`: TXCom (TX Common)
    - `0x34..0x37`: TXP0, TXP1 (to FPGA GTH), TXP2 (Loopout), TXP3
    - `0x48`: NCT7717 Temperature Sensor (reading ~53-54°C)
    - `0x6C`: IT6663 Internal EDID RAM
  - **Dynamic EDID Upload from Host -> MCU -> IT6663 Verified**:
    - Host uploads 256-byte EDID over PCIe via `sc7f0_mcu_flash.py --set-edid <file.bin>`.
    - MCU automatically calculates Block 0 / Block 1 checksums and programs hardware registers `0xC9` / `0xCA`.
    - MCU pulses HPD LOW (50ms) and re-asserts HIGH to force source renegotiation.
    - Host can read back active EDID anytime via `sc7f0_mcu_flash.py --get-edid <file.bin>` or I2C slave `0x50`.
  - **Live Hardware Telemetry via `sc7f0_mcu_flash.py --status`**:
    - Real-time 5V Cable Detect (`hdmi_5v`), SCDT Clock Lock (`clock_locked_scdt`),
      HDMI/DVI mode (`hdmi_mode`), active resolution (`resolution`), temperature, and slave list.

## Remaining release blockers / next steps

1. Finish full top synthesis and review implementation, generated clocks, FIFO
   reset contracts, setup/hold/skew/CDC and IP licence status. Do not apply the
   debug04 gate's fixed CDC whitelist blindly to the new HDMI clock topology.
2. Add the matching PS-side AMD PHY/RX/TX driver control and interrupt handling;
   poll-only register wiring is not a complete HDMI application. RTL-instantiated
   HDMI IP is not automatically described as a Linux device by the PS BD HWH.
3. Extend the exact-version debug daemon/driver/tool allowlists for candidate05
   before any deployment. Current debug04 binaries intentionally reject05; the
   existing Host legacy AV probe sequence must be reviewed, not blindly reused.
4. **[RESOLVED]** MCU returns valid IT6663 identity/init status, configures TXP1 to FPGA,
   and serves 4K HDR EDID / dynamic host EDID with HPD pulsing.
5. Verify RX RGB component ordering, SOF/EOL and recovery from downstream DMA
   stalls using real HDMI timing. Record measured audio rate/channels/width and
   preserve HDMI audio TID/channel semantics before claiming ALSA correctness.
6. TX ACR currently retains the old fixed CTS/N inputs (148500/6144). This is
   **not general audio clock recovery**; add programmable/properly clocked ACR
   for supported modes before enabling HDMI audio output. Likewise, do not
   describe raw 32-bit AXIS audio forwarding as validated PCM conversion.
7. Only after matching XSA/PetaLinux/FSBL packaging and all gates pass, produce
   a separate bundle and perform VERIFY -> COMMIT -> board POR + acceptance.
   Keep debug04 rollback images and never reboot the Host as a substitute.
