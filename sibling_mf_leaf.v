module SiblingMfKeyword #(parameter W = 1) (
  input [W-1:0] in,
  output used
);
  assign used = ^in;
endmodule

module SiblingMfChild (
  output [20:0] a
);
  assign a = 21'h123456;
endmodule

module SiblingMfParent0 (
  output [20:0] b
);
  SiblingMfChild u_child(
    .a(b)
  );
endmodule
