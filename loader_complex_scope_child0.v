module LCSChild0 (
  input clk,
  input rst_n,
  output a,
  output [20:0] data_o
);
  reg q;
  reg [19:0] counter;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q <= 1'b0;
      counter <= 20'h0;
    end else begin
      q <= ~q;
      counter <= counter + 20'h1;
    end
  end

  assign a = q;
  assign data_o = {q, counter};
endmodule
