module FCTKeywordSrc #(parameter W = 1, parameter VALUE = 1) (
  output [W-1:0] out
);
  assign out = VALUE;
endmodule

module FCTKeywordSink #(parameter W = 1) (
  input [W-1:0] in,
  output used
);
  assign used = ^in;
endmodule

module FCTProbe #(parameter ID = 0, parameter DW = 8) (
  input [3:0] drv_vec,
  input drv_alias_bit,
  input drv_range_bit,
  input drv_const_direct,
  input drv_const_parent,
  input drv_const_after_end,
  input drv_false_same_bus,
  input drv_reg_endpoint,
  input drv_float,
  output [7:0] load_bus,
  output load_scalar,
  output load_unconnected
);
  assign load_bus = {
    drv_vec[3],
    drv_vec[2],
    drv_range_bit,
    drv_alias_bit,
    drv_const_direct,
    drv_const_parent,
    drv_reg_endpoint,
    drv_false_same_bus
  };
  assign load_scalar = drv_alias_bit ^ drv_reg_endpoint;
  assign load_unconnected = drv_float;
endmodule

module FCTAuxProbe #(parameter MODE = 0) (
  input aux_in,
  output aux_out
);
  assign aux_out = aux_in;
endmodule

module FCTSubsystem #(parameter SID = 0) (
  input clk,
  input rst_n,
  input tie_in
);
  reg reg_q;
  wire [3:0] kw_vec;
  wire kw_bit;
  wire [1:0] kw_mixed;
  wire [3:0] drv_vec_l0;
  wire [3:0] drv_vec_l1;
  wire alias_bit_l0;
  wire alias_bit_l1;
  wire [15:0] packed_bus;
  wire drv_range_bit;
  wire const_after_end;
  wire [1:0] mixed_bus;
  wire false_same_bus;
  wire [7:0] load_bus;
  wire load_scalar;
  wire [2:0] load_concat;
  wire load_concat_l0;
  wire load_concat_l1;
  wire [3:0] load_range;
  wire aux_in_l0;
  wire aux_in_l1;
  wire aux_out;
  wire sink_concat_used;
  wire sink_range_used;
  wire sink_scalar_used;
  wire sink_aux_used;

  initial begin
    reg_q = 1'b0;
  end

  FCTKeywordSrc #(.W(4), .VALUE(4'b1010)) u_kw_vec(.out(kw_vec));
  FCTKeywordSrc #(.W(1), .VALUE(1'b1)) u_kw_bit(.out(kw_bit));
  FCTKeywordSrc #(.W(2), .VALUE(2'b11)) u_kw_mixed(.out(kw_mixed));

  assign drv_vec_l0 = {1'b0, kw_vec[2], kw_vec[1], 1'b1};
  assign drv_vec_l1 = drv_vec_l0;
  assign alias_bit_l0 = kw_bit;
  assign alias_bit_l1 = alias_bit_l0;
  assign packed_bus[15:8] = {4'b0000, kw_vec};
  assign packed_bus[7:0] = 8'h00;
  assign drv_range_bit = packed_bus[10];

  always @(posedge clk) begin
    reg_q <= kw_bit;
  end

  assign const_after_end = 1'b0;
  assign mixed_bus[0] = const_after_end;
  assign mixed_bus[1] = kw_mixed[0];
  assign false_same_bus = mixed_bus[0];

  FCTProbe #(.ID(SID), .DW(8)) u_probe (
    .drv_vec(drv_vec_l1),
    .drv_alias_bit(alias_bit_l1),
    .drv_range_bit(drv_range_bit),
    .drv_const_direct(1'b0),
    .drv_const_parent(tie_in),
    .drv_const_after_end(const_after_end),
    .drv_false_same_bus(false_same_bus),
    .drv_reg_endpoint(reg_q),
    .drv_float(),
    .load_bus(load_bus),
    .load_scalar(load_scalar),
    .load_unconnected()
  );

  assign load_concat = {1'b0, load_bus[6], 1'b1};
  assign load_concat_l0 = load_concat[1];
  assign load_concat_l1 = load_concat_l0;
  FCTKeywordSink #(.W(1)) u_sink_concat(.in(load_concat_l1), .used(sink_concat_used));

  assign load_range = {load_bus[3], load_bus[2], 1'b0, load_bus[0]};
  FCTKeywordSink #(.W(4)) u_sink_range(.in(load_range), .used(sink_range_used));
  FCTKeywordSink #(.W(1)) u_sink_scalar(.in(load_scalar), .used(sink_scalar_used));

  assign aux_in_l0 = kw_bit;
  assign aux_in_l1 = aux_in_l0;
  FCTAuxProbe #(.MODE(SID + 10)) u_aux(.aux_in(aux_in_l1), .aux_out(aux_out));
  FCTKeywordSink #(.W(1)) u_sink_aux(.in(aux_out), .used(sink_aux_used));
endmodule

module FullCoverageTop;
  reg clk;

  initial begin
    clk = 1'b0;
  end

  FCTSubsystem #(.SID(0)) cluster0(
    .clk(clk),
    .rst_n(1'b1),
    .tie_in(1'b0)
  );

  FCTSubsystem #(.SID(1)) cluster1(
    .clk(clk),
    .rst_n(1'b1),
    .tie_in(1'b0)
  );
endmodule
