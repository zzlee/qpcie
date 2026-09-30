# ==============================================================================
# Pre-Implementation Script for ZU4EV SC7F0 Tandem PCIe & HDMI
# ==============================================================================

# Downgrade HDTC-10 (Config banks not available to second stage I/O) to Warning
# Pin AH6/AJ6 (TX TMDS Clk) is located in Bank 65 (Stage 2 I/O).
set_property SEVERITY {Warning} [get_drc_checks HDTC-10]

# Downgrade HDTC-18 (Stage 1 Pblock boundary alignment) to Warning if encountered
catch {set_property SEVERITY {Warning} [get_drc_checks HDTC-18]}
catch {set_property SNAPPING_MODE ON [get_pblocks -hierarchical *Stage1_main*]}
