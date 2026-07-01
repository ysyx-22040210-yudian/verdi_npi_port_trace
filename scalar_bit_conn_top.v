module ScalarBitConnTop;
  reg clk;

  initial begin
    clk = 1'b0;
  end

  always #5 clk = ~clk;

  ScalarBitConnMid u_mid(.clk(clk));
endmodule
