module SiblingMfProducerWrap (
  output [20:0] out
);
  SiblingMfParent0 u_p0(
    .b(out)
  );
endmodule

module SiblingMfConsumerWrap (
  input [20:0] in,
  output key_b_used,
  output key_c_used,
  output [9:0] c_combo_reg
);
  SiblingMfParent1 u_p1(
    .c(in),
    .key_b_used(key_b_used),
    .key_c_used(key_c_used),
    .c_combo_reg(c_combo_reg)
  );
endmodule

module SiblingMfConsumerExprWrap (
  input [20:0] in,
  output key_b_used,
  output key_c_used,
  output [9:0] c_combo_reg
);
  SiblingMfParent1 u_p1_expr(
    .c({in[20:11], in[10:0]}),
    .key_b_used(key_b_used),
    .key_c_used(key_c_used),
    .c_combo_reg(c_combo_reg)
  );
endmodule
