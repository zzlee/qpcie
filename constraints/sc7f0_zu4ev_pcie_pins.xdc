## SC7F0 N1 HDMI2 V11 PCIe Pinout Constraints
## Target: xczu4ev-fbvb900-2-e
## PCIe Block: PCIE40E4_X0Y1, GT Quad: GTH_Quad_223 (Bank 223)

## PCIe Reference Clock (100 MHz from slot via U7 SI53102-A3-GMR)
set_property PACKAGE_PIN R8 [get_ports sys_clk_p]
set_property PACKAGE_PIN R7 [get_ports sys_clk_n]

## PCIe Reset PERST# (Slot Pin A11 -> Pin K11, Bank 46 HD Bank, 3.3V)
set_property PACKAGE_PIN K11 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]

## PCIe Transceiver Channels (GTH_Quad_223)
## Physical PCB Wiring has reversed lane order:
## Lane 0: GT3 (R4/R3, P2/P1)
## Lane 1: GT2 (T6/T5, T2/T1)
## Lane 2: GT1 (V6/V5, U4/U3)
## Lane 3: GT0 (W4/W3, W1/V1)
## Note: GTH differential transceiver pairs are dedicated MGT pins;
## Vivado GTHE4_CHANNEL placement automatically handles them when bound to Quad 223.
