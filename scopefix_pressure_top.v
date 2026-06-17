module ScopeFixPressureTop;
  wire drv_chain_top;
  wire drv_concat_bit_top;
  wire drv_nested_bit_top;
  wire drv_const_chain_top;
  wire drv_decoy_bit_top;
  wire net;

  SFPDriverProvider u_driver(
    .drv_chain(drv_chain_top),
    .drv_concat_bit(drv_concat_bit_top),
    .drv_nested_bit(drv_nested_bit_top),
    .drv_const_chain(drv_const_chain_top),
    .drv_decoy_bit(drv_decoy_bit_top)
  );

  assign net = drv_decoy_bit_top;

  SFPCluster #(.CLUSTER_ID(0)) u_cluster0(
    .drv_chain_i(drv_chain_top),
    .drv_concat_i(drv_concat_bit_top),
    .drv_nested_i(drv_nested_bit_top),
    .drv_const_i(drv_const_chain_top),
    .drv_decoy_i(drv_decoy_bit_top)
  );

  SFPCluster #(.CLUSTER_ID(1)) u_cluster1(
    .drv_chain_i(drv_chain_top),
    .drv_concat_i(drv_concat_bit_top),
    .drv_nested_i(drv_nested_bit_top),
    .drv_const_i(drv_const_chain_top),
    .drv_decoy_i(drv_decoy_bit_top)
  );

  SFPNoiseCluster u_noise0(
    .net(net)
  );

  SFPNoiseCluster u_noise1(
    .net(drv_const_chain_top)
  );
endmodule
