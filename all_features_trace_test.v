module AFKeywordSrc #(parameter WIDTH = 1, parameter VALUE = 1) (
  output [WIDTH-1:0] out
);
  assign out = VALUE;
endmodule

module AFKeywordSink #(parameter WIDTH = 1) (
  input [WIDTH-1:0] in,
  output used
);
  assign used = ^in;
endmodule

module AFProbe #(parameter ID = 0, parameter DATAW = 8) (
  input clk,
  input rst_n,
  input [3:0] drv_concat,
  input drv_bit,
  input drv_range,
  input drv_const,
  input drv_parent_const,
  input drv_regcombo,
  input drv_false,
  input drv_float,
  output [7:0] load_bus,
  output load_bit,
  output unconnected_out
);
  assign load_bus = {
    drv_concat[3],
    drv_concat[2],
    drv_range,
    drv_bit,
    drv_const,
    drv_parent_const,
    drv_regcombo,
    drv_false
  };
  assign load_bit = drv_regcombo ^ drv_false;
  assign unconnected_out = drv_float;
endmodule

module AFSubsystem #(parameter SID = 0) (
  input clk,
  input rst_n,
  input tie_in
);
  wire [3:0] kw_vec;
  wire kw_bit;
  wire [1:0] mixed_kw;
  wire [3:0] drv_concat_l1;
  wire [3:0] drv_concat_l2;
  wire drv_bit_l1;
  wire drv_bit_l2;
  wire [15:0] shifted_bus;
  wire drv_range;
  wire regcombo_src;
  reg regcombo_q;
  wire [1:0] mixed_bus;
  wire drv_false;
  wire [7:0] load_bus;
  wire load_bit;
  wire [2:0] load_concat;
  wire load_concat_l1;
  wire load_concat_l2;
  wire [3:0] load_range;
  wire sink_concat_used;
  wire sink_range_used;
  wire sink_bit_used;

  AFKeywordSrc #(.WIDTH(4), .VALUE(4'b1010)) u_kw_vec(.out(kw_vec));
  AFKeywordSrc #(.WIDTH(1), .VALUE(1'b1)) u_kw_bit(.out(kw_bit));
  AFKeywordSrc #(.WIDTH(2), .VALUE(2'b11)) u_kw_mixed(.out(mixed_kw));

  assign drv_concat_l1 = {1'b0, kw_vec[2], kw_vec[1], 1'b1};
  assign drv_concat_l2 = drv_concat_l1;
  assign drv_bit_l1 = kw_bit;
  assign drv_bit_l2 = drv_bit_l1;

  assign shifted_bus[15:8] = {4'b0000, kw_vec};
  assign shifted_bus[7:0] = 8'h00;
  assign drv_range = shifted_bus[10];

  assign regcombo_src = kw_bit;
  always @(posedge clk) begin
    regcombo_q <= regcombo_src;
  end

  assign mixed_bus[0] = 1'b0;
  assign mixed_bus[1] = mixed_kw[0];
  assign drv_false = mixed_bus[0];

  AFProbe #(.ID(SID), .DATAW(8)) u_probe (
    .clk(clk),
    .rst_n(rst_n),
    .drv_concat(drv_concat_l2),
    .drv_bit(drv_bit_l2),
    .drv_range(drv_range),
    .drv_const(1'b0),
    .drv_parent_const(tie_in),
    .drv_regcombo(regcombo_q),
    .drv_false(drv_false),
    .drv_float(),
    .load_bus(load_bus),
    .load_bit(load_bit),
    .unconnected_out()
  );

  assign load_concat = {1'b0, load_bus[3], 1'b1};
  assign load_concat_l1 = load_concat[1];
  assign load_concat_l2 = load_concat_l1;
  assign load_range = load_bus[7:4];

  AFKeywordSink #(.WIDTH(1)) u_kw_sink_concat(.in(load_concat_l2), .used(sink_concat_used));
  AFKeywordSink #(.WIDTH(4)) u_kw_sink_range(.in(load_range), .used(sink_range_used));
  AFKeywordSink #(.WIDTH(1)) u_kw_sink_bit(.in(load_bit), .used(sink_bit_used));
endmodule

module AllFeaturesTop;
  reg clk;

  initial begin
    clk = 1'b0;
  end

  AFSubsystem #(.SID(0)) subsys0(
    .clk(clk),
    .rst_n(1'b1),
    .tie_in(1'b0)
  );

  AFSubsystem #(.SID(1)) subsys1(
    .clk(clk),
    .rst_n(1'b1),
    .tie_in(1'b0)
  );
endmodule
