module CFRegSource (
  input clk,
  output reg q
);
  always @(posedge clk) begin
    q <= ~q;
  end
endmodule
