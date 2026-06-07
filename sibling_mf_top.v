module SiblingMfTop;
  wire [20:0] direct_link;
  wire direct_key_b_used;
  wire direct_key_c_used;
  wire [9:0] direct_c_combo_reg;

  wire [20:0] alias_src;
  wire [20:0] alias_dst;
  wire alias_key_b_used;
  wire alias_key_c_used;
  wire [9:0] alias_c_combo_reg;

  wire [20:0] wrap_link;
  wire wrap_key_b_used;
  wire wrap_key_c_used;
  wire [9:0] wrap_c_combo_reg;

  wire [20:0] expr_link;
  wire expr_key_b_used;
  wire expr_key_c_used;
  wire [9:0] expr_c_combo_reg;

  wire [20:0] gen_link;
  wire gen_key_b_used;
  wire gen_key_c_used;
  wire [9:0] gen_c_combo_reg;

  SiblingMfParent0 u_p0(
    .b(direct_link)
  );

  SiblingMfParent1 u_p1(
    .c(direct_link),
    .key_b_used(direct_key_b_used),
    .key_c_used(direct_key_c_used),
    .c_combo_reg(direct_c_combo_reg)
  );

  SiblingMfParent0 u_p0_alias(
    .b(alias_src)
  );
  assign alias_dst = alias_src;
  SiblingMfParent1 u_p1_alias(
    .c(alias_dst),
    .key_b_used(alias_key_b_used),
    .key_c_used(alias_key_c_used),
    .c_combo_reg(alias_c_combo_reg)
  );

  SiblingMfProducerWrap u_prod(
    .out(wrap_link)
  );
  SiblingMfConsumerWrap u_cons(
    .in(wrap_link),
    .key_b_used(wrap_key_b_used),
    .key_c_used(wrap_key_c_used),
    .c_combo_reg(wrap_c_combo_reg)
  );

  SiblingMfProducerWrap u_prod_expr(
    .out(expr_link)
  );
  SiblingMfConsumerExprWrap u_cons_expr(
    .in(expr_link),
    .key_b_used(expr_key_b_used),
    .key_c_used(expr_key_c_used),
    .c_combo_reg(expr_c_combo_reg)
  );

  SiblingMfParent0 u_p0_gen(
    .b(gen_link)
  );

  genvar gi;
  generate
    for (gi = 0; gi < 1; gi = gi + 1) begin : g_cons
      SiblingMfParent1 u_p1_gen(
        .c(gen_link),
        .key_b_used(gen_key_b_used),
        .key_c_used(gen_key_c_used),
        .c_combo_reg(gen_c_combo_reg)
      );
    end
  endgenerate
endmodule
