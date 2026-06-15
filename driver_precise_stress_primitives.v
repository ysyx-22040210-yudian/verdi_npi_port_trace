module DPStressKey #(parameter W = 1, parameter VALUE = 0) (
  output [W-1:0] out
);
  assign out = VALUE;
endmodule

module DPStressPass #(parameter W = 1) (
  input [W-1:0] in,
  output [W-1:0] out
);
  assign out = in;
endmodule

module DPStressReg #(parameter W = 8) (
  input clk,
  output reg [W-1:0] out
);
  initial begin
    out = {W{1'b0}};
  end

  always @(posedge clk) begin
    out <= {W{1'b1}};
  end
endmodule

module DPStressChild (
  input [31:0] deep_bus,
  input [31:0] precise_bus,
  input [31:0] bridge_bus,
  input [7:0] lhs_lane,
  input [7:0] reg_lane,
  input scalar_passthru
);
endmodule
