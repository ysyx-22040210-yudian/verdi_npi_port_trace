module CFKeySrc #(
  parameter integer W = 1,
  parameter [31:0] VALUE = 32'h1
) (
  output [W-1:0] out
);
  assign out = VALUE[W-1:0];
endmodule
