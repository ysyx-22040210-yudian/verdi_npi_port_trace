# npi_port_trace.tcl
#
# For each instance of a given module, iterate its ports, trace drivers
# and loads for the connected net, and output CSV.
#
# CSV columns: inst_full_name, port_name, port_dir, role, signal_full_name
#
# Usage (via npi_trace.sh):
#   verdi -batch -nologo -play npi_port_trace.tcl \
#         +tclarg_filelist <filelist.f> \
#         +tclarg_incdir   <include_dir> \
#         +tclarg_top      <top_module> \
#         +tclarg_module   <target_module> \
#         +tclarg_srcfile  <module_source.v>
#
# All +tclarg_* values are passed as Tcl variables by Verdi's +tclarg mechanism.

if { [info exists env(VERDI_HOME)] } {
    source $env(VERDI_HOME)/share/NPI/L1/TCL/npi_L1.tcl
} elseif { [info exists env(NPIL1_PATH)] } {
    source $env(NPIL1_PATH)/npi_L1.tcl
} else {
    puts stderr "ERROR: VERDI_HOME or NPIL1_PATH must be set"
    exit 1
}

# -----------------------------------------------------------------------
# Required arguments — read from environment variables
# -lib mode: only NPI_MODULE is required
# -filelist mode: NPI_FILELIST, NPI_TOP, NPI_MODULE are required
# NPI_SRCFILE is now optional (deprecated, kept for backward compatibility)
# -----------------------------------------------------------------------
set use_lib [expr { [info exists env(NPI_LIB)] && $env(NPI_LIB) ne "" }]

# Only NPI_MODULE is required
if { ![info exists env(NPI_MODULE)] || $env(NPI_MODULE) eq "" } {
    puts stderr "ERROR: environment variable NPI_MODULE is not set"
    debExit
}
set target_mod $env(NPI_MODULE)

# NPI_SRCFILE is optional (deprecated)
set srcfile ""
if { [info exists env(NPI_SRCFILE)] && $env(NPI_SRCFILE) ne "" } {
    set srcfile $env(NPI_SRCFILE)
}

if { !$use_lib } {
    foreach { varname envname } {
        filelist   NPI_FILELIST
        top_module NPI_TOP
    } {
        if { ![info exists env($envname)] || $env($envname) eq "" } {
            puts stderr "ERROR: environment variable $envname is not set (required when not using -lib)"
            debExit
        }
        set $varname $env($envname)
    }
}
set incdir [expr { [info exists env(NPI_INCDIR)] ? $env(NPI_INCDIR) : "" }]

# Optional: comma-separated list of ports to filter (empty = all ports)
set port_filter {}
if { [info exists env(NPI_PORTS)] && $env(NPI_PORTS) ne "" } {
    foreach p [split $env(NPI_PORTS) ","] {
        set p [string trim $p]
        if { $p ne "" } { lappend port_filter $p }
    }
}

# Output file (written by shell via NPI_OUTFILE env var)
if { [info exists env(NPI_OUTFILE)] && $env(NPI_OUTFILE) ne "" } {
    set outfh [open $env(NPI_OUTFILE) w]
} else {
    set outfh stdout
}

# Optional side output: module-boundary driver/load connections.
# This file only receives entries found with passMod=0, i.e. trace results
# that stop at module ports instead of crossing through the module boundary.
set module_outfh ""
if { [info exists env(NPI_MODULE_OUTFILE)] && $env(NPI_MODULE_OUTFILE) ne "" } {
    set module_outfh [open $env(NPI_MODULE_OUTFILE) w]
}

# -----------------------------------------------------------------------
# Load design
# -----------------------------------------------------------------------
if { $use_lib } {
    if { [catch { debImport -elab $env(NPI_LIB) } e] } {
        puts stderr "ERROR: debImport -elab failed: $e"
        debExit
    }
} elseif { $incdir ne "" } {
    debImport -f $filelist +incdir+$incdir -top $top_module -sv
} else {
    debImport -f $filelist -top $top_module -sv
}

