module TFSubsystem #(parameter SID = 0) (
  input clk,
  input rst_n,
  input tie_parent
);
  wire [3:0] kw_vec;
  wire kw_concat;
  wire kw_plain;
  wire kw_assign;
  wire kw_module_src;
  wire [1:0] kw_rec_hi;
  wire [1:0] kw_rec_lo;
  wire [6:0] noise_b;
  wire [2:0] noise_d;
  wire noise_n;
  wire [10:0] drv_concat_bus;
  wire [3:0] rec_mid;
  wire [3:0] rec_deep;
  wire plain_l0;
  wire plain_l1;
  wire assign_chain_b;
  wire assign_chain_c;
  wire module_pass_l0;
  wire module_pass_l1;
  wire const_source_net;
  reg reg_q;
  wire [20:0] load_bus;
  wire load_plain;
  wire load_module_port;
  wire [20:0] load_sibling_bus;
  wire [31:0] load_leaf_bus;
  wire [10:0] load_slice_lo;
  wire [9:0] load_slice_hi;
  wire [7:0] load_concat;
  wire load_plain_l0;
  wire load_plain_l1;
  wire load_pass_mid;
  wire [20:0] sibling_mid;
  wire sibling_used;
  wire leaf_out;
  wire aux_in_l0;
  wire aux_in_l1;
  wire aux_out;
  wire sink_slice_lo_used;
  wire sink_slice_hi_used;
  wire sink_concat_used;
  wire sink_plain_used;
  wire sink_pass_used;
  wire sink_leaf_out_used;
  wire sink_aux_used;

  TFKeySrc #(.W(4), .VALUE(4'b1010)) u_kw_vec(.out(kw_vec));
  TFKeySrc #(.W(1), .VALUE(1'b1)) u_kw_concat(.out(kw_concat));
  TFKeySrc #(.W(1), .VALUE(1'b1)) u_kw_plain(.out(kw_plain));
  TFKeySrc #(.W(1), .VALUE(1'b1)) u_kw_module(.out(kw_module_src));
  TFKeySrc #(.W(2), .VALUE(2'b10)) u_kw_rec_hi(.out(kw_rec_hi));
  TFKeySrc #(.W(2), .VALUE(2'b01)) u_kw_rec_lo(.out(kw_rec_lo));
  TFParentKey #(.W(1), .VALUE(1'b1)) u_parent_key(.out(kw_assign));
  TFNoiseSrc u_noise(.b(noise_b), .d(noise_d), .n(noise_n));

  assign drv_concat_bus[10:0] = {noise_d[2:0], kw_concat, noise_b[6:0]};
  assign rec_mid = {kw_rec_hi, kw_rec_lo};
  assign rec_deep = {rec_mid[3:2], rec_mid[1:0]};
  assign plain_l0 = kw_plain;
  assign plain_l1 = plain_l0;
  assign assign_chain_c = kw_assign;
  assign assign_chain_b = assign_chain_c;

  TFPass #(.W(1)) u_driver_pass(.i(kw_module_src), .o(module_pass_l0));
  assign module_pass_l1 = module_pass_l0;
  assign const_source_net = 1'b0;

  initial begin
    reg_q = 1'b0;
  end
  always @(posedge clk) begin
    reg_q <= kw_plain;
  end

  TFTarget #(.ID(SID), .DW(16)) u_target (
    .clk(clk),
    .drv_concat_bus(drv_concat_bus),
    .drv_recursive(rec_deep),
    .drv_plain(plain_l1),
    .drv_assign_chain(assign_chain_b),
    .drv_module_port(module_pass_l1),
    .drv_const_direct(1'b0),
    .drv_const_parent(tie_parent),
    .drv_const_source(const_source_net),
    .drv_noise(noise_n),
    .drv_reg_endpoint(reg_q),
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
  TFKeySink #(.W(11)) u_sink_slice_lo(.in(load_slice_lo), .used(sink_slice_lo_used));
  TFKeySink #(.W(10)) u_sink_slice_hi(.in(load_slice_hi), .used(sink_slice_hi_used));
  TFKeySink #(.W(8)) u_sink_concat(.in(load_concat), .used(sink_concat_used));
  TFUnknownDirProbe u_unknown_dir_probe(.a(load_bus));

  assign load_plain_l0 = load_plain;
  assign load_plain_l1 = load_plain_l0;
  TFKeySink #(.W(1)) u_sink_plain(.in(load_plain_l1), .used(sink_plain_used));

  TFPass #(.W(1)) u_load_pass(.i(load_module_port), .o(load_pass_mid));
  TFKeySink #(.W(1)) u_sink_pass(.in(load_pass_mid), .used(sink_pass_used));

  TFSiblingParent0 #(.PID(SID)) u_sib_p0(.in(load_sibling_bus), .out(sibling_mid));
  TFSiblingParent1 #(.PID(SID)) u_sib_p1(.c(sibling_mid), .used(sibling_used));

  TFLeaf #(.LEAF_ID(SID), .BASE(16)) u_leaf(.leaf_in(load_leaf_bus), .leaf_out(leaf_out));
  TFKeySink #(.W(1)) u_sink_leaf_out(.in(leaf_out), .used(sink_leaf_out_used));

  assign aux_in_l0 = kw_plain;
  assign aux_in_l1 = aux_in_l0;
  TFAuxTarget #(.MODE(SID + 20)) u_aux(.aux_in(aux_in_l1), .aux_out(aux_out));
  TFKeySink #(.W(1)) u_sink_aux(.in(aux_out), .used(sink_aux_used));
endmodule
