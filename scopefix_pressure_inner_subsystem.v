module SFPInnerSubsystem #(
  parameter integer SUBID = 0
) (
  input drv_chain_i,
  input drv_concat_i,
  input drv_nested_i,
  input drv_const_i,
  input drv_decoy_i
);
  wire net;
  wire c;
  wire [31:0] bus;
  wire load_orphan;
  wire load_chain;
  wire [31:0] load_bus;
  wire drv_chain_local;
  wire drv_concat_local;
  wire drv_nested_local;
  wire drv_const_local;
  wire drv_decoy_local;
  wire decoy_net;
  wire [31:0] decoy_bus;

  assign drv_chain_local = drv_chain_i;
  assign drv_concat_local = drv_concat_i;
  assign drv_nested_local = drv_nested_i;
  assign drv_const_local = drv_const_i;
  assign drv_decoy_local = drv_decoy_i;

  SFPProbe #(.ID(SUBID), .WIDTH(32)) u_probe(
    .drv_chain(drv_chain_local),
    .drv_concat_bit(drv_concat_local),
    .drv_nested_bit(drv_nested_local),
    .drv_const_chain(drv_const_local),
    .drv_decoy_bit(drv_decoy_local),
    .load_chain(load_chain),
    .load_bus(load_bus),
    .load_orphan(load_orphan)
  );

  assign net = load_chain;
  assign c = net;
  assign bus = load_bus;

  SFPSiblingBridge u_sibling(
    .c(c),
    .bus(bus),
    .orphan(load_orphan)
  );

  assign decoy_net = drv_decoy_local;
  assign decoy_bus = {32{drv_decoy_local}};

  SFPDecoyConsumer u_decoy(
    .net(decoy_net),
    .bus(decoy_bus)
  );
endmodule
