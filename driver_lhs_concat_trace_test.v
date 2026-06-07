module DriverLhsConcatKeyword(
  output [3:0] out
);
  assign out = 4'hA;
endmodule

module DriverLhsConcatRegSource(
  input clk,
  output reg [3:0] out
);
  always @(posedge clk) begin
    out <= 4'h5;
  end
endmodule

module DriverLhsConcatChild(
  input [3:0] a,
  input [3:0] a_reg
);
endmodule

module DriverLhsConcatParent0(
  input [3:0] c,
  input [3:0] c_reg
);
  DriverLhsConcatChild u_child(
    .a(c),
    .a_reg(c_reg)
  );
endmodule

module DriverLhsConcatParent1(
  input clk,
  output [11:0] e,
  output [11:0] e_reg
);
  wire [3:0] f;
  wire [3:0] g;
  wire [3:0] h;
  wire [3:0] k;

  wire [3:0] f_reg;
  wire [3:0] g_reg;
  wire [3:0] h_reg;
  wire [3:0] k_reg;

  DriverLhsConcatKeyword u_key(
    .out(h)
  );

  DriverLhsConcatRegSource u_reg_src(
    .clk(clk),
    .out(h_reg)
  );

  assign f = 4'h1;
  assign g = 4'h2;
  assign k = 4'h3;
  assign e = {f, g, h, k};

  assign f_reg = 4'h4;
  assign g_reg = 4'h5;
  assign k_reg = 4'h6;
  assign e_reg = {f_reg, g_reg, h_reg, k_reg};
endmodule

module DriverLhsConcatTop;
  reg clk;
  wire [3:0] b;
  wire [3:0] c;
  wire [3:0] d;
  wire [11:0] e;

  wire [3:0] b_reg;
  wire [3:0] c_reg;
  wire [3:0] d_reg;
  wire [11:0] e_reg;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  DriverLhsConcatParent1 u_p1(
    .clk(clk),
    .e(e),
    .e_reg(e_reg)
  );

  assign {b, c, d} = e;
  assign {b_reg, c_reg, d_reg} = e_reg;

  DriverLhsConcatParent0 u_p0(
    .c(c),
    .c_reg(c_reg)
  );
endmodule
