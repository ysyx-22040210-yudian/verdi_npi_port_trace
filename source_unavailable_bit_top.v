module SourceUnavailableBitTop;
  wire [7:0] descending_bus;
  wire [0:7] ascending_bus;
  wire [7:0] descending_literal;
  wire [0:7] ascending_literal;

  assign descending_literal = 8'b10000000;
  assign ascending_literal = 8'b10000000;

  SourceUnavailableBitDriver #(.INIT(1'b1)) u_a7_driver(
    .out(descending_bus[7])
  );
  SourceUnavailableBitDriver #(.INIT(1'b0)) u_a6_driver(
    .out(descending_bus[6])
  );
  SourceUnavailableBitDriver #(.INIT(1'b1)) u_b0_driver(
    .out(ascending_bus[0])
  );
  SourceUnavailableBitDriver #(.INIT(1'b0)) u_b1_driver(
    .out(ascending_bus[1])
  );

  SourceUnavailableBitChild u_child(
    .A(descending_bus),
    .B(ascending_bus),
    .C(descending_literal),
    .D(ascending_literal)
  );
endmodule
