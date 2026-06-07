module LPKeySink8(
  input [7:0] in,
  output used
);
  assign used = ^in;
endmodule

module LPPass8(
  input [7:0] in,
  output [7:0] out
);
  assign out = in;
endmodule

module LPDecoySameNames(
  input [7:0] decoy_key,
  output [7:0] direct_slice
);
  assign direct_slice = decoy_key;
endmodule
