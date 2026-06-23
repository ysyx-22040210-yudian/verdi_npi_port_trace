module TDTernaryTop(
  input wire clk,
  input wire c_plain
);
  wire bad_a;
  wire good_a;
  wire cond_reg;
  wire data_reg;

  TDKeySrc u_cond_reg(
    .clk(clk),
    .out(cond_reg)
  );

  TDKeySrc u_data_reg(
    .clk(clk),
    .out(data_reg)
  );

  assign bad_a = cond_reg ? c_plain : 1'b1;
  assign good_a = c_plain ? data_reg : 1'b0;

  TDChild u_child(
    .bad_a(bad_a),
    .good_a(good_a)
  );
endmodule