# -----------------------------------------------------------------------
# Build port -> direction map by parsing the module source file
# -----------------------------------------------------------------------
proc build_port_dir_map { srcfile target_mod } {
    set fh [open $srcfile r]
    set lines [split [read $fh] "\n"]
    close $fh

    set map {}
    set in_module 0
    foreach line $lines {
        set t [string trim $line]
        if { [regexp {^module\s+} $t] && [string match "module ${target_mod} *" $t] ||
             [regexp {^module\s+} $t] && [string match "module ${target_mod}(*" $t] ||
             [regexp {^module\s+} $t] && [string match "module ${target_mod}#*" $t] ||
             $t eq "module ${target_mod}" } {
            set in_module 1
        }
        if { $in_module } {
            if { [regexp {^\s*(input|output|inout)\s+(?:reg\s+)?(?:wire\s+)?(?:\[[^\]]*\]\s+)?(\w+)} $t -> dir portname] } {
                dict set map $portname $dir
            }
            if { [regexp {\);\s*$} $t] || [regexp {^endmodule} $t] } {
                set in_module 0
            }
        }
    }
    return $map
}

# -----------------------------------------------------------------------
# Get ordered port list from npi_mod_inst_get_port
# Returns list of port handles.
# -----------------------------------------------------------------------
proc get_io_handles { inst_path } {
    set hdlList {}
    if { [catch {
        ::npi_L1::npi_mod_inst_get_io $inst_path hdlList
    } e] } {
        puts stderr "WARNING: npi_mod_inst_get_io failed for $inst_path: $e"
        return {}
    }
    return $hdlList
}

proc get_port_handles { inst_path } {
    set hdlList {}
    if { [catch {
        ::npi_L1::npi_mod_inst_get_port $inst_path hdlList
    } e] } {
        puts stderr "WARNING: npi_mod_inst_get_port failed for $inst_path: $e"
        return {}
    }
    return $hdlList
}

# -----------------------------------------------------------------------
# Get port name from port handle
# -----------------------------------------------------------------------
proc get_port_name { port_hdl } {
    set info ""
    catch { set info [::npi_L1::npi_ut_get_hdl_info $port_hdl] }
    # format: "npiPort, portname, {file : line}"
    set portname [string trim [lindex [split $info ","] 1]]
    return $portname
}

# -----------------------------------------------------------------------
# Get port direction from port handle using NPI API
# Returns: "input", "output", "inout", or "unknown"
# -----------------------------------------------------------------------
proc get_port_direction { port_hdl } {
    set dir_val -1
    if { [catch { set dir_val [::npi_L1::npi_nl_get npiNlDirection $port_hdl] } err] } {
        return "unknown"
    }

    # npiInput = 1, npiOutput = 2, npiInout = 3 (standard NPI constants)
    if { $dir_val == 1 } {
        return "input"
    } elseif { $dir_val == 2 } {
        return "output"
    } elseif { $dir_val == 3 } {
        return "inout"
    } else {
        return "unknown"
    }
}

# -----------------------------------------------------------------------
# Resolve a driver/load handle to its full signal name
# -----------------------------------------------------------------------
proc hdl_to_name { hdl } {
    set info ""
    catch { set info [::npi_L1::npi_nl_ut_get_hdl_info $hdl] }
    return [string trim [lindex [split $info ","] 1]]
}

# -----------------------------------------------------------------------
# True module-boundary endpoints are hierarchical nets/ports/instports.
# Trace results can also include generated cells from expressions, always
# blocks, memories, or reg-combo logic; keep those in the main CSV only.
# -----------------------------------------------------------------------
proc is_module_boundary_signal { signame } {
    if { $signame eq "" } {
        return 0
    }

    foreach bad {
        "/" "(@" "_ExprInst__"
        "Always" "Initial" "Init" "SigOp"
        "Combo" "RegCombo" "ComboMemory"
    } {
        if { [string first $bad $signame] >= 0 } {
            return 0
        }
    }

    return [regexp {^[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*)(\[[0-9]+(:[0-9]+)?\])?(\.[A-Za-z_][A-Za-z0-9_$]*(\[[0-9]+(:[0-9]+)?\])?)*$} $signame]
}

