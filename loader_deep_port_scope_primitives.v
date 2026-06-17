module LDPSKeyword (
  input in,
  output used
);
  assign used = in;
endmodule

module LDPSChild0 (
  input clk,
  output a
);
  reg q;

  initial begin
    q = 1'b0;
  end

  always @(posedge clk) begin
    q <= ~q;
  end

  assign a = q;
endmodule

module LDPSChild1 (
  input clk,
  input b,
  output used
);
  reg rb;
  wire keyword_used;

  initial begin
    rb = 1'b0;
  end

  always @(posedge clk) begin
    rb <= b;
  end

  LDPSKeyword u_key (
    .in(b),
    .used(keyword_used)
  );

  assign used = rb | keyword_used;
endmodule
