module BPStressMid (
  input wire clk
);
  wire [7:0]  a_bus;
  wire        one_bit_from_bus;
  wire        ternary_stop;
  wire [20:0] y_bus;

  wire key7;
  wire [31:0] wide_const;
  wire [31:0] wide_key_mix;
  wire [31:0] pass0;
  wire [31:0] pass1;
  wire [15:0] concat_stage0;
  wire [15:0] concat_stage1;
  wire key_path;
  wire local_c0;
  wire local_c1;
  wire local_c2;
  wire local_c3;
  wire local_c4;
  wire local_c5;
  wire local_c6;

  BPStressKeySrc u_key7(.clk(clk), .out(key7));

  assign wide_const = 32'hffff_ff7f;
  assign wide_key_mix = {
    24'h5aa55a,
    key7,
    7'b101_0101
  };
  assign pass0 = wide_key_mix;
  assign pass1 = pass0;
  assign one_bit_from_bus = pass1[7];

  assign concat_stage0 = {8'h3c, wide_const[7], 7'b010_1010};
  assign concat_stage1 = concat_stage0;
  assign {local_c6, key_path, local_c5, local_c4, local_c3, local_c2, local_c1, local_c0} = concat_stage1[7:0];

  assign a_bus[0] = 1'b0;
  assign a_bus[1] = wide_const[1];
  assign a_bus[2] = wide_const[2];
  assign a_bus[3] = wide_const[3];
  assign a_bus[4] = wide_const[4];
  assign a_bus[5] = wide_const[5];
  assign a_bus[6] = 1'b1;
  assign a_bus[7] = key7;

  assign ternary_stop = key_path ? key7 : 1'b1;

  BPStressChild u_child (
    .A(a_bus),
    .one_bit_from_bus(one_bit_from_bus),
    .ternary_stop(ternary_stop),
    .Y(y_bus)
  );

  wire [10:0] y_low;
  wire [9:0]  y_high;
  assign y_low = y_bus[10:0];
  assign y_high = y_bus[20:11];

  BPStressKeySink u_sink_low(.in(y_low[7]));
  BPStressRegSink u_reg_high(.clk(clk), .in(y_high[2]));
endmodule
