module LoaderScopeChild0 (
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
