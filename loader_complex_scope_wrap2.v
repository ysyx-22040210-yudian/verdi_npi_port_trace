module LCSWrap2 (
  input clk,
  input rst_n,
  output used
);
  wire wrap_used;

  LCSWrap1 u_wrap1 (
    .clk(clk),
    .rst_n(rst_n),
    .used(wrap_used)
  );

  assign used = wrap_used;
endmodule
