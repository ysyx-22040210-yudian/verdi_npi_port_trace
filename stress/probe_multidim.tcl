# Read-only Verdi probe. Supply AUDIT_KDB and optionally PROBE_SIGNALS.
source $env(VERDI_HOME)/share/NPI/L1/TCL/npi_L1.tcl
schSetPreference -detailRTL on -detailMux on -recogFSM off -expandGenBlock on
debImport -elab $env(AUDIT_KDB)
proc describe {label hdl} {
    set props [list hdl $hdl]
    if {$hdl ne "" && $hdl ne "0"} {
        foreach p {npiNlFullName npiNlType} {catch {lappend props $p [npi_nl_get_str -property $p -object $hdl]}}
        foreach p {npiNlSize npiNlLeft npiNlRight} {catch {lappend props $p [npi_nl_get -property $p -object $hdl]}}
        catch {lappend props actual [::npi_L1::npi_nl_ut_get_actual_name $hdl]}
    }
    puts "$label $props"
}
proc loads {label hdl} {
    if {$hdl eq "" || $hdl eq "0"} {return}
    set rows {}
    set rc [catch {::npi_L1::npi_nl_bit_trace_load_by_hdl $hdl rows} message]
    puts "$label rc=$rc message=$message rows=[llength $rows] raw=$rows"
    foreach row $rows {
        describe SOURCE [lindex $row 0]
        foreach endpoint [lindex $row 1] {describe LOAD $endpoint}
    }
}
proc structural_info {hdl {depth 0}} {
    if {$hdl eq "" || $hdl eq "0" || $depth > 4} {return}
    set info {}
    foreach p {npiType npiFullName} {catch {lappend info $p [npi_get_str -property $p -object $hdl]}}
    foreach p {npiSize npiLeftRange npiRightRange} {catch {lappend info $p [npi_get -property $p -object $hdl]}}
    puts "STRUCT depth=$depth $info"
    foreach relation {npiTypespec npiElemTypespec npiLowConn npiHighConn} {
        set child ""
        catch {set child [npi_handle -type $relation -refHandle $hdl]}
        if {$child ne "" && $child ne "0"} {puts "REL $relation"; structural_info $child [expr {$depth+1}]}
    }
    set iter ""
    catch {set iter [npi_iterate -type npiRange -refHandle $hdl]}
    if {$iter ne "" && $iter ne "0"} {
        while {[set range [npi_scan -iterator $iter]] ne "" && $range ne "0"} {
            foreach relation {npiLeftRange npiRightRange} {
                set constant [npi_handle -type $relation -refHandle $range]
                puts "RANGE $relation [npi_get_value -format npiDecStrVal -object $constant]"
            }
        }
    }
}
set signals {{SemTop.g[0].lane.packed_conn.a} {SemTop.g[0].lane.packed_conn.a[0][1]}}
if {[info exists env(PROBE_SIGNALS)]} {set signals $env(PROBE_SIGNALS)}
foreach signal $signals {
    puts "QUERY $signal"
    set hdl [::npi_L1::npi_nl_sig_handle_by_name $signal]
    describe DIRECT $hdl
    loads DIRECT_LOAD $hdl
    set structural [npi_handle_by_name -name $signal -scope ""]
    puts "STRUCTURAL [::npi_L1::npi_ut_get_hdl_info $structural]"
    structural_info $structural
    foreach command [list [list npi_nl_handle_by_name -name $signal] \
                         [list ::npi_L1::npi_nl_L1_handle_by_name $signal]] {
        set result ""
        catch {set result [eval $command]}
        describe ALTERNATIVE $result
        loads ALT_LOAD $result
    }
    set scope [join [lrange [split $signal .] 0 end-1] .]
    set leaf [lindex [split $signal .] end]
    foreach candidate [list $leaf "${leaf}\[1:0\]\[1:0\]" "${leaf}\[3:0\]"] {
        set net [::npi_L1::npi_nl_net_handle_by_nl_name $scope $candidate]
        describe "NET $candidate" $net
        loads NET_LOAD $net
        if {$net eq "" || $net eq "0"} {continue}
        for {set i 0} {$i < 4} {incr i} {
            set bit [npi_nl_handle_by_index -object $net -index $i]
            describe "INDEX $i" $bit
            loads INDEX_LOAD $bit
        }
    }
}
puts MULTIDIM_PROBE_COMPLETE
debExit
