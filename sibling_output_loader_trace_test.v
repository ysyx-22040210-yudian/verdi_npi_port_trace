module SiblingKeyword #(parameter W = 1) (
  input [W-1:0] in,
  output used
);
  assign used = ^in;
endmodule

module SiblingChild (
  output [20:0] a
);
  assign a = 21'h155555;
endmodule

module SiblingParent0 (
  output [20:0] b
);
  SiblingChild u_child(
    .a(b)
  );
endmodule

module SiblingParent1 (
  input [20:0] c,
  output key_b_used,
  output key_c_used,
  output reg [9:0] c_combo_reg
);
  wire [10:0] B;
  wire [9:0] C;
  wire [10:0] B_l1;
  wire [9:0] C_l1;

  assign B = c[10:0];
  assign C = c[20:11];
  assign B_l1 = B;
  assign C_l1 = C;

  SiblingKeyword #(.W(11)) u_key_b(
    .in(B_l1),
    .used(key_b_used)
  );

  SiblingKeyword #(.W(10)) u_key_c(
    .in(C_l1),
    .used(key_c_used)
  );

  always @(*) begin
    c_combo_reg = C_l1;
  end
endmodule

module SiblingProducerWrap (
  output [20:0] out
);
  SiblingParent0 u_p0(
    .b(out)
  );
endmodule

module SiblingConsumerWrap (
  input [20:0] in,
  output key_b_used,
  output key_c_used,
  output [9:0] c_combo_reg
);
  SiblingParent1 u_p1(
    .c(in),
    .key_b_used(key_b_used),
    .key_c_used(key_c_used),
    .c_combo_reg(c_combo_reg)
  );
endmodule

module SiblingConsumerExprWrap (
  input [20:0] in,
  output key_b_used,
  output key_c_used,
  output [9:0] c_combo_reg
);
  SiblingParent1 u_p1_expr(
    .c({in[20:11], in[10:0]}),
    .key_b_used(key_b_used),
    .key_c_used(key_c_used),
    .c_combo_reg(c_combo_reg)
  );
endmodule

module SiblingLoaderTop;
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

  SiblingParent0 u_p0(
    .b(direct_link)
  );

  SiblingParent1 u_p1(
    .c(direct_link),
    .key_b_used(direct_key_b_used),
    .key_c_used(direct_key_c_used),
    .c_combo_reg(direct_c_combo_reg)
  );

  SiblingParent0 u_p0_alias(
    .b(alias_src)
  );
  assign alias_dst = alias_src;
  SiblingParent1 u_p1_alias(
    .c(alias_dst),
    .key_b_used(alias_key_b_used),
    .key_c_used(alias_key_c_used),
    .c_combo_reg(alias_c_combo_reg)
  );

  SiblingProducerWrap u_prod(
    .out(wrap_link)
  );
  SiblingConsumerWrap u_cons(
    .in(wrap_link),
    .key_b_used(wrap_key_b_used),
    .key_c_used(wrap_key_c_used),
    .c_combo_reg(wrap_c_combo_reg)
  );

  SiblingProducerWrap u_prod_expr(
    .out(expr_link)
  );
  SiblingConsumerExprWrap u_cons_expr(
    .in(expr_link),
    .key_b_used(expr_key_b_used),
    .key_c_used(expr_key_c_used),
    .c_combo_reg(expr_c_combo_reg)
  );
endmodule
