module TFKeySrc #(parameter W = 1, parameter VALUE = 1) (
  output [W-1:0] out
);
  assign out = VALUE;
endmodule

module TFKeySink #(parameter W = 1) (
  input [W-1:0] in,
  output used
);
  assign used = ^in;
endmodule

module TFNoiseSrc (
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

module TFPass #(parameter W = 1) (
  input [W-1:0] i,
  output [W-1:0] o
);
  assign o = i;
endmodule

`define TF_UNKNOWN_DIR_INPUT input

module TFUnknownDirProbe(a);
  `TF_UNKNOWN_DIR_INPUT [20:0] a;

  wire used;
  assign used = ^a;
endmodule

module TFParentKey #(parameter W = 1, parameter VALUE = 1) (
  output [W-1:0] out
);
  TFKeySrc #(.W(W), .VALUE(VALUE)) u_key_nested(
    .out(out)
  );
endmodule
