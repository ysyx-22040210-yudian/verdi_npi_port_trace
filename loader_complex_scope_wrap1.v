module LCSWrap1 (
  input clk,
  input rst_n,
  output used
);
  wire wrap_used;

  LCSWrap0 u_wrap0 (
    .clk(clk),
    .rst_n(rst_n),
    .used(wrap_used)
  );

  assign used = wrap_used;
endmodule
