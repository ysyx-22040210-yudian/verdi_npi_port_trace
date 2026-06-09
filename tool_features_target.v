module TFTarget #(parameter ID = 0, parameter DW = 16) (
  input clk,
  input [10:0] drv_concat_bus,
  input [3:0] drv_recursive,
  input drv_plain,
  input drv_assign_chain,
  input drv_module_port,
  input drv_const_direct,
  input drv_const_parent,
  input drv_const_source,
  input drv_noise,
  input drv_reg_endpoint,
  input drv_float,
  output [20:0] load_bus,
  output load_plain,
  output load_module_port,
  output [20:0] load_sibling_bus,
  output [31:0] load_leaf_bus,
  output load_unconnected
);
  assign load_bus = {
    drv_concat_bus,
    drv_recursive,
    drv_plain,
    drv_assign_chain,
    drv_module_port,
    drv_const_direct,
    drv_const_parent,
    drv_const_source
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
    drv_plain, drv_plain, drv_plain, drv_plain,
    drv_plain, drv_plain, drv_plain, drv_plain,
    drv_plain, drv_plain, drv_plain, drv_plain,
    drv_plain, drv_plain, drv_plain, drv_plain,
    drv_plain, drv_plain, drv_plain, drv_plain
  };
  assign load_unconnected = drv_noise;
endmodule

module TFAuxTarget #(parameter MODE = 0) (
  input aux_in,
  output aux_out
);
  assign aux_out = aux_in;
endmodule
