module SFPCluster #(
  parameter integer CLUSTER_ID = 0
) (
  input drv_chain_i,
  input drv_concat_i,
  input drv_nested_i,
  input drv_const_i,
  input drv_decoy_i
);
  wire net;
  wire [4:0] bus;

  assign net = drv_chain_i;
  assign bus = {drv_nested_i, drv_concat_i, net, drv_const_i, drv_decoy_i};

  SFPMidSubsystem #(.SUBID(CLUSTER_ID * 10 + 0)) u_path0(
    .drv_chain_i(bus[2]),
    .drv_concat_i(bus[3]),
    .drv_nested_i(bus[4]),
    .drv_const_i(bus[1]),
    .drv_decoy_i(bus[0])
  );

  SFPMidSubsystem #(.SUBID(CLUSTER_ID * 10 + 1)) u_path1(
    .drv_chain_i(bus[2]),
    .drv_concat_i(bus[3]),
    .drv_nested_i(bus[4]),
    .drv_const_i(bus[1]),
    .drv_decoy_i(bus[0])
  );
endmodule
