module SFPKeySrc #(
  parameter integer ID = 0,
  parameter integer WIDTH = 1
) (
  output [WIDTH-1:0] out
);
  assign out = {WIDTH{1'b1}} ^ ID[WIDTH-1:0];
endmodule
