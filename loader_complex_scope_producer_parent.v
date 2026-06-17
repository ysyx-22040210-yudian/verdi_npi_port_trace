module LCSProducerParent (
  input clk,
  input rst_n,
  output net,
  output [20:0] bus
);
  LCSChild0 u_child0 (
    .clk(clk),
    .rst_n(rst_n),
    .a(net),
    .data_o(bus)
  );
endmodule
