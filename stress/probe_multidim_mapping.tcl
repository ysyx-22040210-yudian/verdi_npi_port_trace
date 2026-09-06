# Force the name-parser fallback on a real KDB and verify every mapped handle.
source $env(VERDI_HOME)/share/NPI/L1/TCL/npi_L1.tcl
set root [file dirname [file dirname [info script]]]
source [file join $root trace_support.tcl]
source [file join $root npi_elaborated.tcl]
set fh [open [file join $root npi_port_trace.tcl] r]
set collecting 0
set definition ""
while {[gets $fh line] >= 0} {
    if {!$collecting && [string match {proc *} $line]} {set collecting 1}
    if {$collecting} {
        append definition $line "\n"
        if {[info complete $definition]} {eval $definition; set definition ""; set collecting 0}
    }
}
close $fh
set trace_debug_enabled 0
schSetPreference -detailRTL on -detailMux on -recogFSM off -expandGenBlock on
debImport -elab $env(AUDIT_KDB)
rename ::npi_L1::npi_nl_sig_handle_by_name ::npi_L1::npi_nl_sig_handle_by_name_original
proc ::npi_L1::npi_nl_sig_handle_by_name {name} {return ""}
set checked 0
foreach kind {D2 A2 Mixed D3 Singleton Unpacked MixedArray Unpacked2 UnpackedBits} {
    foreach port {a q} {
        set name "MDTop.g\[0\].lane.t_${kind}.$port"
        set declaration [npi_handle_by_name -name $name -scope ""]
        set width [elab_bit_width $declaration]
        set ranges [elab_ranges $declaration]
        for {set offset 0} {$offset < $width} {incr offset} {
            set query "$name[elab_select_for_offset $ranges $offset]"
            if {[catch {
                set bit [elab_exact_bit_handle $query]
                if {[hdl_to_name $bit] ne $query || [get_handle_size $bit] ne "1"} {error "wrong identity"}
                set loads [elab_exact_load_rows $bit $query]
            } message]} {
                puts "FALLBACK_FAIL query=$query reason=$message"
                foreach method {npi_nl_handle_by_name ::npi_L1::npi_nl_L1_handle_by_name ::npi_L1::npi_nl_sig_handle_by_name_original} {
                    set hdl ""
                    if {$method eq "npi_nl_handle_by_name"} {catch {set hdl [$method -name $name]}} else {catch {set hdl [$method $name]}}
                    puts "FALLBACK_PROBE method=$method hdl=$hdl size=[get_handle_size $hdl] name=[hdl_to_name $hdl] base=[signal_base_without_select [hdl_to_name $hdl]]"
                }
                debExit
                exit 1
            }
            incr checked
        }
    }
}
puts "FALLBACK_MAPPING_PASS checked=$checked"
debExit
