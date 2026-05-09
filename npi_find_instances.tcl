# npi_find_instances.tcl
#
# Find all instances whose definition name matches NPI_FILTER_MODULE and
# write their hierarchical paths to NPI_INSTANCE_OUTFILE, one path per line.

if { [info exists env(VERDI_HOME)] } {
    source $env(VERDI_HOME)/share/NPI/L1/TCL/npi_L1.tcl
} elseif { [info exists env(NPIL1_PATH)] } {
    source $env(NPIL1_PATH)/npi_L1.tcl
} else {
    puts stderr "ERROR: VERDI_HOME or NPIL1_PATH must be set"
    exit 1
}

if { ![info exists env(NPI_FILTER_MODULE)] || $env(NPI_FILTER_MODULE) eq "" } {
    puts stderr "ERROR: environment variable NPI_FILTER_MODULE is not set"
    debExit
}

if { ![info exists env(NPI_INSTANCE_OUTFILE)] || $env(NPI_INSTANCE_OUTFILE) eq "" } {
    puts stderr "ERROR: environment variable NPI_INSTANCE_OUTFILE is not set"
    debExit
}

set use_lib [expr { [info exists env(NPI_LIB)] && $env(NPI_LIB) ne "" }]
if { $use_lib } {
    if { [catch { debImport -elab $env(NPI_LIB) } e] } {
        puts stderr "ERROR: debImport -elab failed: $e"
        debExit
    }
} else {
    if { ![info exists env(NPI_FILELIST)] || $env(NPI_FILELIST) eq "" ||
         ![info exists env(NPI_TOP)] || $env(NPI_TOP) eq "" } {
        puts stderr "ERROR: NPI_FILELIST and NPI_TOP are required when NPI_LIB is not set"
        debExit
    }
    set incdir [expr { [info exists env(NPI_INCDIR)] ? $env(NPI_INCDIR) : "" }]
    if { $incdir ne "" } {
        debImport -f $env(NPI_FILELIST) +incdir+$incdir -top $env(NPI_TOP) -sv
    } else {
        debImport -f $env(NPI_FILELIST) -top $env(NPI_TOP) -sv
    }
}

set hdlList {}
if { [catch {
    ::npi_L1::npi_find_inst_with_def_wildcard "" $env(NPI_FILTER_MODULE) hdlList
} e] } {
    puts stderr "ERROR: npi_find_inst_with_def_wildcard failed: $e"
    debExit
}

set outfh [open $env(NPI_INSTANCE_OUTFILE) w]
foreach ih $hdlList {
    set inst_path ""
    if { [catch {
        set info [::npi_L1::npi_ut_get_hdl_info $ih]
        set inst_path [string trim [lindex [split $info ","] 1]]
    }] } {}
    if { $inst_path ne "" } {
        puts $outfh $inst_path
    }
}
close $outfh
debExit
