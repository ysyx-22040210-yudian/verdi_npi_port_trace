module FMFeatureSubsystem #(parameter SID = 0) (
  input clk,
  input rst_n,
  input tie_parent,
  input [15:0] deep_e_from_top
);
  wire [10:0] drv_precise_bus;
  wire [6:0] precise_b;
  wire precise_c;
  wire [2:0] precise_d;
  wire [3:0] precise_c_vec;
  wire [3:0] rec_mid;
  wire [3:0] rec_deep;
  wire [1:0] kw_rec_hi;
  wire [1:0] kw_rec_lo;
  wire plain_l0;
  wire plain_l1;
  wire kw_plain;
  wire assign_chain_b;
  wire assign_chain_c;
  wire kw_assign;
  wire module_kw_src;
  wire module_pass_l0;
  wire module_pass_l1;
  wire const_source_net;
  wire noise_n;
  wire [6:0] noise_b_unused;
  wire [2:0] noise_d_unused;
  wire [7:0] reg_q;
  wire [15:0] deep_alias0;
  wire [15:0] deep_alias1;
  wire [15:0] local_deep_e;
  wire [3:0] cross_b;
  wire [3:0] cross_c;
  wire [3:0] cross_d;
  wire [3:0] cross_x;
  wire cross_c_alias;

  wire [20:0] load_bus;
  wire load_plain;
  wire load_module_port;
  wire [20:0] load_sibling_bus;
  wire [15:0] load_leaf_bus;
  wire [10:0] load_slice_lo;
  wire [9:0] load_slice_hi;
  wire [7:0] load_concat;
  wire load_plain_l0;
  wire load_plain_l1;
  wire load_pass_mid;
  wire [20:0] sibling_mid;
  wire sibling_used;
  wire leaf_load_out;
  wire leaf_direct_out;
  wire [15:0] leaf_direct_bus;
  wire aux_in_l0;
  wire aux_in_l1;
  wire aux_out;
  wire sink_slice_lo_used;
  wire sink_slice_hi_used;
  wire sink_concat_used;
  wire sink_plain_used;
  wire sink_pass_used;
  wire sink_leaf_out_used;
  wire sink_leaf_direct_out_used;
  wire sink_aux_used;

  assign precise_b = 7'b0101010;
  assign precise_d = 3'b101;
  FMKeySrc #(.W(4), .VALUE(4'h9)) u_key_precise(.out(precise_c_vec));
  assign precise_c = precise_c_vec[0];
  assign drv_precise_bus[10:0] = {precise_d[2:0], precise_c, precise_b[6:0]};

  FMKeySrc #(.W(2), .VALUE(2'b10)) u_kw_rec_hi(.out(kw_rec_hi));
  FMKeySrc #(.W(2), .VALUE(2'b01)) u_kw_rec_lo(.out(kw_rec_lo));
  assign rec_mid = {kw_rec_hi, kw_rec_lo};
  assign rec_deep = {rec_mid[3:2], rec_mid[1:0]};

  FMKeySrc #(.W(1), .VALUE(1'b1)) u_kw_plain(.out(kw_plain));
  assign plain_l0 = kw_plain;
  assign plain_l1 = plain_l0;

  FMNestedKey #(.W(1), .VALUE(1'b1)) u_parent_key(.out(kw_assign));
  assign assign_chain_c = kw_assign;
  assign assign_chain_b = assign_chain_c;

  FMKeySrc #(.W(1), .VALUE(1'b1)) u_kw_module(.out(module_kw_src));
  FMPass #(.W(1)) u_driver_pass(.i(module_kw_src), .o(module_pass_l0));
  assign module_pass_l1 = module_pass_l0;

  assign const_source_net = 1'b0;
  FMNoiseSrc u_noise(.b(noise_b_unused), .d(noise_d_unused), .n(noise_n));
  FMRegSource #(.W(8)) u_reg_source(.clk(clk), .out(reg_q));

  FMDeepConcatProvider u_local_deep_provider(
    .deep_e(local_deep_e)
  );
  assign deep_alias0 = local_deep_e;
  assign deep_alias1[3:0] = deep_alias0[3:0];
  assign deep_alias1[7:4] = deep_alias0[7:4];
  assign deep_alias1[11:8] = deep_alias0[11:8];
  assign deep_alias1[15:12] = deep_alias0[15:12];
  assign {cross_b, cross_c, cross_d, cross_x} = deep_alias1;
  assign cross_c_alias = cross_c[2];

  FMTargetShell1 #(.ID(SID), .DW(16), .TAG(SID + 100)) u_shell1(
    .clk(clk),
    .drv_precise_bus(drv_precise_bus[10:0]),
    .drv_recursive(rec_deep[3:0]),
    .drv_plain(plain_l1),
    .drv_assign_chain(assign_chain_b),
    .drv_cross_concat(cross_c_alias),
    .drv_module_port(module_pass_l1),
    .drv_const_direct(1'b0),
    .drv_const_parent(tie_parent),
    .drv_const_source(const_source_net),
    .drv_noise(noise_n),
    .drv_reg_endpoint(reg_q[7:0]),
    .drv_float(),
    .load_bus(load_bus),
    .load_plain(load_plain),
    .load_module_port(load_module_port),
    .load_sibling_bus(load_sibling_bus),
    .load_leaf_bus(load_leaf_bus),
    .load_unconnected()
  );

  assign load_slice_lo = load_bus[10:0];
  assign load_slice_hi = load_bus[20:11];
  assign load_concat = {load_bus[3:0], load_bus[20:17]};
  FMKeySink #(.W(11)) u_sink_slice_lo(.in(load_slice_lo), .used(sink_slice_lo_used));
  FMKeySink #(.W(10)) u_sink_slice_hi(.in(load_slice_hi), .used(sink_slice_hi_used));
  FMKeySink #(.W(8)) u_sink_concat(.in(load_concat), .used(sink_concat_used));
  FMUnknownDirProbe u_unknown_dir_probe(.a(load_bus));

  assign load_plain_l0 = load_plain;
  assign load_plain_l1 = load_plain_l0;
  FMKeySink #(.W(1)) u_sink_plain(.in(load_plain_l1), .used(sink_plain_used));

  FMPass #(.W(1)) u_load_pass(.i(load_module_port), .o(load_pass_mid));
  FMKeySink #(.W(1)) u_sink_pass(.in(load_pass_mid), .used(sink_pass_used));

  FMSiblingParent0 #(.PID(SID)) u_sib_p0(.in(load_sibling_bus), .out(sibling_mid));
  FMSiblingParent1 #(.PID(SID)) u_sib_p1(.c(sibling_mid), .used(sibling_used));

  FMLeaf #(.LEAF_ID(SID), .BASE(8)) u_leaf_load(.leaf_in(load_leaf_bus), .leaf_out(leaf_load_out));
  FMKeySink #(.W(1)) u_sink_leaf_out(.in(leaf_load_out), .used(sink_leaf_out_used));

  FMKeySrc #(.W(16), .VALUE(16'h5a5a)) u_kw_leaf_direct(.out(leaf_direct_bus));
  FMLeaf #(.LEAF_ID(SID + 10), .BASE(8)) u_leaf_direct(.leaf_in(leaf_direct_bus), .leaf_out(leaf_direct_out));
  FMKeySink #(.W(1)) u_sink_leaf_direct_out(.in(leaf_direct_out), .used(sink_leaf_direct_out_used));

  assign aux_in_l0 = kw_plain;
  assign aux_in_l1 = aux_in_l0;
  FMAuxTarget #(.MODE(SID + 20)) u_aux(
    .aux_in(aux_in_l1),
    .aux_float(),
    .aux_out(aux_out),
    .aux_unused_out()
  );
  FMKeySink #(.W(1)) u_sink_aux(.in(aux_out), .used(sink_aux_used));
endmodule
