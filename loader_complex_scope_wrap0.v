module LCSWrap0 (
  input clk,
  input rst_n,
  output used
);
  wire sub_used;

  LCSSubsystem u_sub (
    .clk(clk),
    .rst_n(rst_n),
    .used(sub_used)
  );

  assign used = sub_used;
endmodule
