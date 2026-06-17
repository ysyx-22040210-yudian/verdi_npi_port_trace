module LCSWrap3 (
  input clk,
  input rst_n,
  output used
);
  wire wrap_used;

  LCSWrap2 u_wrap2 (
    .clk(clk),
    .rst_n(rst_n),
    .used(wrap_used)
  );

  assign used = wrap_used;
endmodule
