module LoaderComplexScopeTop;
  reg clk;
  reg rst_n;
  wire used0;
  wire used1;

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    #17 rst_n = 1'b1;
  end

  always #5 clk = ~clk;

  LCSCluster u_cluster0 (
    .clk(clk),
    .rst_n(rst_n),
    .used(used0)
  );

  LCSCluster u_cluster1 (
    .clk(clk),
    .rst_n(rst_n),
    .used(used1)
  );
endmodule
