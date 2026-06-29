module CFTarget #(
  parameter integer ID = 0,
  parameter integer DW = 8
) (
  input clk,
  input [3:0] drv_bits,
  input drv_chain,
  input drv_port,
  input drv_wide_bit,
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
  assign load_bus = 8'h00;
  assign load_port = 1'b0;
  assign load_reg = 1'b0;
  assign load_no = 1'b0;
endmodule
