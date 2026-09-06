# Bit-position preserving access to the elaborated language model. Structural
# npiHandle and netlist npiNlHandle are deliberately kept in separate helpers.
# Source text is evidence only on this path; it never overrides the KDB.

proc elab_property {hdl property {string_value 0}} {
    if {$hdl eq "" || $hdl eq "0"} {return ""}
    if {$string_value} {return [npi_get_str -property $property -object $hdl]}
    return [npi_get -property $property -object $hdl]
}

proc elab_relation {hdl relation} {
    if {$hdl eq "" || $hdl eq "0"} {return ""}
    return [npi_handle -type $relation -refHandle $hdl]
}

proc elab_children {hdl relation} {
    set result {}
    set iterator [npi_iterate -type $relation -refHandle $hdl]
    if {$iterator eq "" || $iterator eq "0"} {return $result}
    while {[set child [npi_scan -iterator $iterator]] ne "" && $child ne "0"} {
        lappend result $child
    }
    return $result
}

proc elab_integer {hdl} {
    set type [elab_property $hdl npiType 1]
    if {$type in {npiConstant npiParameter}} {
        set value [npi_get_value -format npiDecStrVal -object $hdl]
        return [decimal_index_token $value]
    }
    # Range expressions are elaboration-time integers. Do not eval Tcl text.
    set op [elab_property $hdl npiOpType 1]
    set values {}
    foreach operand [elab_children $hdl npiOperand] {lappend values [elab_integer $operand]}
    set a [lindex $values 0]
    set b [lindex $values 1]
    switch -- $op {
        npiMinusOp {return [expr {-$a}]}
        npiPlusOp {return $a}
        npiAddOp {return [expr {$a + $b}]}
        npiSubOp {return [expr {$a - $b}]}
        npiMultOp {return [expr {$a * $b}]}
        npiDivOp {return [expr {$a / $b}]}
        default {error "unsupported elaborated range operation $op"}
    }
}

proc elab_ranges {hdl} {
    if {[elab_property $hdl npiType 1] eq "npiPort"} {set hdl [elab_relation $hdl npiLowConn]}
    set type [elab_relation $hdl npiTypespec]
    if {$type eq "" || $type eq "0"} {return {}}
    set ranges {}
    set visited {}
    while {[elab_property $type npiType 1] eq "npiArrayTypespec"} {
        if {[dict exists $visited $hdl]} {error "cyclic unpacked array shape"}
        dict set visited $hdl 1
        # Select one array ELEMENT, then inspect its own type. Iterating the
        # full ElemTypespec chain duplicates packed dimensions on O-2018.
        set range [lindex [elab_children $type npiRange] 0]
        if {$range eq ""} {error "array has no fixed elaborated range"}
        set left [elab_integer [elab_relation $range npiLeftRange]]
        set right [elab_integer [elab_relation $range npiRightRange]]
        lappend ranges [list $left $right]
        set hdl [npi_handle_by_index -object $hdl -index $right]
        if {$hdl eq "" || $hdl eq "0"} {error "array element shape unavailable"}
        set type [elab_relation $hdl npiTypespec]
    }
    foreach range [elab_children $type npiRange] {
        lappend ranges [list [elab_integer [elab_relation $range npiLeftRange]] \
                            [elab_integer [elab_relation $range npiRightRange]]]
    }
    return $ranges
}

proc elab_bit_width {hdl} {
    if {[elab_property $hdl npiType 1] eq "npiPort"} {set hdl [elab_relation $hdl npiLowConn]}
    set multiplier 1
    set visited {}
    while {[elab_property [elab_relation $hdl npiTypespec] npiType 1] eq "npiArrayTypespec"} {
        if {[dict exists $visited $hdl]} {error "cyclic unpacked array width"}
        dict set visited $hdl 1
        set range [lindex [elab_children [elab_relation $hdl npiTypespec] npiRange] 0]
        if {$range eq ""} {error "array has no fixed elaborated range"}
        set left [elab_integer [elab_relation $range npiLeftRange]]
        set right [elab_integer [elab_relation $range npiRightRange]]
        set multiplier [expr {$multiplier * (abs($left-$right)+1)}]
        set hdl [npi_handle_by_index -object $hdl -index $right]
        if {$hdl eq "" || $hdl eq "0"} {error "array element width unavailable"}
    }
    # npiSize of an unpacked array counts elements; npiSize of its packed
    # leaf counts bits. Multiplying the element counts is essential.
    set width [elab_property $hdl npiSize]
    if {![string is integer -strict $width] || $width <= 0} {error "unknown elaborated bit width"}
    return [expr {$multiplier * $width}]
}

