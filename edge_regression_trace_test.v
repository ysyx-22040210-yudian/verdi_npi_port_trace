module ERKeySrc #(parameter W = 1, parameter VALUE = 1) (
  output [W-1:0] out
);
  assign out = VALUE;
endmodule

module ERKeySink #(parameter W = 1) (
  input [W-1:0] in,
  output used
);
  assign used = ^in;
endmodule

module ERProbe #(parameter ID = 0) (
  input in_alias_bit,
  input in_range_bit,
  input in_const_after_end,
  input in_const_after_initial,
  input in_false_no_keyword,
  output [7:0] out_bus,
  output out_scalar,
  output unused_out
);
  assign out_bus = {
    in_alias_bit,
    in_range_bit,
    in_const_after_end,
    in_const_after_initial,
    in_false_no_keyword,
    in_alias_bit,
    in_range_bit,
    in_const_after_end
  };
  assign out_scalar = in_alias_bit;
  assign unused_out = in_const_after_initial;
endmodule

module EREdgeTop;
  reg clk;
  reg dummy;
  wire [3:0] key_after_initial;
  wire [3:0] alias_l0;
  wire [3:0] alias_l1;
  wire [3:0] alias_l2;
  wire [7:0] packed_bus;
  wire const_after_always;
  wire const_after_initial;
  wire [1:0] mixed_bus;
  wire false_no_keyword;
  wire [7:0] out_bus;
  wire out_scalar;
  wire [3:0] load_alias0;
  wire [3:0] load_alias1;
  wire [2:0] load_concat;
  wire [3:0] load_range;
  wire sink_concat_used;
  wire sink_range_used;
  wire sink_scalar_used;

  initial begin
    clk = 1'b0;
    dummy = 1'b0;
  end

  ERKeySrc #(.W(4), .VALUE(4'b1101)) u_key_after_initial(.out(key_after_initial));

  assign alias_l0 = key_after_initial;
  assign alias_l1 = alias_l0;
  assign alias_l2 = alias_l1;
  assign packed_bus[7:4] = {alias_l2[3], alias_l2[2], 1'b0, alias_l2[0]};
  assign packed_bus[3:0] = 4'b0000;

  always @(posedge clk) begin
    dummy <= alias_l2[0];
  end

  assign const_after_always = 1'b0;
  assign mixed_bus[0] = const_after_always;
  assign mixed_bus[1] = key_after_initial[1];
  assign false_no_keyword = mixed_bus[0];

  initial begin
    dummy = dummy;
  end

  assign const_after_initial = 1'b1;

  ERProbe #(.ID(7)) u_probe (
    .in_alias_bit(alias_l2[2]),
    .in_range_bit(packed_bus[6]),
    .in_const_after_end(const_after_always),
    .in_const_after_initial(const_after_initial),
    .in_false_no_keyword(false_no_keyword),
    .out_bus(out_bus),
    .out_scalar(out_scalar),
    .unused_out()
  );

  assign load_alias0 = out_bus[7:4];
  assign load_alias1 = load_alias0;
  assign load_concat = {1'b0, load_alias1[2], 1'b1};
  ERKeySink #(.W(1)) u_sink_concat(.in(load_concat[1]), .used(sink_concat_used));

  assign load_range = {out_bus[3], out_bus[2], 1'b0, out_bus[0]};
  ERKeySink #(.W(4)) u_sink_range(.in(load_range), .used(sink_range_used));
  ERKeySink #(.W(1)) u_sink_scalar(.in(out_scalar), .used(sink_scalar_used));
endmodule
