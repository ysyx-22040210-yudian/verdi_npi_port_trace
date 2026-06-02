# npi_port_trace.tcl
#
# For each instance of a given module, iterate its ports, trace drivers
# and loads for the connected net, and output CSV.
#
# CSV columns: inst_full_name, port_name, port_dir, role, signal_full_name
#
# Usage (via npi_trace.sh):
#   verdi -batch -nologo -play npi_port_trace.tcl \
#         with NPI_LIB=<kdb.elab++> \
#         +tclarg_module   <target_module> \
#         +tclarg_srcfile  <module_source.v>
#
# All +tclarg_* values are passed as Tcl variables by Verdi's +tclarg mechanism.

proc log_step {msg} {
    puts stderr "\[npi_port_trace\] $msg"
    flush stderr
}

proc split_port_filter_spec { spec } {
    set spec [string trim $spec]
    if { [regexp {^([A-Za-z_][A-Za-z0-9_$]*)(\[[0-9]+(:[0-9]+)?\])$} $spec -> base select _] } {
        return [list $base $select]
    }
    return [list $spec ""]
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

# -----------------------------------------------------------------------
# Required arguments — read from environment variables
# KDB mode is mandatory: NPI_LIB and NPI_MODULE are required.
# NPI_SRCFILE is now optional (deprecated, kept for backward compatibility)
# -----------------------------------------------------------------------
if { ![info exists env(NPI_LIB)] || $env(NPI_LIB) eq "" } {
    puts stderr "ERROR: environment variable NPI_LIB is required. Filelist import is not supported."
    debExit
}

if { ![info exists env(NPI_MODULE)] || $env(NPI_MODULE) eq "" } {
    puts stderr "ERROR: environment variable NPI_MODULE is not set"
    debExit
}
set target_mod $env(NPI_MODULE)
log_step "target_module=$target_mod"

# NPI_SRCFILE is optional (deprecated)
set srcfile ""
if { [info exists env(NPI_SRCFILE)] && $env(NPI_SRCFILE) ne "" } {
    set srcfile $env(NPI_SRCFILE)
    log_step "deprecated_srcfile=$srcfile"
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

log_step "load_mode=lib lib=$npi_lib"

# Optional: comma-separated list of ports to filter (empty = all ports)
set port_filter {}
set port_filter_select_map {}
if { [info exists env(NPI_PORTS)] && $env(NPI_PORTS) ne "" } {
    foreach p [split $env(NPI_PORTS) ","] {
        set p [string trim $p]
        if { $p ne "" } {
            set parsed [split_port_filter_spec $p]
            set base [lindex $parsed 0]
            set select [lindex $parsed 1]
            lappend port_filter $base
            dict lappend port_filter_select_map $base $select
        }
    }
    set port_filter [lsort -unique $port_filter]
}
if { [llength $port_filter] > 0 } {
    log_step "port_filter=$env(NPI_PORTS)"
} else {
    log_step "port_filter=<all ports>"
}

set const_trace_max_depth 16
if { [info exists env(NPI_CONST_TRACE_MAX_DEPTH)] && $env(NPI_CONST_TRACE_MAX_DEPTH) ne "" } {
    if { [string is integer -strict $env(NPI_CONST_TRACE_MAX_DEPTH)] && $env(NPI_CONST_TRACE_MAX_DEPTH) >= 0 } {
        set const_trace_max_depth $env(NPI_CONST_TRACE_MAX_DEPTH)
    }
}
log_step "const_trace_max_depth=$const_trace_max_depth"

set const_source_fallback 1
if { [info exists env(NPI_CONST_SOURCE_FALLBACK)] && $env(NPI_CONST_SOURCE_FALLBACK) ne "" } {
    set const_source_fallback_raw [string tolower $env(NPI_CONST_SOURCE_FALLBACK)]
    if { $const_source_fallback_raw eq "0" ||
         $const_source_fallback_raw eq "false" ||
         $const_source_fallback_raw eq "no" ||
         $const_source_fallback_raw eq "off" } {
        set const_source_fallback 0
    } elseif { $const_source_fallback_raw eq "1" ||
               $const_source_fallback_raw eq "true" ||
               $const_source_fallback_raw eq "yes" ||
               $const_source_fallback_raw eq "on" } {
        set const_source_fallback 1
    }
}
log_step "const_source_fallback=$const_source_fallback"

set assign_trace_max_depth 2
if { [info exists env(NPI_ASSIGN_TRACE_MAX_DEPTH)] && $env(NPI_ASSIGN_TRACE_MAX_DEPTH) ne "" } {
    if { [string is integer -strict $env(NPI_ASSIGN_TRACE_MAX_DEPTH)] && $env(NPI_ASSIGN_TRACE_MAX_DEPTH) >= 0 } {
        set assign_trace_max_depth $env(NPI_ASSIGN_TRACE_MAX_DEPTH)
    }
}
log_step "assign_trace_max_depth=$assign_trace_max_depth"

set assign_expr_trace_max_depth 1
if { [info exists env(NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH)] && $env(NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH) ne "" } {
    if { [string is integer -strict $env(NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH)] && $env(NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH) >= 0 } {
        set assign_expr_trace_max_depth $env(NPI_ASSIGN_EXPR_TRACE_MAX_DEPTH)
    }
}
log_step "assign_expr_trace_max_depth=$assign_expr_trace_max_depth"

# Output file (written by shell via NPI_OUTFILE env var)
if { [info exists env(NPI_OUTFILE)] && $env(NPI_OUTFILE) ne "" } {
    set outfh [open $env(NPI_OUTFILE) w]
    log_step "full_trace_output=$env(NPI_OUTFILE)"
} else {
    set outfh stdout
    log_step "full_trace_output=stdout"
}

# Optional side output: module-boundary driver/load connections.
# This file only receives entries found with passMod=0, i.e. trace results
# that stop at module ports instead of crossing through the module boundary.
set module_outfh ""
if { [info exists env(NPI_MODULE_OUTFILE)] && $env(NPI_MODULE_OUTFILE) ne "" } {
    set module_outfh [open $env(NPI_MODULE_OUTFILE) w]
    log_step "module_boundary_output=$env(NPI_MODULE_OUTFILE)"
} else {
    log_step "module_boundary_output=<disabled>"
}

# -----------------------------------------------------------------------
# Load design
# -----------------------------------------------------------------------
log_step "import design by KDB"
if { [catch { debImport -elab $npi_lib } e] } {
    puts stderr "ERROR: debImport -elab failed: $e"
    debExit
}
log_step "design import done"

# -----------------------------------------------------------------------
# Build port -> direction map by parsing the module source file
# -----------------------------------------------------------------------
proc add_decl_ports_to_map { map_var dir rest } {
    upvar 1 $map_var map

    regsub -all {\[[^\]]*\]} $rest " " rest
    regsub -all {\b(wire|reg|logic|bit|signed|unsigned)\b} $rest " " rest
    regsub -all {[;()]} $rest " " rest
    foreach item [split $rest ","] {
        regsub {=.*$} $item "" item
        set item [string trim $item]
        if { [regexp {([A-Za-z_][A-Za-z0-9_$]*)$} $item -> portname] } {
            dict set map $portname $dir
        }
    }
}

proc add_ansi_ports_to_map { map_var port_text } {
    upvar 1 $map_var map

    set current_dir ""
    foreach item [split $port_text ","] {
        set item [string trim $item]
        if { $item eq "" } {
            continue
        }
        if { [regexp {^(input|output|inout)([^A-Za-z0-9_$]|$)(.*)$} $item -> dir _ rest] } {
            set current_dir $dir
            add_decl_ports_to_map map $current_dir $rest
        } elseif { $current_dir ne "" } {
            add_decl_ports_to_map map $current_dir $item
        }
    }
}

proc build_port_dir_map { srcfile target_mod } {
    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    set fh [open $srcfile r]
    set lines [split [read $fh] "\n"]
    close $fh

    set map {}
    set in_module 0
    set in_header 0
    set header_text ""
    foreach line $lines {
        set t [regsub {//.*$} [string trim $line] ""]
        if { [regexp {^module\s+([A-Za-z_][A-Za-z0-9_$]*)} $t -> modname] &&
             $modname eq $target_mod } {
            set in_module 1
            set in_header 1
            set header_text $t
        } elseif { $in_header } {
            append header_text " " $t
        }

        if { $in_header && [regexp {\)\s*;} $header_text] } {
            set open_idx [string last "(" $header_text]
            set close_idx [string last ")" $header_text]
            if { $open_idx >= 0 && $close_idx > $open_idx } {
                set port_text [string range $header_text [expr {$open_idx + 1}] [expr {$close_idx - 1}]]
                add_ansi_ports_to_map map $port_text
            }
            set in_header 0
        }

        if { $in_module } {
            if { [regexp {^\s*(input|output|inout)\s+(.*)} $t -> dir rest] } {
                add_decl_ports_to_map map $dir $rest
            }
            if { [regexp {^endmodule([^A-Za-z0-9_$]|$)} $t] } {
                set in_module 0
            }
        }
    }
    return $map
}

proc get_handle_source_file { hdl } {
    foreach getter {::npi_L1::npi_ut_get_hdl_info ::npi_L1::npi_nl_ut_get_hdl_info} {
        set info ""
        catch { set info [$getter $hdl] }
        if { $info eq "" } {
            continue
        }
        foreach token [split $info ","] {
            set token [string trim $token " \t{}"]
            if { [regexp {([^ \t{}]+\.s?vh?)\s*:} $token -> path] && [file exists $path] } {
                return $path
            }
            if { [regexp {([^ \t{}]+\.s?vh?)$} $token -> path] && [file exists $path] } {
                return $path
            }
        }
    }
    return ""
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

    if { [string equal -nocase $dir_val "input"] ||
         [string equal -nocase $dir_val "npiInput"] } {
        return "input"
    } elseif { [string equal -nocase $dir_val "output"] ||
               [string equal -nocase $dir_val "npiOutput"] } {
        return "output"
    } elseif { [string equal -nocase $dir_val "inout"] ||
               [string equal -nocase $dir_val "npiInout"] } {
        return "inout"
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

proc write_trace_row { fh inst_path portname dir role signal } {
    puts $fh "$inst_path,$portname,$dir,$role,$signal"
}

# -----------------------------------------------------------------------
# Resolve a driver/load handle to its full signal name
# -----------------------------------------------------------------------
proc is_const_literal_name { name } {
    if { $name eq "" } {
        return 0
    }
    if { [string match "Const:*" $name] } {
        return 1
    }
    if { [regexp {^'[01xXzZ?]$} $name] } {
        return 1
    }
    if { [regexp {^'[bBoOdDhH][0-9a-fA-F_xXzZ]+$} $name] } {
        return 1
    }
    if { [regexp {^[0-9]+'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+$} $name] } {
        return 1
    }
    if { [regexp {^-?[0-9]+$} $name] } {
        return 1
    }
    if { [regexp {^[\{\},\s0-9_'sSbBoOdDhHxXzZ?]+$} $name] &&
         [regexp {'[sS]?[bBoOdDhH]?[0-9a-fA-F_xXzZ?]+} $name] } {
        return 1
    }
    return 0
}

proc normalize_signal_name { name } {
    if { [is_const_literal_name $name] && ![string match "Const:*" $name] } {
        return "Const:$name"
    }
    return $name
}

proc strip_wrapping_parens { text } {
    set text [string trim $text]
    set changed 1
    while { $changed } {
        set changed 0
        if { [string length $text] >= 2 &&
             [string index $text 0] eq "(" &&
             [string index $text end] eq ")" } {
            set text [string trim [string range $text 1 end-1]]
            set changed 1
        }
    }
    return $text
}

proc const_value_from_rhs { rhs const_map } {
    set rhs [strip_wrapping_parens $rhs]
    regsub -all {\s+} $rhs "" rhs_no_space
    if { [is_const_literal_name $rhs_no_space] } {
        return [normalize_signal_name $rhs_no_space]
    }
    if { [regexp {^[A-Za-z_][A-Za-z0-9_$]*$} $rhs_no_space] &&
         [dict exists $const_map $rhs_no_space] } {
        return [dict get $const_map $rhs_no_space]
    }
    return ""
}

proc last_identifier_before_equal { text } {
    set idx [string first "=" $text]
    if { $idx < 0 } {
        return ""
    }
    set lhs [string trim [string range $text 0 [expr {$idx - 1}]]]
    regsub {\[[^\]]+\]\s*$} $lhs "" lhs
    if { [regexp {([A-Za-z_][A-Za-z0-9_$]*)\s*$} $lhs -> name] } {
        return $name
    }
    return ""
}

proc build_const_assign_map { srcfile } {
    global const_assign_map_cache

    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    if { [info exists const_assign_map_cache($srcfile)] } {
        return $const_assign_map_cache($srcfile)
    }

    set fh [open $srcfile r]
    set text ""
    foreach line [split [read $fh] "\n"] {
        regsub {//.*$} $line "" line
        append text " " [string trim $line]
    }
    close $fh

    set const_map {}
    foreach stmt [split $text ";"] {
        set stmt [string trim $stmt]
        if { $stmt eq "" } {
            continue
        }

        if { [regexp {^(localparam|parameter)\s+(.+)$} $stmt -> _ rest] } {
            set name [last_identifier_before_equal $rest]
            if { $name ne "" } {
                set rhs [string range $rest [expr {[string first "=" $rest] + 1}] end]
                set value [const_value_from_rhs $rhs $const_map]
                if { $value ne "" } {
                    dict set const_map $name $value
                }
            }
            continue
        }

        if { [regexp {^assign\s+([A-Za-z_][A-Za-z0-9_$]*)(\[[^\]]+\])?\s*=\s*(.+)$} $stmt -> name bit rhs] } {
            if { $bit eq "" } {
                set value [const_value_from_rhs $rhs $const_map]
                if { $value ne "" } {
                    dict set const_map $name $value
                }
            }
            continue
        }

        if { [regexp {^(wire|logic|reg)\s+(.+)$} $stmt -> _ rest] } {
            foreach item [split $rest ","] {
                if { [string first "=" $item] < 0 } {
                    continue
                }
                set name [last_identifier_before_equal $item]
                if { $name eq "" } {
                    continue
                }
                set rhs [string range $item [expr {[string first "=" $item] + 1}] end]
                set value [const_value_from_rhs $rhs $const_map]
                if { $value ne "" } {
                    dict set const_map $name $value
                }
            }
        }
    }

    set const_assign_map_cache($srcfile) $const_map
    return $const_map
}

proc signal_leaf_name { signame } {
    set signame [normalize_signal_name $signame]
    if { [is_const_literal_name $signame] } {
        return ""
    }
    regsub {#\[[^\]]+\]$} $signame "" signame
    regsub {\[[^\]]+\]$} $signame "" signame
    if { [regexp {([A-Za-z_][A-Za-z0-9_$]*)$} $signame -> name] } {
        return $name
    }
    return ""
}

proc signal_bit_index { signame } {
    set signame [normalize_signal_name $signame]
    if { [regexp {\[([0-9]+)\]$} $signame -> bit] } {
        return $bit
    }
    return ""
}

proc signal_scope_prefix { signame } {
    set signame [normalize_signal_name $signame]
    regsub {\[[^\]]+\]$} $signame "" signame
    if { [regexp {^(.+)\.[A-Za-z_][A-Za-z0-9_$]*$} $signame -> prefix] } {
        return $prefix
    }
    return ""
}

proc assign_lhs_leaf_name { lhs } {
    set lhs [string trim $lhs]
    regsub {\[[^\]]+\]\s*$} $lhs "" lhs
    if { [regexp {([A-Za-z_][A-Za-z0-9_$]*)\s*$} $lhs -> name] } {
        return $name
    }
    return ""
}

proc assign_lhs_select { lhs } {
    set lhs [string trim $lhs]
    if { [regexp {(\[[0-9]+(:[0-9]+)?\])\s*$} $lhs -> select] } {
        return $select
    }
    return ""
}

proc lhs_select_contains_bit { select bit } {
    if { $select eq "" } {
        return 1
    }
    if { $bit eq "" } {
        return 1
    }
    if { [regexp {^\[([0-9]+)\]$} $select -> idx] } {
        return [expr {$bit == $idx}]
    }
    if { [regexp {^\[([0-9]+):([0-9]+)\]$} $select -> hi lo] } {
        if { $hi >= $lo } {
            return [expr {$bit <= $hi && $bit >= $lo}]
        }
        return [expr {$bit >= $hi && $bit <= $lo}]
    }
    return 0
}

proc lhs_select_rhs_bit_for_target { select bit } {
    if { $bit eq "" } {
        return ""
    }
    if { $select eq "" } {
        return $bit
    }
    if { [regexp {^\[([0-9]+)\]$} $select -> idx] } {
        if { $bit == $idx } {
            return 0
        }
        return ""
    }
    if { [regexp {^\[([0-9]+):([0-9]+)\]$} $select -> hi lo] } {
        if { $hi >= $lo } {
            if { $bit <= $hi && $bit >= $lo } {
                return [expr {$bit - $lo}]
            }
        } else {
            if { $bit >= $hi && $bit <= $lo } {
                return [expr {$bit - $hi}]
            }
        }
    }
    return ""
}

proc lhs_select_bit_from_rhs_offset { select offset } {
    if { $offset eq "" } {
        return ""
    }
    if { $select eq "" } {
        return $offset
    }
    if { [regexp {^\[([0-9]+)\]$} $select -> idx] } {
        if { $offset == 0 } {
            return $idx
        }
        return ""
    }
    if { [regexp {^\[([0-9]+):([0-9]+)\]$} $select -> hi lo] } {
        if { $hi >= $lo } {
            set bit [expr {$lo + $offset}]
            if { $bit <= $hi } {
                return $bit
            }
        } else {
            set bit [expr {$hi + $offset}]
            if { $bit <= $lo } {
                return $bit
            }
        }
    }
    return ""
}

proc rhs_references_signal_bit { rhs leaf bit } {
    regsub -all {\s+} $rhs "" rhs_no_space

    if { $bit eq "" } {
        return [regexp [format {(^|[^A-Za-z0-9_$])%s([^A-Za-z0-9_$]|$)} $leaf] $rhs_no_space]
    }

    set bit_pattern [format {(^|[^A-Za-z0-9_$])%s\[%s\]([^A-Za-z0-9_$]|$)} $leaf $bit]
    if { [regexp $bit_pattern $rhs_no_space] } {
        return 1
    }

    set range_pattern [format {%s\[([0-9]+):([0-9]+)\]} $leaf]
    foreach {_ hi lo} [regexp -all -inline $range_pattern $rhs_no_space] {
        if { $hi >= $lo } {
            if { $bit <= $hi && $bit >= $lo } {
                return 1
            }
        } else {
            if { $bit >= $hi && $bit <= $lo } {
                return 1
            }
        }
    }

    set rhs_without_selected $rhs_no_space
    regsub -all [format {%s\[[^\]]+\]} $leaf] $rhs_without_selected "" rhs_without_selected
    return [regexp [format {(^|[^A-Za-z0-9_$])%s([^A-Za-z0-9_$]|$)} $leaf] $rhs_without_selected]
}

proc rhs_item_offsets_for_signal_bit { item leaf bit } {
    set item [string trim $item]
    regsub -all {\s+} $item "" item

    if { [regexp [format {^%s\[%s\]$} $leaf $bit] $item] } {
        return [list 0]
    }

    if { [regexp [format {^%s\[([0-9]+):([0-9]+)\]$} $leaf] $item -> hi lo] } {
        if { $hi >= $lo } {
            if { $bit <= $hi && $bit >= $lo } {
                return [list [expr {$bit - $lo}]]
            }
        } else {
            if { $bit >= $hi && $bit <= $lo } {
                return [list [expr {$bit - $hi}]]
            }
        }
        return {}
    }

    if { [regexp [format {^%s$} $leaf] $item] } {
        return [list $bit]
    }
    return {}
}

proc rhs_lhs_bits_for_signal_bit { rhs leaf bit {width_map {}} } {
    set rhs [string trim $rhs]
    regsub -all {\s+} $rhs "" rhs_no_space

    if { [string index $rhs_no_space 0] eq "\{" && [string index $rhs_no_space end] eq "\}" } {
        set bits {}
        set lsb 0
        foreach item [lreverse [split_concat_items $rhs_no_space]] {
            set width [expr_item_width $item $width_map]
            if { $width eq "" } {
                return {}
            }
            foreach item_offset [rhs_item_offsets_for_signal_bit $item $leaf $bit] {
                lappend bits [expr {$lsb + $item_offset}]
            }
            incr lsb $width
        }
        return $bits
    }

    return [rhs_item_offsets_for_signal_bit $rhs_no_space $leaf $bit]
}

proc strip_leading_block_end_tokens { stmt } {
    set stmt [string trim $stmt]
    set changed 1
    while { $changed } {
        set changed 0
        if { [regexp {^(end|endcase|endgenerate|join|join_any|join_none)\s+(.+)$} $stmt -> _ rest] } {
            set stmt [string trim $rest]
            set changed 1
        }
    }
    return $stmt
}

proc build_assign_stmt_list { srcfile } {
    global assign_stmt_list_cache

    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    if { [info exists assign_stmt_list_cache($srcfile)] } {
        return $assign_stmt_list_cache($srcfile)
    }

    set fh [open $srcfile r]
    set text ""
    foreach line [split [read $fh] "\n"] {
        regsub {//.*$} $line "" line
        append text " " [string trim $line]
    }
    close $fh

    set assigns {}
    foreach stmt [split $text ";"] {
        set stmt [strip_leading_block_end_tokens $stmt]
        # The simple semicolon splitter can leave a leading procedural
        # block terminator before the next continuous assign, for example
        # "end assign a = b" after an always block. Keep only the continuous
        # assign portion so source fallback does not miss that first assign.
        if { ![regexp {^assign\s+} $stmt] &&
             [regexp {(^|[^A-Za-z0-9_$])assign\s+(.+)$} $stmt -> _ assign_tail] } {
            set stmt "assign $assign_tail"
        }
        if { [regexp {^assign\s+(.+?)\s*=\s*(.+)$} $stmt -> lhs rhs] } {
            set lhs_leaf [assign_lhs_leaf_name $lhs]
            if { $lhs_leaf ne "" } {
                set lhs_select [assign_lhs_select $lhs]
                lappend assigns [list $lhs_leaf $lhs_select $rhs]
            }
        }
    }

    set assign_stmt_list_cache($srcfile) $assigns
    return $assigns
}

proc build_signal_width_map { srcfile } {
    global signal_width_map_cache

    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    if { [info exists signal_width_map_cache($srcfile)] } {
        return $signal_width_map_cache($srcfile)
    }

    set fh [open $srcfile r]
    set lines [split [read $fh] "\n"]
    close $fh

    set widths {}
    foreach line $lines {
        regsub {//.*$} $line "" line
        set line [string trim $line]
        if { $line eq "" } {
            continue
        }
        if { ![regexp {^(input|output|inout|wire|reg|logic)\s+(.*)$} $line -> _ rest] } {
            continue
        }

        regsub -all {\b(wire|reg|logic|bit|signed|unsigned)\b} $rest " " rest
        set width 1
        if { [regexp {\[([0-9]+):([0-9]+)\]} $rest -> hi lo] } {
            if { $hi >= $lo } {
                set width [expr {$hi - $lo + 1}]
            } else {
                set width [expr {$lo - $hi + 1}]
            }
            regsub -all {\[[0-9]+:[0-9]+\]} $rest " " rest
        }
        regsub -all {[;()]} $rest " " rest
        foreach item [split $rest ","] {
            regsub {=.*$} $item "" item
            set item [string trim $item]
            if { [regexp {([A-Za-z_][A-Za-z0-9_$]*)$} $item -> name] } {
                dict set widths $name $width
            }
        }
    }

    set signal_width_map_cache($srcfile) $widths
    return $widths
}

proc conn_references_signal_bit { conn leaf bit } {
    set conn [string trim $conn]
    regsub -all {\s+} $conn "" conn
    set conn_leaf [assign_lhs_leaf_name $conn]
    if { $conn_leaf ne $leaf } {
        return 0
    }

    set select [assign_lhs_select $conn]
    if { $bit eq "" } {
        return 1
    }
    return [lhs_select_contains_bit $select $bit]
}

proc build_instantiation_stmt_list { srcfile } {
    global inst_stmt_list_cache

    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    if { [info exists inst_stmt_list_cache($srcfile)] } {
        return $inst_stmt_list_cache($srcfile)
    }

    set fh [open $srcfile r]
    set text ""
    foreach line [split [read $fh] "\n"] {
        regsub {//.*$} $line "" line
        append text " " [string trim $line]
    }
    close $fh

    set insts {}
    foreach stmt [split $text ";"] {
        set stmt [strip_leading_block_end_tokens $stmt]
        if { $stmt eq "" } {
            continue
        }
        if { [regexp {^(module|endmodule|assign|always|initial|input|output|inout|wire|reg|logic|parameter|localparam)\b} $stmt] } {
            continue
        }
        if { [regexp {^([A-Za-z_][A-Za-z0-9_$]*)\s*(#\s*\(.*\)\s*)?([A-Za-z_][A-Za-z0-9_$]*)\s*\((.*)\)$} $stmt -> modname _ instname conn_text] } {
            lappend insts [list $modname $instname $conn_text]
        }
    }

    set inst_stmt_list_cache($srcfile) $insts
    return $insts
}

proc source_module_port_driver_sources { srcfile signame } {
    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }

    set leaf [signal_leaf_name $signame]
    if { $leaf eq "" } {
        return {}
    }
    set bit [signal_bit_index $signame]
    set prefix [signal_scope_prefix $signame]

    set sources {}
    foreach inst [build_instantiation_stmt_list $srcfile] {
        set modname [lindex $inst 0]
        set instname [lindex $inst 1]
        set conn_text [lindex $inst 2]
        set dir_map [build_port_dir_map $srcfile $modname]
        if { [dict size $dir_map] == 0 } {
            continue
        }

        foreach {_ port conn} [regexp -all -inline {\.([A-Za-z_][A-Za-z0-9_$]*)\s*\(\s*([^)]+?)\s*\)} $conn_text] {
            if { ![dict exists $dir_map $port] } {
                continue
            }
            set dir [dict get $dir_map $port]
            if { $dir ne "output" && $dir ne "inout" } {
                continue
            }
            if { ![conn_references_signal_bit $conn $leaf $bit] } {
                continue
            }
            if { $prefix ne "" } {
                append_unique_signal sources "${prefix}.${instname}.${port}"
            } else {
                append_unique_signal sources "${instname}.${port}"
            }
        }
    }

    if { [llength $sources] > 0 } {
        log_step "source_module_port_driver signal=$signame source=$srcfile drivers=[join $sources ,]"
    }
    return $sources
}

proc rhs_is_concat_expr { rhs } {
    set rhs [string trim $rhs]
    regsub -all {\s+} $rhs "" rhs_no_space
    return [expr {[string index $rhs_no_space 0] eq "\{" && [string index $rhs_no_space end] eq "\}"}]
}

proc rhs_is_simple_signal_expr { rhs } {
    set rhs [string trim $rhs]
    regsub -all {\s+} $rhs "" rhs_no_space
    return [expr {[llength [expr_item_source_signals $rhs_no_space ""]] > 0}]
}

proc source_assign_load_fanouts_core { sig_hdl signame {include_expr 1} } {
    set bit [signal_bit_index $signame]
    set srcfile [get_handle_source_file $sig_hdl]
    if { $srcfile eq "" } {
        return {}
    }

    set leaf [signal_leaf_name $signame]
    if { $leaf eq "" } {
        return {}
    }
    set prefix [signal_scope_prefix $signame]
    set width_map [build_signal_width_map $srcfile]

    set fanouts {}
    foreach assign [build_assign_stmt_list $srcfile] {
        set lhs_leaf [lindex $assign 0]
        set lhs_select [lindex $assign 1]
        set rhs [lindex $assign 2]
        set is_simple [rhs_is_simple_signal_expr $rhs]
        set is_concat [rhs_is_concat_expr $rhs]
        if { !$is_simple && !($include_expr && $is_concat) } {
            continue
        }
        if { ![rhs_references_signal_bit $rhs $leaf $bit] } {
            continue
        }

        if { $bit eq "" } {
            if { $prefix ne "" } {
                append_unique_signal fanouts "${prefix}.${lhs_leaf}"
            } else {
                append_unique_signal fanouts $lhs_leaf
            }
            continue
        }

        set lhs_bits [rhs_lhs_bits_for_signal_bit $rhs $leaf $bit $width_map]
        if { $prefix ne "" } {
            append_unique_signal fanouts "${prefix}.${lhs_leaf}"
        } else {
            append_unique_signal fanouts $lhs_leaf
        }
        if { [llength $lhs_bits] == 0 } {
            continue
        }
        foreach lhs_bit $lhs_bits {
            set lhs_bit [lhs_select_bit_from_rhs_offset $lhs_select $lhs_bit]
            if { $lhs_bit eq "" } {
                continue
            }
            set select ""
            if { $lhs_bit ne "" } {
                set select "\[$lhs_bit\]"
            }
            if { $prefix ne "" } {
                append_unique_signal fanouts "${prefix}.${lhs_leaf}${select}"
            } else {
                append_unique_signal fanouts "${lhs_leaf}${select}"
            }
        }
    }

    return $fanouts
}

proc source_assign_direct_load_fanouts { sig_hdl signame } {
    set fanouts [source_assign_load_fanouts_core $sig_hdl $signame 0]
    if { [llength $fanouts] > 0 } {
        set srcfile [get_handle_source_file $sig_hdl]
        log_step "source_assign_direct_load_fanout signal=$signame source=$srcfile fanouts=[join $fanouts ,]"
    }
    return $fanouts
}

proc source_assign_load_fanouts { sig_hdl signame } {
    global assign_expr_trace_max_depth

    if { $assign_expr_trace_max_depth <= 0 } {
        return {}
    }

    set fanouts [source_assign_load_fanouts_core $sig_hdl $signame 1]
    if { [llength $fanouts] > 0 } {
        set srcfile [get_handle_source_file $sig_hdl]
        log_step "source_assign_load_fanout signal=$signame source=$srcfile fanouts=[join $fanouts ,]"
    }
    return $fanouts
}

proc split_concat_items { text } {
    set text [string trim $text]
    if { [string index $text 0] eq "\{" && [string index $text end] eq "\}" } {
        set text [string range $text 1 end-1]
    }

    set items {}
    set depth 0
    set current ""
    foreach ch [split $text ""] {
        if { $ch eq "\{" } {
            incr depth
            append current $ch
        } elseif { $ch eq "\}" } {
            incr depth -1
            append current $ch
        } elseif { $ch eq "," && $depth == 0 } {
            lappend items [string trim $current]
            set current ""
        } else {
            append current $ch
        }
    }
    if { [string trim $current] ne "" } {
        lappend items [string trim $current]
    }
    return $items
}

proc const_literal_to_signal { item } {
    set item [string trim $item]
    regsub -all {\s+} $item "" item
    if { [is_const_literal_name $item] } {
        return [normalize_signal_name $item]
    }
    if { [regexp {^[0-9]+$} $item] } {
        return "Const:$item"
    }
    return ""
}

proc expr_item_width { item {width_map {}} } {
    set item [string trim $item]
    regsub -all {\s+} $item "" item
    if { [regexp {^([0-9]+)'} $item -> width] } {
        return $width
    }
    if { [regexp {\[([0-9]+):([0-9]+)\]$} $item -> hi lo] } {
        if { $hi >= $lo } {
            return [expr {$hi - $lo + 1}]
        }
        return [expr {$lo - $hi + 1}]
    }
    if { [regexp {\[[0-9]+\]$} $item] } {
        return 1
    }
    if { [regexp {^([A-Za-z_][A-Za-z0-9_$]*)$} $item -> name] } {
        if { [dict exists $width_map $name] } {
            return [dict get $width_map $name]
        }
        return 1
    }
    return ""
}

proc expr_item_source_signal { item prefix } {
    set item [string trim $item]
    regsub -all {\s+} $item "" item

    set const_sig [const_literal_to_signal $item]
    if { $const_sig ne "" } {
        return $const_sig
    }

    if { [regexp {^([A-Za-z_][A-Za-z0-9_$]*)(\[[0-9]+(:[0-9]+)?\])?$} $item -> name select] } {
        if { $prefix ne "" } {
            return "${prefix}.${name}${select}"
        }
        return "${name}${select}"
    }
    return ""
}

proc expr_item_source_signal_for_bit { item bit prefix {width_map {}} } {
    set item [string trim $item]
    regsub -all {\s+} $item "" item

    set const_sig [const_literal_to_signal $item]
    if { $const_sig ne "" } {
        return $const_sig
    }

    if { ![regexp {^([A-Za-z_][A-Za-z0-9_$]*)(\[[0-9]+(:[0-9]+)?\])?$} $item -> name select] } {
        return ""
    }

    set source_select $select
    if { $bit ne "" } {
        if { $select eq "" } {
            set width ""
            if { [dict exists $width_map $name] } {
                set width [dict get $width_map $name]
            }
            if { $width eq "" || $width > 1 || $bit != 0 } {
                set source_select "\[$bit\]"
            }
        } else {
            set source_bit [lhs_select_bit_from_rhs_offset $select $bit]
            if { $source_bit eq "" } {
                return ""
            }
            set source_select "\[$source_bit\]"
        }
    }

    if { $prefix ne "" } {
        return "${prefix}.${name}${source_select}"
    }
    return "${name}${source_select}"
}

proc expr_item_source_signals { item prefix } {
    set item [string trim $item]
    regsub -all {\s+} $item "" item

    set const_sig [const_literal_to_signal $item]
    if { $const_sig ne "" } {
        return [list $const_sig]
    }

    if { [regexp {^([A-Za-z_][A-Za-z0-9_$]*)(\[[0-9]+(:[0-9]+)?\])?$} $item -> name select] } {
        set result {}
        if { $prefix ne "" } {
            lappend result "${prefix}.${name}${select}"
        } else {
            lappend result "${name}${select}"
        }
        return $result
    }
    return {}
}

proc rhs_driver_sources_for_bit { rhs bit prefix {width_map {}} } {
    set rhs [string trim $rhs]
    regsub -all {\s+} $rhs "" rhs_no_space

    set direct_source [expr_item_source_signal_for_bit $rhs_no_space $bit $prefix $width_map]
    if { $direct_source ne "" } {
        return [list $direct_source]
    }

    if { !([string index $rhs_no_space 0] eq "\{" && [string index $rhs_no_space end] eq "\}") } {
        return {}
    }

    set items [split_concat_items $rhs_no_space]
    set lsb 0
    foreach item [lreverse $items] {
        set width [expr_item_width $item $width_map]
        if { $width eq "" } {
            return {}
        }
        set msb [expr {$lsb + $width - 1}]
        if { $bit >= $lsb && $bit <= $msb } {
            set source [expr_item_source_signal_for_bit $item [expr {$bit - $lsb}] $prefix $width_map]
            if { $source ne "" } {
                return [list $source]
            }
            return {}
        }
        incr lsb $width
    }
    return {}
}

proc rhs_driver_sources_for_whole { rhs prefix {width_map {}} } {
    set rhs [string trim $rhs]
    regsub -all {\s+} $rhs "" rhs_no_space

    set direct_sources [expr_item_source_signals $rhs_no_space $prefix]
    if { [llength $direct_sources] > 0 } {
        return $direct_sources
    }

    if { !([string index $rhs_no_space 0] eq "\{" && [string index $rhs_no_space end] eq "\}") } {
        return {}
    }

    set sources {}
    foreach item [split_concat_items $rhs_no_space] {
        foreach source [expr_item_source_signals $item $prefix] {
            append_unique_signal sources $source
        }
    }
    return $sources
}

proc source_assign_driver_sources_core { sig_hdl signame {srcfile_hint ""} {include_expr 1} } {
    set bit [signal_bit_index $signame]
    set srcfile $srcfile_hint
    if { $srcfile eq "" && $sig_hdl ne "" } {
        set srcfile [get_handle_source_file $sig_hdl]
    }
    if { $srcfile eq "" } {
        return {}
    }

    set leaf [signal_leaf_name $signame]
    if { $leaf eq "" } {
        return {}
    }
    set prefix [signal_scope_prefix $signame]
    set width_map [build_signal_width_map $srcfile]

    set sources {}
    foreach assign [build_assign_stmt_list $srcfile] {
        set lhs_leaf [lindex $assign 0]
        set lhs_select [lindex $assign 1]
        set rhs [lindex $assign 2]
        if { $lhs_leaf ne $leaf } {
            continue
        }
        if { $bit eq "" } {
            set direct_sources [expr_item_source_signals $rhs $prefix]
            foreach source $direct_sources {
                append_unique_signal sources $source
            }
            if { [llength $direct_sources] > 0 || !$include_expr } {
                continue
            }
            foreach source [rhs_driver_sources_for_whole $rhs $prefix $width_map] {
                append_unique_signal sources $source
            }
        } else {
            set rhs_bit [lhs_select_rhs_bit_for_target $lhs_select $bit]
            if { $rhs_bit eq "" } {
                continue
            }
            set direct_source [expr_item_source_signal_for_bit $rhs $rhs_bit $prefix $width_map]
            if { $direct_source ne "" } {
                append_unique_signal sources $direct_source
                continue
            }
            if { !$include_expr } {
                continue
            }
            foreach source [rhs_driver_sources_for_bit $rhs $rhs_bit $prefix $width_map] {
                append_unique_signal sources $source
            }
        }
    }

    return $sources
}

proc source_assign_const_chain { signame srcfile depth visited_var } {
    upvar 1 $visited_var visited

    if { $depth <= 0 || $srcfile eq "" } {
        return {}
    }
    set signame [normalize_signal_name $signame]
    if { $signame eq "" || [is_const_literal_name $signame] } {
        return {}
    }
    if { [lsearch -exact $visited $signame] >= 0 } {
        return {}
    }
    lappend visited $signame

    set consts {}
    foreach source_sig [source_assign_driver_sources_core "" $signame $srcfile 1] {
        if { [is_const_literal_name $source_sig] } {
            append_unique_signal consts $source_sig
        } else {
            foreach const_sig [source_assign_const_chain $source_sig $srcfile [expr {$depth - 1}] visited] {
                append_unique_signal consts $const_sig
            }
        }
    }
    return $consts
}

proc source_assign_direct_driver_sources { sig_hdl signame {srcfile_hint ""} } {
    set sources [source_assign_driver_sources_core $sig_hdl $signame $srcfile_hint 0]
    if { [llength $sources] > 0 } {
        log_step "source_assign_direct_driver_source signal=$signame source=$srcfile_hint drivers=[join $sources ,]"
    }
    return $sources
}

proc source_assign_driver_sources { sig_hdl signame {srcfile_hint ""} } {
    global assign_expr_trace_max_depth

    if { $assign_expr_trace_max_depth <= 0 } {
        return {}
    }

    set sources [source_assign_driver_sources_core $sig_hdl $signame $srcfile_hint 1]
    if { [llength $sources] == 0 } {
        return {}
    }

    set srcfile $srcfile_hint
    if { $srcfile eq "" && $sig_hdl ne "" } {
        set srcfile [get_handle_source_file $sig_hdl]
    }

    set expanded_sources $sources
    if { $srcfile ne "" && $assign_expr_trace_max_depth > 0 } {
        foreach source_sig $sources {
            set visited {}
            foreach const_sig [source_assign_const_chain $source_sig $srcfile $assign_expr_trace_max_depth visited] {
                append_unique_signal expanded_sources $const_sig
            }
        }
    }

    if { [llength $expanded_sources] > 0 } {
        log_step "source_assign_driver_source signal=$signame source=$srcfile drivers=[join $expanded_sources ,]"
    }
    return $expanded_sources
}

proc parent_instance_path { inst_path } {
    set parts [split $inst_path "."]
    if { [llength $parts] <= 1 } {
        return ""
    }
    return [join [lrange $parts 0 end-1] "."]
}

proc strip_signal_selects { signame } {
    regsub {#\[[^\]]+\]$} $signame "" signame
    regsub {\[[^\]]+\]$} $signame "" signame
    return $signame
}

proc signal_matches_inst_port { signame inst_path portname } {
    set signame [strip_signal_selects [normalize_signal_name $signame]]
    if { [is_const_literal_name $signame] || $inst_path eq "" || $portname eq "" } {
        return 0
    }

    set full_port "${inst_path}.${portname}"
    if { $signame eq $full_port } {
        return 1
    }

    set inst_leaf [lindex [split $inst_path "."] end]
    set leaf_port "${inst_leaf}.${portname}"
    if { $signame eq $leaf_port } {
        return 1
    }

    return 0
}

proc get_inst_port_handle_by_signal { inst_path signame } {
    foreach port_hdl [get_port_handles $inst_path] {
        set portname [get_port_name $port_hdl]
        if { [signal_matches_inst_port $signame $inst_path $portname] } {
            return $port_hdl
        }
    }
    return ""
}

proc get_high_conn_sigs_for_port_hdl { inst_path target_port_hdl } {
    set port2highList {}
    if { [catch { ::npi_L1::npi_inst_port_2_high_conn_sig $inst_path port2highList } e] } {
        return {}
    }
    foreach pair $port2highList {
        set port_hdl [lindex $pair 0]
        if { $port_hdl == $target_port_hdl } {
            return [lindex $pair 1]
        }
    }
    return {}
}

proc const_driver_from_parent_ports { sig_hdl signame start_inst max_depth } {
    if { $max_depth <= 0 } {
        return ""
    }

    set current_hdl $sig_hdl
    set current_name [normalize_signal_name $signame]
    set current_inst $start_inst
    set depth 0
    set visited {}

    while { $depth < $max_depth } {
        if { [is_const_literal_name $current_name] } {
            return $current_name
        }
        if { $current_inst eq "" || $current_name eq "" } {
            return ""
        }

        set visit_key "${current_inst}|${current_name}"
        if { [lsearch -exact $visited $visit_key] >= 0 } {
            log_step "const_parent_port_trace_stop reason=loop signal=$current_name inst=$current_inst"
            return ""
        }
        lappend visited $visit_key

        set port_hdl [get_inst_port_handle_by_signal $current_inst $current_name]
        if { $port_hdl eq "" } {
            return ""
        }

        set high_sigs [get_high_conn_sigs_for_port_hdl $current_inst $port_hdl]
        log_step "const_parent_port_trace depth=$depth inst=$current_inst signal=$current_name high_conn_count=[llength $high_sigs]"
        if { [llength $high_sigs] == 0 } {
            return ""
        }

        foreach high_hdl $high_sigs {
            set high_name [hdl_to_name $high_hdl]
            if { [is_const_literal_name $high_name] } {
                log_step "const_driver_from_parent_port_chain signal=$current_name inst=$current_inst value=$high_name depth=$depth"
                return $high_name
            }
        }

        if { [llength $high_sigs] != 1 } {
            return ""
        }

        set current_hdl [lindex $high_sigs 0]
        set current_name [hdl_to_name $current_hdl]
        set current_inst [parent_instance_path $current_inst]
        incr depth
    }

    log_step "const_parent_port_trace_stop reason=max_depth signal=$current_name inst=$current_inst depth=$max_depth"
    return ""
}

proc const_driver_from_connected_signal { sig_hdl signame } {
    global const_source_fallback

    set signame [normalize_signal_name $signame]
    if { [is_const_literal_name $signame] } {
        return $signame
    }
    if { !$const_source_fallback } {
        return ""
    }

    set srcfile [get_handle_source_file $sig_hdl]
    if { $srcfile eq "" } {
        return ""
    }

    set leaf [signal_leaf_name $signame]
    if { $leaf eq "" } {
        return ""
    }

    set const_map [build_const_assign_map $srcfile]
    if { [dict exists $const_map $leaf] } {
        set value [dict get $const_map $leaf]
        log_step "const_driver_from_parent_signal signal=$signame source=$srcfile value=$value"
        return $value
    }
    return ""
}

proc is_self_port_signal { signame inst_path portname } {
    set signame [normalize_signal_name $signame]
    if { [is_const_literal_name $signame] } {
        return 0
    }

    set suffix "${inst_path}.${portname}"
    if { [string equal $signame $suffix] ||
         [string first "${suffix}\[" $signame] == 0 } {
        return 1
    }

    set inst_parts [split $inst_path "."]
    set common_prefix [join [lrange $inst_parts 0 end-2] "."]
    set short_name $signame
    if { $common_prefix ne "" && [string match "${common_prefix}.*" $short_name] } {
        set short_name [string range $short_name [expr {[string length $common_prefix] + 1}] end]
    }
    set short_suffix "[lindex $inst_parts end].${portname}"
    if { [string equal $short_name $short_suffix] ||
         [string first "${short_suffix}\[" $short_name] == 0 } {
        return 1
    }
    return 0
}

proc hdl_to_name { hdl } {
    set is_literal 0
    catch { set is_literal [::npi_L1::npi_nl_ut_get_actual_is_literal $hdl] }
    if { $is_literal == 1 } {
        set value ""
        catch { set value [::npi_L1::npi_nl_ut_get_actual_value $hdl] }
        if { $value ne "" } {
            return "Const:$value"
        }
    }

    set info ""
    catch { set info [::npi_L1::npi_nl_ut_get_hdl_info $hdl] }
    set signame [string trim [lindex [split $info ","] 1]]
    if { $signame eq "" } {
        catch { set info [::npi_L1::npi_ut_get_hdl_info $hdl] }
        set signame [string trim [lindex [split $info ","] 1]]
    }
    if { $signame eq "" } {
        set net_hdl ""
        catch { set net_hdl [::npi_L1::npi_nl_port_instport_2_net $hdl] }
        if { $net_hdl ne "" && $net_hdl != 0 } {
            set net_literal 0
            catch { set net_literal [::npi_L1::npi_nl_ut_get_actual_is_literal $net_hdl] }
            if { $net_literal == 1 } {
                set value ""
                catch { set value [::npi_L1::npi_nl_ut_get_actual_value $net_hdl] }
                if { $value ne "" } {
                    return "Const:$value"
                }
            }
            catch { set info [::npi_L1::npi_nl_ut_get_hdl_info $net_hdl] }
            set signame [string trim [lindex [split $info ","] 1]]
            if { $signame eq "" } {
                catch { set info [::npi_L1::npi_ut_get_hdl_info $net_hdl] }
                set signame [string trim [lindex [split $info ","] 1]]
            }
        }
    }
    return [normalize_signal_name $signame]
}

proc hdl_kind { hdl } {
    foreach api {
        ::npi_L1::npi_nl_ut_get_hdl_info
        ::npi_L1::npi_ut_get_hdl_info
    } {
        set info ""
        if { ![catch { set info [$api $hdl] } err] && $info ne "" } {
            return [string trim [lindex [split $info ","] 0]]
        }
    }
    return ""
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

    if { [is_const_literal_name $signame] } {
        return 1
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

proc module_boundary_port_direction { hdl signame } {
    set dir [get_port_direction $hdl]
    if { $dir ne "unknown" } {
        return $dir
    }

    set base [strip_signal_selects [normalize_signal_name $signame]]
    if { ![regexp {^(.+)\.([A-Za-z_][A-Za-z0-9_$]*)$} $base -> inst_path portname] } {
        return "unknown"
    }

    set port_hdl [get_inst_port_handle_by_signal $inst_path $base]
    if { $port_hdl eq "" } {
        return "unknown"
    }
    return [get_port_direction $port_hdl]
}

proc collect_conn_module_ports_for_query { query_sig role all_var module_var } {
    upvar 1 $all_var all_values
    upvar 1 $module_var module_values
    set connList {}
    if { [catch { ::npi_L1::npi_nl_sig_2_mod_inst_conn $query_sig connList 0 1 } err] } {
        log_step "module_conn_trace_error role=$role signal=$query_sig error=$err"
        return
    }

    foreach hdl $connList {
        set sig [hdl_to_name $hdl]
        if { ![is_module_boundary_signal $sig] } {
            continue
        }

        set dir [module_boundary_port_direction $hdl $sig]
        set keep 0
        if { $role eq "driver" } {
            if { $dir eq "output" || $dir eq "inout" } {
                set keep 1
            }
        } elseif { $role eq "load" } {
            if { $dir eq "input" || $dir eq "inout" } {
                set keep 1
            }
        }
        if { !$keep } {
            continue
        }

        append_unique_signal all_values $sig
        append_unique_signal module_values $sig
    }
}

proc collect_conn_module_ports_by_name { signame role all_var module_var } {
    upvar 1 $all_var all_values
    upvar 1 $module_var module_values

    collect_conn_module_ports_for_query $signame $role all_values module_values

    set base [strip_signal_selects [normalize_signal_name $signame]]
    if { $base ne $signame } {
        collect_conn_module_ports_for_query $base $role all_values module_values
    }
}

proc should_expand_assign_endpoint { hdl signame } {
    set signame [normalize_signal_name $signame]
    if { $signame eq "" || [is_const_literal_name $signame] } {
        return 0
    }

    # Generated logic, module ports, and expression instances are real trace
    # endpoints. Expanding through them can cross logic that should stay
    # visible in the result.
    foreach bad {
        "/" "_ExprInst__"
        "Always" "Initial" "Init" "SigOp"
        "Combo" "RegCombo" "ComboMemory"
    } {
        if { [string first $bad $signame] >= 0 } {
            return 0
        }
    }

    set kind [string tolower [hdl_kind $hdl]]
    if { $kind ne "" } {
        if { [string first "port" $kind] >= 0 ||
             [string match "*pin" $kind] } {
            return 0
        }
        if { [string first "net" $kind] >= 0 ||
             [string first "sig" $kind] >= 0 ||
             [string first "wire" $kind] >= 0 } {
            return 1
        }
    }

    return [is_module_boundary_signal $signame]
}

proc should_expand_assign_expr_endpoint { hdl signame } {
    set signame [normalize_signal_name $signame]
    if { $signame eq "" || [is_const_literal_name $signame] } {
        return 0
    }

    # These are semantic endpoints. They should be reported, but should not be
    # used as a new starting point for expression expansion.
    foreach stop {
        "RegCombo" "ComboMemory" "_ExprInst__"
        "Always" "Initial" "Init"
    } {
        if { [string first $stop $signame] >= 0 } {
            return 0
        }
    }

    set kind [string tolower [hdl_kind $hdl]]
    if { $kind ne "" } {
        if { [string first "port" $kind] >= 0 ||
             [string match "*pin" $kind] } {
            return 0
        }
        if { [string first "expr" $kind] >= 0 ||
             [string first "op" $kind] >= 0 ||
             [string first "assign" $kind] >= 0 } {
            return 1
        }
    }

    # Verdi often names continuous-assign expression nodes as SigOp/SigTap or
    # Combo nodes. Treat them as expandable only on the driver path, with a
    # separate depth limit.
    foreach marker {
        "SigOp" "SigTap" "Concat" "/Combo."
    } {
        if { [string first $marker $signame] >= 0 } {
            return 1
        }
    }

    return 0
}

proc append_unique_signal { list_var signame } {
    upvar 1 $list_var values

    set signame [normalize_signal_name $signame]
    if { $signame eq "" } {
        return 0
    }
    if { [lsearch -exact $values $signame] >= 0 } {
        return 0
    }

    lappend values $signame
    return 1
}

proc signal_seen_or_mark { visited_var signame } {
    upvar 1 $visited_var visited

    set signame [normalize_signal_name $signame]
    if { [lsearch -exact $visited $signame] >= 0 } {
        return 1
    }
    lappend visited $signame
    return 0
}

proc collect_drivers_by_name { signame all_drivers_var module_drivers_var {srcfile_hint ""} } {
    global assign_trace_max_depth assign_expr_trace_max_depth
    upvar 1 $all_drivers_var all_drivers
    upvar 1 $module_drivers_var module_drivers

    set visited {}
    collect_drivers_by_name_rec $signame all_drivers module_drivers $assign_trace_max_depth $assign_expr_trace_max_depth visited $srcfile_hint
}

proc collect_source_driver_sources { signame srcfile_hint all_drivers_var module_drivers_var net_depth expr_depth visited_var } {
    upvar 1 $all_drivers_var all_drivers
    upvar 1 $module_drivers_var module_drivers
    upvar 1 $visited_var visited

    if { ($net_depth <= 0 && $expr_depth <= 0) || $srcfile_hint eq "" } {
        return
    }

    foreach port_sig [source_module_port_driver_sources $srcfile_hint $signame] {
        append_unique_signal all_drivers $port_sig
        append_unique_signal module_drivers $port_sig
    }

    set direct_sources {}
    if { $net_depth > 0 } {
        foreach source_sig [source_assign_direct_driver_sources "" $signame $srcfile_hint] {
            append_unique_signal direct_sources $source_sig
            append_unique_signal all_drivers $source_sig
            if { [is_module_boundary_signal $source_sig] } {
                append_unique_signal module_drivers $source_sig
            }
            if { ![is_const_literal_name $source_sig] } {
                collect_drivers_by_name_rec $source_sig all_drivers module_drivers [expr {$net_depth - 1}] $expr_depth visited $srcfile_hint
            }
        }
    }

    if { $expr_depth <= 0 } {
        return
    }

    foreach source_sig [source_assign_driver_sources "" $signame $srcfile_hint] {
        if { [lsearch -exact $direct_sources $source_sig] >= 0 } {
            continue
        }
        append_unique_signal all_drivers $source_sig
        if { [is_module_boundary_signal $source_sig] } {
            append_unique_signal module_drivers $source_sig
        }
        if { ![is_const_literal_name $source_sig] } {
            collect_drivers_by_name_rec $source_sig all_drivers module_drivers $net_depth [expr {$expr_depth - 1}] visited $srcfile_hint
        }
    }
}

proc collect_drivers_by_name_rec { signame all_drivers_var module_drivers_var net_depth expr_depth visited_var {srcfile_hint ""} } {
    upvar 1 $all_drivers_var all_drivers
    upvar 1 $module_drivers_var module_drivers
    upvar 1 $visited_var visited

    set signame [normalize_signal_name $signame]
    if { $signame eq "" || [is_const_literal_name $signame] } {
        return
    }
    if { [signal_seen_or_mark visited $signame] } {
        return
    }

    set driverList {}
    if { [catch { ::npi_L1::npi_nl_trace_driver $signame driverList 0 1 } err] } {
        log_step "driver_assign_trace_error passMod=1 signal=$signame error=$err"
        set driverList {}
    }

    foreach hdl $driverList {
        set sig [hdl_to_name $hdl]
        if { $sig eq "" } {
            continue
        }
        append_unique_signal all_drivers $sig
        if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
            log_step "driver_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
            collect_drivers_by_name_rec $sig all_drivers module_drivers [expr {$net_depth - 1}] $expr_depth $visited_var $srcfile_hint
        } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
            log_step "driver_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
            collect_drivers_by_name_rec $sig all_drivers module_drivers $net_depth [expr {$expr_depth - 1}] $visited_var $srcfile_hint
        }
    }

    set moduleDriverList {}
    if { [catch { ::npi_L1::npi_nl_trace_driver $signame moduleDriverList 0 0 } err] } {
        log_step "driver_assign_trace_error passMod=0 signal=$signame error=$err"
        set moduleDriverList {}
    }
    foreach hdl $moduleDriverList {
        set sig [hdl_to_name $hdl]
        if { [is_module_boundary_signal $sig] } {
            append_unique_signal module_drivers $sig
            append_unique_signal all_drivers $sig
            if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
                log_step "driver_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
                collect_drivers_by_name_rec $sig all_drivers module_drivers [expr {$net_depth - 1}] $expr_depth $visited_var $srcfile_hint
            } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
                log_step "driver_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
                collect_drivers_by_name_rec $sig all_drivers module_drivers $net_depth [expr {$expr_depth - 1}] $visited_var $srcfile_hint
            }
        }
    }

    collect_conn_module_ports_by_name $signame driver all_drivers module_drivers
    collect_source_driver_sources $signame $srcfile_hint all_drivers module_drivers $net_depth $expr_depth $visited_var
}

proc collect_loads_by_name { signame all_loads_var module_loads_var } {
    global assign_trace_max_depth assign_expr_trace_max_depth
    upvar 1 $all_loads_var all_loads
    upvar 1 $module_loads_var module_loads

    set visited {}
    collect_loads_by_name_rec $signame all_loads module_loads $assign_trace_max_depth $assign_expr_trace_max_depth visited
}

proc collect_source_load_fanouts { hdl signame all_loads_var module_loads_var net_depth expr_depth visited_var } {
    upvar 1 $all_loads_var all_loads
    upvar 1 $module_loads_var module_loads
    upvar 1 $visited_var visited

    if { $net_depth <= 0 && $expr_depth <= 0 } {
        return
    }

    set direct_fanouts {}
    if { $net_depth > 0 } {
        foreach fanout_sig [source_assign_direct_load_fanouts $hdl $signame] {
            append_unique_signal direct_fanouts $fanout_sig
            append_unique_signal all_loads $fanout_sig
            collect_loads_by_name_rec $fanout_sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth visited
        }
    }

    if { $expr_depth <= 0 } {
        return
    }

    foreach fanout_sig [source_assign_load_fanouts $hdl $signame] {
        if { [lsearch -exact $direct_fanouts $fanout_sig] >= 0 } {
            continue
        }
        append_unique_signal all_loads $fanout_sig
        collect_loads_by_name_rec $fanout_sig all_loads module_loads $net_depth [expr {$expr_depth - 1}] visited
    }
}

proc collect_loads_by_name_rec { signame all_loads_var module_loads_var net_depth expr_depth visited_var } {
    upvar 1 $all_loads_var all_loads
    upvar 1 $module_loads_var module_loads
    upvar 1 $visited_var visited

    set signame [normalize_signal_name $signame]
    if { $signame eq "" || [is_const_literal_name $signame] } {
        return
    }
    if { [signal_seen_or_mark visited $signame] } {
        return
    }

    set loadList {}
    if { [catch { ::npi_L1::npi_nl_trace_load $signame loadList 1 1 } err] } {
        log_step "load_assign_trace_error passMod=1 signal=$signame error=$err"
        set loadList {}
    }

    foreach hdl $loadList {
        set sig [hdl_to_name $hdl]
        if { $sig eq "" } {
            continue
        }
        append_unique_signal all_loads $sig
        if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
            log_step "load_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
            collect_loads_by_name_rec $sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth $visited_var
        } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
            log_step "load_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
            collect_loads_by_name_rec $sig all_loads module_loads $net_depth [expr {$expr_depth - 1}] $visited_var
        }
        collect_source_load_fanouts $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var
    }

    set moduleLoadList {}
    if { [catch { ::npi_L1::npi_nl_trace_load $signame moduleLoadList 1 0 } err] } {
        log_step "load_assign_trace_error passMod=0 signal=$signame error=$err"
        set moduleLoadList {}
    }
    foreach hdl $moduleLoadList {
        set sig [hdl_to_name $hdl]
        if { [is_module_boundary_signal $sig] } {
            append_unique_signal module_loads $sig
            append_unique_signal all_loads $sig
            if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
                log_step "load_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
                collect_loads_by_name_rec $sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth $visited_var
            } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
                log_step "load_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
                collect_loads_by_name_rec $sig all_loads module_loads $net_depth [expr {$expr_depth - 1}] $visited_var
            }
            collect_source_load_fanouts $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var
        }
    }

    # npi_nl_trace_load can stop at assign-generated SigTap/Combo pins for
    # sliced fanout such as "assign B = A[10:0]". The connection API with
    # assignCell=0 passes through assign cells and, with isStopAtPin=1, returns
    # real module instance ports connected to the same network.
    set connLoadList {}
    if { [catch { ::npi_L1::npi_nl_sig_2_mod_inst_conn $signame connLoadList 0 1 } err] } {
        log_step "load_assign_conn_error signal=$signame error=$err"
        set connLoadList {}
    }
    foreach hdl $connLoadList {
        set sig [hdl_to_name $hdl]
        if { [is_module_boundary_signal $sig] } {
            append_unique_signal module_loads $sig
            append_unique_signal all_loads $sig
            if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
                log_step "load_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
                collect_loads_by_name_rec $sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth $visited_var
            } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
                log_step "load_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
                collect_loads_by_name_rec $sig all_loads module_loads $net_depth [expr {$expr_depth - 1}] $visited_var
            }
            collect_source_load_fanouts $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var
        }
    }
}

# -----------------------------------------------------------------------
# Format signal name for better readability
# Remove common prefix and simplify the output
# -----------------------------------------------------------------------
proc format_signal_name { signame inst_path } {
    set signame [normalize_signal_name $signame]

    if { [string match "Const:*" $signame] } {
        return $signame
    }

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

proc apply_signal_select { signame select } {
    set signame [normalize_signal_name $signame]
    if { $select eq "" ||
         $signame eq "" ||
         [is_const_literal_name $signame] } {
        return $signame
    }

    # Do not append bit selects to generated logic/expression names or to an
    # already-selected connection. Those names are not valid Verilog bit-select
    # roots for NPI string tracing.
    foreach marker {
        "/" "_ExprInst__" "Always" "Initial" "Init"
        "SigOp" "SigTap" "Combo" "RegCombo" "ComboMemory"
    } {
        if { [string first $marker $signame] >= 0 } {
            return $signame
        }
    }
    if { [regexp {\[[0-9]+(:[0-9]+)?\]$} $signame] } {
        return $signame
    }
    return "${signame}${select}"
}

proc selected_port_names { portname } {
    global port_filter_select_map

    if { [dict exists $port_filter_select_map $portname] } {
        set names {}
        foreach select [dict get $port_filter_select_map $portname] {
            if { $select eq "" } {
                lappend names $portname
            } else {
                lappend names "${portname}${select}"
            }
        }
        return [lsort -unique $names]
    }
    return [list $portname]
}

# -----------------------------------------------------------------------
# Process one instance: emit CSV rows for all its ports
# -----------------------------------------------------------------------
proc process_instance { inst_path parent_path instname port_filter outfh module_outfh } {
    global target_mod const_trace_max_depth assign_trace_max_depth assign_expr_trace_max_depth

    log_step "process_instance=$inst_path parent=$parent_path instname=$instname"
    # Get IO handles for port direction lookup (needed for internal logic)
    set io_hdl_list [get_io_handles $inst_path]
    log_step "io_handle_count=[llength $io_hdl_list] instance=$inst_path"

    # Build port name -> direction map from IO handles
    set port_dir_map {}
    set src_port_dir_map {}
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
    log_step "port_handle_count=[llength $port_hdl_list] instance=$inst_path"

    if { [llength $port_hdl_list] > 0 } {
        set module_srcfile [get_handle_source_file [lindex $port_hdl_list 0]]
        if { $module_srcfile ne "" } {
            set src_port_dir_map [build_port_dir_map $module_srcfile $target_mod]
            log_step "source_port_direction_file=$module_srcfile parsed_ports=[dict size $src_port_dir_map] instance=$inst_path"
        }
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
    log_step "connection_maps high_entries=[llength $port2highList] low_entries=[llength $port2lowList] instance=$inst_path"

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
            log_step "skip_port port=$portname reason=not_in_filter instance=$inst_path"
            continue
        }

        # Get direction from the map (for internal logic only, not output)
        set dir "unknown"
        if { [dict exists $port_dir_map $portname] } {
            set dir [dict get $port_dir_map $portname]
        }
        if { $dir eq "unknown" && [dict exists $src_port_dir_map $portname] } {
            set dir [dict get $src_port_dir_map $portname]
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
        log_step "trace_port instance=$inst_path port=$portname dir=$dir high_conn_count=[llength $high_sigs] low_conn_count=[llength $low_sigs]"

        set base_portname $portname
        foreach trace_portname [selected_port_names $base_portname] {
            set parsed_trace_port [split_port_filter_spec $trace_portname]
            set trace_select [lindex $parsed_trace_port 1]
            set portname $trace_portname
            if { $trace_select ne "" } {
                log_step "trace_port_bit instance=$inst_path port=$portname base_port=$base_portname select=$trace_select"
            }

        if { [llength $high_sigs] == 0 && [llength $low_sigs] == 0 } {
            log_step "port_no_connections instance=$inst_path port=$portname"
            write_trace_row $outfh $inst_path $portname $dir driver "ERROR:no_connections"
            write_trace_row $outfh $inst_path $portname $dir load "ERROR:no_connections"
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
            set signame [apply_signal_select [hdl_to_name $sig_hdl] $trace_select]
            if { $signame eq "" } {
                continue
            }

            set const_driver_for_connection 0

            if { $module_outfh ne "" && [is_const_literal_name $signame] } {
                lappend module_drivers $signame
                set const_driver_for_connection 1
            }

            set parent_const_driver [const_driver_from_connected_signal $sig_hdl $signame]
            if { $parent_const_driver ne "" } {
                lappend all_drivers $parent_const_driver
                set const_driver_for_connection 1
                if { $module_outfh ne "" } {
                    lappend module_drivers $parent_const_driver
                }
            }

            set parent_port_const_driver [const_driver_from_parent_ports $sig_hdl $signame $parent_path $const_trace_max_depth]
            if { $parent_port_const_driver ne "" } {
                lappend all_drivers $parent_port_const_driver
                set const_driver_for_connection 1
                if { $module_outfh ne "" } {
                    lappend module_drivers $parent_port_const_driver
                }
            }

            set driver_count_before [llength $all_drivers]
            set module_driver_count_before [llength $module_drivers]
            set driver_srcfile_hint [get_handle_source_file $sig_hdl]
            collect_drivers_by_name $signame all_drivers module_drivers $driver_srcfile_hint
            if { [llength $all_drivers] == $driver_count_before } {
                set direct_sources {}
                if { $assign_trace_max_depth > 0 } {
                    foreach source_sig [source_assign_direct_driver_sources $sig_hdl $signame $driver_srcfile_hint] {
                        append_unique_signal direct_sources $source_sig
                        append_unique_signal all_drivers $source_sig
                        if { $module_outfh ne "" && [is_module_boundary_signal $source_sig] } {
                            append_unique_signal module_drivers $source_sig
                        }
                        if { ![is_const_literal_name $source_sig] } {
                            collect_drivers_by_name $source_sig all_drivers module_drivers $driver_srcfile_hint
                        }
                    }
                }
                foreach source_sig [source_assign_driver_sources $sig_hdl $signame $driver_srcfile_hint] {
                    if { [lsearch -exact $direct_sources $source_sig] >= 0 } {
                        continue
                    }
                    append_unique_signal all_drivers $source_sig
                    if { $module_outfh ne "" && [is_module_boundary_signal $source_sig] } {
                        append_unique_signal module_drivers $source_sig
                    }
                    if { ![is_const_literal_name $source_sig] } {
                        collect_drivers_by_name $source_sig all_drivers module_drivers $driver_srcfile_hint
                    }
                }
            }

            # If name-based tracing returns no endpoint, keep the old
            # handle-based fallback for the direct connection only.
            if { [llength $all_drivers] == $driver_count_before } {
                # Note: return value can be 1 (success) or 2 (success with some condition)
                set driverList {}
                catch { ::npi_L1::npi_nl_trace_driver_by_hdl $sig_hdl driverList 0 1 }
                foreach hdl $driverList {
                    set sig [hdl_to_name $hdl]
                    if { $sig ne "" } {
                        append_unique_signal all_drivers $sig
                        if { [should_expand_assign_endpoint $hdl $sig] } {
                            log_step "driver_assign_continue from=$signame via=$sig remaining_depth=$assign_trace_max_depth"
                            collect_drivers_by_name $sig all_drivers module_drivers $driver_srcfile_hint
                        } elseif { [should_expand_assign_expr_endpoint $hdl $sig] } {
                            log_step "driver_assign_expr_continue from=$signame via=$sig remaining_depth=$assign_expr_trace_max_depth"
                            collect_drivers_by_name $sig all_drivers module_drivers $driver_srcfile_hint
                        }
                    }
                }
            }

            # If module-boundary name tracing also returns no endpoint, keep
            # the old handle-based fallback for the direct connection only.
            if { $module_outfh ne "" && !$const_driver_for_connection &&
                 [llength $module_drivers] == $module_driver_count_before } {
                set moduleDriverList {}
                catch { ::npi_L1::npi_nl_trace_driver_by_hdl $sig_hdl moduleDriverList 0 0 }
                foreach hdl $moduleDriverList {
                    set sig [hdl_to_name $hdl]
                    if { [is_module_boundary_signal $sig] } {
                        append_unique_signal module_drivers $sig
                        append_unique_signal all_drivers $sig
                        if { [should_expand_assign_endpoint $hdl $sig] } {
                            log_step "driver_assign_continue from=$signame via=$sig remaining_depth=$assign_trace_max_depth"
                            collect_drivers_by_name $sig all_drivers module_drivers $driver_srcfile_hint
                        } elseif { [should_expand_assign_expr_endpoint $hdl $sig] } {
                            log_step "driver_assign_expr_continue from=$signame via=$sig remaining_depth=$assign_expr_trace_max_depth"
                            collect_drivers_by_name $sig all_drivers module_drivers $driver_srcfile_hint
                        }
                    }
                }
            }
        }

        # Collect all loads
        set all_loads {}
        set module_loads {}
        foreach sig_hdl $load_sigs {
            set signame [apply_signal_select [hdl_to_name $sig_hdl] $trace_select]
            if { $signame eq "" } {
                continue
            }

            collect_loads_by_name $signame all_loads module_loads
            set source_load_visited {}
            collect_source_load_fanouts $sig_hdl $signame all_loads module_loads $assign_trace_max_depth $assign_expr_trace_max_depth source_load_visited

            # If string-based tracing returns no endpoint, keep the old
            # handle-based fallback for the direct connection only.
            if { [llength $all_loads] == 0 } {
                set loadList {}
                catch { ::npi_L1::npi_nl_trace_load_by_hdl $sig_hdl loadList }
                foreach hdl $loadList {
                    set sig [hdl_to_name $hdl]
                    append_unique_signal all_loads $sig
                    if { [should_expand_assign_endpoint $hdl $sig] } {
                        log_step "load_assign_continue from=$signame via=$sig remaining_depth=$assign_trace_max_depth"
                        collect_loads_by_name $sig all_loads module_loads
                    } elseif { [should_expand_assign_expr_endpoint $hdl $sig] } {
                        log_step "load_assign_expr_continue from=$signame via=$sig remaining_depth=$assign_expr_trace_max_depth"
                        collect_loads_by_name $sig all_loads module_loads
                    }
                }
            }
        }

        set filtered_drivers {}
        foreach sig $all_drivers {
            if { ![is_self_port_signal $sig $inst_path $portname] } {
                lappend filtered_drivers $sig
            }
        }
        set all_drivers $filtered_drivers

        set filtered_loads {}
        foreach sig $all_loads {
            if { ![is_self_port_signal $sig $inst_path $portname] } {
                lappend filtered_loads $sig
            }
        }
        set all_loads $filtered_loads

        set filtered_module_drivers {}
        foreach sig $module_drivers {
            if { ![is_self_port_signal $sig $inst_path $portname] } {
                lappend filtered_module_drivers $sig
            }
        }
        set module_drivers $filtered_module_drivers

        set filtered_module_loads {}
        foreach sig $module_loads {
            if { ![is_self_port_signal $sig $inst_path $portname] } {
                lappend filtered_module_loads $sig
            }
        }
        set module_loads $filtered_module_loads

        # Remove duplicates
        set all_drivers [lsort -unique $all_drivers]
        set all_loads [lsort -unique $all_loads]
        set module_drivers [lsort -unique $module_drivers]
        set module_loads [lsort -unique $module_loads]
        log_step "trace_result instance=$inst_path port=$portname drivers=[llength $all_drivers] loads=[llength $all_loads] module_drivers=[llength $module_drivers] module_loads=[llength $module_loads]"

        # Output module-boundary connections to the side CSV.
        if { $module_outfh ne "" } {
            foreach sig $module_drivers {
                set formatted_sig [format_signal_name $sig $inst_path]
                write_trace_row $module_outfh $inst_path $portname $dir driver $formatted_sig
            }
            foreach sig $module_loads {
                set formatted_sig [format_signal_name $sig $inst_path]
                write_trace_row $module_outfh $inst_path $portname $dir load $formatted_sig
            }
        }

        # Output drivers
        if { [llength $all_drivers] > 0 } {
            foreach sig $all_drivers {
                set formatted_sig [format_signal_name $sig $inst_path]
                write_trace_row $outfh $inst_path $portname $dir driver $formatted_sig
            }
        } else {
            # If no drivers found via tracing, output the direct connection signal
            # This handles cases where trace APIs cannot follow the signal further
            if { [llength $driver_sigs] > 0 } {
                foreach sig_hdl $driver_sigs {
                    set signame [apply_signal_select [hdl_to_name $sig_hdl] $trace_select]
                    if { $signame ne "" } {
                        if { [is_self_port_signal $signame $inst_path $portname] } {
                            continue
                        }
                        set formatted_sig [format_signal_name $signame $inst_path]
                        write_trace_row $outfh $inst_path $portname $dir driver $formatted_sig
                    }
                }
            }
            if { [llength $driver_sigs] == 0 } {
                write_trace_row $outfh $inst_path $portname $dir driver "NO_DRIVER"
            }
        }

        # Output loads
        if { [llength $all_loads] > 0 } {
            foreach sig $all_loads {
                set formatted_sig [format_signal_name $sig $inst_path]
                write_trace_row $outfh $inst_path $portname $dir load $formatted_sig
            }
        } else {
            # If no loads found via tracing, output the direct connection signal
            # This is valid when a signal is connected but not actually used
            if { [llength $load_sigs] > 0 } {
                foreach sig_hdl $load_sigs {
                    set signame [apply_signal_select [hdl_to_name $sig_hdl] $trace_select]
                    if { $signame ne "" } {
                        set formatted_sig [format_signal_name $signame $inst_path]
                        write_trace_row $outfh $inst_path $portname $dir load $formatted_sig
                    }
                }
            }
            if { [llength $load_sigs] == 0 } {
                write_trace_row $outfh $inst_path $portname $dir load "NO_LOAD"
            }
        }
        }
        set portname $base_portname
    }
}

# -----------------------------------------------------------------------
# Find all instances of target_mod and process each
# -----------------------------------------------------------------------
set hdlList {}
log_step "find target instances for module definition: $target_mod"
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
log_step "found_target_instance_handles=[llength $hdlList]"

# Print CSV header
log_step "write CSV headers"
puts $outfh "inst_full_name,port_name,port_dir,role,signal_full_name"
if { $module_outfh ne "" } {
    puts $module_outfh "inst_full_name,port_name,port_dir,role,module_signal_full_name"
}

set processed_instances 0
set skipped_instances 0
set seen_paths {}
foreach ih $hdlList {
    # Get instance full path from npi_ut_get_hdl_info
    # format: "npiNlHierInst, full.path, (null)" — but this returns empty for inst handles
    # Use npi_nl_ut_get_hdl_info instead
    set inst_path [get_instance_path $ih]

    if { $inst_path eq "" } {
        puts stderr "WARNING: could not get path for instance handle $ih, skipping"
        incr skipped_instances
        continue
    }

    if { [dict exists $seen_paths $inst_path] } {
        log_step "duplicate target instance skipped: $inst_path"
        continue
    }
    dict set seen_paths $inst_path 1

    # Derive parent path and instance name
    set parts [split $inst_path "."]
    set instname   [lindex $parts end]
    set parent_path [join [lrange $parts 0 end-1] "."]

    process_instance $inst_path $parent_path $instname $port_filter $outfh $module_outfh
    incr processed_instances
}
log_step "processed_target_instances=$processed_instances skipped_handles=$skipped_instances"

if { $outfh ne "stdout" } { close $outfh }
if { $module_outfh ne "" } { close $module_outfh }
log_step "done"
debExit