proc elab_offsets {width ranges select} {
    if {![string is integer -strict $width] || $width <= 0} {error "unknown elaborated width"}
    if {$select eq ""} {
        set result {}
        for {set i 0} {$i < $width} {incr i} {lappend result $i}
        return $result
    }
    if {![regexp {^(\[-?[0-9]+(?::-?[0-9]+)?\])+$} $select]} {error "unsupported select $select"}
    set indices [regexp -all -inline {\[[^]]+\]} $select]
    if {[llength $ranges] == 0 && $width == 1 && [llength $indices] == 1} {
        if {$select in {{[0]} {[0:0]}}} {return {0}}
        return -code error -errorcode {NPI_QUERY OUT_OF_RANGE} "select $select outside scalar declaration"
    }
    set product 1
    foreach range $ranges {lassign $range left right; set product [expr {$product * (abs($left-$right)+1)}]}
    if {[llength $ranges] == 0 || $product != $width || [llength $indices] > [llength $ranges]} {
        error "unresolved declaration shape width=$width ranges=$ranges select=$select"
    }
    set offsets {0}
    set dimension 0
    foreach range $ranges {
        lassign $range left right
        set size [expr {abs($left-$right)+1}]
        set selection [lindex $indices $dimension]
        set local {}
        if {$selection eq ""} {
            for {set i 0} {$i < $size} {incr i} {lappend local $i}
        } else {
            regexp {^\[(-?[0-9]+)(?::(-?[0-9]+))?\]$} $selection -> first last
            if {$last eq ""} {set last $first}
            if {min($first,$last) < min($left,$right) || max($first,$last) > max($left,$right)} {
                return -code error -errorcode {NPI_QUERY OUT_OF_RANGE} "select $select outside declaration $ranges"
            }
            for {set i [expr {min($first,$last)}]} {$i <= max($first,$last)} {incr i} {
                lappend local [expr {abs($i-$right)}]
            }
        }
        set next {}
        foreach prefix $offsets {foreach i $local {lappend next [expr {$prefix*$size+$i}]}}
        set offsets $next
        incr dimension
    }
    return [lsort -integer -unique $offsets]
}

proc elab_select_for_offset {ranges offset} {
    set select ""
    foreach range [lreverse $ranges] {
        lassign $range left right
        set width [expr {abs($left-$right)+1}]
        set digit [expr {$offset % $width}]
        set index [expr {$left >= $right ? $right+$digit : $right-$digit}]
        set select "\[$index\]$select"
        set offset [expr {$offset / $width}]
    }
    if {$offset != 0} {error "expression offset outside declaration"}
    return $select
}

proc elab_nl_multidim_bit_name {hdl native_name} {
    # O-2018 may label a[0][1] as a[1:0]#[2]. The number after # is
    # a netlist index, NOT an RTL subscript. Never normalize it to a[2].
    # Use the documented *complete* actual-name list (the singular helper
    # returns only the first constituent of a concatenation).
    if {[string first "#\[" $native_name] < 0 || [string first "," $native_name] >= 0} {return ""}
    if {[catch {
        if {[npi_nl_get -property npiNlSize -object $hdl] ne "1"} {return ""}
        set names {}
        ::npi_L1::npi_nl_ut_get_actual_name_vec $hdl names 1
        if {[llength $names] != 1} {return ""}
        set actual [normalize_signal_name [lindex $names 0]]
        set select [signal_select_suffix $actual]
        if {![regexp {^(\[-?[0-9]+\]){2,}$} $select] ||
            [signal_base_without_select $native_name] ne [signal_base_without_select $actual]} {return ""}
        set structural [npi_handle_by_name -name $actual -scope ""]
        if {$structural eq "" || $structural eq "0" || [elab_property $structural npiSize] ne "1"} {return ""}
    }]} {return ""}
    return $actual
}

