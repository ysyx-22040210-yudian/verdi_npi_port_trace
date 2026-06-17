module LDPSProducerParent (
  input clk,
  output net
);
  LDPSChild0 u_child0 (
    .clk(clk),
    .a(net)
  );
endmodule

module LDPSConsumerParent (
  input clk,
  input net,
  output used
);
  LDPSChild1 u_child1 (
    .clk(clk),
    .b(net),
    .used(used)
  );
endmodule

module LDPSSubsystem (
  input clk,
  output used
);
  wire net;
  wire prod_shadow;
  wire cons_used;

  LDPSProducerParent u_parent0 (
    .clk(clk),
    .net(net)
  );

  assign prod_shadow = net;

  LDPSConsumerParent u_parent1 (
    .clk(clk),
    .net(prod_shadow),
    .used(cons_used)
  );

  assign used = cons_used;
endmodule
