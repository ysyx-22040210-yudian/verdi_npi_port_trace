module ToolFeatureTop;
  reg clk;

  initial begin
    clk = 1'b0;
  end

  TFSubsystem #(.SID(0)) subsys0(
    .clk(clk),
    .rst_n(1'b1),
    .tie_parent(1'b0)
  );

  TFSubsystem #(.SID(1)) subsys1(
    .clk(clk),
    .rst_n(1'b1),
    .tie_parent(1'b0)
  );
endmodule