proc elab_exact_bit_handle {name} {
    set direct ""
    catch {set direct [::npi_L1::npi_nl_sig_handle_by_name $name]}
    if {$direct ne "" && $direct ne "0" && [get_handle_size $direct] eq "1" &&
        [hdl_matches_selected_signal $direct [hdl_to_name $direct] $name]} {
        return $direct
    }
    # The L1 name parser explicitly does not support all multidimensional
    # slices. Resolve the DECLARATION, then select a netlist index from the
    # elaborated LSB offset and the native netlist's own left/right range.
    set base [signal_base_without_select $name]
    set select [signal_select_suffix $name]
    set declaration [npi_handle_by_name -name $base -scope ""]
    set width [elab_bit_width $declaration]
    set offsets [elab_offsets $width [elab_ranges $declaration] $select]
    if {[llength $offsets] != 1} {error "exact bit query selects [llength $offsets] bits: $name"}
    # L0 lookup alone can return null until the scope's netlist is expanded.
    # Use L1 for the unselected declaration (no unsupported slice parsing),
    # which initializes that scope before applying the L0 index operation.
    set net [::npi_L1::npi_nl_L1_handle_by_name $base]
    if {$net eq "" || $net eq "0" || [get_handle_size $net] ne $width ||
        [signal_base_without_select [hdl_to_name $net]] ne $base} {error "netlist declaration mismatch for $name"}
    set left [npi_nl_get -property npiNlLeft -object $net]
    set right [npi_nl_get -property npiNlRight -object $net]
    if {abs($left-$right)+1 != $width} {error "netlist range/width mismatch for $name"}
    set offset [lindex $offsets 0]
    set index [expr {$left >= $right ? $right+$offset : $right-$offset}]
    set bit [npi_nl_handle_by_index -object $net -index $index]
    if {$bit eq "" || $bit eq "0" || [get_handle_size $bit] ne "1" ||
        ![hdl_matches_selected_signal $bit [hdl_to_name $bit] $name]} {error "exact elaborated bit identity unavailable for $name"}
    log_step "exact_bit_handle_mapped signal=$name lsb_offset=$offset netlist_index=$index netlist_range=$left:$right"
    return $bit
}

proc elab_exact_load_rows {hdl name} {
    if {[get_handle_size $hdl] ne "1"} {error "load query did not resolve to one bit: $name"}
    set rows {}
    set count [::npi_L1::npi_nl_bit_trace_load_by_hdl $hdl rows]
    if {![string is integer -strict $count] || $count < 0} {error "invalid bit-load count for $name"}
    # O-2018's C bridge emits {src}, not {src {}}, for an unused bit.
    # Normalize that shorthand, but still demand explicit source coverage.
    if {$count == 0 && [llength $rows] == 1 && [llength [lindex $rows 0]] == 1} {
        set rows [list [list [lindex [lindex $rows 0] 0] {}]]
    }
    if {[llength $rows] != 1 || [llength [lindex $rows 0]] != 2 ||
        [llength [lindex [lindex $rows 0] 1]] != $count} {
        error "bit-load response did not cover exactly one source bit: $name"
    }
    set source [lindex [lindex $rows 0] 0]
    if {$source eq "" || $source eq "0" || [get_handle_size $source] ne "1" ||
        ![hdl_matches_selected_signal $source [hdl_to_name $source] $name]} {
        error "bit-load response source does not match $name"
    }
    return $rows
}

