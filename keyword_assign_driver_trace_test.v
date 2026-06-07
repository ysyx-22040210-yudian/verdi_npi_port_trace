module KeyMod(
  output out
);
  assign out = 1'b1;
endmodule

module AssignDriverChild(
  input a
);
endmodule

module KeyParent(
  output out
);
  KeyMod u_key_nested(
    .out(out)
  );
endmodule

module KeywordAssignDriverTop;
  wire b;
  wire c;
  wire b_nested;
  wire c_nested;

  KeyMod u_key(
    .out(c)
  );

  assign b = c;

  AssignDriverChild u_child_direct(
    .a(b)
  );

  KeyParent u_parent(
    .out(c_nested)
  );

  assign b_nested = c_nested;

  AssignDriverChild u_child_nested(
    .a(b_nested)
  );
endmodule
