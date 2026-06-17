module TAFRegSource #(parameter W = 8) (
  input clk,
  output reg [W-1:0] out
);
  initial begin
    out = {W{1'b0}};
  end

  always @(posedge clk) begin
    out <= out + {{(W-1){1'b0}}, 1'b1};
  end
endmodule
