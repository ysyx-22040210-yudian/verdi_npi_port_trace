module DCP_MuxSource (
  input  wire sel,
  output wire out
);
  assign out = sel ? 1'b1 : 1'b0;
endmodule
