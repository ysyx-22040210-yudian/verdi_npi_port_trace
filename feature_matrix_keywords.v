module FMKeySrc #(parameter W = 1, parameter VALUE = 1) (
  output [W-1:0] out
);
  assign out = VALUE;
endmodule

module FMKeySink #(parameter W = 1) (
  input [W-1:0] in,
  output used
);
  assign used = ^in;
endmodule

module FMNoiseSrc (
  output [6:0] b,
  output [2:0] d,
  output reg n
);
  assign b = 7'h35;
  assign d = 3'h6;

  initial begin
    n = 1'b1;
  end
endmodule

module FMPass #(parameter W = 1) (
  input [W-1:0] i,
  output [W-1:0] o
);
  assign o = i;
endmodule

module FMRegSource #(parameter W = 8) (
  input clk,
  output reg [W-1:0] out
);
  initial begin
    out = {W{1'b0}};
  end

  always @(posedge clk) begin
    out <= out + {{(W-1){1'b0}}, 1'b1};
  end
endmodule

module FMNestedKey #(parameter W = 1, parameter VALUE = 1) (
  output [W-1:0] out
);
  FMKeySrc #(.W(W), .VALUE(VALUE)) u_key_nested(
    .out(out)
  );
endmodule

module FMDeepConcatProvider (
  output [15:0] deep_e
);
  wire [3:0] lane_f_const;
  wire [3:0] lane_h_key;
  wire [3:0] lane_g_const;
  wire [3:0] lane_k_const;
  wire [15:0] pack0;
  wire [15:0] pack1;

  assign lane_f_const = 4'h1;
  assign lane_g_const = 4'h2;
  assign lane_k_const = 4'h3;
  FMKeySrc #(.W(4), .VALUE(4'ha)) u_key_deep_h(.out(lane_h_key));

  assign pack0 = {lane_f_const, lane_h_key, lane_g_const, lane_k_const};
  assign pack1[3:0] = pack0[3:0];
  assign pack1[7:4] = pack0[7:4];
  assign pack1[11:8] = pack0[11:8];
  assign pack1[15:12] = pack0[15:12];
  assign deep_e = pack1;
endmodule

`define FM_UNKNOWN_DIR_INPUT input

module FMUnknownDirProbe(a);
  `FM_UNKNOWN_DIR_INPUT [20:0] a;

  wire used;
  assign used = ^a;
endmodule
