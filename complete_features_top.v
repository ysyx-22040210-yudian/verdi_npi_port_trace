module CompleteFeatureTop;
  reg clk;

  initial begin
    clk = 1'b0;
  end

  CFSubsystem #(.SID(0)) subsys0(
    .clk(clk),
    .rst_n(1'b1),
    .tie_in(1'b0)
  );

  CFSubsystem #(.SID(1)) subsys1(
    .clk(clk),
    .rst_n(1'b1),
    .tie_in(1'b0)
  );
endmodule
