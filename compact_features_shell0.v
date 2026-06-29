module CFShell0 #(
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
  wire [3:0] bits_alias;
  assign bits_alias = drv_bits;

  CFTarget #(.ID(ID), .DW(DW)) u_target (
    .clk(clk),
    .drv_bits(bits_alias),
    .drv_chain(drv_chain),
    .drv_port(drv_port),
    .drv_wide_bit(drv_wide_bit),
    .drv_ternary_stop(drv_ternary_stop),
    .drv_const(drv_const),
    .drv_reg(drv_reg),
    .drv_float(drv_float),
    .drv_noise(drv_noise),
    .load_bus(load_bus),
    .load_port(load_port),
    .load_reg(load_reg),
    .load_no(load_no)
  );
endmodule
