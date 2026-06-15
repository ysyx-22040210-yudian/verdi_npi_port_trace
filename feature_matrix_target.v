module FMTarget #(parameter ID = 0, parameter DW = 16, parameter TAG = 0) (
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
  assign load_unconnected = drv_noise;
endmodule

module FMTargetShell0 #(parameter ID = 0, parameter DW = 16, parameter TAG = 0) (
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
  output load_unconnected
);
  wire [10:0] precise_alias;
  wire [3:0] recursive_alias;
  wire [7:0] reg_alias;

  assign precise_alias[10:0] = drv_precise_bus[10:0];
  assign recursive_alias = drv_recursive;
  assign reg_alias = drv_reg_endpoint[7:0];

  FMTarget #(.ID(ID), .DW(DW), .TAG(TAG)) u_target(
    .clk(clk),
    .drv_precise_bus(precise_alias[10:0]),
    .drv_recursive(recursive_alias[3:0]),
    .drv_plain(drv_plain),
    .drv_assign_chain(drv_assign_chain),
    .drv_cross_concat(drv_cross_concat),
    .drv_module_port(drv_module_port),
    .drv_const_direct(drv_const_direct),
    .drv_const_parent(drv_const_parent),
    .drv_const_source(drv_const_source),
    .drv_noise(drv_noise),
    .drv_reg_endpoint(reg_alias[7:0]),
    .drv_float(drv_float),
    .load_bus(load_bus),
    .load_plain(load_plain),
    .load_module_port(load_module_port),
    .load_sibling_bus(load_sibling_bus),
    .load_leaf_bus(load_leaf_bus),
    .load_unconnected(load_unconnected)
  );
endmodule

module FMTargetShell1 #(parameter ID = 0, parameter DW = 16, parameter TAG = 0) (
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
  output load_unconnected
);
  wire [10:0] precise_mid;
  wire [3:0] recursive_mid;
  wire [7:0] reg_mid;

  assign precise_mid = drv_precise_bus[10:0];
  assign recursive_mid[3:2] = drv_recursive[3:2];
  assign recursive_mid[1:0] = drv_recursive[1:0];
  assign reg_mid[7:0] = drv_reg_endpoint[7:0];

  FMTargetShell0 #(.ID(ID), .DW(DW), .TAG(TAG)) u_shell0(
    .clk(clk),
    .drv_precise_bus(precise_mid[10:0]),
    .drv_recursive(recursive_mid[3:0]),
    .drv_plain(drv_plain),
    .drv_assign_chain(drv_assign_chain),
    .drv_cross_concat(drv_cross_concat),
    .drv_module_port(drv_module_port),
    .drv_const_direct(drv_const_direct),
    .drv_const_parent(drv_const_parent),
    .drv_const_source(drv_const_source),
    .drv_noise(drv_noise),
    .drv_reg_endpoint(reg_mid[7:0]),
    .drv_float(drv_float),
    .load_bus(load_bus),
    .load_plain(load_plain),
    .load_module_port(load_module_port),
    .load_sibling_bus(load_sibling_bus),
    .load_leaf_bus(load_leaf_bus),
    .load_unconnected(load_unconnected)
  );
endmodule

module FMAuxTarget #(parameter MODE = 0) (
  input aux_in,
  input aux_float,
  output aux_out,
  output aux_unused_out
);
  assign aux_out = aux_in;
  assign aux_unused_out = aux_in;
endmodule
