module TAFRegSink #(parameter W = 1) (
  input clk,
  input [W-1:0] in,
  output reg used
);
  initial begin
    used = 1'b0;
  end

  always @(posedge clk) begin
    used <= ^in;
  end
endmodule
