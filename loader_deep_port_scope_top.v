module LoaderDeepPortScopeTop;
  reg clk;
  wire used0;
  wire used1;

  initial begin
    clk = 1'b0;
  end

  always #5 clk = ~clk;

  LDPSCluster u_cluster0 (
    .clk(clk),
    .used(used0)
  );

  LDPSCluster u_cluster1 (
    .clk(clk),
    .used(used1)
  );
endmodule
