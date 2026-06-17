module LCSAliasStage0 (
  input net_i,
  input [20:0] bus_i,
  output net_o,
  output [20:0] bus_o
);
  wire mid_net;
  wire [20:0] mid_bus;

  assign mid_net = net_i;
  assign mid_bus = bus_i;
  assign net_o = mid_net;
  assign bus_o = {mid_bus[10:0], mid_bus[20:11]};
endmodule
