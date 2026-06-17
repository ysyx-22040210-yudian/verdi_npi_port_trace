module SFPSiblingBridge (
  input c,
  input [31:0] bus,
  input orphan
);
  wire mid0;
  wire mid1;
  wire [31:0] bus_mid0;
  wire [31:0] bus_mid1;

  SFPLoaderStage0 u_stage0(
    .net(c),
    .mid(mid0)
  );

  SFPLoaderStage1 u_stage1(
    .mid(mid0),
    .out(mid1)
  );

  assign bus_mid0 = bus;
  assign bus_mid1 = bus_mid0;

  SFPLoaderConsumer u_consumer(
    .c(mid1),
    .bus(bus_mid1),
    .orphan(orphan)
  );
endmodule
