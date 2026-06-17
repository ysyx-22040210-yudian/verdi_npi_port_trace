module LCSAliasStage1 (
  input net_i,
  input [20:0] bus_i,
  output net_o,
  output [20:0] bus_o
);
  wire bridge_net;
  wire [20:0] bridge_bus;

  assign bridge_net = net_i;
  assign bridge_bus[10:0] = bus_i[10:0];
  assign bridge_bus[20:11] = bus_i[20:11];
  assign net_o = bridge_net;
  assign bus_o = bridge_bus;
endmodule
