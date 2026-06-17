module SFPProbe #(
  parameter integer ID = 0,
  parameter integer WIDTH = 32
) (
  input drv_chain,
  input drv_concat_bit,
  input drv_nested_bit,
  input drv_const_chain,
  input drv_decoy_bit,
  output load_chain,
  output [31:0] load_bus,
  output load_orphan
);
  assign load_chain = drv_chain ^ drv_concat_bit ^ drv_nested_bit ^ drv_const_chain ^ drv_decoy_bit;
  assign load_bus = {WIDTH{load_chain}};
  assign load_orphan = 1'b0;
endmodule
