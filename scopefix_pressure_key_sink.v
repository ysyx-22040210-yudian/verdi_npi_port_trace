module SFPKeySink #(
  parameter integer ID = 0,
  parameter integer WIDTH = 1
) (
  input [WIDTH-1:0] in,
  output used
);
  assign used = ^(in ^ ID[WIDTH-1:0]);
endmodule
