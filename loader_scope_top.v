module LoaderScopeTop;
  reg clk;
  wire used0;
  wire used1;

  initial begin
    clk = 1'b0;
  end

  always #5 clk = ~clk;

  LoaderScopeParent0 u_parent0(.clk(clk), .used(used0));
  LoaderScopeParent0 u_parent1(.clk(clk), .used(used1));
endmodule
