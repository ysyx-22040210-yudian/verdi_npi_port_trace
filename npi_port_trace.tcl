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

set trace_debug_enabled 0

proc debug_step {msg} {
    global trace_debug_enabled
    if { $trace_debug_enabled } {
        log_step "DEBUG $msg"
    }
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

if { [info exists env(NPI_TRACE_DEBUG)] && $env(NPI_TRACE_DEBUG) ne "" } {
    set trace_debug_raw [string tolower $env(NPI_TRACE_DEBUG)]
    if { $trace_debug_raw eq "1" ||
         $trace_debug_raw eq "true" ||
         $trace_debug_raw eq "yes" ||
         $trace_debug_raw eq "on" } {
        set trace_debug_enabled 1
    }
}
log_step "trace_debug=$trace_debug_enabled"

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

proc const_map_keys_for_lhs { name select } {
    if { $select eq "" } {
        return [list $name]
    }

    set keys {}
    foreach bit [select_selected_bits $select] {
        lappend keys "${name}\[$bit\]"
    }
    if { [llength $keys] == 0 } {
        lappend keys "${name}${select}"
    }
    return $keys
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
            set value [const_value_from_rhs $rhs $const_map]
            if { $value ne "" } {
                foreach key [const_map_keys_for_lhs $name $bit] {
                    dict set const_map $key $value
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

proc const_driver_from_assign_map { const_map signame leaf } {
    set signame [normalize_signal_name $signame]
    set leaf_key $leaf
    set select [signal_select_suffix $signame]
    if { $leaf ne "" && $select ne "" } {
        set leaf_key "${leaf}${select}"
    }
    foreach key [list $signame [signal_base_without_select $signame] $leaf_key $leaf] {
        if { $key ne "" && [dict exists $const_map $key] } {
            return [dict get $const_map $key]
        }
    }
    return ""
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

proc signal_selected_bits { signame } {
    set signame [normalize_signal_name $signame]
    if { [regexp {\[([0-9]+)\]$} $signame -> bit] } {
        return [list $bit]
    }
    if { [regexp {\[([0-9]+):([0-9]+)\]$} $signame -> hi lo] } {
        set bits {}
        if { $hi >= $lo } {
            for {set bit $lo} {$bit <= $hi} {incr bit} {
                lappend bits $bit
            }
        } else {
            for {set bit $hi} {$bit <= $lo} {incr bit} {
                lappend bits $bit
            }
        }
        return $bits
    }
    return {}
}

proc signal_select_suffix { signame } {
    set signame [normalize_signal_name $signame]
    if { [regexp {(\[[0-9]+(:[0-9]+)?\])$} $signame -> select] } {
        return $select
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

proc signal_base_without_select { signame } {
    set signame [normalize_signal_name $signame]
    regsub {#\[[^\]]+\]$} $signame "" signame
    regsub {\[[^\]]+\]$} $signame "" signame
    return $signame
}

proc select_bits_from_signal { signame } {
    set signame [normalize_signal_name $signame]
    if { [regexp {#\[([0-9]+):([0-9]+)\]$} $signame -> hi lo] ||
         [regexp {\[([0-9]+):([0-9]+)\]$} $signame -> hi lo] } {
        set bits {}
        if { $hi >= $lo } {
            for {set bit $lo} {$bit <= $hi} {incr bit} {
                lappend bits $bit
            }
        } else {
            for {set bit $hi} {$bit <= $lo} {incr bit} {
                lappend bits $bit
            }
        }
        return $bits
    }
    if { [regexp {#\[([0-9]+)\]$} $signame -> bit] ||
         [regexp {\[([0-9]+)\]$} $signame -> bit] } {
        return [list $bit]
    }
    return {}
}

proc signal_selects_overlap { lhs rhs } {
    set lhs_bits [select_bits_from_signal $lhs]
    set rhs_bits [select_bits_from_signal $rhs]

    if { [llength $lhs_bits] == 0 || [llength $rhs_bits] == 0 } {
        return 1
    }

    foreach bit $lhs_bits {
        if { [lsearch -exact $rhs_bits $bit] >= 0 } {
            return 1
        }
    }
    return 0
}

proc signal_effective_scope_prefix { signame {scope_hint ""} } {
    set prefix [signal_scope_prefix $signame]
    if { $prefix ne "" } {
        return $prefix
    }
    return $scope_hint
}

proc signal_scope_hint_after { signame {scope_hint ""} } {
    set prefix [signal_scope_prefix $signame]
    if { $prefix ne "" } {
        return $prefix
    }
    return $scope_hint
}

proc scoped_signal_for_query { signame {scope_hint ""} } {
    set signame [normalize_signal_name $signame]
    if { $scope_hint eq "" ||
         $signame eq "" ||
         [is_const_literal_name $signame] ||
         [signal_scope_prefix $signame] ne "" } {
        return $signame
    }
    if { [regexp {^[A-Za-z_][A-Za-z0-9_$]*(\[[0-9]+(:[0-9]+)?\])?$} $signame] } {
        return "${scope_hint}.${signame}"
    }
    return $signame
}

proc source_module_port_candidate_exists { candidate } {
    if { [info commands ::npi_L1::npi_mod_inst_get_port] eq "" } {
        return 1
    }
    if { [is_const_literal_name $candidate] } {
        return 1
    }

    set base [strip_signal_selects [normalize_signal_name $candidate]]
    if { ![regexp {^(.+)\.([A-Za-z_][A-Za-z0-9_$]*)$} $base -> inst_path portname] } {
        return 1
    }

    set hdlList {}
    if { [catch { ::npi_L1::npi_mod_inst_get_port $inst_path hdlList } _] } {
        log_step "source_module_port_skip_nonexistent signal=$candidate inst=$inst_path port=$portname"
        return 0
    }
    foreach port_hdl $hdlList {
        if { [get_port_name $port_hdl] eq $portname } {
            return 1
        }
    }

    log_step "source_module_port_skip_nonexistent signal=$candidate inst=$inst_path port=$portname"
    return 0
}

proc source_has_assign_driver_for_signal { candidate srcfile } {
    if { $srcfile eq "" } {
        return 0
    }
    set leaf [signal_leaf_name $candidate]
    if { $leaf eq "" } {
        return 0
    }
    set scope [signal_scope_prefix $candidate]
    set ctx [source_context_for_signal $candidate $srcfile]
    set ctx_srcfile [lindex $ctx 0]
    set module [lindex $ctx 1]
    if { $ctx_srcfile ne "" } {
        set srcfile $ctx_srcfile
    }
    if { $module eq "" } {
        set module [source_scope_module_name $scope $srcfile]
    }
    foreach assign [build_assign_stmt_list_for_module $srcfile $module] {
        if { [lindex $assign 0] eq $leaf } {
            return 1
        }
    }
    return 0
}

proc source_signal_candidate_exists { candidate {mode "strict"} {srcfile ""} } {
    if { [info commands ::npi_L1::npi_nl_trace_driver] eq "" } {
        return 1
    }
    if { [is_const_literal_name $candidate] } {
        return 1
    }
    set candidate_prefix [signal_scope_prefix $candidate]
    if { $candidate_prefix eq "" } {
        return 1
    }
    if { [string first "." $candidate_prefix] < 0 } {
        return 1
    }

    set driverList {}
    if { ![catch { ::npi_L1::npi_nl_trace_driver $candidate driverList 0 1 }] &&
         [llength $driverList] > 0 } {
        return 1
    }

    set loadList {}
    if { ![catch { ::npi_L1::npi_nl_trace_load $candidate loadList 0 1 }] &&
         [llength $loadList] > 0 } {
        return 1
    }

    if { [source_module_port_candidate_exists $candidate] } {
        return 1
    }

    if { $mode eq "driver" && [source_has_assign_driver_for_signal $candidate $srcfile] } {
        return 1
    }

    if { $mode eq "driver" &&
         [llength [source_module_port_driver_sources $srcfile $candidate]] > 0 } {
        return 1
    }

    log_step "source_assign_skip_nonexistent signal=$candidate"
    return 0
}

proc append_source_signal_candidate { list_var candidate {mode "strict"} {srcfile ""} } {
    upvar 1 $list_var values
    if { [source_signal_candidate_exists $candidate $mode $srcfile] } {
        append_unique_signal values $candidate
    }
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

proc lhs_is_concat_expr { lhs } {
    set lhs [string trim $lhs]
    regsub -all {\s+} $lhs "" lhs_no_space
    return [expr {[string index $lhs_no_space 0] eq "\{" && [string index $lhs_no_space end] eq "\}"}]
}

proc lhs_concat_rhs_offsets_for_signal_bit { lhs leaf bit {width_map {}} } {
    set lhs [string trim $lhs]
    regsub -all {\s+} $lhs "" lhs_no_space
    if { ![lhs_is_concat_expr $lhs_no_space] } {
        return {}
    }

    set offsets {}
    set lsb 0
    foreach item [lreverse [split_concat_items $lhs_no_space]] {
        set width [expr_item_width $item $width_map]
        if { $width eq "" } {
            return {}
        }

        set item_leaf [assign_lhs_leaf_name $item]
        if { $item_leaf eq $leaf } {
            set item_select [assign_lhs_select $item]
            if { $bit eq "" } {
                for {set item_offset 0} {$item_offset < $width} {incr item_offset} {
                    lappend offsets [expr {$lsb + $item_offset}]
                }
            } else {
                set item_offset [lhs_select_rhs_bit_for_target $item_select $bit]
                if { $item_offset ne "" && $item_offset >= 0 && $item_offset < $width } {
                    lappend offsets [expr {$lsb + $item_offset}]
                }
            }
        }
        incr lsb $width
    }
    return $offsets
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

proc read_source_text_without_line_comments { srcfile } {
    if { $srcfile eq "" || ![file exists $srcfile] } {
        return ""
    }
    set fh [open $srcfile r]
    set text ""
    foreach line [split [read $fh] "\n"] {
        regsub {//.*$} $line "" line
        append text [string trim $line] "\n"
    }
    close $fh
    return $text
}

proc build_module_text_map { srcfile } {
    global module_text_map_cache

    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    if { [info exists module_text_map_cache($srcfile)] } {
        return $module_text_map_cache($srcfile)
    }

    set modules {}
    set in_module 0
    set modname ""
    set text ""
    foreach line [split [read_source_text_without_line_comments $srcfile] "\n"] {
        set trimmed [string trim $line]
        if { !$in_module } {
            if { [regexp {^module\s+([A-Za-z_][A-Za-z0-9_$]*)([^A-Za-z0-9_$]|$)} $trimmed -> name _] } {
                set in_module 1
                set modname $name
                set text "$trimmed\n"
                if { [regexp {(^|[^A-Za-z0-9_$])endmodule([^A-Za-z0-9_$]|$)} $trimmed] } {
                    dict set modules $modname $text
                    set in_module 0
                    set modname ""
                    set text ""
                }
            }
            continue
        }

        append text "$trimmed\n"
        if { [regexp {(^|[^A-Za-z0-9_$])endmodule([^A-Za-z0-9_$]|$)} $trimmed] } {
            dict set modules $modname $text
            set in_module 0
            set modname ""
            set text ""
        }
    }

    set module_text_map_cache($srcfile) $modules
    return $modules
}

proc source_module_text { srcfile module } {
    if { $module eq "" } {
        return ""
    }
    set modules [build_module_text_map $srcfile]
    if { [dict exists $modules $module] } {
        return [dict get $modules $module]
    }
    return ""
}

proc source_module_names_in_file { srcfile } {
    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    return [dict keys [build_module_text_map $srcfile]]
}

proc source_module_name_by_port { srcfile portname } {
    if { $srcfile eq "" || $portname eq "" || ![file exists $srcfile] } {
        return ""
    }

    set matches {}
    foreach modname [source_module_names_in_file $srcfile] {
        set dir_map [build_port_dir_map $srcfile $modname]
        if { [dict exists $dir_map $portname] } {
            lappend matches $modname
        }
    }
    if { [llength $matches] == 1 } {
        return [lindex $matches 0]
    }
    return ""
}

proc source_module_name_by_signal { srcfile leaf } {
    if { $srcfile eq "" || $leaf eq "" || ![file exists $srcfile] } {
        return ""
    }

    set matches {}
    foreach modname [source_module_names_in_file $srcfile] {
        set width_map [build_signal_width_map_for_module $srcfile $modname]
        if { [dict exists $width_map $leaf] } {
            lappend matches $modname
        }
    }
    if { [llength $matches] == 1 } {
        return [lindex $matches 0]
    }
    return ""
}

proc source_file_for_scope_instance { scope {fallback ""} } {
    global source_scope_file_cache

    set scope [strip_signal_selects [normalize_signal_name $scope]]
    if { $scope eq "" } {
        return $fallback
    }
    if { [info exists source_scope_file_cache($scope)] } {
        set cached $source_scope_file_cache($scope)
        if { $cached ne "" } {
            return $cached
        }
        return $fallback
    }

    set srcfile ""
    if { [info commands ::npi_L1::npi_mod_inst_get_port] ne "" } {
        set hdlList {}
        if { ![catch { ::npi_L1::npi_mod_inst_get_port $scope hdlList }] } {
            foreach port_hdl $hdlList {
                set srcfile [get_handle_source_file $port_hdl]
                if { $srcfile ne "" } {
                    break
                }
            }
        }
    }

    set source_scope_file_cache($scope) $srcfile
    if { $srcfile ne "" } {
        return $srcfile
    }
    return $fallback
}

proc source_file_for_scope_module { scope module {fallback ""} } {
    global source_scope_module_file_cache

    set scope [strip_signal_selects [normalize_signal_name $scope]]
    if { $scope eq "" || $module eq "" } {
        return $fallback
    }

    set key "${scope}::${module}"
    if { [info exists source_scope_module_file_cache($key)] } {
        set cached $source_scope_module_file_cache($key)
        if { $cached ne "" } {
            return $cached
        }
        return $fallback
    }

    set apis {
        ::npi_L1::npi_mod_inst_get_port
        ::npi_L1::npi_mod_inst_get_io
        ::npi_L1::npi_mod_inst_get_net
        ::npi_L1::npi_mod_inst_get_var
        ::npi_L1::npi_mod_inst_get_instance
        ::npi_L1::npi_mod_inst_get_cont_assign
        ::npi_L1::npi_mod_inst_get_process_always
        ::npi_L1::npi_mod_inst_get_process_init
    }

    foreach api $apis {
        if { [info commands $api] eq "" } {
            continue
        }
        set hdlList {}
        if { [catch { $api $scope hdlList }] } {
            continue
        }
        foreach hdl $hdlList {
            set srcfile [get_handle_source_file $hdl]
            if { $srcfile ne "" && [source_module_text $srcfile $module] ne "" } {
                set source_scope_module_file_cache($key) $srcfile
                return $srcfile
            }
        }
    }

    set source_scope_module_file_cache($key) ""
    return $fallback
}

proc source_context_for_signal { signame {srcfile_hint ""} {scope_hint ""} } {
    global source_scope_module_context_cache

    set signame [normalize_signal_name $signame]
    set leaf [signal_leaf_name $signame]
    set prefix [signal_effective_scope_prefix $signame $scope_hint]
    set srcfile $srcfile_hint
    set module ""

    if { $prefix eq "" } {
        return [list $srcfile ""]
    }

    if { [info exists source_scope_module_context_cache($prefix)] } {
        set cached $source_scope_module_context_cache($prefix)
        set cached_srcfile [lindex $cached 0]
        set cached_module [lindex $cached 1]
        if { $cached_srcfile ne "" && $cached_module ne "" } {
            return $cached
        }
    }

    set cache_key "${prefix}::${srcfile_hint}"
    if { [info exists source_scope_module_context_cache($cache_key)] } {
        return $source_scope_module_context_cache($cache_key)
    }

    if { $srcfile_hint ne "" } {
        set module [source_scope_module_name $prefix $srcfile_hint]
    }

    set scope_srcfile [source_file_for_scope_instance $prefix ""]
    if { $scope_srcfile ne "" } {
        set srcfile $scope_srcfile
    }

    set base [strip_signal_selects $signame]
    if { $module eq "" &&
         [regexp {^(.+)\.([A-Za-z_][A-Za-z0-9_$]*)$} $base -> inst_path portname] &&
         $inst_path eq $prefix } {
        set module [source_module_name_by_port $srcfile $portname]
    }

    if { $module eq "" } {
        set module [source_module_name_by_signal $srcfile $leaf]
    }

    if { $module ne "" } {
        if { $srcfile ne "" && [source_module_text $srcfile $module] eq "" } {
            set scope_module_srcfile [source_file_for_scope_module $prefix $module ""]
            if { $scope_module_srcfile ne "" } {
                set srcfile $scope_module_srcfile
            }
        }
        if { $srcfile ne "" && [source_module_text $srcfile $module] eq "" &&
             $srcfile_hint ne "" && [source_module_text $srcfile_hint $module] ne "" } {
            set srcfile $srcfile_hint
        }
    }

    set result [list $srcfile $module]
    set source_scope_module_context_cache($cache_key) $result
    if { $srcfile ne "" && $module ne "" } {
        set source_scope_module_context_cache($prefix) $result
    }
    debug_step "source_context signal=$signame scope_hint=$scope_hint prefix=$prefix src_hint=$srcfile_hint resolved_src=$srcfile module=$module"
    return $result
}

proc parse_assign_stmt_text { text } {
    set assigns {}
    foreach stmt [split $text ";"] {
        set stmt [strip_leading_block_end_tokens $stmt]
        regsub -all {\s+} $stmt " " stmt
        set stmt [string trim $stmt]
        # The simple semicolon splitter can leave a leading procedural
        # block terminator before the next continuous assign, for example
        # "end assign a = b" after an always block. Keep only the continuous
        # assign portion so source fallback does not miss that first assign.
        if { ![regexp {^assign\s+} $stmt] &&
             [regexp {(^|[^A-Za-z0-9_$])assign\s+(.+)$} $stmt -> _ assign_tail] } {
            set stmt "assign $assign_tail"
        }
        if { [regexp {^assign\s+(.+?)\s*=\s*(.+)$} $stmt -> lhs rhs] } {
            if { [lhs_is_concat_expr $lhs] } {
                foreach lhs_item [split_concat_items $lhs] {
                    set lhs_leaf [assign_lhs_leaf_name $lhs_item]
                    if { $lhs_leaf ne "" } {
                        set lhs_select [assign_lhs_select $lhs_item]
                        lappend assigns [list $lhs_leaf $lhs_select $rhs $lhs]
                    }
                }
            } else {
                set lhs_leaf [assign_lhs_leaf_name $lhs]
                if { $lhs_leaf ne "" } {
                    set lhs_select [assign_lhs_select $lhs]
                    lappend assigns [list $lhs_leaf $lhs_select $rhs]
                }
            }
        }
    }
    return $assigns
}

proc build_assign_stmt_list { srcfile } {
    global assign_stmt_list_cache

    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    if { [info exists assign_stmt_list_cache($srcfile)] } {
        return $assign_stmt_list_cache($srcfile)
    }

    set text [read_source_text_without_line_comments $srcfile]
    set assigns [parse_assign_stmt_text $text]

    set assign_stmt_list_cache($srcfile) $assigns
    return $assigns
}

proc build_assign_stmt_list_for_module { srcfile module } {
    global assign_stmt_list_module_cache

    if { $srcfile eq "" || ![file exists $srcfile] || $module eq "" } {
        return [build_assign_stmt_list $srcfile]
    }

    set key "${srcfile}::${module}"
    if { [info exists assign_stmt_list_module_cache($key)] } {
        return $assign_stmt_list_module_cache($key)
    }

    set text [source_module_text $srcfile $module]
    if { $text eq "" } {
        set assigns [build_assign_stmt_list $srcfile]
    } else {
        set assigns [parse_assign_stmt_text $text]
    }
    set assign_stmt_list_module_cache($key) $assigns
    return $assigns
}

proc parse_signal_width_text { text } {
    global signal_width_map_cache

    set widths {}
    foreach line [split $text "\n"] {
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
    return $widths
}

proc build_signal_width_map { srcfile } {
    global signal_width_map_cache

    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    if { [info exists signal_width_map_cache($srcfile)] } {
        return $signal_width_map_cache($srcfile)
    }

    set widths [parse_signal_width_text [read_source_text_without_line_comments $srcfile]]

    set signal_width_map_cache($srcfile) $widths
    return $widths
}

proc build_signal_width_map_for_module { srcfile module } {
    global signal_width_map_module_cache

    if { $srcfile eq "" || ![file exists $srcfile] || $module eq "" } {
        return [build_signal_width_map $srcfile]
    }

    set key "${srcfile}::${module}"
    if { [info exists signal_width_map_module_cache($key)] } {
        return $signal_width_map_module_cache($key)
    }

    set text [source_module_text $srcfile $module]
    if { $text eq "" } {
        set widths [build_signal_width_map $srcfile]
    } else {
        set widths [parse_signal_width_text $text]
    }
    set signal_width_map_module_cache($key) $widths
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

proc conn_port_select_for_signal_bit { conn bit } {
    if { $bit eq "" } {
        return ""
    }
    set select [assign_lhs_select $conn]
    set port_bit [lhs_select_rhs_bit_for_target $select $bit]
    if { $port_bit eq "" } {
        return ""
    }
    return "\[$port_bit\]"
}

proc parse_instantiation_stmt_text { text } {
    set insts {}
    foreach stmt [split $text ";"] {
        set stmt [strip_leading_block_end_tokens $stmt]
        regsub -all {\s+} $stmt " " stmt
        set stmt [string trim $stmt]
        if { $stmt eq "" } {
            continue
        }
        if { [regexp {^(module|endmodule|assign|always|initial|input|output|inout|wire|reg|logic|parameter|localparam)([^A-Za-z0-9_$]|$)} $stmt] } {
            continue
        }
        if { [regexp {^([A-Za-z_][A-Za-z0-9_$]*)\s*(#\s*\(.*\)\s*)?([A-Za-z_][A-Za-z0-9_$]*)\s*\((.*)\)$} $stmt -> modname _ instname conn_text] } {
            lappend insts [list $modname $instname $conn_text]
            continue
        }
        if { [regexp {([A-Za-z_][A-Za-z0-9_$]*)\s*(#\s*\(.*\)\s*)?([A-Za-z_][A-Za-z0-9_$]*)\s*\((\s*\.[A-Za-z_][A-Za-z0-9_$]*\s*\(.*)\)$} $stmt -> modname _ instname conn_text] } {
            if { [lsearch -exact {for if case while begin end generate endgenerate} $modname] < 0 } {
                lappend insts [list $modname $instname $conn_text]
            }
        }
    }
    return $insts
}

proc build_instantiation_stmt_list { srcfile } {
    global inst_stmt_list_cache

    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }
    if { [info exists inst_stmt_list_cache($srcfile)] } {
        return $inst_stmt_list_cache($srcfile)
    }

    set insts [parse_instantiation_stmt_text [read_source_text_without_line_comments $srcfile]]

    set inst_stmt_list_cache($srcfile) $insts
    return $insts
}

proc build_instantiation_stmt_list_for_module { srcfile module } {
    global inst_stmt_list_module_cache

    if { $srcfile eq "" || ![file exists $srcfile] || $module eq "" } {
        return [build_instantiation_stmt_list $srcfile]
    }

    set key "${srcfile}::${module}"
    if { [info exists inst_stmt_list_module_cache($key)] } {
        return $inst_stmt_list_module_cache($key)
    }

    set text [source_module_text $srcfile $module]
    if { $text eq "" } {
        set insts [build_instantiation_stmt_list $srcfile]
    } else {
        set insts [parse_instantiation_stmt_text $text]
    }
    set inst_stmt_list_module_cache($key) $insts
    return $insts
}

proc source_scope_module_name { scope srcfile } {
    global source_scope_module_cache

    set scope [strip_signal_selects [normalize_signal_name $scope]]
    if { $scope eq "" || $srcfile eq "" || ![file exists $srcfile] } {
        return ""
    }

    set key "${srcfile}::${scope}"
    if { [info exists source_scope_module_cache($key)] } {
        return $source_scope_module_cache($key)
    }

    set parts [split $scope "."]
    set module [lindex $parts 0]
    if { [source_module_text $srcfile $module] eq "" } {
        set source_scope_module_cache($key) ""
        return ""
    }

    for {set idx 1} {$idx < [llength $parts]} {incr idx} {
        set instname [lindex $parts $idx]
        set found ""
        foreach inst [build_instantiation_stmt_list_for_module $srcfile $module] {
            if { [lindex $inst 1] eq $instname } {
                set found [lindex $inst 0]
                break
            }
        }
        if { $found ne "" } {
            set module $found
        }
    }

    set source_scope_module_cache($key) $module
    return $module
}

proc source_module_port_driver_sources { srcfile signame {scope_hint ""} } {
    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }

    set leaf [signal_leaf_name $signame]
    if { $leaf eq "" } {
        return {}
    }
    set selected_bits [signal_selected_bits $signame]
    set prefix [signal_effective_scope_prefix $signame $scope_hint]
    set ctx [source_context_for_signal $signame $srcfile $scope_hint]
    set ctx_srcfile [lindex $ctx 0]
    set module [lindex $ctx 1]
    if { $ctx_srcfile ne "" } {
        set srcfile $ctx_srcfile
    }
    if { $module eq "" } {
        set module [source_scope_module_name $prefix $srcfile]
    }

    set sources {}
    foreach inst [build_instantiation_stmt_list_for_module $srcfile $module] {
        set modname [lindex $inst 0]
        set instname [lindex $inst 1]
        set conn_text [lindex $inst 2]

        foreach {_ port conn} [regexp -all -inline {\.([A-Za-z_][A-Za-z0-9_$]*)\s*\(\s*([^)]+?)\s*\)} $conn_text] {
            set target_bits $selected_bits
            if { [llength $target_bits] == 0 } {
                set target_bits [list ""]
            }
            foreach bit $target_bits {
                if { ![conn_references_signal_bit $conn $leaf $bit] } {
                    continue
                }
                set port_select [conn_port_select_for_signal_bit $conn $bit]
                if { $bit ne "" && $port_select eq "" } {
                    continue
                }
                if { $prefix ne "" } {
                    set candidate "${prefix}.${instname}.${port}${port_select}"
                } else {
                    set candidate "${instname}.${port}${port_select}"
                }
                set dir [source_candidate_port_direction $candidate $srcfile $modname $port]
                if { $dir ne "output" && $dir ne "inout" && $dir ne "unknown" } {
                    continue
                }
                if { $dir eq "unknown" } {
                    debug_step "source_module_port_driver_unknown_direction_keep signal=$signame inst=$instname mod=$modname port=$port conn=$conn candidate=$candidate"
                }
                if { [source_module_port_candidate_exists $candidate] } {
                    append_unique_signal sources $candidate
                }
            }
        }
    }

    if { [llength $sources] > 0 } {
        log_step "source_module_port_driver signal=$signame source=$srcfile drivers=[join $sources ,]"
    }
    return $sources
}

proc source_candidate_port_direction { candidate srcfile modname portname } {
    set base [strip_signal_selects [normalize_signal_name $candidate]]
    if { [regexp {^(.+)\.([A-Za-z_][A-Za-z0-9_$]*)$} $base -> inst_path _] } {
        set port_hdl [get_inst_port_handle_by_signal $inst_path $base]
        if { $port_hdl ne "" } {
            set dir [get_port_direction $port_hdl]
            if { $dir ne "unknown" } {
                return $dir
            }
            set port_srcfile [get_handle_source_file $port_hdl]
            if { $port_srcfile ne "" } {
                set dir_map [build_port_dir_map $port_srcfile $modname]
                if { [dict exists $dir_map $portname] } {
                    return [dict get $dir_map $portname]
                }
            }
        }
    }

    if { [regexp {^(.+)\.([A-Za-z_][A-Za-z0-9_$]*)$} $base -> inst_path _] } {
        set scoped_srcfile [source_file_for_scope_module $inst_path $modname ""]
        if { $scoped_srcfile ne "" } {
            set dir_map [build_port_dir_map $scoped_srcfile $modname]
            if { [dict exists $dir_map $portname] } {
                return [dict get $dir_map $portname]
            }
        }
    }

    set dir_map [build_port_dir_map $srcfile $modname]
    if { [dict exists $dir_map $portname] } {
        return [dict get $dir_map $portname]
    }
    return "unknown"
}

proc source_module_port_load_fanouts { srcfile signame {scope_hint ""} } {
    if { $srcfile eq "" || ![file exists $srcfile] } {
        return {}
    }

    set leaf [signal_leaf_name $signame]
    if { $leaf eq "" } {
        return {}
    }
    set selected_bits [signal_selected_bits $signame]
    set prefix [signal_effective_scope_prefix $signame $scope_hint]
    set ctx [source_context_for_signal $signame $srcfile $scope_hint]
    set ctx_srcfile [lindex $ctx 0]
    set module [lindex $ctx 1]
    if { $ctx_srcfile ne "" } {
        set srcfile $ctx_srcfile
    }
    if { $module eq "" } {
        set module [source_scope_module_name $prefix $srcfile]
    }

    set fanouts {}
    set inst_list [build_instantiation_stmt_list_for_module $srcfile $module]
    debug_step "source_module_port_load_probe signal=$signame leaf=$leaf selected_bits=[join $selected_bits ,] prefix=$prefix srcfile=$srcfile module=$module inst_count=[llength $inst_list]"
    foreach inst $inst_list {
        set modname [lindex $inst 0]
        set instname [lindex $inst 1]
        set conn_text [lindex $inst 2]

        foreach {_ port conn} [regexp -all -inline {\.([A-Za-z_][A-Za-z0-9_$]*)\s*\(\s*([^)]+?)\s*\)} $conn_text] {
            set target_bits $selected_bits
            if { [llength $target_bits] == 0 } {
                set target_bits [list ""]
            }
            foreach bit $target_bits {
                if { ![conn_references_signal_bit $conn $leaf $bit] } {
                    continue
                }
                set port_select [conn_port_select_for_signal_bit $conn $bit]
                if { $bit ne "" && $port_select eq "" } {
                    debug_step "source_module_port_load_skip signal=$signame inst=$instname port=$port conn=$conn bit=$bit reason=port_select_empty"
                    continue
                }
                if { $prefix ne "" } {
                    set candidate "${prefix}.${instname}.${port}${port_select}"
                } else {
                    set candidate "${instname}.${port}${port_select}"
                }
                set dir [source_candidate_port_direction $candidate $srcfile $modname $port]
                if { $dir ne "input" && $dir ne "inout" && $dir ne "unknown" } {
                    debug_step "source_module_port_load_skip signal=$signame inst=$instname mod=$modname port=$port conn=$conn candidate=$candidate dir=$dir reason=direction"
                    continue
                }
                if { $dir eq "unknown" } {
                    debug_step "source_module_port_load_unknown_direction_keep signal=$signame inst=$instname mod=$modname port=$port conn=$conn candidate=$candidate"
                }
                set exists [source_module_port_candidate_exists $candidate]
                debug_step "source_module_port_load_match signal=$signame inst=$instname mod=$modname port=$port conn=$conn bit=$bit candidate=$candidate dir=$dir exists=$exists"
                if { $exists } {
                    append_unique_signal fanouts $candidate
                }
            }
        }
    }

    if { [llength $fanouts] > 0 } {
        log_step "source_module_port_load signal=$signame source=$srcfile fanouts=[join $fanouts ,]"
    } else {
        debug_step "source_module_port_load_empty signal=$signame source=$srcfile module=$module"
    }
    return $fanouts
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

proc source_assign_load_fanouts_core { sig_hdl signame {include_expr 1} {srcfile_hint ""} {scope_hint ""} } {
    set bit [signal_bit_index $signame]
    set srcfile [get_handle_source_file $sig_hdl]
    if { $srcfile eq "" } {
        set srcfile $srcfile_hint
    }
    if { $srcfile eq "" } {
        return {}
    }

    set leaf [signal_leaf_name $signame]
    if { $leaf eq "" } {
        return {}
    }
    set prefix [signal_effective_scope_prefix $signame $scope_hint]
    set ctx [source_context_for_signal $signame $srcfile $scope_hint]
    set ctx_srcfile [lindex $ctx 0]
    set module [lindex $ctx 1]
    if { $ctx_srcfile ne "" } {
        set srcfile $ctx_srcfile
    }
    if { $module eq "" } {
        set module [source_scope_module_name $prefix $srcfile]
    }
    set width_map [build_signal_width_map_for_module $srcfile $module]

    set fanouts {}
    set assign_list [build_assign_stmt_list_for_module $srcfile $module]
    set match_count 0
    set candidate_count 0
    set rejected_count 0
    debug_step "source_assign_load_probe signal=$signame leaf=$leaf bit=$bit prefix=$prefix scope_hint=$scope_hint srcfile=$srcfile module=$module include_expr=$include_expr assign_count=[llength $assign_list]"
    foreach assign $assign_list {
        set lhs_leaf [lindex $assign 0]
        set lhs_select [lindex $assign 1]
        set rhs [lindex $assign 2]
        set is_simple [rhs_is_simple_signal_expr $rhs]
        set is_concat [rhs_is_concat_expr $rhs]
        if { !$is_simple && !($include_expr && $is_concat) } {
            if { [string first $leaf $rhs] >= 0 } {
                debug_step "source_assign_load_skip signal=$signame lhs=$lhs_leaf$lhs_select rhs=$rhs simple=$is_simple concat=$is_concat include_expr=$include_expr reason=unsupported_rhs"
            }
            continue
        }
        if { ![rhs_references_signal_bit $rhs $leaf $bit] } {
            if { [string first $leaf $rhs] >= 0 } {
                debug_step "source_assign_load_skip signal=$signame lhs=$lhs_leaf$lhs_select rhs=$rhs bit=$bit reason=rhs_bit_mismatch"
            }
            continue
        }
        incr match_count
        debug_step "source_assign_load_match signal=$signame lhs=$lhs_leaf$lhs_select rhs=$rhs simple=$is_simple concat=$is_concat"

        if { $bit eq "" } {
            if { $prefix ne "" } {
                set candidate "${prefix}.${lhs_leaf}"
            } else {
                set candidate $lhs_leaf
            }
            incr candidate_count
            set exists [source_signal_candidate_exists $candidate strict $srcfile]
            debug_step "source_assign_load_candidate signal=$signame lhs=$lhs_leaf$lhs_select rhs=$rhs candidate=$candidate exists=$exists"
            if { $exists } {
                append_unique_signal fanouts $candidate
            } else {
                incr rejected_count
            }
            continue
        }

        set lhs_bits [rhs_lhs_bits_for_signal_bit $rhs $leaf $bit $width_map]
        if { $prefix ne "" } {
            set candidate "${prefix}.${lhs_leaf}"
        } else {
            set candidate $lhs_leaf
        }
        incr candidate_count
        set exists [source_signal_candidate_exists $candidate strict $srcfile]
        debug_step "source_assign_load_candidate signal=$signame lhs=$lhs_leaf$lhs_select rhs=$rhs candidate=$candidate exists=$exists lhs_bits=[join $lhs_bits ,]"
        if { $exists } {
            append_unique_signal fanouts $candidate
        } else {
            incr rejected_count
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
                set candidate "${prefix}.${lhs_leaf}${select}"
            } else {
                set candidate "${lhs_leaf}${select}"
            }
            incr candidate_count
            set exists [source_signal_candidate_exists $candidate strict $srcfile]
            debug_step "source_assign_load_candidate signal=$signame lhs=$lhs_leaf$lhs_select rhs=$rhs candidate=$candidate exists=$exists lhs_bit=$lhs_bit"
            if { $exists } {
                append_unique_signal fanouts $candidate
            } else {
                incr rejected_count
            }
        }
    }

    if { [llength $fanouts] == 0 } {
        debug_step "source_assign_load_empty signal=$signame srcfile=$srcfile module=$module include_expr=$include_expr assign_count=[llength $assign_list] match_count=$match_count candidate_count=$candidate_count rejected_count=$rejected_count"
    }
    return $fanouts
}

proc source_assign_direct_load_fanouts { sig_hdl signame {srcfile_hint ""} {scope_hint ""} } {
    set fanouts [source_assign_load_fanouts_core $sig_hdl $signame 0 $srcfile_hint $scope_hint]
    if { [llength $fanouts] > 0 } {
        set srcfile [get_handle_source_file $sig_hdl]
        if { $srcfile eq "" } {
            set srcfile $srcfile_hint
        }
        log_step "source_assign_direct_load_fanout signal=$signame source=$srcfile fanouts=[join $fanouts ,]"
    }
    return $fanouts
}

proc source_assign_load_fanouts { sig_hdl signame {srcfile_hint ""} {scope_hint ""} } {
    global assign_expr_trace_max_depth

    if { $assign_expr_trace_max_depth <= 0 } {
        return {}
    }

    set fanouts [source_assign_load_fanouts_core $sig_hdl $signame 1 $srcfile_hint $scope_hint]
    if { [llength $fanouts] > 0 } {
        set srcfile [get_handle_source_file $sig_hdl]
        if { $srcfile eq "" } {
            set srcfile $srcfile_hint
        }
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

proc find_top_level_char { text target } {
    set depth_paren 0
    set depth_brace 0
    set depth_bracket 0
    set idx 0
    foreach ch [split $text ""] {
        if { $ch eq "(" } {
            incr depth_paren
        } elseif { $ch eq ")" } {
            incr depth_paren -1
        } elseif { $ch eq "\{" } {
            incr depth_brace
        } elseif { $ch eq "\}" } {
            incr depth_brace -1
        } elseif { $ch eq "\[" } {
            incr depth_bracket
        } elseif { $ch eq "\]" } {
            incr depth_bracket -1
        } elseif { $ch eq $target &&
                   $depth_paren == 0 &&
                   $depth_brace == 0 &&
                   $depth_bracket == 0 } {
            return $idx
        }
        incr idx
    }
    return -1
}

proc split_top_level_ternary { text } {
    set text [strip_wrapping_parens [string trim $text]]
    regsub -all {\s+} $text "" text

    set qidx [find_top_level_char $text "?"]
    if { $qidx < 0 } {
        return {}
    }

    set depth_paren 0
    set depth_brace 0
    set depth_bracket 0
    set nested_ternary 0
    set idx 0
    foreach ch [split $text ""] {
        if { $idx <= $qidx } {
            incr idx
            continue
        }

        if { $ch eq "(" } {
            incr depth_paren
        } elseif { $ch eq ")" } {
            incr depth_paren -1
        } elseif { $ch eq "\{" } {
            incr depth_brace
        } elseif { $ch eq "\}" } {
            incr depth_brace -1
        } elseif { $ch eq "\[" } {
            incr depth_bracket
        } elseif { $ch eq "\]" } {
            incr depth_bracket -1
        } elseif { $depth_paren == 0 && $depth_brace == 0 && $depth_bracket == 0 } {
            if { $ch eq "?" } {
                incr nested_ternary
            } elseif { $ch eq ":" } {
                if { $nested_ternary == 0 } {
                    set cond [string range $text 0 [expr {$qidx - 1}]]
                    set true_expr [string range $text [expr {$qidx + 1}] [expr {$idx - 1}]]
                    set false_expr [string range $text [expr {$idx + 1}] end]
                    if { $cond ne "" && $true_expr ne "" && $false_expr ne "" } {
                        return [list $cond $true_expr $false_expr]
                    }
                    return {}
                }
                incr nested_ternary -1
            }
        }
        incr idx
    }
    return {}
}

proc rhs_driver_data_exprs { rhs } {
    set rhs [strip_wrapping_parens [string trim $rhs]]
    set ternary [split_top_level_ternary $rhs]
    if { [llength $ternary] == 3 } {
        set exprs {}
        foreach branch [list [lindex $ternary 1] [lindex $ternary 2]] {
            foreach expr [rhs_driver_data_exprs $branch] {
                lappend exprs $expr
            }
        }
        return $exprs
    }
    return [list $rhs]
}

proc rhs_has_ternary_expr { rhs } {
    set rhs [strip_wrapping_parens [string trim $rhs]]
    set ternary [split_top_level_ternary $rhs]
    if { [llength $ternary] == 3 } {
        return 1
    }
    return 0
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

    set ternary [split_top_level_ternary $rhs_no_space]
    if { [llength $ternary] == 3 } {
        return {}
    }

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

    set ternary [split_top_level_ternary $rhs_no_space]
    if { [llength $ternary] == 3 } {
        return {}
    }

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

proc source_assign_driver_sources_core { sig_hdl signame {srcfile_hint ""} {include_expr 1} {scope_hint ""} } {
    set selected_bits [signal_selected_bits $signame]
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
    set prefix [signal_effective_scope_prefix $signame $scope_hint]
    set ctx [source_context_for_signal $signame $srcfile $scope_hint]
    set ctx_srcfile [lindex $ctx 0]
    set module [lindex $ctx 1]
    if { $ctx_srcfile ne "" } {
        set srcfile $ctx_srcfile
    }
    if { $module eq "" } {
        set module [source_scope_module_name $prefix $srcfile]
    }
    set width_map [build_signal_width_map_for_module $srcfile $module]

    set sources {}
    foreach assign [build_assign_stmt_list_for_module $srcfile $module] {
        set lhs_leaf [lindex $assign 0]
        set lhs_select [lindex $assign 1]
        set rhs [lindex $assign 2]
        set lhs_expr [lindex $assign 3]
        if { $lhs_leaf ne $leaf } {
            continue
        }

        if { $lhs_expr ne "" } {
            set rhs_offsets {}
            if { [llength $selected_bits] == 0 } {
                foreach rhs_bit [lhs_concat_rhs_offsets_for_signal_bit $lhs_expr $leaf "" $width_map] {
                    if { [lsearch -exact $rhs_offsets $rhs_bit] < 0 } {
                        lappend rhs_offsets $rhs_bit
                    }
                }
            } else {
                foreach target_bit $selected_bits {
                    foreach rhs_bit [lhs_concat_rhs_offsets_for_signal_bit $lhs_expr $leaf $target_bit $width_map] {
                        if { [lsearch -exact $rhs_offsets $rhs_bit] < 0 } {
                            lappend rhs_offsets $rhs_bit
                        }
                    }
                }
            }

            foreach rhs_bit $rhs_offsets {
                set direct_source [expr_item_source_signal_for_bit $rhs $rhs_bit $prefix $width_map]
                if { $direct_source ne "" } {
                    append_source_signal_candidate sources $direct_source driver $srcfile
                    continue
                }
                if { !$include_expr } {
                    continue
                }
                foreach source [rhs_driver_sources_for_bit $rhs $rhs_bit $prefix $width_map] {
                    append_source_signal_candidate sources $source driver $srcfile
                }
            }
            continue
        }

        if { [llength $selected_bits] == 0 } {
            set direct_sources [expr_item_source_signals $rhs $prefix]
            foreach source $direct_sources {
                append_source_signal_candidate sources $source driver $srcfile
            }
            if { [llength $direct_sources] > 0 || !$include_expr } {
                continue
            }
            foreach source [rhs_driver_sources_for_whole $rhs $prefix $width_map] {
                append_source_signal_candidate sources $source driver $srcfile
            }
        } else {
            foreach target_bit $selected_bits {
                set rhs_bit [lhs_select_rhs_bit_for_target $lhs_select $target_bit]
                if { $rhs_bit eq "" } {
                    continue
                }
                set direct_source [expr_item_source_signal_for_bit $rhs $rhs_bit $prefix $width_map]
                if { $direct_source ne "" } {
                    append_source_signal_candidate sources $direct_source driver $srcfile
                    continue
                }
                if { !$include_expr } {
                    continue
                }
                foreach source [rhs_driver_sources_for_bit $rhs $rhs_bit $prefix $width_map] {
                    append_source_signal_candidate sources $source driver $srcfile
                }
            }
        }
    }

    return $sources
}

proc source_assign_driver_data_sources { sig_hdl signame {srcfile_hint ""} {scope_hint ""} } {
    set selected_bits [signal_selected_bits $signame]
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
    set prefix [signal_effective_scope_prefix $signame $scope_hint]
    set ctx [source_context_for_signal $signame $srcfile $scope_hint]
    set ctx_srcfile [lindex $ctx 0]
    set module [lindex $ctx 1]
    if { $ctx_srcfile ne "" } {
        set srcfile $ctx_srcfile
    }
    if { $module eq "" } {
        set module [source_scope_module_name $prefix $srcfile]
    }
    set width_map [build_signal_width_map_for_module $srcfile $module]

    set sources {}
    set found_restrictive_assign 0
    foreach assign [build_assign_stmt_list_for_module $srcfile $module] {
        set lhs_leaf [lindex $assign 0]
        set lhs_select [lindex $assign 1]
        set rhs [lindex $assign 2]
        set lhs_expr [lindex $assign 3]
        if { $lhs_leaf ne $leaf } {
            continue
        }

        if { ![rhs_has_ternary_expr $rhs] } {
            continue
        }

        set data_exprs [rhs_driver_data_exprs $rhs]
        if { [llength $data_exprs] == 0 } {
            continue
        }

        if { $lhs_expr ne "" } {
            set rhs_offsets {}
            if { [llength $selected_bits] == 0 } {
                foreach rhs_bit [lhs_concat_rhs_offsets_for_signal_bit $lhs_expr $leaf "" $width_map] {
                    if { [lsearch -exact $rhs_offsets $rhs_bit] < 0 } {
                        lappend rhs_offsets $rhs_bit
                    }
                }
            } else {
                foreach target_bit $selected_bits {
                    foreach rhs_bit [lhs_concat_rhs_offsets_for_signal_bit $lhs_expr $leaf $target_bit $width_map] {
                        if { [lsearch -exact $rhs_offsets $rhs_bit] < 0 } {
                            lappend rhs_offsets $rhs_bit
                        }
                    }
                }
            }

            foreach rhs_bit $rhs_offsets {
                foreach data_expr $data_exprs {
                    foreach source [rhs_driver_sources_for_bit $data_expr $rhs_bit $prefix $width_map] {
                        append_source_signal_candidate sources $source driver $srcfile
                    }
                }
            }
            set found_restrictive_assign 1
            continue
        }

        if { [llength $selected_bits] == 0 } {
            foreach data_expr $data_exprs {
                foreach source [rhs_driver_sources_for_whole $data_expr $prefix $width_map] {
                    append_source_signal_candidate sources $source driver $srcfile
                }
            }
            set found_restrictive_assign 1
        } else {
            foreach target_bit $selected_bits {
                set rhs_bit [lhs_select_rhs_bit_for_target $lhs_select $target_bit]
                if { $rhs_bit eq "" } {
                    continue
                }
                foreach data_expr $data_exprs {
                    foreach source [rhs_driver_sources_for_bit $data_expr $rhs_bit $prefix $width_map] {
                        append_source_signal_candidate sources $source driver $srcfile
                    }
                }
            }
            set found_restrictive_assign 1
        }
    }

    if { !$found_restrictive_assign } {
        return {}
    }

    if { [llength $sources] > 0 } {
        log_step "source_assign_driver_data_sources signal=$signame source=$srcfile drivers=[join $sources ,]"
    } else {
        debug_step "source_assign_driver_data_sources_empty signal=$signame source=$srcfile module=$module"
    }
    return $sources
}

proc source_assign_driver_combo_stop_expr { sig_hdl signame {srcfile_hint ""} {scope_hint ""} } {
    set selected_bits [signal_selected_bits $signame]
    set srcfile $srcfile_hint
    if { $srcfile eq "" && $sig_hdl ne "" } {
        set srcfile [get_handle_source_file $sig_hdl]
    }
    if { $srcfile eq "" } {
        return ""
    }

    set leaf [signal_leaf_name $signame]
    if { $leaf eq "" } {
        return ""
    }
    set prefix [signal_effective_scope_prefix $signame $scope_hint]
    set ctx [source_context_for_signal $signame $srcfile $scope_hint]
    set ctx_srcfile [lindex $ctx 0]
    set module [lindex $ctx 1]
    if { $ctx_srcfile ne "" } {
        set srcfile $ctx_srcfile
    }
    if { $module eq "" } {
        set module [source_scope_module_name $prefix $srcfile]
    }
    set width_map [build_signal_width_map_for_module $srcfile $module]

    foreach assign [build_assign_stmt_list_for_module $srcfile $module] {
        set lhs_leaf [lindex $assign 0]
        set lhs_select [lindex $assign 1]
        set rhs [lindex $assign 2]
        set lhs_expr [lindex $assign 3]
        if { $lhs_leaf ne $leaf || ![rhs_has_ternary_expr $rhs] } {
            continue
        }

        set affected 0
        if { $lhs_expr ne "" } {
            if { [llength $selected_bits] == 0 } {
                set affected [expr {[llength [lhs_concat_rhs_offsets_for_signal_bit $lhs_expr $leaf "" $width_map]] > 0}]
            } else {
                foreach target_bit $selected_bits {
                    if { [llength [lhs_concat_rhs_offsets_for_signal_bit $lhs_expr $leaf $target_bit $width_map]] > 0 } {
                        set affected 1
                        break
                    }
                }
            }
        } elseif { [llength $selected_bits] == 0 } {
            set affected 1
        } else {
            foreach target_bit $selected_bits {
                if { [lhs_select_rhs_bit_for_target $lhs_select $target_bit] ne "" } {
                    set affected 1
                    break
                }
            }
        }

        if { $affected } {
            log_step "driver_combo_stop signal=$signame source=$srcfile reason=ternary"
            return "COMBO_EXPR:ternary"
        }
    }
    return ""
}

proc source_assign_const_chain { signame srcfile depth visited_var {scope_hint ""} } {
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
    foreach source_sig [source_assign_driver_sources_core "" $signame $srcfile 1 $scope_hint] {
        if { [is_const_literal_name $source_sig] } {
            append_unique_signal consts $source_sig
        } else {
            set next_scope_hint [signal_scope_hint_after $source_sig $scope_hint]
            foreach const_sig [source_assign_const_chain $source_sig $srcfile [expr {$depth - 1}] visited $next_scope_hint] {
                append_unique_signal consts $const_sig
            }
        }
    }
    return $consts
}

proc source_assign_direct_driver_sources { sig_hdl signame {srcfile_hint ""} {scope_hint ""} } {
    set sources [source_assign_driver_sources_core $sig_hdl $signame $srcfile_hint 0 $scope_hint]
    if { [llength $sources] > 0 } {
        log_step "source_assign_direct_driver_source signal=$signame source=$srcfile_hint drivers=[join $sources ,]"
    }
    return $sources
}

proc source_assign_driver_sources { sig_hdl signame {srcfile_hint ""} {scope_hint ""} } {
    global assign_expr_trace_max_depth

    if { $assign_expr_trace_max_depth <= 0 } {
        return {}
    }

    set sources [source_assign_driver_sources_core $sig_hdl $signame $srcfile_hint 1 $scope_hint]
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
            set next_scope_hint [signal_scope_hint_after $source_sig $scope_hint]
            foreach const_sig [source_assign_const_chain $source_sig $srcfile $assign_expr_trace_max_depth visited $next_scope_hint] {
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

proc select_selected_bits { select } {
    set select [string trim $select]
    if { [regexp {^\[([0-9]+)\]$} $select -> bit] } {
        return [list $bit]
    }
    if { [regexp {^\[([0-9]+):([0-9]+)\]$} $select -> hi lo] } {
        set bits {}
        if { $hi >= $lo } {
            for {set bit $lo} {$bit <= $hi} {incr bit} {
                lappend bits $bit
            }
        } else {
            for {set bit $hi} {$bit <= $lo} {incr bit} {
                lappend bits $bit
            }
        }
        return $bits
    }
    return {}
}

proc bits_to_select_suffix { bits } {
    if { [llength $bits] == 0 } {
        return ""
    }

    set sorted [lsort -integer -unique $bits]
    if { [llength $sorted] == 1 } {
        return "\[[lindex $sorted 0]\]"
    }

    set prev [lindex $sorted 0]
    foreach bit [lrange $sorted 1 end] {
        if { $bit != $prev + 1 } {
            return ""
        }
        set prev $bit
    }

    set lo [lindex $sorted 0]
    set hi [lindex $sorted end]
    return "\[$hi:$lo\]"
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
    set value [const_driver_from_assign_map $const_map $signame $leaf]
    if { $value ne "" } {
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

    # Netlist handles can report only a local nlName through the L1 helper in
    # some large KDBs. Prefer the native npiNlFullName property when present so
    # later fallback never has to guess the scope of a bare "net" or "port".
    set signame ""
    catch { set signame [npi_nl_get_str -property npiNlFullName -object $hdl] }
    set signame [string trim $signame]
    if { $signame ne "" } {
        return [normalize_signal_name $signame]
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
            catch { set signame [npi_nl_get_str -property npiNlFullName -object $net_hdl] }
            set signame [string trim $signame]
            if { $signame ne "" } {
                return [normalize_signal_name $signame]
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

    # Generated logic and expression instances are real trace endpoints.
    # Module port/pin endpoints are still structural connections, so they are
    # allowed below when the normalized name is a clean module-boundary signal.
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
            return [is_module_boundary_signal $signame]
        }
        if { [string first "net" $kind] >= 0 ||
             [string first "sig" $kind] >= 0 ||
             [string first "wire" $kind] >= 0 } {
            return 1
        }
    }

    return [is_module_boundary_signal $signame]
}

proc trace_source_hint_for_hdl { hdl fallback } {
    set srcfile [get_handle_source_file $hdl]
    if { $srcfile ne "" } {
        return $srcfile
    }
    return $fallback
}

proc source_instance_module_name { srcfile instname } {
    if { $srcfile eq "" || $instname eq "" } {
        return ""
    }
    foreach inst [build_instantiation_stmt_list $srcfile] {
        if { [lindex $inst 1] eq $instname } {
            return [lindex $inst 0]
        }
    }
    return ""
}

proc source_module_port_direction { srcfile inst_path portname } {
    if { $srcfile eq "" || $inst_path eq "" || $portname eq "" } {
        return "unknown"
    }
    set instname [lindex [split $inst_path "."] end]
    set modname [source_instance_module_name $srcfile $instname]
    if { $modname eq "" } {
        return "unknown"
    }
    set dir_map [build_port_dir_map $srcfile $modname]
    if { [dict exists $dir_map $portname] } {
        return [dict get $dir_map $portname]
    }
    return "unknown"
}

proc module_port_high_conn_pairs { hdl signame role {srcfile_hint ""} } {
    set signame [normalize_signal_name $signame]
    if { ![is_module_boundary_signal $signame] } {
        return {}
    }

    set base [strip_signal_selects $signame]
    if { ![regexp {^(.+)\.([A-Za-z_][A-Za-z0-9_$]*)$} $base -> inst_path portname] } {
        return {}
    }

    set dir [module_boundary_port_direction $hdl $signame]
    if { $dir eq "unknown" } {
        set srcfile [trace_source_hint_for_hdl $hdl $srcfile_hint]
        set dir [source_module_port_direction $srcfile $inst_path $portname]
    }

    set port_hdl [get_inst_port_handle_by_signal $inst_path $base]
    if { $dir eq "unknown" && $port_hdl ne "" } {
        set dir [get_port_direction $port_hdl]
    }
    if { $dir eq "unknown" } {
        set ctx [source_context_for_signal $signame $srcfile_hint]
        set ctx_srcfile [lindex $ctx 0]
        set ctx_module [lindex $ctx 1]
        if { $ctx_srcfile ne "" && $ctx_module ne "" } {
            set dir_map [build_port_dir_map $ctx_srcfile $ctx_module]
            if { [dict exists $dir_map $portname] } {
                set dir [dict get $dir_map $portname]
            }
        }
    }

    set cross 0
    if { $role eq "driver" } {
        if { $dir eq "input" || $dir eq "inout" } {
            set cross 1
        }
    } elseif { $role eq "load" } {
        if { $dir eq "output" || $dir eq "inout" } {
            set cross 1
        }
    }
    if { !$cross } {
        debug_step "module_port_high_skip role=$role signal=$signame inst=$inst_path port=$portname dir=$dir reason=direction"
        return {}
    }

    if { $port_hdl eq "" } {
        debug_step "module_port_high_skip role=$role signal=$signame inst=$inst_path port=$portname dir=$dir reason=port_handle_empty"
        return {}
    }

    set pairs {}
    set signame_select [signal_select_suffix $signame]
    set high_hdls [get_high_conn_sigs_for_port_hdl $inst_path $port_hdl]
    debug_step "module_port_high_probe role=$role signal=$signame inst=$inst_path port=$portname dir=$dir high_count=[llength $high_hdls] select=$signame_select"
    foreach high_hdl $high_hdls {
        set high_name [hdl_to_name $high_hdl]
        if { $high_name eq "" } {
            debug_step "module_port_high_skip role=$role signal=$signame inst=$inst_path port=$portname reason=high_name_empty"
            continue
        }
        if { $signame_select ne "" } {
            set high_name [apply_signal_select $high_name $signame_select]
            if { $high_name eq "" } {
                debug_step "module_port_high_skip role=$role signal=$signame inst=$inst_path port=$portname reason=select_mapping_empty"
                continue
            }
        }
        if { ![is_const_literal_name $high_name] &&
             [signal_scope_prefix $high_name] eq "" } {
            set parent_scope [parent_instance_path $inst_path]
            if { $parent_scope ne "" } {
                set high_name "${parent_scope}.${high_name}"
            }
        }
        lappend pairs [list $high_hdl $high_name]
    }
    return $pairs
}

proc collect_driver_module_port_high_conns { hdl signame all_drivers_var module_drivers_var net_depth expr_depth visited_var srcfile_hint } {
    upvar 1 $all_drivers_var all_drivers
    upvar 1 $module_drivers_var module_drivers
    upvar 1 $visited_var visited

    if { $net_depth <= 0 && $expr_depth <= 0 } {
        return
    }

    foreach pair [module_port_high_conn_pairs $hdl $signame driver $srcfile_hint] {
        set high_hdl [lindex $pair 0]
        set high_sig [lindex $pair 1]
        append_unique_signal all_drivers $high_sig
        if { [is_module_boundary_signal $high_sig] } {
            append_unique_signal module_drivers $high_sig
        }
        if { ![is_const_literal_name $high_sig] } {
            log_step "driver_module_port_high_continue from=$signame via=$high_sig remaining_net_depth=$net_depth"
            set next_srcfile_hint [trace_source_hint_for_hdl $high_hdl $srcfile_hint]
            set next_scope_hint [signal_scope_hint_after $high_sig]
            if { $net_depth > 0 } {
                collect_drivers_by_name_rec $high_sig all_drivers module_drivers [expr {$net_depth - 1}] $expr_depth visited $next_srcfile_hint $next_scope_hint
            } else {
                collect_drivers_by_name_rec $high_sig all_drivers module_drivers 0 [expr {$expr_depth - 1}] visited $next_srcfile_hint $next_scope_hint
            }
        }
    }
}

proc collect_load_module_port_high_conns { hdl signame all_loads_var module_loads_var net_depth expr_depth visited_var {srcfile_hint ""} {scope_hint ""} } {
    upvar 1 $all_loads_var all_loads
    upvar 1 $module_loads_var module_loads
    upvar 1 $visited_var visited

    if { $net_depth <= 0 && $expr_depth <= 0 } {
        debug_step "load_module_port_high_skip signal=$signame reason=depth_exhausted net_depth=$net_depth expr_depth=$expr_depth srcfile_hint=$srcfile_hint"
        return
    }

    set query_signame [scoped_signal_for_query $signame $scope_hint]
    set pairs [module_port_high_conn_pairs $hdl $query_signame load $srcfile_hint]
    if { [llength $pairs] == 0 } {
        debug_step "load_module_port_high_empty signal=$signame query=$query_signame scope_hint=$scope_hint net_depth=$net_depth expr_depth=$expr_depth srcfile_hint=$srcfile_hint"
    }
    foreach pair $pairs {
        set high_hdl [lindex $pair 0]
        set high_sig [lindex $pair 1]
        append_unique_signal all_loads $high_sig
        if { [is_module_boundary_signal $high_sig] } {
            append_unique_signal module_loads $high_sig
        }
        if { ![is_const_literal_name $high_sig] } {
            log_step "load_module_port_high_continue from=$signame via=$high_sig remaining_net_depth=$net_depth"
            set next_srcfile_hint [trace_source_hint_for_hdl $high_hdl $srcfile_hint]
            set next_scope_hint [signal_scope_hint_after $high_sig $scope_hint]
            if { $net_depth > 0 } {
                collect_loads_by_name_rec $high_sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth visited $next_srcfile_hint $next_scope_hint
            } else {
                collect_loads_by_name_rec $high_sig all_loads module_loads 0 [expr {$expr_depth - 1}] visited $next_srcfile_hint $next_scope_hint
            }
        }
    }
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

proc collect_drivers_by_name { signame all_drivers_var module_drivers_var {srcfile_hint ""} {scope_hint ""} {data_source_restrict {}} } {
    global assign_trace_max_depth assign_expr_trace_max_depth
    upvar 1 $all_drivers_var all_drivers
    upvar 1 $module_drivers_var module_drivers

    set visited {}
    collect_drivers_by_name_rec $signame all_drivers module_drivers $assign_trace_max_depth $assign_expr_trace_max_depth visited $srcfile_hint $scope_hint $data_source_restrict
}

proc trace_allowed_by_data_sources { sig data_sources } {
    if { [llength $data_sources] == 0 } {
        return 1
    }
    set sig_norm [normalize_signal_name $sig]
    if { $sig_norm eq "" } {
        return 1
    }
    if { [is_const_literal_name $sig_norm] } {
        foreach src $data_sources {
            if { [normalize_signal_name $src] eq $sig_norm } {
                return 1
            }
        }
        return 0
    }
    set sig_base [signal_base_without_select $sig_norm]
    foreach src $data_sources {
        set src_norm [normalize_signal_name $src]
        if { [is_const_literal_name $src_norm] } {
            continue
        }
        set src_base [signal_base_without_select $src_norm]
        if { $src_base eq "" } {
            continue
        }
        if { $sig_base eq $src_base ||
             [string first "${src_base}." $sig_base] == 0 ||
             [string first "${sig_base}." $src_base] == 0 } {
            if { ![signal_selects_overlap $sig_norm $src_norm] } {
                continue
            }
            return 1
        }
    }
    return 0
}

proc filter_by_data_sources { values data_sources } {
    if { [llength $data_sources] == 0 } {
        return $values
    }
    set filtered {}
    foreach sig $values {
        if { [trace_allowed_by_data_sources $sig $data_sources] } {
            append_unique_signal filtered $sig
        }
    }
    return $filtered
}

proc collect_source_driver_sources { signame srcfile_hint all_drivers_var module_drivers_var net_depth expr_depth visited_var {scope_hint ""} {data_source_restrict {}} } {
    upvar 1 $all_drivers_var all_drivers
    upvar 1 $module_drivers_var module_drivers
    upvar 1 $visited_var visited

    if { $net_depth <= 0 && $expr_depth <= 0 } {
        return
    }
    if { $srcfile_hint eq "" } {
        set ctx [source_context_for_signal $signame "" $scope_hint]
        set ctx_srcfile [lindex $ctx 0]
        if { $ctx_srcfile ne "" } {
            set srcfile_hint $ctx_srcfile
        }
    }
    if { $srcfile_hint eq "" } {
        return
    }

    set combo_stop [source_assign_driver_combo_stop_expr "" $signame $srcfile_hint $scope_hint]
    if { $combo_stop ne "" } {
        append_unique_signal all_drivers $combo_stop
        return
    }

    foreach port_sig [source_module_port_driver_sources $srcfile_hint $signame $scope_hint] {
        if { ![trace_allowed_by_data_sources $port_sig $data_source_restrict] } {
            debug_step "driver_data_source_skip signal=$signame candidate=$port_sig reason=not_data_branch"
            continue
        }
        append_unique_signal all_drivers $port_sig
        append_unique_signal module_drivers $port_sig
        collect_driver_module_port_high_conns "" $port_sig all_drivers module_drivers $net_depth $expr_depth visited $srcfile_hint
        if { $net_depth > 0 && ![is_const_literal_name $port_sig] } {
            log_step "driver_module_port_continue from=$signame via=$port_sig remaining_net_depth=$net_depth"
            set next_scope_hint [signal_scope_hint_after $port_sig $scope_hint]
            collect_drivers_by_name_rec $port_sig all_drivers module_drivers [expr {$net_depth - 1}] $expr_depth visited $srcfile_hint $next_scope_hint {}
        }
    }

    set direct_sources {}
    if { $net_depth > 0 } {
        foreach source_sig [source_assign_direct_driver_sources "" $signame $srcfile_hint $scope_hint] {
            if { ![trace_allowed_by_data_sources $source_sig $data_source_restrict] } {
                debug_step "driver_data_source_skip signal=$signame candidate=$source_sig reason=not_data_branch"
                continue
            }
            append_unique_signal direct_sources $source_sig
            append_unique_signal all_drivers $source_sig
            if { [is_module_boundary_signal $source_sig] } {
                append_unique_signal module_drivers $source_sig
            }
            if { ![is_const_literal_name $source_sig] } {
                set next_scope_hint [signal_scope_hint_after $source_sig $scope_hint]
                collect_drivers_by_name_rec $source_sig all_drivers module_drivers [expr {$net_depth - 1}] $expr_depth visited $srcfile_hint $next_scope_hint {}
            }
        }
    }

    if { $expr_depth <= 0 } {
        return
    }

    foreach source_sig [source_assign_driver_sources "" $signame $srcfile_hint $scope_hint] {
        if { ![trace_allowed_by_data_sources $source_sig $data_source_restrict] } {
            debug_step "driver_data_source_skip signal=$signame candidate=$source_sig reason=not_data_branch"
            continue
        }
        if { [lsearch -exact $direct_sources $source_sig] >= 0 } {
            continue
        }
        append_unique_signal all_drivers $source_sig
        if { [is_module_boundary_signal $source_sig] } {
            append_unique_signal module_drivers $source_sig
        }
        if { ![is_const_literal_name $source_sig] } {
            set next_scope_hint [signal_scope_hint_after $source_sig $scope_hint]
            collect_drivers_by_name_rec $source_sig all_drivers module_drivers $net_depth [expr {$expr_depth - 1}] visited $srcfile_hint $next_scope_hint {}
        }
    }
}

proc collect_drivers_by_name_rec { signame all_drivers_var module_drivers_var net_depth expr_depth visited_var {srcfile_hint ""} {scope_hint ""} {data_source_restrict {}} } {
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

    if { $srcfile_hint eq "" } {
        set ctx [source_context_for_signal $signame "" $scope_hint]
        set ctx_srcfile [lindex $ctx 0]
        if { $ctx_srcfile ne "" } {
            set srcfile_hint $ctx_srcfile
        }
    }

    set combo_stop [source_assign_driver_combo_stop_expr "" $signame $srcfile_hint $scope_hint]
    if { $combo_stop ne "" } {
        append_unique_signal all_drivers $combo_stop
        return
    }

    # NPI string tracing can lose the bit-select on wide nets in some KDBs and
    # then return endpoints for sibling bits. For A[7]-style queries, prefer
    # the source/KDB-backed bit mapping when it can resolve at least one source.
    if { [llength [signal_selected_bits $signame]] > 0 } {
        set source_count_before [llength $all_drivers]
        collect_source_driver_sources $signame $srcfile_hint all_drivers module_drivers $net_depth $expr_depth $visited_var $scope_hint $data_source_restrict
        if { [llength $all_drivers] > $source_count_before } {
            log_step "bit_driver_source_restrict signal=$signame source=$srcfile_hint drivers=[join [lrange $all_drivers $source_count_before end] ,]"
            return
        }
    }

    set module_port_query [scoped_signal_for_query $signame $scope_hint]
    collect_driver_module_port_high_conns "" $module_port_query all_drivers module_drivers $net_depth $expr_depth $visited_var $srcfile_hint

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
        if { ![trace_allowed_by_data_sources $sig $data_source_restrict] } {
            debug_step "driver_data_source_skip signal=$signame candidate=$sig reason=not_data_branch"
            continue
        }
        append_unique_signal all_drivers $sig
        collect_driver_module_port_high_conns $hdl $sig all_drivers module_drivers $net_depth $expr_depth $visited_var $srcfile_hint
        if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
            log_step "driver_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
            set next_srcfile_hint [trace_source_hint_for_hdl $hdl $srcfile_hint]
            set next_scope_hint [signal_scope_hint_after $sig $scope_hint]
            collect_drivers_by_name_rec $sig all_drivers module_drivers [expr {$net_depth - 1}] $expr_depth $visited_var $next_srcfile_hint $next_scope_hint {}
        } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
            log_step "driver_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
            set next_srcfile_hint [trace_source_hint_for_hdl $hdl $srcfile_hint]
            set next_scope_hint [signal_scope_hint_after $sig $scope_hint]
            collect_drivers_by_name_rec $sig all_drivers module_drivers $net_depth [expr {$expr_depth - 1}] $visited_var $next_srcfile_hint $next_scope_hint {}
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
            if { ![trace_allowed_by_data_sources $sig $data_source_restrict] } {
                debug_step "driver_data_source_skip signal=$signame candidate=$sig reason=not_data_branch"
                continue
            }
            append_unique_signal module_drivers $sig
            append_unique_signal all_drivers $sig
            collect_driver_module_port_high_conns $hdl $sig all_drivers module_drivers $net_depth $expr_depth $visited_var $srcfile_hint
            if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
                log_step "driver_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
                set next_srcfile_hint [trace_source_hint_for_hdl $hdl $srcfile_hint]
                set next_scope_hint [signal_scope_hint_after $sig $scope_hint]
                collect_drivers_by_name_rec $sig all_drivers module_drivers [expr {$net_depth - 1}] $expr_depth $visited_var $next_srcfile_hint $next_scope_hint {}
            } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
                log_step "driver_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
                set next_srcfile_hint [trace_source_hint_for_hdl $hdl $srcfile_hint]
                set next_scope_hint [signal_scope_hint_after $sig $scope_hint]
                collect_drivers_by_name_rec $sig all_drivers module_drivers $net_depth [expr {$expr_depth - 1}] $visited_var $next_srcfile_hint $next_scope_hint {}
            }
        }
    }

    set conn_driver_count_before [llength $all_drivers]
    collect_conn_module_ports_by_name $signame driver all_drivers module_drivers
    if { [llength $data_source_restrict] > 0 } {
        set all_drivers [filter_by_data_sources $all_drivers $data_source_restrict]
        set module_drivers [filter_by_data_sources $module_drivers $data_source_restrict]
    }
    if { $net_depth > 0 } {
        foreach sig [lrange $all_drivers $conn_driver_count_before end] {
            if { ![trace_allowed_by_data_sources $sig $data_source_restrict] } {
                debug_step "driver_data_source_skip signal=$signame candidate=$sig reason=not_data_branch"
                continue
            }
            if { [is_module_boundary_signal $sig] && ![is_const_literal_name $sig] } {
                collect_driver_module_port_high_conns "" $sig all_drivers module_drivers $net_depth $expr_depth $visited_var $srcfile_hint
                log_step "driver_conn_module_port_continue from=$signame via=$sig remaining_net_depth=$net_depth"
                set next_scope_hint [signal_scope_hint_after $sig $scope_hint]
                collect_drivers_by_name_rec $sig all_drivers module_drivers [expr {$net_depth - 1}] $expr_depth $visited_var $srcfile_hint $next_scope_hint {}
            }
        }
    }
    collect_source_driver_sources $signame $srcfile_hint all_drivers module_drivers $net_depth $expr_depth $visited_var $scope_hint $data_source_restrict
}

proc collect_loads_by_name { signame all_loads_var module_loads_var {srcfile_hint ""} {scope_hint ""} } {
    global assign_trace_max_depth assign_expr_trace_max_depth
    upvar 1 $all_loads_var all_loads
    upvar 1 $module_loads_var module_loads

    set visited {}
    collect_loads_by_name_rec $signame all_loads module_loads $assign_trace_max_depth $assign_expr_trace_max_depth visited $srcfile_hint $scope_hint
}

proc collect_source_load_fanouts { hdl signame all_loads_var module_loads_var net_depth expr_depth visited_var {srcfile_hint ""} {scope_hint ""} } {
    upvar 1 $all_loads_var all_loads
    upvar 1 $module_loads_var module_loads
    upvar 1 $visited_var visited

    set hdl_empty [expr {$hdl eq ""}]
    debug_step "collect_source_load_fanouts_enter signal=$signame net_depth=$net_depth expr_depth=$expr_depth srcfile_hint=$srcfile_hint scope_hint=$scope_hint hdl_empty=$hdl_empty"
    if { $net_depth <= 0 && $expr_depth <= 0 } {
        debug_step "collect_source_load_fanouts_skip signal=$signame reason=depth_exhausted"
        return
    }

    set direct_fanouts {}
    if { $net_depth > 0 } {
        foreach port_sig [source_module_port_load_fanouts $srcfile_hint $signame $scope_hint] {
            append_unique_signal direct_fanouts $port_sig
            append_unique_signal all_loads $port_sig
            append_unique_signal module_loads $port_sig
            set next_scope_hint [signal_scope_hint_after $port_sig $scope_hint]
            set next_ctx [source_context_for_signal $port_sig $srcfile_hint $next_scope_hint]
            set next_srcfile_hint [lindex $next_ctx 0]
            if { $next_srcfile_hint eq "" } {
                set next_srcfile_hint $srcfile_hint
            }
            collect_load_module_port_high_conns "" $port_sig all_loads module_loads $net_depth $expr_depth visited $next_srcfile_hint $next_scope_hint
            collect_loads_by_name_rec $port_sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth visited $next_srcfile_hint $next_scope_hint
        }
        foreach fanout_sig [source_assign_direct_load_fanouts $hdl $signame $srcfile_hint $scope_hint] {
            append_unique_signal direct_fanouts $fanout_sig
            append_unique_signal all_loads $fanout_sig
            set next_scope_hint [signal_scope_hint_after $fanout_sig $scope_hint]
            set next_ctx [source_context_for_signal $fanout_sig $srcfile_hint $next_scope_hint]
            set next_srcfile_hint [lindex $next_ctx 0]
            if { $next_srcfile_hint eq "" } {
                set next_srcfile_hint $srcfile_hint
            }
            collect_loads_by_name_rec $fanout_sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth visited $next_srcfile_hint $next_scope_hint
        }
    }

    if { $expr_depth <= 0 } {
        return
    }

    foreach fanout_sig [source_assign_load_fanouts $hdl $signame $srcfile_hint $scope_hint] {
        if { [lsearch -exact $direct_fanouts $fanout_sig] >= 0 } {
            continue
        }
        append_unique_signal all_loads $fanout_sig
        set next_scope_hint [signal_scope_hint_after $fanout_sig $scope_hint]
        set next_ctx [source_context_for_signal $fanout_sig $srcfile_hint $next_scope_hint]
        set next_srcfile_hint [lindex $next_ctx 0]
        if { $next_srcfile_hint eq "" } {
            set next_srcfile_hint $srcfile_hint
        }
        collect_loads_by_name_rec $fanout_sig all_loads module_loads $net_depth [expr {$expr_depth - 1}] visited $next_srcfile_hint $next_scope_hint
    }
}

proc append_load_hdl_endpoint { hdl from_sig all_loads_var module_loads_var net_depth expr_depth visited_var {srcfile_hint ""} {scope_hint ""} {remaining_net_adjust 0} } {
    upvar 1 $all_loads_var all_loads
    upvar 1 $module_loads_var module_loads
    upvar 1 $visited_var visited

    set sig [hdl_to_name $hdl]
    if { $sig eq "" } {
        return
    }
    append_unique_signal all_loads $sig
    if { [is_module_boundary_signal $sig] } {
        append_unique_signal module_loads $sig
    }

    set next_srcfile_hint [trace_source_hint_for_hdl $hdl $srcfile_hint]
    set next_scope_hint [signal_scope_hint_after $sig $scope_hint]
    collect_load_module_port_high_conns $hdl $sig all_loads module_loads $net_depth $expr_depth visited $next_srcfile_hint $next_scope_hint

    set next_net_depth [expr {$net_depth - $remaining_net_adjust}]
    if { $next_net_depth < 0 } {
        set next_net_depth 0
    }

    if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
        log_step "load_assign_continue from=$from_sig via=$sig remaining_net_depth=$net_depth"
        collect_loads_by_name_rec $sig all_loads module_loads $next_net_depth $expr_depth visited $next_srcfile_hint $next_scope_hint
    } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
        log_step "load_assign_expr_continue from=$from_sig via=$sig remaining_expr_depth=$expr_depth"
        collect_loads_by_name_rec $sig all_loads module_loads $net_depth [expr {$expr_depth - 1}] visited $next_srcfile_hint $next_scope_hint
    }

    collect_source_load_fanouts $hdl $sig all_loads module_loads $net_depth $expr_depth visited $next_srcfile_hint $next_scope_hint
}

proc collect_loads_by_hdl_fallback { hdl signame all_loads_var module_loads_var net_depth expr_depth visited_var {srcfile_hint ""} {scope_hint ""} } {
    upvar 1 $all_loads_var all_loads
    upvar 1 $module_loads_var module_loads
    upvar 1 $visited_var visited

    if { $hdl eq "" || $hdl == 0 } {
        return
    }
    set visit_key "hdl_load:$hdl"
    if { [lsearch -exact $visited $visit_key] >= 0 } {
        return
    }
    lappend visited $visit_key

    set loadList {}
    set used_api ""
    if { [info commands ::npi_L1::npi_nl_trace_load_by_hdl2] ne "" &&
         ![catch { ::npi_L1::npi_nl_trace_load_by_hdl2 $hdl loadList }] } {
        set used_api "npi_nl_trace_load_by_hdl2"
    } elseif { ![catch { ::npi_L1::npi_nl_trace_load_by_hdl $hdl loadList }] } {
        set used_api "npi_nl_trace_load_by_hdl"
    }
    if { [llength $loadList] > 0 } {
        debug_step "load_hdl_trace signal=$signame api=$used_api count=[llength $loadList]"
    }
    foreach load_hdl $loadList {
        append_load_hdl_endpoint $load_hdl $signame all_loads module_loads $net_depth $expr_depth visited $srcfile_hint $scope_hint 1
    }

    set net_hdl $hdl
    set net_name [hdl_to_name $net_hdl]
    if { ![is_module_boundary_signal $net_name] } {
        set net_hdl ""
        catch { set net_hdl [::npi_L1::npi_nl_port_instport_2_net $hdl] }
    }
    if { $net_hdl eq "" || $net_hdl == 0 } {
        return
    }

    set portList {}
    if { [catch { ::npi_L1::npi_nl_net_2_port_instport $net_hdl portList } err] } {
        debug_step "load_net_port_trace_error signal=$signame error=$err"
        return
    }
    if { [llength $portList] > 0 } {
        debug_step "load_net_port_trace signal=$signame count=[llength $portList]"
    }
    foreach port_hdl $portList {
        set port_sig [hdl_to_name $port_hdl]
        if { $port_sig eq "" } {
            continue
        }
        set dir [module_boundary_port_direction $port_hdl $port_sig]
        if { $dir ne "input" && $dir ne "inout" && $dir ne "unknown" } {
            debug_step "load_net_port_skip signal=$signame candidate=$port_sig dir=$dir reason=direction"
            continue
        }
        append_load_hdl_endpoint $port_hdl $signame all_loads module_loads $net_depth $expr_depth visited $srcfile_hint $scope_hint 1
    }
}

proc collect_loads_by_name_rec { signame all_loads_var module_loads_var net_depth expr_depth visited_var {srcfile_hint ""} {scope_hint ""} } {
    upvar 1 $all_loads_var all_loads
    upvar 1 $module_loads_var module_loads
    upvar 1 $visited_var visited

    set signame [normalize_signal_name $signame]
    if { $signame eq "" || [is_const_literal_name $signame] } {
        debug_step "collect_load_rec_skip signal=$signame reason=empty_or_const"
        return
    }
    set query_signame [scoped_signal_for_query $signame $scope_hint]
    if { [signal_seen_or_mark visited $query_signame] } {
        debug_step "collect_load_rec_skip signal=$signame reason=visited"
        return
    }
    if { $srcfile_hint eq "" } {
        set ctx [source_context_for_signal $signame "" $scope_hint]
        set ctx_srcfile [lindex $ctx 0]
        if { $ctx_srcfile ne "" } {
            set srcfile_hint $ctx_srcfile
        }
    }
    debug_step "collect_load_rec_enter signal=$signame query=$query_signame net_depth=$net_depth expr_depth=$expr_depth srcfile_hint=$srcfile_hint scope_hint=$scope_hint"

    # A load trace can reach a plain parent-scope net through module-port
    # continuation. In large designs, NPI may stop at that net and not return
    # continuous-assign fanout handles, so run source fallback for every
    # recursive load entry, not only for the original -ports signal.
    collect_load_module_port_high_conns "" $query_signame all_loads module_loads $net_depth $expr_depth $visited_var $srcfile_hint $scope_hint
    collect_source_load_fanouts "" $signame all_loads module_loads $net_depth $expr_depth $visited_var $srcfile_hint $scope_hint

    set query_hdl ""
    catch { set query_hdl [::npi_L1::npi_nl_ut_get_hdl_by_actual_name $query_signame npiNlUndefined] }
    if { $query_hdl ne "" && $query_hdl != 0 } {
        collect_loads_by_hdl_fallback $query_hdl $query_signame all_loads module_loads $net_depth $expr_depth $visited_var $srcfile_hint $scope_hint
    }

    set loadList {}
    if { [catch { ::npi_L1::npi_nl_trace_load $query_signame loadList 1 1 } err] } {
        log_step "load_assign_trace_error passMod=1 signal=$query_signame error=$err"
        set loadList {}
    }

    foreach hdl $loadList {
        set sig [hdl_to_name $hdl]
        if { $sig eq "" } {
            continue
        }
        append_unique_signal all_loads $sig
        set next_srcfile_hint [trace_source_hint_for_hdl $hdl $srcfile_hint]
        set next_scope_hint [signal_scope_hint_after $sig $scope_hint]
        collect_load_module_port_high_conns $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
        if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
            log_step "load_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
            collect_loads_by_name_rec $sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
        } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
            log_step "load_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
            collect_loads_by_name_rec $sig all_loads module_loads $net_depth [expr {$expr_depth - 1}] $visited_var $next_srcfile_hint $next_scope_hint
        }
        collect_loads_by_hdl_fallback $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
        collect_source_load_fanouts $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
    }

    set moduleLoadList {}
    if { [catch { ::npi_L1::npi_nl_trace_load $query_signame moduleLoadList 1 0 } err] } {
        log_step "load_assign_trace_error passMod=0 signal=$query_signame error=$err"
        set moduleLoadList {}
    }
    foreach hdl $moduleLoadList {
        set sig [hdl_to_name $hdl]
        if { [is_module_boundary_signal $sig] } {
            append_unique_signal module_loads $sig
            append_unique_signal all_loads $sig
            set next_srcfile_hint [trace_source_hint_for_hdl $hdl $srcfile_hint]
            set next_scope_hint [signal_scope_hint_after $sig $scope_hint]
            collect_load_module_port_high_conns $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
            if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
                log_step "load_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
                collect_loads_by_name_rec $sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
            } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
                log_step "load_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
                collect_loads_by_name_rec $sig all_loads module_loads $net_depth [expr {$expr_depth - 1}] $visited_var $next_srcfile_hint $next_scope_hint
            }
            collect_loads_by_hdl_fallback $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
            collect_source_load_fanouts $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
        }
    }

    # npi_nl_trace_load can stop at assign-generated SigTap/Combo pins for
    # sliced fanout such as "assign B = A[10:0]". The connection API with
    # assignCell=0 passes through assign cells and, with isStopAtPin=1, returns
    # real module instance ports connected to the same network.
    set connLoadList {}
    if { [catch { ::npi_L1::npi_nl_sig_2_mod_inst_conn $query_signame connLoadList 0 1 } err] } {
        log_step "load_assign_conn_error signal=$query_signame error=$err"
        set connLoadList {}
    }
    foreach hdl $connLoadList {
        set sig [hdl_to_name $hdl]
        if { [is_module_boundary_signal $sig] } {
            append_unique_signal module_loads $sig
            append_unique_signal all_loads $sig
            set next_srcfile_hint [trace_source_hint_for_hdl $hdl $srcfile_hint]
            set next_scope_hint [signal_scope_hint_after $sig $scope_hint]
            collect_load_module_port_high_conns $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
            if { $net_depth > 0 && [should_expand_assign_endpoint $hdl $sig] } {
                log_step "load_assign_continue from=$signame via=$sig remaining_net_depth=$net_depth"
                collect_loads_by_name_rec $sig all_loads module_loads [expr {$net_depth - 1}] $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
            } elseif { $expr_depth > 0 && [should_expand_assign_expr_endpoint $hdl $sig] } {
                log_step "load_assign_expr_continue from=$signame via=$sig remaining_expr_depth=$expr_depth"
                collect_loads_by_name_rec $sig all_loads module_loads $net_depth [expr {$expr_depth - 1}] $visited_var $next_srcfile_hint $next_scope_hint
            }
            collect_loads_by_hdl_fallback $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
            collect_source_load_fanouts $hdl $sig all_loads module_loads $net_depth $expr_depth $visited_var $next_srcfile_hint $next_scope_hint
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
        if { ![regexp {^(.+)(\[[0-9]+(:[0-9]+)?\])$} $signame -> base existing_select _] } {
            return $signame
        }

        set mapped_bits {}
        foreach bit [select_selected_bits $select] {
            set mapped_bit [lhs_select_bit_from_rhs_offset $existing_select $bit]
            if { $mapped_bit eq "" } {
                debug_step "apply_signal_select_skip signame=$signame select=$select reason=outside_existing_select"
                return ""
            }
            lappend mapped_bits $mapped_bit
        }

        set mapped_select [bits_to_select_suffix $mapped_bits]
        if { $mapped_select eq "" } {
            debug_step "apply_signal_select_skip signame=$signame select=$select reason=non_contiguous_mapping"
            return ""
        }
        debug_step "apply_signal_select_combine signame=$signame select=$select mapped=${base}${mapped_select}"
        return "${base}${mapped_select}"
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

            set driver_scope_hint [signal_scope_prefix $signame]
            if { $driver_scope_hint eq "" } {
                if { $dir eq "output" } {
                    set driver_scope_hint $inst_path
                } elseif { $dir eq "input" && $parent_path ne "" } {
                    set driver_scope_hint $parent_path
                } elseif { $dir eq "input" } {
                    set driver_scope_hint $inst_path
                } elseif { [lsearch -exact $low_sigs $sig_hdl] >= 0 } {
                    set driver_scope_hint $inst_path
                } elseif { $parent_path ne "" } {
                    set driver_scope_hint $parent_path
                } else {
                    set driver_scope_hint $inst_path
                }
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
            set driver_combo_stop [source_assign_driver_combo_stop_expr $sig_hdl $signame $driver_srcfile_hint $driver_scope_hint]
            if { $driver_combo_stop ne "" } {
                append_unique_signal all_drivers $driver_combo_stop
                set driver_data_sources {}
            } else {
                set driver_data_sources [source_assign_driver_data_sources $sig_hdl $signame $driver_srcfile_hint $driver_scope_hint]
                if { [llength $driver_data_sources] > 0 } {
                    log_step "driver_data_source_restrict signal=$signame allowed=[join $driver_data_sources ,]"
                }
                collect_drivers_by_name $signame all_drivers module_drivers $driver_srcfile_hint $driver_scope_hint $driver_data_sources
            }
            if { $driver_combo_stop eq "" && [llength $all_drivers] == $driver_count_before } {
                set direct_sources {}
                if { $assign_trace_max_depth > 0 } {
                    foreach source_sig [source_assign_direct_driver_sources $sig_hdl $signame $driver_srcfile_hint $driver_scope_hint] {
                        if { ![trace_allowed_by_data_sources $source_sig $driver_data_sources] } {
                            debug_step "driver_data_source_skip signal=$signame candidate=$source_sig reason=not_data_branch"
                            continue
                        }
                        append_unique_signal direct_sources $source_sig
                        append_unique_signal all_drivers $source_sig
                        if { $module_outfh ne "" && [is_module_boundary_signal $source_sig] } {
                            append_unique_signal module_drivers $source_sig
                        }
                        if { ![is_const_literal_name $source_sig] } {
                            set next_scope_hint [signal_scope_hint_after $source_sig $driver_scope_hint]
                            collect_drivers_by_name $source_sig all_drivers module_drivers $driver_srcfile_hint $next_scope_hint
                        }
                    }
                }
                foreach source_sig [source_assign_driver_sources $sig_hdl $signame $driver_srcfile_hint $driver_scope_hint] {
                    if { ![trace_allowed_by_data_sources $source_sig $driver_data_sources] } {
                        debug_step "driver_data_source_skip signal=$signame candidate=$source_sig reason=not_data_branch"
                        continue
                    }
                    if { [lsearch -exact $direct_sources $source_sig] >= 0 } {
                        continue
                    }
                    append_unique_signal all_drivers $source_sig
                    if { $module_outfh ne "" && [is_module_boundary_signal $source_sig] } {
                        append_unique_signal module_drivers $source_sig
                    }
                    if { ![is_const_literal_name $source_sig] } {
                        set next_scope_hint [signal_scope_hint_after $source_sig $driver_scope_hint]
                        collect_drivers_by_name $source_sig all_drivers module_drivers $driver_srcfile_hint $next_scope_hint
                    }
                }
            }

            # If name-based tracing returns no endpoint, keep the old
            # handle-based fallback for the direct connection only.
            if { $driver_combo_stop eq "" && [llength $all_drivers] == $driver_count_before } {
                # Note: return value can be 1 (success) or 2 (success with some condition)
                set driverList {}
                catch { ::npi_L1::npi_nl_trace_driver_by_hdl $sig_hdl driverList 0 1 }
                foreach hdl $driverList {
                    set sig [hdl_to_name $hdl]
                    if { $sig ne "" } {
                        if { ![trace_allowed_by_data_sources $sig $driver_data_sources] } {
                            debug_step "driver_data_source_skip signal=$signame candidate=$sig reason=not_data_branch"
                            continue
                        }
                        append_unique_signal all_drivers $sig
                        set fallback_driver_visited {}
                        collect_driver_module_port_high_conns $hdl $sig all_drivers module_drivers $assign_trace_max_depth $assign_expr_trace_max_depth fallback_driver_visited $driver_srcfile_hint
                        if { [should_expand_assign_endpoint $hdl $sig] } {
                            log_step "driver_assign_continue from=$signame via=$sig remaining_depth=$assign_trace_max_depth"
                            set next_srcfile_hint [trace_source_hint_for_hdl $hdl $driver_srcfile_hint]
                            set next_scope_hint [signal_scope_hint_after $sig $driver_scope_hint]
                            collect_drivers_by_name $sig all_drivers module_drivers $next_srcfile_hint $next_scope_hint
                        } elseif { [should_expand_assign_expr_endpoint $hdl $sig] } {
                            log_step "driver_assign_expr_continue from=$signame via=$sig remaining_depth=$assign_expr_trace_max_depth"
                            set next_srcfile_hint [trace_source_hint_for_hdl $hdl $driver_srcfile_hint]
                            set next_scope_hint [signal_scope_hint_after $sig $driver_scope_hint]
                            collect_drivers_by_name $sig all_drivers module_drivers $next_srcfile_hint $next_scope_hint
                        }
                    }
                }
            }

            # If module-boundary name tracing also returns no endpoint, keep
            # the old handle-based fallback for the direct connection only.
            if { $module_outfh ne "" && !$const_driver_for_connection &&
                 $driver_combo_stop eq "" &&
                 [llength $module_drivers] == $module_driver_count_before } {
                set moduleDriverList {}
                catch { ::npi_L1::npi_nl_trace_driver_by_hdl $sig_hdl moduleDriverList 0 0 }
                foreach hdl $moduleDriverList {
                    set sig [hdl_to_name $hdl]
                    if { [is_module_boundary_signal $sig] } {
                        if { ![trace_allowed_by_data_sources $sig $driver_data_sources] } {
                            debug_step "driver_data_source_skip signal=$signame candidate=$sig reason=not_data_branch"
                            continue
                        }
                        append_unique_signal module_drivers $sig
                        append_unique_signal all_drivers $sig
                        set fallback_module_driver_visited {}
                        collect_driver_module_port_high_conns $hdl $sig all_drivers module_drivers $assign_trace_max_depth $assign_expr_trace_max_depth fallback_module_driver_visited $driver_srcfile_hint
                        if { [should_expand_assign_endpoint $hdl $sig] } {
                            log_step "driver_assign_continue from=$signame via=$sig remaining_depth=$assign_trace_max_depth"
                            set next_srcfile_hint [trace_source_hint_for_hdl $hdl $driver_srcfile_hint]
                            set next_scope_hint [signal_scope_hint_after $sig $driver_scope_hint]
                            collect_drivers_by_name $sig all_drivers module_drivers $next_srcfile_hint $next_scope_hint
                        } elseif { [should_expand_assign_expr_endpoint $hdl $sig] } {
                            log_step "driver_assign_expr_continue from=$signame via=$sig remaining_depth=$assign_expr_trace_max_depth"
                            set next_srcfile_hint [trace_source_hint_for_hdl $hdl $driver_srcfile_hint]
                            set next_scope_hint [signal_scope_hint_after $sig $driver_scope_hint]
                            collect_drivers_by_name $sig all_drivers module_drivers $next_srcfile_hint $next_scope_hint
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

            set load_scope_hint [signal_scope_prefix $signame]
            if { $load_scope_hint eq "" } {
                if { $dir eq "input" } {
                    set load_scope_hint $inst_path
                } elseif { $dir eq "output" && $parent_path ne "" } {
                    set load_scope_hint $parent_path
                } elseif { $dir eq "output" } {
                    set load_scope_hint $inst_path
                } elseif { [lsearch -exact $low_sigs $sig_hdl] >= 0 } {
                    set load_scope_hint $inst_path
                } elseif { $parent_path ne "" } {
                    set load_scope_hint $parent_path
                } else {
                    set load_scope_hint $inst_path
                }
            }

            set load_srcfile_hint [get_handle_source_file $sig_hdl]
            set load_hdl_visited {}
            collect_loads_by_hdl_fallback $sig_hdl $signame all_loads module_loads $assign_trace_max_depth $assign_expr_trace_max_depth load_hdl_visited $load_srcfile_hint $load_scope_hint
            collect_loads_by_name $signame all_loads module_loads $load_srcfile_hint $load_scope_hint

            # If string-based tracing returns no endpoint, keep the old
            # handle-based fallback for the direct connection only.
            if { [llength $all_loads] == 0 } {
                set loadList {}
                catch { ::npi_L1::npi_nl_trace_load_by_hdl $sig_hdl loadList }
                foreach hdl $loadList {
                    set sig [hdl_to_name $hdl]
                    append_unique_signal all_loads $sig
                    set fallback_load_visited {}
                    set next_load_srcfile_hint [trace_source_hint_for_hdl $hdl $load_srcfile_hint]
                    set next_load_scope_hint [signal_scope_hint_after $sig $load_scope_hint]
                    collect_load_module_port_high_conns $hdl $sig all_loads module_loads $assign_trace_max_depth $assign_expr_trace_max_depth fallback_load_visited $next_load_srcfile_hint $next_load_scope_hint
                    if { [should_expand_assign_endpoint $hdl $sig] } {
                        log_step "load_assign_continue from=$signame via=$sig remaining_depth=$assign_trace_max_depth"
                        collect_loads_by_name $sig all_loads module_loads $next_load_srcfile_hint $next_load_scope_hint
                    } elseif { [should_expand_assign_expr_endpoint $hdl $sig] } {
                        log_step "load_assign_expr_continue from=$signame via=$sig remaining_depth=$assign_expr_trace_max_depth"
                        collect_loads_by_name $sig all_loads module_loads $next_load_srcfile_hint $next_load_scope_hint
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
