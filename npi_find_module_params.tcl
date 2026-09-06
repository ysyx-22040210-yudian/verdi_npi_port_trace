# npi_find_module_params.tcl
#
# Find all instances of one or more module definitions and dump each
# instance's elaborated parameter values to CSV.

proc log_step {msg} {
    puts stderr "\[npi_find_module_params\] $msg"
    flush stderr
}

proc csv_escape {text} {
    set text [string map [list "\"" "\"\""] $text]
    if { [regexp {[,\"\r\n]} $text] } {
        return "\"$text\""
    }
    return $text
}

proc csv_put {fh fields} {
    set out {}
    foreach field $fields {
        lappend out [csv_escape $field]
    }
    puts $fh [join $out ","]
}

proc hdl_info_to_path {info} {
    set info [string trim $info]
    if { $info eq "" } {
        return ""
    }

    set fields [split $info ","]
    if { [llength $fields] >= 2 } {
        return [string trim [lindex $fields 1]]
    }

    return ""
}

proc get_hdl_info {hdl} {
    foreach api {
        ::npi_L1::npi_ut_get_hdl_info
        ::npi_L1::npi_nl_ut_get_hdl_info
    } {
        set info ""
        if { ![catch { set info [$api $hdl] } err] && [string trim $info] ne "" } {
            return [string trim $info]
        }
    }
    return ""
}

proc get_instance_path {hdl} {
    return [hdl_info_to_path [get_hdl_info $hdl]]
}

proc get_param_name {param_hdl inst_path info} {
    set name ""
    catch { set name [npi_get_str -property npiName -object $param_hdl] }
    set name [string trim $name]

    if { $name ne "" } {
        if { [string first "$inst_path." $name] == 0 } {
            return [string range $name [expr {[string length $inst_path] + 1}] end]
        }
        return $name
    }

    set full_path [hdl_info_to_path $info]
    if { $full_path ne "" } {
        if { [string first "$inst_path." $full_path] == 0 } {
            return [string range $full_path [expr {[string length $inst_path] + 1}] end]
        }
        set parts [split $full_path "."]
        return [lindex $parts end]
    }

    return "UNKNOWN_PARAM"
}

proc get_int_property {hdl prop default} {
    set value $default
    catch { set value [npi_get -property $prop -object $hdl] }
    return $value
}

proc get_str_property {hdl prop default} {
    set value $default
    catch { set value [npi_get_str -property $prop -object $hdl] }
    return [string trim $value]
}

proc get_parameter_value {param_hdl} {
    set size [get_int_property $param_hdl npiSize ""]
    set signed_value [get_int_property $param_hdl npiSigned 0]
    if { [string trim $signed_value] eq "1" } {
        set sign_str "s"
    } else {
        set sign_str ""
    }

    set const_type [get_str_property $param_hdl npiConstType ""]
    if { $const_type eq "" } {
        set expr_hdl ""
        catch { set expr_hdl [npi_handle -type npiExpr -refHandle $param_hdl] }
        if { $expr_hdl ne "" && $expr_hdl ne "0" } {
            if { [get_str_property $expr_hdl npiType ""] eq "npiConstant" } {
                set const_type [get_str_property $expr_hdl npiConstType ""]
            }
        }
    }

    set value ""
    switch -- $const_type {
        npiRealConst {
            if { ![catch { set value [npi_get_value -format npiRealVal -object $param_hdl] }] } {
                return $value
            }
        }
        npiStringConst {
            if { ![catch { set value [npi_get_value -format npiStringVal -object $param_hdl] }] } {
                return "\"$value\""
            }
        }
        npiBinaryConst {
            if { ![catch { set value [npi_get_value -format npiBinStrVal -object $param_hdl] }] } {
                if { $size ne "" } { return "${size}'${sign_str}b${value}" }
                return $value
            }
        }
        npiOctConst {
            if { ![catch { set value [npi_get_value -format npiOctStrVal -object $param_hdl] }] } {
                if { $size ne "" } { return "${size}'${sign_str}o${value}" }
                return $value
            }
        }
        npiHexConst {
            if { ![catch { set value [npi_get_value -format npiHexStrVal -object $param_hdl] }] } {
                if { $size ne "" } { return "${size}'${sign_str}h${value}" }
                return $value
            }
        }
        npiDecConst {
            if { ![catch { set value [npi_get_value -format npiDecStrVal -object $param_hdl] }] } {
                if { $size ne "" } { return "${size}'${sign_str}d${value}" }
                return $value
            }
        }
    }

    foreach fmt {npiIntVal npiDecStrVal npiHexStrVal npiBinStrVal npiStringVal npiRealVal} {
        if { ![catch { set value [npi_get_value -format $fmt -object $param_hdl] }] } {
            if { [string trim $value] ne "" } {
                return $value
            }
        }
    }

    return "UNKNOWN_VALUE"
}

proc get_param_kind {param_hdl} {
    set is_local [get_int_property $param_hdl npiLocalParam 0]
    if { [string trim $is_local] eq "1" } {
        return "localparam"
    }
    return "parameter"
}

log_step "start"

if { [info exists env(VERDI_HOME)] } {
    log_step "source NPI from VERDI_HOME=$env(VERDI_HOME)"
    source $env(VERDI_HOME)/share/NPI/L1/TCL/npi_L1.tcl
} elseif { [info exists env(NPIL1_PATH)] } {
    log_step "source NPI from NPIL1_PATH=$env(NPIL1_PATH)"
    source $env(NPIL1_PATH)/npi_L1.tcl
} else {
    puts stderr "ERROR: VERDI_HOME or NPIL1_PATH must be set"
    exit 1
}

if { ![info exists env(NPI_LIB)] || $env(NPI_LIB) eq "" } {
    puts stderr "ERROR: environment variable NPI_LIB is required. Filelist import is not supported."
    debExit
}

if { (![info exists env(NPI_PARAM_MODULES)] || $env(NPI_PARAM_MODULES) eq "") &&
     (![info exists env(NPI_PARAM_MODULES_FILE)] || $env(NPI_PARAM_MODULES_FILE) eq "") } {
    puts stderr "ERROR: NPI_PARAM_MODULES_FILE or NPI_PARAM_MODULES is required"
    debExit
}

if { ![info exists env(NPI_PARAM_OUTFILE)] || $env(NPI_PARAM_OUTFILE) eq "" } {
    puts stderr "ERROR: environment variable NPI_PARAM_OUTFILE is not set"
    debExit
}

set target_modules {}
if {[info exists env(NPI_PARAM_MODULES_FILE)] && $env(NPI_PARAM_MODULES_FILE) ne ""} {
    set listfh [open $env(NPI_PARAM_MODULES_FILE) r]
    fconfigure $listfh -encoding utf-8
    set module_items [split [read $listfh] "\n"]
    close $listfh
} else {
    set module_items [split $env(NPI_PARAM_MODULES) ","]
}
foreach item $module_items {
    set item [string trim $item]
    if { $item ne "" } {
        lappend target_modules $item
    }
}
if { [llength $target_modules] == 0 } {
    puts stderr "ERROR: NPI_PARAM_MODULES contains no module names"
    debExit
}

set npi_lib [file normalize $env(NPI_LIB)]
if { ![file exists $npi_lib] } {
    puts stderr "ERROR: KDB path does not exist: $npi_lib"
    debExit
}
if { [file isdirectory $npi_lib] && [llength [glob -nocomplain -directory $npi_lib *]] == 0 } {
    puts stderr "ERROR: KDB path is empty: $npi_lib"
    debExit
}

log_step "import design by KDB: $npi_lib"
if { [catch { debImport -elab $npi_lib } e] } {
    puts stderr "ERROR: debImport -elab failed: $e"
    debExit
}

log_step "write parameter CSV: $env(NPI_PARAM_OUTFILE)"
set outfh [open $env(NPI_PARAM_OUTFILE) w]
csv_put $outfh {module inst_full_name param_name param_value param_kind param_info}

set total_instances 0
set total_params 0
set collection_errors 0
foreach target_mod $target_modules {
    set hdlList {}
    log_step "find instances for module definition: $target_mod"
    if { [catch {
        ::npi_L1::npi_find_inst_with_def_wildcard "" $target_mod hdlList
    } e] } {
        puts stderr "WARNING: npi_find_inst_with_def_wildcard failed for $target_mod: $e"
        incr collection_errors
        continue
    }

    log_step "module=$target_mod instance_handles=[llength $hdlList]"
    set seen_paths {}
    foreach ih $hdlList {
        set inst_path [get_instance_path $ih]
        if { $inst_path eq "" } {
            puts stderr "WARNING: could not resolve instance path for handle $ih"
            incr collection_errors
            continue
        }
        if { [dict exists $seen_paths $inst_path] } {
            log_step "duplicate instance skipped: $inst_path"
            continue
        }
        dict set seen_paths $inst_path 1
        incr total_instances
        csv_put $outfh [list $target_mod $inst_path "" "" instance INSTANCE_INVENTORY]

        set param_hdl_list {}
        set count 0
        if { [catch {
            set count [::npi_L1::npi_mod_inst_get_parameter $inst_path param_hdl_list]
        } e] } {
            puts stderr "WARNING: npi_mod_inst_get_parameter failed for $inst_path: $e"
            incr collection_errors
            continue
        }

        log_step "instance=$inst_path parameter_handles=[llength $param_hdl_list] return_count=$count"
        foreach param_hdl $param_hdl_list {
            if { [catch {
                set info [get_hdl_info $param_hdl]
                set name [get_param_name $param_hdl $inst_path $info]
                set value [get_parameter_value $param_hdl]
                set kind [get_param_kind $param_hdl]
                csv_put $outfh [list $target_mod $inst_path $name $value $kind $info]
                incr total_params
                log_step "param instance=$inst_path $kind $name=$value"
            } e] } {
                puts stderr "WARNING: parameter handle failed for $inst_path: $e"
                incr collection_errors
                csv_put $outfh [list $target_mod $inst_path UNKNOWN_PARAM UNKNOWN_VALUE parameter "ERROR:$e"]
                incr total_params
            }
        }
    }
}

close $outfh
if {$collection_errors == 0 && [info exists env(NPI_PARAM_STATUS_FILE)] && $env(NPI_PARAM_STATUS_FILE) ne ""} {
    set statusfh [open $env(NPI_PARAM_STATUS_FILE) w]
    puts $statusfh "COMPLETE [llength $target_modules] $total_instances $total_params"
    close $statusfh
}
log_step "done instances=$total_instances params=$total_params"
debExit
