module CSKeywordSink11(input [10:0] in, output used);
  assign used = ^in;
endmodule

module CSKeywordSink10(input [9:0] in, output used);
  assign used = ^in;
endmodule

module CSProducer(output [20:0] out);
  assign out = 21'h155555;
endmodule

module CSSiblingFanout(
  input [20:0] in_bus,
  output used_b,
  output used_c
);
  wire [10:0] B;
  wire [9:0] C;

  assign B = in_bus[10:0];
  assign C = in_bus[20:11];

  CSKeywordSink11 u_sibling_b(.in(B), .used(used_b));
  CSKeywordSink10 u_sibling_c(.in(C), .used(used_c));
endmodule

module CSMid(output [20:0] out_mid);
  wire [20:0] A_mid;

  CSProducer u_prod(.out(A_mid));
  assign out_mid = A_mid;
endmodule

module CrossScopeLoaderTop;
  wire [20:0] A;
  wire [10:0] B_top;
  wire [9:0] C_top;
  wire top_b_used;
  wire top_c_used;
  wire sibling_b_used;
  wire sibling_c_used;

  CSMid u_mid(.out_mid(A));

  assign B_top = A[10:0];
  assign C_top = A[20:11];

  CSKeywordSink11 u_top_b(.in(B_top), .used(top_b_used));
  CSKeywordSink10 u_top_c(.in(C_top), .used(top_c_used));
  CSSiblingFanout u_sibling(
    .in_bus(A),
    .used_b(sibling_b_used),
    .used_c(sibling_c_used)
  );
endmodule
