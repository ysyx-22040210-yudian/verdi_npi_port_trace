module CFProbe #(parameter ID = 0, parameter DW = 8) (
  input [10:0] drv_concat_bus,
  input [3:0] drv_recursive,
  input drv_plain,
  input drv_range_bit,
  input drv_module_port,
  input drv_const_direct,
  input drv_const_parent,
  input drv_const_after_block,
  input drv_false_same_bus,
  input drv_noise,
  input drv_reg_endpoint,
  input drv_float,
  output [20:0] load_bus,
  output load_plain,
  output load_module_port,
  output load_unconnected
);
  assign load_bus = {
    drv_concat_bus,
    drv_recursive,
    drv_plain,
    drv_range_bit,
    drv_module_port,
    drv_const_direct,
    drv_const_parent,
    drv_const_after_block
  };
  assign load_plain = drv_plain;
  assign load_module_port = drv_module_port;
  assign load_unconnected = drv_float;
endmodule

module CFAuxProbe #(parameter MODE = 0) (
  input aux_in,
  output aux_out
);
  assign aux_out = aux_in;
endmodule
