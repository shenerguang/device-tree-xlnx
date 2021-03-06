#
# common procedures
#
proc get_clock_frequency {ip_handle portname} {
	set clk ""
	set clkhandle [get_pins -of_objects $ip_handle $portname]
	if {[string compare -nocase $clkhandle ""] != 0} {
		set clk [get_property CLK_FREQ $clkhandle ]
	}
	return $clk
}

proc set_drv_conf_prop args {
	set drv_handle [lindex $args 0]
	set pram [lindex $args 1]
	set conf_prop [lindex $args 2]
	set ip [get_cells $drv_handle]
	set value [get_property CONFIG.${pram} $ip]
	if { [llength $value] } {
		regsub -all "MIO( |)" $value "" value
		if { $value != "-1" && [llength $value] !=0  } {
			if {[llength $args] >= 4} {
				set type [lindex $args 3]
				if {[string equal -nocase $type "boolean"]} {
					set_boolean_property $drv_handle $value ${conf_prop}
					return 0
				}
				set_property ${conf_prop} $value $drv_handle
				set prop [get_comp_params ${conf_prop} $drv_handle]
				set_property CONFIG.TYPE $type $prop
				return 0
			}
			set_property ${conf_prop} $value $drv_handle
		}
	}
}

proc set_boolean_property {drv_handle value conf_prop} {
	if {[expr $value >= 1]} {
		set_property ${conf_prop} "" $drv_handle
		set prop [get_comp_params ${conf_prop} $drv_handle]
		set_property CONFIG.TYPE referencelist $prop
	}
}

proc add_cross_property args {
	set src_handle [lindex $args 0]
	set src_prams [lindex $args 1]
	set dest_handle [lindex $args 2]
	set dest_prop [lindex $args 3]
	set ip [get_cells $src_handle]
	foreach conf_prop $src_prams {
		set value [get_property ${conf_prop} $ip]
		if { [llength $value] } {
			if { $value != "-1" && [llength $value] !=0  } {
				set type "hexint"
				if {[llength $args] >= 5} {
					set type [lindex $args 4]
					if {[string equal -nocase $type "boolean"]} {
						set type referencelist
						if {[expr $value >= 1]} {
							hsm::utils::add_new_property $dest_handle $dest_prop $type ""
						}
						return 0
					}
				}
				hsm::utils::add_new_property $dest_handle $dest_prop $type $value
				return 0
			}
		}
	}
}

proc get_ip_property {drv_handle parameter} {
	set ip [get_cells $drv_handle]
	return [get_property ${parameter} $ip]
}

proc is_it_in_pl {ip} {
	# FIXME: This is a workaround to check if IP that's in PL however,
	# this is not entirely correct, it is a hack and only works for
	# IP_NAME that does not matches ps7_*
	# better detection is required

	# handles interrupt that coming from get_drivers only
	if {[llength [get_drivers $ip]] < 1} {
		return -1
	}
	set ip_type [get_property IP_NAME $ip]
	if {![regexp "ps7_*" "$ip_type" match]} {
		return 1
	}
	return -1
}

#
# HSM 2014.2 workaround
# This proc is designed to generated the correct interrupt cells for both
# MB and Zynq
proc get_intr_id { periph_name intr_port_name } {
	set intr_info -1
	set ip [get_cells $periph_name]

	set intr_pin [get_pins -of_objects $ip $intr_port_name -filter "TYPE==INTERRUPT"]
	if { [llength $intr_pin] == 0 } {
		return -1
	}

	# identify the source controller port
	set intc_port ""
	set intc_periph ""
	set intr_sink_pins [xget_sink_pins $intr_pin]
	foreach intr_sink $intr_sink_pins {
		set sink_periph [get_cells -of_objects $intr_sink]
		if { [is_interrupt_controller $sink_periph] == 1} {
			set intc_port $intr_sink
			set intc_periph $sink_periph
			break
		}
	}
	if {$intc_port == ""} {
		return -1
	}

	# workaround for 2014.2
	# get_interrupt_id returns incorrect id for Zynq
	# issue: the xget_interrupt_sources returns all interrupt signals
	# connected to the interrupt controller, which is not limited to IP
	# in PL
	set intc_type [get_property IP_NAME $intc_periph]
	# CHECK with Heera for zynq the intc_src_ports are in reverse order
	if { [string match -nocase $intc_type "ps7_scugic"] } {
		set ip_param [get_property CONFIG.C_IRQ_F2P_MODE $intc_periph]
		if { [string match -nocase "$ip_param" "REVERSE"]} {
			set intc_src_ports [xget_interrupt_sources $intc_periph]
		} else {
			set intc_src_ports [lreverse [xget_interrupt_sources $intc_periph]]
		}
		set total_intr_count -1
		foreach intc_src_port $intc_src_ports {
			set intr_periph [get_cells -of_objects $intc_src_port]
			if { [string match -nocase $intc_type "ps7_scugic"] } {
				if {[is_it_in_pl "$intr_periph"] == 1} {
					incr total_intr_count
					continue
				}
			}
		}
	} else {
		set intc_src_ports [xget_interrupt_sources $intc_periph]
	}

	set i 0
	set intr_id -1
	set ret -1
	foreach intc_src_port $intc_src_ports {
		if { [llength $intc_src_port] == 0 } {
			incr i
			continue
		}
		set intr_periph [get_cells -of_objects $intc_src_port]
		set ip_type [get_property IP_NAME $intr_periph]
		if { [string compare -nocase "$intr_port_name"  "$intc_src_port" ] == 0 } {
			if { [string compare -nocase "$intr_periph" "$ip"] == 0 } {
				set ret $i
				break
			}
		}
		if { [string match -nocase $intc_type "ps7_scugic"] } {
			if {[is_it_in_pl "$intr_periph"] == 1} {
				incr i
				continue
			}
		} else {
			incr i
		}
	}

	if { [string match -nocase $intc_type "ps7_scugic"] && [string match -nocase $intc_port "IRQ_F2P"] } {
		set ip_param [get_property CONFIG.C_IRQ_F2P_MODE $intc_periph]
		if { [string match -nocase "$ip_param" "REVERSE"]} {
			set diff [expr $total_intr_count - $ret]
			if { $diff < 8 } {
				set intr_id [expr 91 - $diff]
			} elseif { $diff  < 16} {
				set intr_id [expr 68 - ${diff} + 8 ]
			}
		} else {
			if { $ret < 8 } {
				set intr_id [expr 61 + $ret]
			} elseif { $ret  < 16} {
				set intr_id [expr 84 + $ret - 8 ]
			}
		}
	} else {
		set intr_id $ret
	}

	if { [string match -nocase $intr_id "-1"] } {
		set intr_id [xget_port_interrupt_id "$periph_name" "$intr_port_name" ]
	}

	if { [string match -nocase $intr_id "-1"] } {
		return -1
	}

	# format the interrupt cells
	set intc [get_connected_interrupt_controller $periph_name $intr_port_name]
	set intr_type [hsm::utils::get_dtg_interrupt_type $intc $ip $intr_port_name]
	if {[string match "[get_property IP_NAME $intc]" "ps7_scugic"]} {
		if { $intr_id > 32 } {
			set intr_id [expr $intr_id - 32]
		}
		set intr_info "0 $intr_id $intr_type"
	} else {
		set intr_info "$intr_id $intr_type"
	}
	return $intr_info
}
