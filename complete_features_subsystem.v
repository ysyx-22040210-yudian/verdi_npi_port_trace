module CFLoaderBridge #(parameter BID = 0) (
  input [31:0] in_bus
);
  wire [31:0] stage0;
  wire [31:0] stage1;

  assign stage0 = in_bus;
  assign stage1 = stage0;

  CFFanoutLeaf #(.LEAF_ID(BID)) u_leaf(
    .leaf_in(stage1)
  );
endmodule

module CFSubsystem #(parameter SID = 0) (
  input clk,
  input rst_n,
  input tie_in
);
  wire [3:0] kw_vec;
  wire kw_concat;
  wire kw_plain;
  wire kw_module_src;
  wire [1:0] kw_rec_hi;
  wire [1:0] kw_rec_lo;
  wire [1:0] kw_mixed;
  wire [6:0] noise_b;
  wire [2:0] noise_d;
  wire noise_n;
  wire [10:0] drv_concat_bus;
  wire [3:0] rec_mid;
  wire [3:0] rec_deep;
  wire plain_l0;
  wire plain_l1;
  wire [15:0] packed_bus;
  wire drv_range_bit;
  wire pass_l0;
  wire pass_l1;
  wire const_after_block;
  wire [1:0] mixed_bus;
  wire false_same_bus;
  reg reg_q;
  wire [20:0] load_bus;
  wire load_plain;
  wire load_module_port;
  wire load_unconnected;
  wire [2:0] load_concat;
  wire [2:0] load_concat_l1;
  wire [2:0] load_concat_l2;
  wire [10:0] load_slice0;
  wire [10:0] load_slice1;
  wire load_plain_l0;
  wire load_pass_mid;
  wire aux_in_l0;
  wire aux_in_l1;
  wire aux_out;
  wire [31:0] load_plain_bus;
  wire sink_concat_used;
  wire sink_slice_used;
  wire sink_plain_used;
  wire sink_pass_used;
  wire sink_aux_used;

  CFKeywordSrc #(.W(4), .VALUE(4'b1010)) u_kw_vec(.out(kw_vec));
  CFKeywordSrc #(.W(1), .VALUE(1'b1)) u_kw_concat(.out(kw_concat));
  CFKeywordSrc #(.W(1), .VALUE(1'b1)) u_kw_plain(.out(kw_plain));
  CFKeywordSrc #(.W(1), .VALUE(1'b1)) u_kw_module(.out(kw_module_src));
  CFKeywordSrc #(.W(2), .VALUE(2'b10)) u_kw_rec_hi(.out(kw_rec_hi));
  CFKeywordSrc #(.W(2), .VALUE(2'b01)) u_kw_rec_lo(.out(kw_rec_lo));
  CFKeywordSrc #(.W(2), .VALUE(2'b11)) u_kw_mixed(.out(kw_mixed));
  CFNoiseSrc u_noise(.b(noise_b), .d(noise_d), .n(noise_n));

  assign drv_concat_bus[10:0] = {noise_d[2:0], kw_concat, noise_b[6:0]};
  assign rec_mid = {kw_rec_hi, kw_rec_lo};
  assign rec_deep = {rec_mid[3:2], rec_mid[1:0]};
  assign plain_l0 = kw_plain;
  assign plain_l1 = plain_l0;

  assign packed_bus[15:8] = {4'b0000, kw_vec};
  assign packed_bus[7:0] = 8'h00;
  assign drv_range_bit = packed_bus[10];

  CFPass #(.W(1)) u_driver_pass(.i(kw_module_src), .o(pass_l0));
  assign pass_l1 = pass_l0;

  initial begin
    reg_q = 1'b0;
  end
  always @(posedge clk) begin
    reg_q <= kw_plain;
  end
  assign const_after_block = 1'b0;

  assign mixed_bus[0] = const_after_block;
  assign mixed_bus[1] = kw_mixed[0];
  assign false_same_bus = mixed_bus[0];

  CFProbe #(.ID(SID), .DW(16)) u_probe (
    .drv_concat_bus(drv_concat_bus),
    .drv_recursive(rec_deep),
    .drv_plain(plain_l1),
    .drv_range_bit(drv_range_bit),
    .drv_module_port(pass_l1),
    .drv_const_direct(1'b0),
    .drv_const_parent(tie_in),
    .drv_const_after_block(const_after_block),
    .drv_false_same_bus(false_same_bus),
    .drv_noise(noise_n),
    .drv_reg_endpoint(reg_q),
    .drv_float(),
    .load_bus(load_bus),
    .load_plain(load_plain),
    .load_module_port(load_module_port),
    .load_unconnected()
  );

  assign load_concat = {1'b0, load_bus[7], 1'b1};
  assign load_concat_l1 = load_concat;
  assign load_concat_l2 = load_concat_l1;
  CFKeywordSink #(.W(3)) u_sink_concat(.in(load_concat_l2), .used(sink_concat_used));

  assign load_slice0 = load_bus[10:0];
  assign load_slice1 = {load_slice0[10:0]};
  CFKeywordSink #(.W(11)) u_sink_slice(.in(load_slice1), .used(sink_slice_used));

  assign load_plain_l0 = load_plain;
  CFKeywordSink #(.W(1)) u_sink_plain(.in(load_plain_l0), .used(sink_plain_used));

  CFPass #(.W(1)) u_load_pass(.i(load_module_port), .o(load_pass_mid));
  CFKeywordSink #(.W(1)) u_sink_pass(.in(load_pass_mid), .used(sink_pass_used));

  assign load_plain_bus = {
    load_plain, load_plain, load_plain, load_plain,
    load_plain, load_plain, load_plain, load_plain,
    load_plain, load_plain, load_plain, load_plain,
    load_plain, load_plain, load_plain, load_plain,
    load_plain, load_plain, load_plain, load_plain,
    load_plain, load_plain, load_plain, load_plain,
    load_plain, load_plain, load_plain, load_plain,
    load_plain, load_plain, load_plain, load_plain
  };
  CFLoaderBridge #(.BID(SID)) u_loader_bridge(
    .in_bus(load_plain_bus)
  );

  assign aux_in_l0 = kw_plain;
  assign aux_in_l1 = aux_in_l0;
  CFAuxProbe #(.MODE(SID + 20)) u_aux(.aux_in(aux_in_l1), .aux_out(aux_out));
  CFKeywordSink #(.W(1)) u_sink_aux(.in(aux_out), .used(sink_aux_used));
endmodule
