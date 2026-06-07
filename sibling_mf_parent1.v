module SiblingMfParent1 (
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

  SiblingMfKeyword #(.W(11)) u_key_b(
    .in(B_l1),
    .used(key_b_used)
  );

  SiblingMfKeyword #(.W(10)) u_key_c(
    .in(C_l1),
    .used(key_c_used)
  );

  always @(*) begin
    c_combo_reg = C_l1;
  end
endmodule
