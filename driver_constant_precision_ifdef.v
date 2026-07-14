module DCP_IfdefSource (
  output wire out
);
`ifdef DCP_USE_ONE
  assign out = 1'b1;
`else
  assign out = 1'b0;
`endif
endmodule
