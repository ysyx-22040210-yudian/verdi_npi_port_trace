module TAFTargetShell0 #(parameter ID = 0, parameter DW = 16, parameter TAG = 0) (
  input clk,
  input [10:0] drv_precise_bus,
  input [3:0] drv_recursive,
  input drv_plain,
  input drv_assign_chain,
  input drv_cross_concat,
  input drv_module_port,
  input drv_wide_bit,
  input drv_const_direct,
  input drv_const_parent,
  input drv_const_source,
  input drv_noise,
  input [7:0] drv_reg_endpoint,
  input drv_ternary_stop,
  input drv_float,
  output [20:0] load_bus,
  output load_plain,
  output load_module_port,
  output [20:0] load_sibling_bus,
  output [15:0] load_leaf_bus,
  output load_reg_endpoint,
  output load_unconnected
);
  wire [10:0] precise_alias;
  wire [3:0] recursive_alias;
  wire [7:0] reg_alias;

  assign precise_alias[10:0] = drv_precise_bus[10:0];
  assign recursive_alias = drv_recursive;
  assign reg_alias = drv_reg_endpoint[7:0];

  TAFTarget #(.ID(ID), .DW(DW), .TAG(TAG)) u_target(
    .clk(clk),
    .drv_precise_bus(precise_alias[10:0]),
    .drv_recursive(recursive_alias[3:0]),
    .drv_plain(drv_plain),
    .drv_assign_chain(drv_assign_chain),
    .drv_cross_concat(drv_cross_concat),
    .drv_module_port(drv_module_port),
    .drv_wide_bit(drv_wide_bit),
    .drv_const_direct(drv_const_direct),
    .drv_const_parent(drv_const_parent),
    .drv_const_source(drv_const_source),
    .drv_noise(drv_noise),
    .drv_reg_endpoint(reg_alias[7:0]),
    .drv_ternary_stop(drv_ternary_stop),
    .drv_float(drv_float),
    .load_bus(load_bus),
    .load_plain(load_plain),
    .load_module_port(load_module_port),
    .load_sibling_bus(load_sibling_bus),
    .load_leaf_bus(load_leaf_bus),
    .load_reg_endpoint(load_reg_endpoint),
    .load_unconnected(load_unconnected)
  );
endmodule
