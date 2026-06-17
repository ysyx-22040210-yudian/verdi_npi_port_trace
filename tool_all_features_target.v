module TAFTarget #(parameter ID = 0, parameter DW = 16, parameter TAG = 0) (
  input clk,
  input [10:0] drv_precise_bus,
  input [3:0] drv_recursive,
  input drv_plain,
  input drv_assign_chain,
  input drv_cross_concat,
  input drv_module_port,
  input drv_const_direct,
  input drv_const_parent,
  input drv_const_source,
  input drv_noise,
  input [7:0] drv_reg_endpoint,
  input drv_float,
  output [20:0] load_bus,
  output load_plain,
  output load_module_port,
  output [20:0] load_sibling_bus,
  output [15:0] load_leaf_bus,
  output load_reg_endpoint,
  output load_unconnected
);
  assign load_bus = {
    drv_precise_bus,
    drv_recursive,
    drv_assign_chain,
    drv_cross_concat,
    drv_module_port,
    drv_plain,
    drv_const_direct,
    drv_const_parent
  };

  assign load_plain = drv_plain;
  assign load_module_port = drv_module_port;
  assign load_sibling_bus = {
    drv_assign_chain, drv_assign_chain, drv_assign_chain, drv_assign_chain,
    drv_assign_chain, drv_assign_chain, drv_assign_chain, drv_assign_chain,
    drv_assign_chain, drv_assign_chain, drv_assign_chain, drv_assign_chain,
    drv_assign_chain, drv_assign_chain, drv_assign_chain, drv_assign_chain,
    drv_assign_chain, drv_assign_chain, drv_assign_chain, drv_assign_chain,
    drv_assign_chain
  };
  assign load_leaf_bus = {
    drv_plain, drv_plain, drv_plain, drv_plain,
    drv_plain, drv_plain, drv_plain, drv_plain,
    drv_plain, drv_plain, drv_plain, drv_plain,
    drv_plain, drv_plain, drv_plain, drv_plain
  };
  assign load_reg_endpoint = drv_reg_endpoint[0];
  assign load_unconnected = drv_noise;
endmodule
