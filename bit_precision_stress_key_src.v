module BPStressKeySrc (
  input  wire clk,
  output reg  out
);
  initial out = 1'b0;

  always @(posedge clk) begin
    out <= ~out;
  end
endmodule
