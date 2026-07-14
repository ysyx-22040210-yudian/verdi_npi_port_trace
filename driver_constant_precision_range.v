module DCP_RangeSource (
  output wire [1:0] desc,
  output wire [0:7] asc,
  output wire [0:7] asc_whole
);
  assign desc[1:0] = 2'b10;
  assign asc[0:7] = 8'b10000000;
  assign asc_whole = 8'b10000000;
endmodule

module DCP_SymbolicAscSource #(
  parameter W = 8
) (
  output wire [0:W-1] out
);
  assign out = 8'b10000000;
endmodule

module DCP_DescVectorSource (
  output wire [7:0] out
);
  assign out = 8'b10000000;
endmodule