proc elab_expression_bit {hdl offset evidence {depth 0}} {
    if {$depth > 128} {error "expression nesting exceeds supported traversal depth"}
    set type [elab_property $hdl npiType 1]
    set width [elab_bit_width $hdl]
    if {![string is integer -strict $width] || $width <= 0} {error "unknown $type expression width"}
    if {$type eq "npiConstant" && [regexp {^\s*'([01xXzZ])\s*$} [elab_property $hdl npiDecompile 1] -> fill]} {
        # Unbased unsized literals fill the assignment context; unlike 1'b1,
        # '1 is not zero-extended. The spelling comes from KDB, not live source.
        return "Const:1'b[string tolower $fill]"
    }
    if {$offset >= $width} {
        set signed [elab_property $hdl npiSigned]
        if {$signed eq ""} {set signed [elab_property [elab_relation $hdl npiTypespec] npiSigned]}
        if {$signed eq "1"} {set offset [expr {$width-1}]} else {return "Const:1'b0"}
    }
    if {$type in {npiConstant npiParameter}} {
        set bits [string tolower [npi_get_value -format npiBinStrVal -object $hdl]]
        if {![regexp {^[01xz]+$} $bits] || [string length $bits] != $width} {error "invalid elaborated literal value"}
        return "Const:1'b[string index $bits [expr {$width-1-$offset}]]"
    }
    if {$type eq "npiPartSelect"} {
        # O-2018 can leave a part-select's npiFullName empty even for an
        # ordinary bus[10:0]. Its documented parent/range relations retain
        # the exact identity and indices; never infer them from source text.
        set parent [elab_relation $hdl npiParent]
        set left [elab_integer [elab_relation $hdl npiLeftRange]]
        set right [elab_integer [elab_relation $hdl npiRightRange]]
        set positions [elab_offsets [elab_bit_width $parent] [elab_ranges $parent] "\[$left:$right\]"]
        if {[llength $positions] != $width} {error "inconsistent elaborated part-select width"}
        return [elab_expression_bit $parent [lindex $positions $offset] $evidence [expr {$depth+1}]]
    }
    if {$type eq "npiOperation"} {
        set op [elab_property $hdl npiOpType 1]
        if {$op in {npiConcatOp npiMultiConcatOp}} {
            set operands [elab_children $hdl npiOperand]
            if {$op eq "npiMultiConcatOp"} {
                set repeat [elab_integer [lindex $operands 0]]
                if {$repeat <= 0 || $width % $repeat != 0} {error "invalid concatenation repeat"}
                set offset [expr {$offset % ($width/$repeat)}]
                set operands [lrange $operands 1 end]
            }
            foreach operand [lreverse $operands] {
                set size [elab_bit_width $operand]
                if {![string is integer -strict $size] || $size <= 0} {error "unknown concat operand width"}
                if {$offset < $size} {return [elab_expression_bit $operand $offset $evidence [expr {$depth+1}]]}
                incr offset -$size
            }
            error "concat offset outside expression"
        }
        # Mux/arithmetic/logic/casts are semantic stops, not literal ties.
        log_step "driver_combo_stop signal=$evidence npi_operation=$op evidence_source=elaborated_expression"
        return "COMBO_EXPR:port_connection"
    }
    set name [elab_property $hdl npiFullName 1]
    if {$name eq ""} {error "unnamed elaborated $type expression"}
    if {$width == 1} {return [normalize_signal_name $name]}
    set ranges [elab_ranges $hdl]
    if {[llength $ranges] == 0} {
        # A part select's indices describe this expression's bit positions.
        if {[regexp {^(.*)\[(-?[0-9]+):(-?[0-9]+)\]$} $name -> base left right]} {
            set name $base
            set ranges [list [list $left $right]]
        } else {error "unresolved expression shape $name"}
    }
    return "${name}[elab_select_for_offset $ranges $offset]"
}

proc elab_high_literal_spelling {port_hdl inst_path portname} {
    # Older structural NPI normalizes both '1 and 1'b1 to size=1, unsigned,
    # binary value=1. The parent net's *elaborated* nlName retains the spelling.
    set low [elab_relation $port_hdl npiLowConn]
    set suffix ""
    foreach range [elab_ranges $low] {lassign $range left right; append suffix "\[$left:$right\]"}
    set candidates [list $portname "$portname$suffix"]
    # Multidimensional netlist port names can retain only the outer range,
    # e.g. a[1:0] for RTL a[1:0][3:0]. Read the native declaration spelling
    # instead of guessing it from the full structural dimension suffix.
    if {![catch {set declared [::npi_L1::npi_nl_L1_handle_by_name "${inst_path}.${portname}"]}] &&
        $declared ne "" && $declared ne "0" &&
        [get_handle_size $declared] eq [elab_bit_width $port_hdl] &&
        [signal_base_without_select [hdl_to_name $declared]] eq "${inst_path}.${portname}"} {
        set native [npi_nl_get_str -property npiNlName -object $declared]
        if {$native ne ""} {lappend candidates $native}
    }
    set scope [parent_instance_path $inst_path]
    set child [lindex [split $inst_path .] end]
    foreach candidate [lsort -unique $candidates] {
        set hdl [::npi_L1::npi_nl_instport_handle_by_nl_name $scope $child $candidate]
        if {$hdl eq "" || $hdl eq "0"} {continue}
        set net [::npi_L1::npi_nl_port_instport_2_net $hdl]
        if {$net eq "" || $net eq "0"} {continue}
        set name [npi_nl_get_str -property npiNlFullName -object $net]
        if {[regexp {\.('[01xXzZ]|[0-9]+'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+)$} $name -> literal]} {return $literal}
    }
    return ""
}

proc elab_port_starts {port_hdl inst_path portname select side} {
    set low [elab_relation $port_hdl npiLowConn]
    set width [elab_bit_width $port_hdl]
    set offsets [elab_offsets $width [elab_ranges $low] $select]
    set connection [elab_relation $port_hdl $side]
    if {$connection eq "" || $connection eq "0"} {return {}}
    set fill ""
    if {$side eq "npiHighConn" && [elab_property $connection npiType 1] eq "npiConstant" &&
        [elab_property $connection npiSize] eq "1" && $width > 1} {
        set spelling [elab_high_literal_spelling $port_hdl $inst_path $portname]
        if {[regexp {^'[01xXzZ]$} $spelling]} {set fill $spelling}
        if {$spelling eq "" && [lindex $offsets end] > 0 && [elab_property $connection npiSigned] ne "1"} {
            error "cannot distinguish sized and context-fill literal at ${inst_path}.${portname}"
        }
    }
    set result {}
    foreach offset $offsets {
        if {$fill ne ""} {set start [project_const_literal_to_bit $fill $offset]} else {
            set start [elab_expression_bit $connection $offset "${inst_path}.${portname}${select}"]
        }
        append_unique_signal result $start
        if {[is_const_literal_name $start]} {
            set source [elab_property $connection npiFile 1]
            set line [elab_property $connection npiLineNo]
            if {$source eq ""} {
                set instance [npi_handle_by_name -name $inst_path -scope ""]
                set source [elab_property $instance npiFile 1]
                set line [elab_property $instance npiLineNo]
            }
            log_const_source_detail elaborated_port_bit $start \
                resolved_signal "${inst_path}.${portname}${select}" source_file $source source_line $line \
                source_scope [parent_instance_path $inst_path] unbased_fill $fill \
                source_handle_kind [elab_property $connection npiType 1] \
                formal_width $width rhs_width [elab_property $connection npiSize] \
                rhs_offset $offset connection_side $side
        }
    }
    return $result
}

proc elab_collect_driver {name all_var module_var depth visited_var {source ""}} {
    upvar 1 $all_var all $module_var modules $visited_var visited
    # Crossing a module is not an assign expansion. Use a work queue and an
    # exact-name visited set, not the assign budget or Tcl recursion depth.
    set pending [list [list $name $source]]
    while {[llength $pending]} {
        lassign [lindex $pending end] name source
        set pending [lreplace $pending end end]
        if {$name eq ""} {continue}
        if {[is_const_literal_name $name] || [string match {COMBO_EXPR:*} $name] || [string match {ERROR:*} $name]} {
            append_unique_signal all $name
            if {![string match {COMBO_EXPR:*} $name]} {append_unique_signal modules $name}
            continue
        }
        if {[dict exists $visited $name]} {continue}
        dict set visited $name 1
        if {[signal_belongs_to_stop_instance $name]} {
            append_unique_signal all $name
            append_unique_signal modules $name
            continue
        }
        set base [regsub {(\[[^]]+\])+$} $name ""]
        set select [string range $name [string length $base] end]
        set scope [parent_instance_path $base]
        set port [get_inst_port_handle_by_signal $scope $base]
        if {$port ne "" && [get_port_direction $port] eq "input"} {
            set starts [elab_port_starts $port $scope [lindex [split $base .] end] $select npiHighConn]
            if {[llength $starts]} {
                foreach start $starts {lappend pending [list $start $source]}
                continue
            }
        }
        set hdl [elab_exact_bit_handle $name]
        if {$hdl eq "" || $hdl eq "0" || ![hdl_matches_selected_signal $hdl [hdl_to_name $hdl] $name]} {
            error "exact elaborated driver handle unavailable for $name"
        }
        # Read source provenance from the elaborated object, even when the RTL
        # file is unavailable. Never substitute a child definition for its
        # parent's assignment file merely because it was the initial hint.
        if {![catch {set structural [npi_handle_by_name -name $name -scope ""]}]} {
            set actual_source [elab_property $structural npiFile 1]
            if {$actual_source ne ""} {set source $actual_source}
        }
        set status 0
        set drivers [bit_driver_handles_by_exact_hdl $hdl $name status $depth]
        if {!$status} {error "bit driver API failed for $name"}
        if {![llength $drivers]} {append_unique_signal all $name; continue}
        foreach driver $drivers {
            set signal [hdl_to_name $driver]
            if {$signal eq ""} {error "unnamed driver of $name"}
            append_unique_signal all $signal
            if {[is_module_boundary_signal $signal]} {append_unique_signal modules $signal}
            if {[is_const_literal_name $signal]} {
                log_const_source_detail elaborated_bit_driver $signal \
                    resolved_traced_signal $name source_file $source \
                    source_handle_path [hdl_evidence_name $driver] source_handle_kind [hdl_kind $driver]
            } elseif {![is_generated_logic_signal $signal] && $signal ne $name} {
                lappend pending [list $signal $source]
            }
        }
    }
}

proc elab_exact_assign_load_net {hdl} {
    if {[info commands ::npi_L1::npi_nl_pass_assign_cell] eq ""} {return ""}
    set pass [::npi_L1::npi_nl_pass_assign_cell $hdl]
    if {$pass eq "" || $pass eq "0" || $pass eq $hdl} {return ""}
    # Only positively identified transparent assign cells may be crossed.
    # Verify that neither the opposite pin nor its net has widened the bit.
    set net [::npi_L1::npi_nl_port_instport_2_net $pass]
    if {[get_handle_size $hdl] ne "1" || [get_handle_size $pass] ne "1" ||
        $net eq "" || $net eq "0" || [get_handle_size $net] ne "1"} {
        error "assign load mapping did not preserve one-bit width"
    }
    return $net
}

proc elab_named_load_handles {net depth visited_var} {
    upvar 1 $visited_var visited
    if {[dict exists $visited $net]} {return {}}
    dict set visited $net 1
    if {[is_module_boundary_signal [hdl_to_name $net]]} {return [list $net]}
    # Concatenated LHS pseudo nets have an opaque comma-separated nlName.
    # Do not turn that spelling into an RTL name. Keep the exact one-bit
    # handle until NPI returns a real load pin/net, including further assigns.
    set rows {}
    ::npi_L1::npi_nl_bit_trace_load_by_hdl $net rows
    set handles {}
    foreach row [load_trace_limited_list $rows bit_load_opaque_net [hdl_to_name $net]] {
        foreach endpoint [load_trace_limited_list [lindex $row 1] bit_load_opaque_endpoints [hdl_to_name $net]] {
            set next ""
            if {$depth > 0 && ![signal_belongs_to_stop_instance [hdl_to_name $endpoint]]} {
                set next [elab_exact_assign_load_net $endpoint]
            }
            if {$next eq ""} {lappend handles $endpoint} else {
                foreach resolved [elab_named_load_handles $next [expr {$depth-1}] visited] {lappend handles $resolved}
            }
        }
    }
    return [lsort -unique $handles]
}
