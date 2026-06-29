module BPStressRegSink (
  input wire clk,
  input wire in
);
  reg q;

  always @(posedge clk) begin
    q <= in;
  end
endmodule
