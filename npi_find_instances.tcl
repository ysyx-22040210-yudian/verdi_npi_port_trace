# npi_find_instances.tcl
#
# Find all instances whose definition name matches NPI_FILTER_MODULES
# or NPI_FILTER_MODULE and write their hierarchical paths to
# NPI_INSTANCE_OUTFILE, one path per line.

proc log_step {msg} {
    puts stderr "\[npi_find_instances\] $msg"
    flush stderr
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

proc get_instance_path {hdl} {
    foreach api {
        ::npi_L1::npi_ut_get_hdl_info
        ::npi_L1::npi_nl_ut_get_hdl_info
    } {
        set info ""
        if { ![catch { set info [$api $hdl] } err] } {
            set path [hdl_info_to_path $info]
            if { $path ne "" } {
                return $path
            }
        }
    }
    return ""
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

if { ![info exists env(NPI_INSTANCE_OUTFILE)] || $env(NPI_INSTANCE_OUTFILE) eq "" } {
    puts stderr "ERROR: environment variable NPI_INSTANCE_OUTFILE is not set"
    debExit
}

if { ![info exists env(NPI_LIB)] || $env(NPI_LIB) eq "" } {
    puts stderr "ERROR: environment variable NPI_LIB is required. Filelist import is not supported."
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

set filter_modules_text ""
if { [info exists env(NPI_FILTER_MODULES)] && $env(NPI_FILTER_MODULES) ne "" } {
    set filter_modules_text $env(NPI_FILTER_MODULES)
} elseif { [info exists env(NPI_FILTER_MODULE)] && $env(NPI_FILTER_MODULE) ne "" } {
    set filter_modules_text $env(NPI_FILTER_MODULE)
}

set filter_modules {}
foreach item [split $filter_modules_text ","] {
    set item [string trim $item]
    if { $item ne "" } {
        lappend filter_modules $item
    }
}

if { [llength $filter_modules] == 0 } {
    puts stderr "ERROR: environment variable NPI_FILTER_MODULES or NPI_FILTER_MODULE is not set"
    debExit
}

set log_instances 0
if { [info exists env(NPI_FIND_LOG_INSTANCES)] } {
    set value [string tolower [string trim $env(NPI_FIND_LOG_INSTANCES)]]
    if { $value in {"1" "true" "yes" "on"} } {
        set log_instances 1
    }
}

log_step "import design by KDB: $npi_lib"
if { [catch { debImport -elab $npi_lib } e] } {
    puts stderr "ERROR: debImport -elab failed: $e"
    debExit
}

log_step "write instance list: $env(NPI_INSTANCE_OUTFILE)"
set outfh [open $env(NPI_INSTANCE_OUTFILE) w]
set total_handles 0
set written 0
set skipped 0
set seen_paths {}

foreach filter_module $filter_modules {
    set hdlList {}
    log_step "find instances for module definition: $filter_module"
    if { [catch {
        ::npi_L1::npi_find_inst_with_def_wildcard "" $filter_module hdlList
    } e] } {
        puts stderr "ERROR: npi_find_inst_with_def_wildcard failed for $filter_module: $e"
        close $outfh
        debExit
    }

    log_step "module=$filter_module found_instance_handles=[llength $hdlList]"
    incr total_handles [llength $hdlList]
    foreach ih $hdlList {
        set inst_path [get_instance_path $ih]
        if { $inst_path ne "" } {
            if { [dict exists $seen_paths $inst_path] } {
                log_step "duplicate instance skipped: $inst_path"
                continue
            }
            dict set seen_paths $inst_path 1
            if { $log_instances } {
                log_step "instance module=$filter_module path=$inst_path"
            }
            puts $outfh $inst_path
            incr written
        } else {
            incr skipped
            puts stderr "WARNING: could not resolve instance path for handle $ih module=$filter_module"
        }
    }
}
close $outfh
log_step "done module_count=[llength $filter_modules] handle_count=$total_handles written_instances=$written skipped_handles=$skipped"
debExit
