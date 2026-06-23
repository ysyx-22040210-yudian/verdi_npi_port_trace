module CFTop;
  reg clk;

  initial begin
    clk = 1'b0;
  end

  always #5 clk = ~clk;

  CFSubsystem #(.SID(0)) subsys0 (
    .clk(clk),
    .tie_parent(1'b0)
  );

  CFSubsystem #(.SID(1)) subsys1 (
    .clk(clk),
    .tie_parent(1'b1)
  );
endmodule
