import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent


class TclSupportTests(unittest.TestCase):
    def run_tcl(self, body):
        # Load definitions only: these tests do not import Verdi or a design.
        script = '''
source {%s}
source {%s}
set fh [open {%s} r]
set collecting 0
set definition ""
while {[gets $fh line] >= 0} {
    if {!$collecting && [string match {proc *} $line]} {set collecting 1}
    if {$collecting} {
        append definition $line "\\n"
        if {[info complete $definition]} {
            eval $definition
            set definition ""
            set collecting 0
        }
    }
}
close $fh
proc check {expression message} {
    if {![uplevel 1 [list expr $expression]]} {error $message}
}
''' % ((ROOT / 'trace_support.tcl').as_posix(), (ROOT / 'npi_elaborated.tcl').as_posix(), (ROOT / 'npi_port_trace.tcl').as_posix())
        script += body
        tclsh = shutil.which('tclsh')
        if tclsh:
            proc = subprocess.run([tclsh], input='if {[catch {\n' + script + '\n} message]} {puts stderr $message; exit 1}\n', text=True, capture_output=True, timeout=30)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        else:
            import tkinter
            tkinter.Tcl().eval(script)

    def test_decimal_selects_and_parameter_ranges(self):
        self.run_tcl('''
check {[decimal_index_token 0008] eq "8"} decimal_8
check {[decimal_index_token -0009] eq "-9"} decimal_negative
check {[decimal_index_token 00018446744073709551617] eq "18446744073709551617"} big_integer
check {[normalize_signal_name {Top.gen[08].p[09]}] eq {Top.gen[8].p[9]}} canonical_name
check {[split_port_filter_spec {p[08:09]}] eq {p {[8:9]}} canonical_request
check {[resolve_parameterized_index_expr {W-08} {W 16}] eq "8"} symbolic_range
check {[resolve_parameterized_index_expr {$bad+1} {}] eq ""} reject_substitution
check {[resolve_parameterized_index_expr {UNKNOWN+1} {}] eq ""} reject_unknown
''')

    def test_port_directions_are_independent_of_line_layout(self):
        self.run_tcl('''
set map [parse_port_directions_text {module Wrap #(parameter W=$clog2(256))(input [W-1:0] a, b, output [7:0] y, inout pad); Child u(.a(a),.b(b),.y(y)); endmodule}]
check {$map eq {a input b input y output pad inout}} ansi_same_line
set map [parse_port_directions_text {module Wrap(a,b,y); input [7:0] a,b; output y; assign y=^a; endmodule}]
check {$map eq {a input b input y output}} nonansi_same_line
''')

    def test_csv_diagnostics_keep_commas_and_quotes(self):
        self.run_tcl('''
check {[trace_csv_cell {ERROR:CONST_DRIVER_CONFLICT:0,1}] eq {"ERROR:CONST_DRIVER_CONFLICT:0,1"}} comma
check {[trace_csv_cell {a"b}] eq {"a""b"}} quote
check {[trace_csv_cell {Top.u.p[7]}] eq {Top.u.p[7]}} simple
''')

    def test_named_connection_index_nested_and_large(self):
        self.run_tcl('''
set text {.a({x[3:0],f(y)}), .b(1'b0), .empty()}
check {[inst_conn_expr_for_port $text a] eq {{x[3:0],f(y)}}} nested
check {[inst_conn_expr_for_port $text b] eq {1'b0}} literal
check {[inst_conn_expr_for_port $text absent] eq {}} absent
set text ""
for {set i 0} {$i < 8192} {incr i} {append text ".port${i}(bus),"}
set map [parse_named_connection_map $text]
check {[dict size $map] == 8192} large_count
check {[dict get $map port8191] eq {bus}} large_last
''')

    def test_direction_uses_structural_and_netlist_apis(self):
        self.run_tcl('''
proc npi_get_str {args} {
    if {[lindex $args end] eq "structural"} {return npiInput}
    error wrong_domain
}
proc npi_nl_get_str {args} {return npiOutput}
check {[get_port_direction structural] eq "input"} structural_direction
check {[get_port_direction netlist] eq "output"} netlist_direction
check {[get_port_direction ""] eq "unknown"} absent_handle
''')

    def test_nested_expression_boundaries_ignore_lexical_punctuation(self):
        self.run_tcl(r'''
foreach expression {{(sel ? a : b) & ~hold} {~(sel ? a : b)} {{data, (sel ? a : b)}} {func(sel ? a : b)}} {
    check {[rhs_has_ternary_expr $expression]} "nested mux: $expression"
    check {[rhs_is_computed_connection $expression]} "computed mux: $expression"
}
foreach expression {{1'b?} {8'h?f} {"what?"} {\escaped?name } {a /* ? */} {a // ?}} {
    check {![rhs_has_ternary_expr $expression]} "not a mux: $expression"
}
foreach expression {{a & 1'b1} {a | hold} {~hold} {a + b} {func(a)} {logic'(a)} {bus[index +: 4]}} {
    check {[rhs_is_computed_connection $expression]} "computed connection: $expression"
}
foreach expression {{a} {(a)} {{3'b101, bus[7:0]}} {bus[31:16]} {1'b0} {'1} {\escaped+name }} {
    check {![rhs_is_computed_connection $expression]} "transparent connection: $expression"
}
''')

    def test_stop_index_matches_reference_semantics(self):
        self.run_tcl('''
set stops {Top.left.key Top.left.wrap Top.tile[8].key Top.right.key}
set index [build_stop_instance_index $stops]
foreach current {{} Top.left.key Top.left.wrap} {
    foreach signal {Top.left.key Top.left.key.out Top.left.key.Src/Always0:1/RegCombo.q Top.left.key._ExprInst__:1 Top.left.key.child.Mod.p Top.left.wrap.child.p Top.tile[8].key.out Top.tile[9].key.out Other.left.key.out} {
        set expected 0
        foreach stop $stops {
            if {$stop ne $current && [is_direct_instance_node [strip_instance_prefix $signal $stop]]} {set expected 1}
        }
        check {[indexed_stop_instance_match $signal $index $current] == $expected} "index mismatch: $signal"
    }
}
set stops {}
for {set i 0} {$i < 50000} {incr i} {lappend stops "Top.tile${i}.key"}
set index [build_stop_instance_index $stops]
check {[dict size $index] == 50000} stop_count
for {set i 0} {$i < 1000} {incr i} {
    check {[indexed_stop_instance_match Top.tile49999.key.out $index]} large_stop_hit
    check {![indexed_stop_instance_match Top.decoy.key.out $index]} large_stop_miss
}
''')

    def test_source_index_preserves_all_references(self):
        self.run_tcl('''
rename build_instantiation_stmt_list_for_module saved_instantiation_list
proc build_instantiation_stmt_list_for_module {src module} {
    return {{Pass u0 {.i(bus[7:0]), .o(alias)}} {Pass u1 {.i({bus[0],other}), .o(y)}} {Pass u2 {.i(bus_decoy), .o(z)}}}
}
check {[llength [source_instance_candidates fake Top bus]] == 2} references
check {[llength [source_instance_candidates fake Top bus_decoy]] == 1} exact_token
check {[llength [source_instance_candidates fake Top absent]] == 0} absent
''')

    def test_selected_load_does_not_widen_after_exact_source_mapping(self):
        self.run_tcl(r'''
proc load_trace_limited {} {return 0}
proc load_trace_stop_at_endpoint {args} {return 0}
proc scoped_signal_for_query {name scope} {return $name}
proc load_trace_node_seen_or_mark {args} {return 0}
proc load_trace_budget_mark_node {args} {return 1}
proc debug_step {args} {}
proc collect_load_module_port_high_conns {args} {}
proc collect_source_load_fanouts {args} {}
proc load_trace_should_run_hdl_fallback {args} {return 0}
namespace eval ::npi_L1 {}
proc ::npi_L1::npi_nl_trace_load {args} {error BROAD_API_MUST_NOT_RUN}
proc ::npi_L1::npi_nl_sig_handle_by_name {args} {return exact}
proc ::npi_L1::npi_nl_bit_trace_load_by_hdl {hdl result_var} {upvar 1 $result_var result; set result {{exact {}}}; return 0}
proc hdl_to_name {args} {return {Top.bus[18]}}
proc get_handle_size {args} {return 1}
proc load_trace_limited_list {values args} {return $values}
proc log_step {message} {error $message}
set loads {}; set modules {}; set visited {}
collect_loads_by_name_rec {Top.bus[18]} loads modules 12 4 visited rtl.v Top
check {$loads eq {}} unused_bit_has_no_sinks
''')

    def test_multidim_netlist_identity_is_not_a_flat_rtl_subscript(self):
        self.run_tcl(r'''
namespace eval ::npi_L1 {}
proc npi_nl_get {args} {return $::size}
proc ::npi_L1::npi_nl_ut_get_actual_name_vec {hdl result full} {
    upvar 1 $result names; set names $::names
}
proc npi_handle_by_name {args} {return structural}
proc elab_property {args} {return 1}
set size 1
set names {{Top.a[0][1]}}
check {[elab_nl_multidim_bit_name bit {Top.a[1:0]#[2]}] eq {Top.a[0][1]}} correct_rtl_identity
set size 4
check {[elab_nl_multidim_bit_name bit {Top.a[1:0]#[2]}] eq {}} reject_wide_handle
set size 1
set names {{Top.a[0][1]} {Top.b[0][1]}}
check {[elab_nl_multidim_bit_name bit {Top.a[1:0]#[2]}] eq {}} reject_multi_name
set names {{WrongTop.a[0][1]}}
check {[elab_nl_multidim_bit_name bit {Top.a[1:0]#[2]}] eq {}} reject_rebased_owner
set names {{Top.a[0][1]}}
check {[elab_nl_multidim_bit_name bit {Top.a[1:0],b[0]#[2]}] eq {}} preserve_opaque_concat
set names {{Top.a[0]}}
check {[elab_nl_multidim_bit_name bit {Top.a[1:0]#[0]}] eq {}} keep_ordinary_vectors
''')

    def test_multidim_exact_handle_fallback_uses_native_index_orientation(self):
        self.run_tcl(r'''
namespace eval ::npi_L1 {}
proc ::npi_L1::npi_nl_sig_handle_by_name {name} {return wrong}
proc hdl_to_name {hdl} {
    switch $hdl {wrong {return {Top.a[0][0]}} net {return {Top.a[1:0]}} bit {return $::bit_name}}
}
proc get_handle_size {hdl} {return [expr {$hdl eq "net" ? 4 : 1}]}
proc npi_handle_by_name {args} {return structural}
proc elab_property {args} {return 4}
proc elab_ranges {args} {return {{1 0} {1 0}}}
proc elab_relation {args} {return ""}
proc npi_nl_handle_by_name {args} {return net}
proc ::npi_L1::npi_nl_L1_handle_by_name {args} {return net}
proc npi_nl_get {args} {
    return [expr {[lindex $args 1] eq "npiNlLeft" ? $::left : $::right}]
}
proc npi_nl_handle_by_index {args} {set ::index [lindex $args 3]; return bit}
proc log_step {args} {}
set left 0; set right 3; set bit_name {Top.a[0][1]}
check {[elab_exact_bit_handle {Top.a[0][1]}] eq "bit"} fallback_resolves
check {$index == 2} msb_first_native_index
set left 3; set right 0
check {[elab_exact_bit_handle {Top.a[0][1]}] eq "bit"} reverse_native_resolves
check {$index == 1} lsb_first_native_index
set bit_name {Top.a[1][0]}
check {[catch {elab_exact_bit_handle {Top.a[0][1]}}]} reject_wrong_actual_bit
check {[catch {elab_exact_bit_handle {Top.a[0]}}]} reject_partial_subvector_handle
set left 7; set right 0
check {[catch {elab_exact_bit_handle {Top.a[0][1]}}]} reject_range_width_mismatch
''')

    def test_unpacked_size_counts_elements_not_bits(self):
        self.run_tcl(r'''
proc elab_property {hdl property args} {
    if {$property eq "npiType"} {
        switch $hdl {port {return npiPort} array_type {return npiArrayTypespec} default {return npiLogicTypespec}}
    }
    if {$property eq "npiSize"} {return [expr {$hdl eq "array" ? 2 : 6}]}
}
proc elab_relation {hdl relation} {
    switch -- $relation {
        npiLowConn {return array}
        npiTypespec {return [expr {$hdl eq "array" ? "array_type" : "packed_type"}]}
        npiLeftRange {return [dict get {outer -1 packed0 1 packed1 0} $hdl]}
        npiRightRange {return [dict get {outer -2 packed0 0 packed1 2} $hdl]}
    }
}
proc elab_children {hdl relation} {return [expr {$hdl eq "array_type" ? {outer} : {packed0 packed1}}]}
proc elab_integer {hdl} {return $hdl}
proc npi_handle_by_index {args} {return element}
check {[elab_ranges array] eq {{-1 -2} {1 0} {0 2}}} all_declaration_dimensions
check {[elab_bit_width array] == 12} unpacked_element_width
check {[elab_bit_width port] == 12} formal_uses_low_connection_shape
check {[elab_offsets [elab_bit_width port] [elab_ranges port] {[-2][0][2]}] eq {0}} array_lsb
check {[elab_offsets [elab_bit_width port] [elab_ranges port] {[-1][1][0]}] eq {11}} array_msb
''')

    def test_exact_load_response_must_cover_queried_bit(self):
        self.run_tcl(r'''
namespace eval ::npi_L1 {}
proc get_handle_size {hdl} {return [expr {$hdl eq "wide" ? 8 : 1}]}
proc hdl_to_name {hdl} {return [expr {$hdl eq "other" ? {Top.a[0][0]} : {Top.a[0][1]}}]}
proc ::npi_L1::npi_nl_bit_trace_load_by_hdl {hdl output} {upvar 1 $output rows; set rows $::reply; return $::count}
set count 0
set reply {{exact {}}}
check {[elab_exact_load_rows exact {Top.a[0][1]}] eq $reply} confirmed_no_load
set reply {exact}
check {[elab_exact_load_rows exact {Top.a[0][1]}] eq {{exact {}}}} omitted_empty_load_list
set reply {}
check {[catch {elab_exact_load_rows exact {Top.a[0][1]}}]} missing_source_is_not_no_load
set count 1
foreach bad {{} {{other {sink}}} {{wide {sink}}} {{exact {sink}} {other {sink}}}} {
    set reply $bad
    check {[catch {elab_exact_load_rows exact {Top.a[0][1]}}]} invalid_source_coverage
}
set count -1; set reply {}
check {[catch {elab_exact_load_rows exact {Top.a[0][1]}}]} negative_api_return
''')

    def test_multidim_fill_literal_uses_native_port_declaration_name(self):
        self.run_tcl(r'''
namespace eval ::npi_L1 {}
proc elab_relation {args} {return low}
proc elab_ranges {args} {return {{1 0} {3 0}}}
proc elab_bit_width {args} {return 8}
proc get_handle_size {args} {return 8}
proc hdl_to_name {args} {return {Top.u.a[1:0]}}
proc ::npi_L1::npi_nl_L1_handle_by_name {name} {return declaration}
proc npi_nl_get_str {args} {
    if {[lindex $args 1] eq "npiNlName"} {return {a[1:0]}}
    return {Top.'1}
}
proc ::npi_L1::npi_nl_instport_handle_by_nl_name {scope child port} {
    if {$scope eq "Top" && $child eq "u" && $port eq {a[1:0]}} {return instport}
    return ""
}
proc ::npi_L1::npi_nl_port_instport_2_net {args} {return constant}
check {[elab_high_literal_spelling port Top.u a] eq {'1}} native_packed_port_literal
''')

    def test_elaborated_shapes_and_literal_projection(self):
        self.run_tcl(r'''
check {[elab_offsets 4 {{1 0} {1 0}} {[0][1]}] eq {1}} packed
check {[elab_offsets 4 {{-1 -4}} {[-4]}] eq {0}} negative_lsb
check {[elab_offsets 4 {{-1 -4}} {[-1]}] eq {3}} negative_msb
check {[elab_offsets 8 {{0 7}} {[0]}] eq {7}} ascending
check {[catch {elab_offsets 8 {{7 0}} {[8]}}]} out_of_range
check {[split_port_filter_spec {a[-4]}] eq {a {[-4]}}} signed_port_select
check {[split_port_filter_spec {a[0][1]}] eq {a {[0][1]}}} packed_port_select
check {[project_const_literal_to_bit {Const:8'd08} 3] eq {Const:1'b1}} decimal_08
check {[project_const_literal_to_bit {Const:8'd09} 0] eq {Const:1'b1}} decimal_09
check {[project_const_literal_to_bit {Const:2'sb10} 7] eq {Const:1'b1}} sign_extend
check {[project_const_literal_to_bit {Const:2'b10} 7] eq {Const:1'b0}} zero_extend
check {[expr_item_source_signal_for_bit {{1'b1,1'b0}} 0 Top {} {}] eq {}} no_whole_literal_on_failure
foreach name {Top.u_InitMonitor.out Top.u_ComboLogic.out Top.AlwaysController.q} {
    check {[is_module_boundary_signal $name]} legitimate_identifier
    check {![is_generated_logic_signal $name]} not_generated
    check {[should_expand_assign_endpoint {} $name]} legitimate_assign_path
}
check {![is_direct_instance_node child.out]} not_parent_owned
''')

    def test_module_crossing_is_iterative_and_independent_of_assign_depth(self):
        self.run_tcl(r'''
proc signal_belongs_to_stop_instance {args} {return 0}
proc get_inst_port_handle_by_signal {scope base} {return $base}
proc get_port_direction {args} {return input}
proc elab_port_starts {hdl inst port select side} {
    regexp {\.i([0-9]+)$} $inst -> i
    if {$i == 1500} {return {Const:1'b1}}
    return [list "Top.i[expr {$i+1}].p"]
}
set all {}; set modules {}; set visited {}
elab_collect_driver Top.i0.p all modules 0 visited
check {$all eq {Const:1'b1}} preserved_constant
check {[dict size $visited] == 1501} full_hierarchy_walk
''')

    def test_union_columns_cannot_hide_unresolved_shapes(self):
        self.run_tcl(r'''
check {[catch {elab_offsets 8 {{7 0}} {[8]}} message options]} range_error
check {[dict get $options -errorcode] eq {NPI_QUERY OUT_OF_RANGE}} proven_range_mismatch
check {[catch {elab_offsets 1 {} {[7]}} message options]} scalar_range_error
check {[dict get $options -errorcode] eq {NPI_QUERY OUT_OF_RANGE}} proven_scalar_mismatch
check {[elab_offsets 1 {} {[0:0]}] eq {0}} scalar_zero_range
check {[catch {elab_offsets 8 {} {[7]}} message options]} unknown_shape
check {[dict get $options -errorcode] ne {NPI_QUERY OUT_OF_RANGE}} unknown_shape_is_fatal
check {[catch {elab_offsets {} {} {[7]}} message options]} unknown_width
check {[dict get $options -errorcode] ne {NPI_QUERY OUT_OF_RANGE}} unknown_width_is_fatal
check {[string first {[dict get $query_options -errorcode] eq {NPI_QUERY OUT_OF_RANGE}} [info body process_instance]] >= 0} union_is_guarded
''')

    def test_ambiguous_fill_literal_fails_closed(self):
        self.run_tcl(r'''
proc elab_relation {hdl relation} {return $relation}
proc elab_ranges {hdl} {return {{7 0}}}
proc elab_property {hdl property args} {
    if {$property eq "npiSize"} {return [expr {$hdl eq "port" ? 8 : 1}]}
    if {$property eq "npiType"} {return npiConstant}
    if {$property eq "npiSigned"} {return 0}
    if {$property eq "npiFile"} {return rtl.sv}
    return ""
}
proc elab_high_literal_spelling {args} {return ""}
check {[catch {elab_port_starts port Top.u a {[7]} npiHighConn} message]} ambiguity_rejected
check {[string match {cannot distinguish*} $message]} explicit_diagnostic
proc log_const_source_detail {args} {}
proc elab_high_literal_spelling {args} {return '1}
check {[elab_port_starts port Top.u a {[7]} npiHighConn] eq {Const:1'b1}} fill_one
proc elab_high_literal_spelling {args} {return 1'b1}
check {[elab_port_starts port Top.u a {[7]} npiHighConn] eq {Const:1'b0}} sized_one
''')

    def test_unnamed_part_select_uses_parent_and_ranges(self):
        self.run_tcl(r'''
proc elab_property {hdl property args} {
    if {$property eq "npiType"} {return [expr {$hdl eq "slice" ? "npiPartSelect" : "npiNet"}]}
    if {$property eq "npiSize"} {return [expr {$hdl eq "slice" ? 4 : 16}]}
    if {$property eq "npiFullName" && $hdl eq "net"} {return Top.bus}
    return ""
}
proc elab_relation {hdl relation} {
    if {$relation eq "npiParent"} {return net}
    if {$relation eq "npiLeftRange"} {return 11}
    if {$relation eq "npiRightRange"} {return 8}
    return ""
}
proc elab_ranges {hdl} {return {{15 0}}}
proc elab_integer {hdl} {return $hdl}
check {[elab_expression_bit slice 0 query] eq {Top.bus[8]}} slice_lsb
check {[elab_expression_bit slice 3 query] eq {Top.bus[11]}} slice_msb
check {[elab_expression_bit slice 4 query] eq {Const:1'b0}} slice_zero_extension
''')

    def test_exact_assign_loader_rejects_widened_opposite_net(self):
        self.run_tcl(r'''
namespace eval ::npi_L1 {}
proc ::npi_L1::npi_nl_pass_assign_cell {hdl} {return [expr {$hdl eq "combo" ? 0 : "pass"}]}
proc ::npi_L1::npi_nl_port_instport_2_net {hdl} {return net}
proc get_handle_size {hdl} {return 1}
check {[elab_exact_assign_load_net combo] eq ""} computation_stops
check {[elab_exact_assign_load_net input] eq "net"} exact_bit_passes
proc get_handle_size {hdl} {return [expr {$hdl eq "net" ? 8 : 1}]}
check {[catch {elab_exact_assign_load_net input} message]} widened_net_rejected
check {[string match {assign load mapping*} $message]} explicit_width_error
''')

    def test_lhs_concat_load_preserves_opaque_handle_until_named_sink(self):
        self.run_tcl(r'''
namespace eval ::npi_L1 {}
proc hdl_to_name {hdl} {return [expr {$hdl eq "opaque" ? {Top.hi[3:0],lo[0]} : {Top.sink.in[3]}}]}
proc ::npi_L1::npi_nl_bit_trace_load_by_hdl {hdl result_var} {
    upvar 1 $result_var result
    check {$hdl eq "opaque"} exact_handle_is_retained
    set result {{opaque {sink}}}
}
proc load_trace_limited_list {values args} {return $values}
proc signal_belongs_to_stop_instance {args} {return 1}
set visited {}
check {[elab_named_load_handles opaque 12 visited] eq {sink}} named_sink_resolved
check {[elab_named_load_handles opaque 12 visited] eq {}} revisit_stops
''')

    def test_parent_constant_chain_requires_one_exact_noncomputed_mapping(self):
        self.run_tcl(r'''
proc get_inst_port_handle_by_signal {args} {return handle}
proc get_port_name {args} {return p}
proc get_handle_source_file {args} {return rtl.v}
proc log_step {args} {}
proc qualify_signal_for_log {signal args} {return $signal}
proc module_port_high_conn_pairs {args} {return {{{} Const:1'b0} {{} Top.other}}}
check {[const_driver_from_parent_ports handle Top.wrap.p Top.wrap 4] eq {}} constituent_not_constant
proc module_port_high_conn_pairs {args} {return {{{} COMBO_EXPR:port_connection}}}
check {[const_driver_from_parent_ports handle Top.wrap.p Top.wrap 4] eq {}} computation_not_constant
''')

    def test_concat_connection_maps_every_repeated_bit_without_widening(self):
        self.run_tcl(r'''
set widths {bus 16 asc 16}
set ranges {bus {[15:0]} asc {[0:15]}}
check {[connection_port_selects {{bus[0],bus[7],bus[8],bus[15]}} bus 7 $widths $ranges p {p 4} {p {[3:0]}}] eq {{[2]}}} concat_bit7
check {[connection_port_selects {{bus[7],{bus[8],bus[7]},bus[0]}} bus 7 $widths $ranges p {p 4} {p {[3:0]}}] eq {{[1]} {[3]}}} repeated_nested
check {[connection_port_selects {{bus[0],bus[7],bus[8],bus[15]}} bus 6 $widths $ranges p {p 4} {p {[3:0]}}] eq {}} unused_bit
check {[connection_port_selects {asc} asc 0 $widths $ranges p {p 16} {p {[31:16]}}] eq {{[31]}}} ascending_offset
check {[connection_port_selects {bus & 16'hff} bus 7 $widths $ranges p {p 16} {p {[15:0]}}] eq {}} logic_boundary
''')

    def test_node_budget_counts_stopped_endpoints_only_once(self):
        self.run_tcl(r'''
proc log_step {args} {}
proc debug_step {args} {}
proc load_trace_edge_key {a b args} {return "$a->$b"}
set load_trace_node_limit 2; set load_trace_edge_limit 100
reset_load_trace_budget
check {[load_trace_budget_mark_node Top.root]} root
check {[load_trace_budget_mark_node Top.root]} duplicate_root
check {[load_trace_budget_mark_edge Top.root Top.key.in source] == 1} first_endpoint
check {$load_trace_node_count == 2} unique_nodes
check {[load_trace_budget_mark_edge Top.root Top.key2.in source] == 0} stopped_endpoint_is_budgeted
check {[load_trace_limit_marker] eq {TRACE_LIMIT_REACHED:node_limit_2}} diagnostic
''')


if __name__ == '__main__':
    unittest.main()
