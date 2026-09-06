# Pure helpers: loadable without Verdi for fast deterministic regression tests.

proc sv_expression_code {text} {
    # Mask tokens whose punctuation is not an operator: comments, strings,
    # escaped identifiers and four-state numeric literals (including b? / h?).
    regsub -all {(?s)/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\\\S+|(?:[0-9_]+)?'[sS]?[bBoOdDhH][ \t]*[0-9a-fA-F_xXzZ?]+|'[01xXzZ]} $text { } text
    return $text
}

proc rhs_has_ternary_expr {rhs} {
    # A mux remains computation when nested under &, ~, a call or a concat.
    # Looking only for a top-level '?' incorrectly promoted an operand's tie
    # value to the value of the entire expression.
    return [expr {[string first ? [sv_expression_code $rhs]] >= 0}]
}

proc rhs_is_computed_connection {rhs} {
    set code [sv_expression_code $rhs]
    if {[regexp {[?~!%^&*+=|<>/-]} $code]} {return 1}
    # Calls and casts are computation, not transparent wiring. Parentheses
    # around a plain signal are still allowed.
    return [regexp {[A-Za-z_$][A-Za-z0-9_$]*\s*\(|'\s*\(} $code]
}

proc canonical_port_direction {value} {
    switch -nocase -- $value {
        input - npiInput - 1 {return input}
        output - npiOutput - 2 {return output}
        inout - npiInout - 3 {return inout}
        default {return unknown}
    }
}

proc connection_expr_width {expression widths} {
    set expression [strip_wrapping_parens [string trim $expression]]
    if {[rhs_is_concat_expr $expression]} {
        set total 0
        foreach item [split_concat_items $expression] {
            set width [connection_expr_width $item $widths]
            if {$width eq ""} {return ""}
            incr total $width
        }
        return $total
    }
    return [expr_item_width $expression $widths]
}

proc connection_offsets_for_bit {expression leaf bit widths ranges} {
    set expression [strip_wrapping_parens [string trim $expression]]
    if {[rhs_is_concat_expr $expression]} {
        set offset 0
        set result {}
        foreach item [lreverse [split_concat_items $expression]] {
            set width [connection_expr_width $item $widths]
            if {$width eq ""} {return {}}
            foreach local [connection_offsets_for_bit $item $leaf $bit $widths $ranges] {
                lappend result [expr {$offset + $local}]
            }
            incr offset $width
        }
        return $result
    }
    if {[assign_lhs_leaf_name $expression] ne $leaf} {return {}}
    set select [assign_lhs_select $expression]
    if {$select eq "" && [dict exists $ranges $leaf]} {set select [dict get $ranges $leaf]}
    if {$select eq ""} {
        if {![dict exists $widths $leaf] || [dict get $widths $leaf] ne "1" || $bit ne "0"} {return {}}
        return [list 0]
    }
    set offset [lhs_select_rhs_bit_for_target $select $bit]
    return [expr {$offset eq "" ? {} : [list $offset]}]
}

proc connection_port_selects {connection leaf bit widths ranges port port_widths port_ranges} {
    if {[rhs_is_computed_connection $connection]} {return {}}
    if {$bit eq ""} {return [list ""]}
    set result {}
    foreach offset [connection_offsets_for_bit $connection $leaf $bit $widths $ranges] {
        if {[dict exists $port_ranges $port]} {
            set mapped [lhs_select_bit_from_rhs_offset [dict get $port_ranges $port] $offset]
            if {$mapped ne ""} {lappend result "\[$mapped\]"}
        } elseif {[dict exists $port_widths $port] && [dict get $port_widths $port] eq "1" && $offset == 0} {
            lappend result {[0]}
        }
    }
    return [lsort -unique $result]
}

proc trace_csv_cell {value} {
    if {[regexp {[,"\r\n]} $value]} {
        return "\"[string map [list \" \"\"] $value]\""
    }
    return $value
}

proc parse_port_directions_text {text} {
    set map {}
    # The declaration ends at the first semicolon, not at the end of its
    # physical line. Instances and assignments may legally share that line.
    set statements [split $text ";"]
    set header [lindex $statements 0]
    set depth 0
    set start -1
    set ports ""
    for {set i 0} {$i < [string length $header]} {incr i} {
        set ch [string index $header $i]
        if {$ch eq "("} {
            if {$depth == 0} {set start [expr {$i + 1}]}
            incr depth
        } elseif {$ch eq ")"} {
            incr depth -1
            if {$depth == 0 && $start >= 0} {
                # Last top-level group is the port list, after optional #(...).
                set ports [string range $header $start [expr {$i - 1}]]
            }
        }
    }
    add_ansi_ports_to_map map $ports
    foreach statement [lrange $statements 1 end] {
        if {[regexp {^\s*(input|output|inout)\s+(.*)} $statement -> dir rest]} {
            add_decl_ports_to_map map $dir $rest
        }
    }
    return $map
}

proc decimal_index_token {value} {
    if {![regexp {^([+-]?)([0-9]+)$} $value -> sign digits]} {
        return -code error "invalid decimal index: $value"
    }
    set digits [string trimleft $digits 0]
    if {$digits eq ""} {return 0}
    if {$sign eq "-"} {return "-$digits"}
    return $digits
}

proc canonicalize_numeric_selects {text} {
    if {[string first "\[" $text] < 0} {return $text}
    foreach {whole left right} [regexp -all -inline {\[([+-]?[0-9]+)(?::([+-]?[0-9]+))?\]} $text] {
        set select "\[[decimal_index_token $left]"
        if {$right ne ""} {append select ":[decimal_index_token $right]"}
        append select "\]"
        set text [string map [list $whole $select] $text]
    }
    return $text
}

proc build_stop_instance_index {instances} {
    set index {}
    foreach instance $instances {
        set instance [string trim $instance]
        if {$instance ne ""} {dict set index $instance 1}
    }
    return $index
}

proc indexed_stop_instance_match {signal index {current_instance ""}} {
    if {[dict size $index] == 0} {return 0}
    set start 0
    set length [string length $signal]
    while {$start <= $length} {
        set dot [string first . $signal $start]
        set slash [string first / $signal $start]
        if {$dot < 0} {set pos $slash} elseif {$slash < 0} {set pos $dot} else {set pos [expr {min($dot, $slash)}]}
        if {$pos < 0} {set pos $length}
        set prefix [string range $signal 0 [expr {$pos - 1}]]
        if {$prefix ne $current_instance && [dict exists $index $prefix]} {
            set rest [string range $signal [expr {$pos + 1}] end]
            if {[is_direct_instance_node $rest]} {return 1}
        }
        if {$pos == $length} {break}
        set start [expr {$pos + 1}]
    }
    return 0
}

proc source_instance_candidates {srcfile module leaf} {
    global source_instance_signal_index
    set key [list $srcfile $module]
    if {![info exists source_instance_signal_index($key)]} {
        set index {}
        foreach instance [build_instantiation_stmt_list_for_module $srcfile $module] {
            foreach token [lsort -unique [regexp -all -inline {[A-Za-z_][A-Za-z0-9_$]*} [lindex $instance 2]]] {
                dict lappend index $token $instance
            }
        }
        set source_instance_signal_index($key) $index
    }
    if {[dict exists $source_instance_signal_index($key) $leaf]} {
        return [dict get $source_instance_signal_index($key) $leaf]
    }
    return {}
}

proc enrich_child_port_shape_maps {scope srcfile module port width_var range_var} {
    upvar 1 $width_var widths $range_var ranges
    global child_port_shape_cache
    set key [list $scope $srcfile $module $port]
    if {![info exists child_port_shape_cache($key)]} {
        enrich_child_port_shape_maps_uncached $scope $srcfile $module $port widths ranges
        set shape {}
        if {[dict exists $widths $port]} {dict set shape width [dict get $widths $port]}
        if {[dict exists $ranges $port]} {dict set shape range [dict get $ranges $port]}
        set child_port_shape_cache($key) $shape
    }
    set shape $child_port_shape_cache($key)
    if {[dict exists $shape width]} {dict set widths $port [dict get $shape width]}
    if {[dict exists $shape range]} {dict set ranges $port [dict get $shape range]}
}
