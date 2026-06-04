module CFKeywordSrc #(parameter W = 1, parameter VALUE = 1) (
  output [W-1:0] out
);
  assign out = VALUE;
endmodule

module CFKeywordSink #(parameter W = 1) (
  input [W-1:0] in,
  output used
);
  assign used = ^in;
endmodule

module CFNoiseSrc (
  output [6:0] b,
  output [2:0] d,
  output reg n
);
  assign b = 7'h2a;
  assign d = 3'h5;

  initial begin
    n = 1'b1;
  end
endmodule

module CFPass #(parameter W = 1) (
  input [W-1:0] i,
  output [W-1:0] o
);
  assign o = i;
endmodule
