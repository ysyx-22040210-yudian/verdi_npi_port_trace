module FeatureMatrixTop;
  reg clk;
  reg rst_n;
  wire [15:0] global_deep_e;
  wire [15:0] global_deep_e_alias;

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
  end

  always #5 clk = ~clk;

  FMDeepConcatProvider u_global_deep_provider(
    .deep_e(global_deep_e)
  );
  assign global_deep_e_alias = global_deep_e;

  FMFeatureSubsystem #(.SID(0)) subsys0(
    .clk(clk),
    .rst_n(rst_n),
    .tie_parent(1'b0),
    .deep_e_from_top(global_deep_e_alias)
  );

  FMFeatureSubsystem #(.SID(1)) subsys1(
    .clk(clk),
    .rst_n(rst_n),
    .tie_parent(1'b1),
    .deep_e_from_top(global_deep_e_alias)
  );
endmodule