# -----------------------------------------------------------------------
# Format signal name for better readability
# Remove common prefix and simplify the output
# -----------------------------------------------------------------------
proc format_signal_name { signame inst_path } {
    # Extract the common prefix (up to the target module's parent)
    set inst_parts [split $inst_path "."]
    set common_prefix [join [lrange $inst_parts 0 end-2] "."]

    # Remove common prefix if signal starts with it
    if { $common_prefix ne "" && [string match "${common_prefix}.*" $signame] } {
        set signame [string range $signame [expr {[string length $common_prefix] + 1}] end]
    }

    # Simplify the format: extract key information
    # Format: module:block:line:type.signal
    if { [regexp {([^:]+):([^:]+):([^:]+):([^:]+):([^.]+)\.(.+)} $signame -> mod block line1 line2 type sig] } {
        return "${mod}/${block}:${line1}-${line2}/${type}.${sig}"
    } elseif { [regexp {([^:]+):([^:]+):([^:]+):([^.]+)\.(.+)} $signame -> mod block line type sig] } {
        return "${mod}/${block}:${line}/${type}.${sig}"
    }

    return $signame
}

# -----------------------------------------------------------------------
# Process one instance: emit CSV rows for all its ports
# -----------------------------------------------------------------------
proc process_instance { inst_path parent_path instname port_filter outfh module_outfh } {
    # Get IO handles for port direction lookup (needed for internal logic)
    set io_hdl_list [get_io_handles $inst_path]

    # Build port name -> direction map from IO handles
    set port_dir_map {}
    foreach io_hdl $io_hdl_list {
        set portname [get_port_name $io_hdl]
        if { $portname ne "" } {
            set dir [get_port_direction $io_hdl]
            dict set port_dir_map $portname $dir
        }
    }

    # Get port handles for connection tracing
    set port_hdl_list [get_port_handles $inst_path]
    if { [llength $port_hdl_list] == 0 } {
        puts stderr "WARNING: no ports found for $inst_path"
        return
    }

    # Get high-side connections (parent scope nets) and low-side connections (child scope)
    set port2highList {}
    set port2lowList {}
    if { [catch {
        ::npi_L1::npi_inst_port_2_high_conn_sig $inst_path port2highList
    } e] } {
        puts stderr "WARNING: npi_inst_port_2_high_conn_sig failed for $inst_path: $e"
    }
    if { [catch {
        ::npi_L1::npi_inst_port_2_low_conn_sig $inst_path port2lowList
    } e] } {
        puts stderr "WARNING: npi_inst_port_2_low_conn_sig failed for $inst_path: $e"
    }

    # Build maps: port_handle -> list of signal handles
    set high_conn_map {}
    foreach pair $port2highList {
        set ph [lindex $pair 0]
        set sigList [lindex $pair 1]
        dict set high_conn_map $ph $sigList
    }

    set low_conn_map {}
    foreach pair $port2lowList {
        set ph [lindex $pair 0]
        set sigList [lindex $pair 1]
        dict set low_conn_map $ph $sigList
    }

    # Process each port
    foreach port_hdl $port_hdl_list {
        set portname [get_port_name $port_hdl]
        if { $portname eq "" } { continue }

        # Skip if port filter is active and this port is not in the list
        if { [llength $port_filter] > 0 && [lsearch -exact $port_filter $portname] < 0 } {
            continue
        }

        # Get direction from the map (for internal logic only, not output)
        set dir "unknown"
        if { [dict exists $port_dir_map $portname] } {
            set dir [dict get $port_dir_map $portname]
        }

        # Get high-side and low-side connected signals
        set high_sigs {}
        set low_sigs {}
        if { [dict exists $high_conn_map $port_hdl] } {
            set high_sigs [dict get $high_conn_map $port_hdl]
        }
        if { [dict exists $low_conn_map $port_hdl] } {
            set low_sigs [dict get $low_conn_map $port_hdl]
        }

        if { [llength $high_sigs] == 0 && [llength $low_sigs] == 0 } {
            puts $outfh "$inst_path,$portname,driver,ERROR:no_connections"
            puts $outfh "$inst_path,$portname,load,ERROR:no_connections"
            continue
        }

        # Determine which side to trace based on port direction
        # For INPUT ports: driver is on high-side (parent), load is on low-side (child)
        # For OUTPUT ports: driver is on low-side (child), load is on high-side (parent)
        set driver_sigs {}
        set load_sigs {}

        if { $dir eq "input" } {
            set driver_sigs $high_sigs
            set load_sigs $low_sigs
        } elseif { $dir eq "output" } {
            set driver_sigs $low_sigs
            set load_sigs $high_sigs
        } else {
            # For unknown direction, trace both sides
            set driver_sigs [concat $high_sigs $low_sigs]
            set load_sigs [concat $high_sigs $low_sigs]
        }

        # Collect all drivers
        set all_drivers {}
        set module_drivers {}
        foreach sig_hdl $driver_sigs {
            # Try different methods to get signal info
            set signame ""

            # Method 1: Try npi_nl_ut_get_hdl_info (for netlist objects)
            if { [catch {
                set sig_info [::npi_L1::npi_nl_ut_get_hdl_info $sig_hdl]
                set signame [string trim [lindex [split $sig_info ","] 1]]
            }] } {}

            # Method 2: If empty, try npi_ut_get_hdl_info (for general objects)
            if { $signame eq "" } {
                if { [catch {
                    set sig_info [::npi_L1::npi_ut_get_hdl_info $sig_hdl]
                    set signame [string trim [lindex [split $sig_info ","] 1]]
                }] } {}
            }

            # Method 3: If still empty, try to convert handle to net and get name
            if { $signame eq "" } {
                # Try to get net handle if this is a port/instport
                set net_hdl ""
                if { [catch {
                    set net_hdl [::npi_L1::npi_nl_port_instport_2_net $sig_hdl]
                }] } {}

                if { $net_hdl ne "" && $net_hdl != 0 } {
                    if { [catch {
                        set sig_info [::npi_L1::npi_nl_ut_get_hdl_info $net_hdl]
                        set signame [string trim [lindex [split $sig_info ","] 1]]
                    }] } {}
                }
            }

            if { $signame eq "" } {
                continue
            }

            # Trace drivers
            set driverList {}
            set r [::npi_L1::npi_nl_trace_driver $signame driverList 0 1]

            # If no drivers found, try handle-based tracing
            # Note: return value can be 1 (success) or 2 (success with some condition)
            # Only retry if driverList is actually empty
            if { [llength $driverList] == 0 } {
                set driverList {}
                catch { ::npi_L1::npi_nl_trace_driver_by_hdl $sig_hdl driverList 0 1 }
            }

            foreach hdl $driverList {
                set sig [hdl_to_name $hdl]
                if { $sig ne "" } {
                    lappend all_drivers $sig
                }
            }

            # Trace module-boundary drivers. passMod=0 keeps module port
            # connections as trace endpoints; these are emitted to the side CSV.
            if { $module_outfh ne "" } {
                set moduleDriverList {}
                catch { ::npi_L1::npi_nl_trace_driver $signame moduleDriverList 0 0 }
                if { [llength $moduleDriverList] == 0 } {
                    set moduleDriverList {}
                    catch { ::npi_L1::npi_nl_trace_driver_by_hdl $sig_hdl moduleDriverList 0 0 }
                }
                foreach hdl $moduleDriverList {
                    set sig [hdl_to_name $hdl]
                    if { [is_module_boundary_signal $sig] } {
                        lappend module_drivers $sig
                    }
                }
            }
        }

        # Collect all loads
        set all_loads {}
        set module_loads {}
        foreach sig_hdl $load_sigs {
            # Try different methods to get signal info
            set signame ""

            # Method 1: Try npi_nl_ut_get_hdl_info (for netlist objects)
            if { [catch {
                set sig_info [::npi_L1::npi_nl_ut_get_hdl_info $sig_hdl]
                set signame [string trim [lindex [split $sig_info ","] 1]]
            }] } {}

            # Method 2: If empty, try npi_ut_get_hdl_info (for general objects)
            if { $signame eq "" } {
                if { [catch {
                    set sig_info [::npi_L1::npi_ut_get_hdl_info $sig_hdl]
                    set signame [string trim [lindex [split $sig_info ","] 1]]
                }] } {}
            }

            # Method 3: If still empty, try to convert handle to net and get name
            if { $signame eq "" } {
                # Try to get net handle if this is a port/instport
                set net_hdl ""
                if { [catch {
                    set net_hdl [::npi_L1::npi_nl_port_instport_2_net $sig_hdl]
                }] } {}

                if { $net_hdl ne "" && $net_hdl != 0 } {
                    if { [catch {
                        set sig_info [::npi_L1::npi_nl_ut_get_hdl_info $net_hdl]
                        set signame [string trim [lindex [split $sig_info ","] 1]]
                    }] } {}
                }
            }

            if { $signame eq "" } {
                continue
            }

            # Trace loads
            set loadList {}
            set r2 [::npi_L1::npi_nl_trace_load $signame loadList 0 1]

            # If no loads found, try handle-based tracing
            # Only retry if loadList is actually empty
            if { [llength $loadList] == 0 } {
                set loadList {}
                catch { ::npi_L1::npi_nl_trace_load_by_hdl $sig_hdl loadList }
            }

            foreach hdl $loadList {
                set sig [hdl_to_name $hdl]
                if { $sig ne "" } {
                    lappend all_loads $sig
                }
            }

            # Trace module-boundary loads. passMod=0 keeps module port
            # connections as trace endpoints; these are emitted to the side CSV.
            if { $module_outfh ne "" } {
                set moduleLoadList {}
                catch { ::npi_L1::npi_nl_trace_load $signame moduleLoadList 0 0 }
                if { [llength $moduleLoadList] == 0 } {
                    set moduleLoadList {}
                    catch { ::npi_L1::npi_nl_trace_load_by_hdl $sig_hdl moduleLoadList 0 0 }
                }
                foreach hdl $moduleLoadList {
                    set sig [hdl_to_name $hdl]
                    if { [is_module_boundary_signal $sig] } {
                        lappend module_loads $sig
                    }
                }
            }
        }

        # Remove duplicates
        set all_drivers [lsort -unique $all_drivers]
        set all_loads [lsort -unique $all_loads]
        set module_drivers [lsort -unique $module_drivers]
        set module_loads [lsort -unique $module_loads]

        # Output module-boundary connections to the side CSV.
        if { $module_outfh ne "" } {
            foreach sig $module_drivers {
                set formatted_sig [format_signal_name $sig $inst_path]
                puts $module_outfh "$inst_path,$portname,driver,$formatted_sig"
            }
            foreach sig $module_loads {
                set formatted_sig [format_signal_name $sig $inst_path]
                puts $module_outfh "$inst_path,$portname,load,$formatted_sig"
            }
        }

        # Output drivers
        if { [llength $all_drivers] > 0 } {
            foreach sig $all_drivers {
                set formatted_sig [format_signal_name $sig $inst_path]
                puts $outfh "$inst_path,$portname,driver,$formatted_sig"
            }
        } else {
            # If no drivers found via tracing, output the direct connection signal
            # This handles cases where trace APIs cannot follow the signal further
            if { [llength $driver_sigs] > 0 } {
                foreach sig_hdl $driver_sigs {
                    set signame ""
                    catch {
                        set sig_info [::npi_L1::npi_nl_ut_get_hdl_info $sig_hdl]
                        set signame [string trim [lindex [split $sig_info ","] 1]]
                    }
                    if { $signame eq "" } {
                        catch {
                            set sig_info [::npi_L1::npi_ut_get_hdl_info $sig_hdl]
                            set signame [string trim [lindex [split $sig_info ","] 1]]
                        }
                    }
                    if { $signame ne "" } {
                        set formatted_sig [format_signal_name $signame $inst_path]
                        puts $outfh "$inst_path,$portname,driver,$formatted_sig"
                    }
                }
            }
            if { [llength $driver_sigs] == 0 } {
                puts $outfh "$inst_path,$portname,driver,NO_DRIVER"
            }
        }

        # Output loads
        if { [llength $all_loads] > 0 } {
            foreach sig $all_loads {
                set formatted_sig [format_signal_name $sig $inst_path]
                puts $outfh "$inst_path,$portname,load,$formatted_sig"
            }
        } else {
            # If no loads found via tracing, output the direct connection signal
            # This is valid when a signal is connected but not actually used
            if { [llength $load_sigs] > 0 } {
                foreach sig_hdl $load_sigs {
                    set signame ""
                    catch {
                        set sig_info [::npi_L1::npi_nl_ut_get_hdl_info $sig_hdl]
                        set signame [string trim [lindex [split $sig_info ","] 1]]
                    }
                    if { $signame eq "" } {
                        catch {
                            set sig_info [::npi_L1::npi_ut_get_hdl_info $sig_hdl]
                            set signame [string trim [lindex [split $sig_info ","] 1]]
                        }
                    }
                    if { $signame ne "" } {
                        set formatted_sig [format_signal_name $signame $inst_path]
                        puts $outfh "$inst_path,$portname,load,$formatted_sig"
                    }
                }
            }
            if { [llength $load_sigs] == 0 } {
                puts $outfh "$inst_path,$portname,load,NO_LOAD"
            }
        }
    }
}

