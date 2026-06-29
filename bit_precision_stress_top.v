module BPStressTop;
  reg clk;

  initial begin
    clk = 1'b0;
  end

  always #5 clk = ~clk;

  BPStressMid u_mid(.clk(clk));
endmodule
