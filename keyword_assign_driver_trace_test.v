module KeyMod(
  output out
);
  assign out = 1'b1;
endmodule

module AssignDriverChild(
  input a
);
endmodule

module KeywordAssignDriverTop;
  wire b;
  wire c;

  KeyMod u_key(
    .out(c)
  );

  assign b = c;

  AssignDriverChild u_child(
    .a(b)
  );
endmodule
