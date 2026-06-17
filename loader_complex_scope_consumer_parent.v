module LCSConsumerParent (
  input clk,
  input rst_n,
  input net,
  input [20:0] bus,
  output used
);
  wire net_alias;
  wire [20:0] bus_alias;

  assign net_alias = net;
  assign bus_alias = {bus[20:11], bus[10:0]};

  LCSChild1 u_child1 (
    .clk(clk),
    .rst_n(rst_n),
    .b(net_alias),
    .bus_i(bus_alias),
    .used(used)
  );
endmodule
