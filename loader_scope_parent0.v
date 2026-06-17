module LoaderScopeParent0 (
  input clk,
  output used
);
  wire net;

  LoaderScopeChild0 u_child0(.clk(clk), .a(net));
  LoaderScopeChild1 u_child1(.clk(clk), .b(net), .used(used));
endmodule
