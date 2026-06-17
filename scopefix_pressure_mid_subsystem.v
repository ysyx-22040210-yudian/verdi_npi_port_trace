module SFPMidSubsystem #(
  parameter integer SUBID = 0
) (
  input drv_chain_i,
  input drv_concat_i,
  input drv_nested_i,
  input drv_const_i,
  input drv_decoy_i
);
  wire net;
  wire [4:0] pack0;
  wire [4:0] pack1;
  wire drv_chain_next;
  wire drv_concat_next;
  wire drv_nested_next;
  wire drv_const_next;
  wire drv_decoy_next;

  assign net = drv_chain_i;
  assign pack0 = {drv_nested_i, drv_concat_i, net, drv_const_i, drv_decoy_i};
  assign pack1 = {pack0[4], pack0[2], pack0[3], pack0[1], pack0[0]};
  assign {drv_nested_next, drv_chain_next, drv_concat_next, drv_const_next, drv_decoy_next} = pack1;

  SFPInnerSubsystem #(.SUBID(SUBID)) u_inner(
    .drv_chain_i(drv_chain_next),
    .drv_concat_i(drv_concat_next),
    .drv_nested_i(drv_nested_next),
    .drv_const_i(drv_const_next),
    .drv_decoy_i(drv_decoy_next)
  );
endmodule