# -----------------------------------------------------------------------
# Find all instances of target_mod and process each
# -----------------------------------------------------------------------
set hdlList {}
if { [catch {
    ::npi_L1::npi_find_inst_with_def_wildcard "" $target_mod hdlList
} e] } {
    puts stderr "ERROR: npi_find_inst_with_def_wildcard failed: $e"
    debExit
}

if { [llength $hdlList] == 0 } {
    puts stderr "ERROR: no instances of module '$target_mod' found"
    debExit
}

# Print CSV header
puts $outfh "inst_full_name,port_name,role,signal_full_name"
if { $module_outfh ne "" } {
    puts $module_outfh "inst_full_name,port_name,role,module_signal_full_name"
}

foreach ih $hdlList {
    # Get instance full path from npi_ut_get_hdl_info
    # format: "npiNlHierInst, full.path, (null)" — but this returns empty for inst handles
    # Use npi_nl_ut_get_hdl_info instead
    set inst_path ""
    if { [catch {
        set info [::npi_L1::npi_ut_get_hdl_info $ih]
        set inst_path [string trim [lindex [split $info ","] 1]]
    }] } {}

    if { $inst_path eq "" } {
        puts stderr "WARNING: could not get path for instance handle $ih, skipping"
        continue
    }

    # Derive parent path and instance name
    set parts [split $inst_path "."]
    set instname   [lindex $parts end]
    set parent_path [join [lrange $parts 0 end-1] "."]

    process_instance $inst_path $parent_path $instname $port_filter $outfh $module_outfh
}

if { $outfh ne "stdout" } { close $outfh }
if { $module_outfh ne "" } { close $module_outfh }
debExit
