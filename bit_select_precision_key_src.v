module BSPKeySrc (
  input clk,
  output reg out
);
  always @(posedge clk) begin
    out <= ~out;
  end
endmodule
