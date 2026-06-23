module CFTarget #(
  parameter integer ID = 0,
  parameter integer DW = 8
) (
  input clk,
  input [3:0] drv_bits,
  input drv_chain,
  input drv_port,
  input drv_ternary_stop,
  input drv_const,
  input drv_reg,
  input drv_float,
  input drv_noise,
  output [7:0] load_bus,
  output load_port,
  output load_reg,
  output load_no
);
  assign load_bus = {drv_bits, drv_chain, drv_port, drv_const, drv_const};
  assign load_port = drv_port;
  assign load_reg = drv_reg;
  assign load_no = drv_noise;
endmodule
