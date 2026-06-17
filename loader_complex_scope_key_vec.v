module LCSKeyVec #(
  parameter W = 8
) (
  input [W-1:0] in,
  output used
);
  assign used = ^in;
endmodule
