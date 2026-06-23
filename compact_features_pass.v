module CFPass #(
  parameter integer W = 1
) (
  input [W-1:0] i,
  output [W-1:0] o
);
  assign o = i;
endmodule
