module SFPNoiseCluster (
  input net
);
  wire c;
  wire [31:0] bus;

  assign c = net;
  assign bus = {32{net}};

  SFPDecoyConsumer u_decoy0(
    .net(c),
    .bus(bus)
  );

  SFPDecoyConsumer u_decoy1(
    .net(net),
    .bus(~bus)
  );
endmodule
