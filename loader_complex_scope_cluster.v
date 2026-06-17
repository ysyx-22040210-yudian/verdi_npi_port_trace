module LCSCluster (
  input clk,
  input rst_n,
  output used
);
  wire path0_used;
  wire path1_used;

  LCSWrap3 u_path0 (
    .clk(clk),
    .rst_n(rst_n),
    .used(path0_used)
  );

  LCSWrap3 u_path1 (
    .clk(clk),
    .rst_n(rst_n),
    .used(path1_used)
  );

  assign used = path0_used | path1_used;
endmodule
