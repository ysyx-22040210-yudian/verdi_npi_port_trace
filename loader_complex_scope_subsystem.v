module LCSSubsystem (
  input clk,
  input rst_n,
  output used
);
  wire net;
  wire [20:0] bus;
  wire net_stage0;
  wire [20:0] bus_stage0;
  wire net_stage1;
  wire [20:0] bus_stage1;
  wire net_final;
  wire [20:0] bus_final;
  wire keyword_used;
  wire decoy_used;

  LCSProducerParent u_parent0 (
    .clk(clk),
    .rst_n(rst_n),
    .net(net),
    .bus(bus)
  );

  LCSAliasStage0 u_alias0 (
    .net_i(net),
    .bus_i(bus),
    .net_o(net_stage0),
    .bus_o(bus_stage0)
  );

  LCSAliasStage1 u_alias1 (
    .net_i(net_stage0),
    .bus_i(bus_stage0),
    .net_o(net_stage1),
    .bus_o(bus_stage1)
  );

  assign net_final = net_stage1;
  assign bus_final = {bus_stage1[20:11], bus_stage1[10:0]};

  LCSConsumerParent u_parent1 (
    .clk(clk),
    .rst_n(rst_n),
    .net(net_final),
    .bus(bus_final),
    .used(keyword_used)
  );

  LCSDecoyConsumer u_decoy (
    .net(net),
    .bus(bus),
    .used(decoy_used)
  );

  assign used = keyword_used | decoy_used;
endmodule
