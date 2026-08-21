# Write MCS format for Macronix 128Mb SPI Flash (MX25L12872F - SPIx1 Interface)
write_cfgmem -format mcs -size 16 -interface SPIx4 -loadbit "up 0x00000000 ./build/qpcie_a50t_proj/qpcie_a50t_card.runs/impl_1/a50t_pcie_card_top.bit" -file ./a50t_pcie_card_top.mcs -force
puts "================================================================="
puts " 🎉 SUCCESS: Generated MCS file for SPI Flash!"
puts " Location: ./a50t_pcie_card_top.mcs"
puts "================================================================="
exit
