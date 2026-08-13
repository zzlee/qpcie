create_project proj_tmp ./tmp_proj -part xcku3p-ffva676-2-e -force
create_ip -name pcie4_uscale_plus -vendor xilinx.com -library ip -version 1.3 -module_name pcie_test
foreach prop [list_property [get_ips pcie_test]] {
    if {[string match "CONFIG.*" $prop]} {
        puts "$prop = [get_property $prop [get_ips pcie_test]]"
    }
}
exit
