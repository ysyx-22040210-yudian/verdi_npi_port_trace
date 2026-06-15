module DPStressProvider (
  input clk,
  output [31:0] deep_bus,
  output [31:0] bridge_bus,
  output [23:0] lhs_e,
  output [7:0] reg_lane,
  output scalar_key
);
  wire [7:0] deep_lane0_const;
  wire [7:0] deep_lane1_key;
  wire [7:0] deep_lane2_const;
  wire [7:0] deep_lane3_key;
  wire [31:0] deep_pack0;
  wire [31:0] deep_pack1;
  wire [31:0] deep_pack2;

  wire [7:0] bridge_lane0_const;
  wire [7:0] bridge_lane1_key;
  wire [7:0] bridge_lane2_const;
  wire [7:0] bridge_lane3_key;
  wire [31:0] bridge_pack0;
  wire [31:0] bridge_pack1;

  wire [7:0] lhs_b_const;
  wire [7:0] lhs_c_key;
  wire [7:0] lhs_d_const;

  assign deep_lane0_const = 8'h11;
  assign deep_lane2_const = 8'h22;
  DPStressKey #(.W(8), .VALUE(8'hA5)) u_key_deep_lane1(.out(deep_lane1_key));
  DPStressKey #(.W(8), .VALUE(8'h3C)) u_key_deep_lane3(.out(deep_lane3_key));

  assign deep_pack0 = {deep_lane3_key, deep_lane2_const, deep_lane1_key, deep_lane0_const};
  assign deep_pack1[7:0] = deep_pack0[7:0];
  assign deep_pack1[15:8] = deep_pack0[15:8];
  assign deep_pack1[23:16] = deep_pack0[23:16];
  assign deep_pack1[31:24] = deep_pack0[31:24];
  assign deep_pack2[7:0] = deep_pack1[7:0];
  assign deep_pack2[15:8] = deep_pack1[15:8];
  assign deep_pack2[23:16] = deep_pack1[23:16];
  assign deep_pack2[31:24] = deep_pack1[31:24];
  assign deep_bus = deep_pack2;

  assign bridge_lane0_const = 8'h44;
  assign bridge_lane2_const = 8'h55;
  DPStressKey #(.W(8), .VALUE(8'h69)) u_key_bridge_lane1(.out(bridge_lane1_key));
  DPStressKey #(.W(8), .VALUE(8'h96)) u_key_bridge_lane3(.out(bridge_lane3_key));
  assign bridge_pack0 = {bridge_lane3_key, bridge_lane2_const, bridge_lane1_key, bridge_lane0_const};
  assign bridge_pack1[7:0] = bridge_pack0[7:0];
  assign bridge_pack1[15:8] = bridge_pack0[15:8];
  assign bridge_pack1[23:16] = bridge_pack0[23:16];
  assign bridge_pack1[31:24] = bridge_pack0[31:24];
  assign bridge_bus = bridge_pack1;

  assign lhs_b_const = 8'h12;
  assign lhs_d_const = 8'h34;
  DPStressKey #(.W(8), .VALUE(8'h5A)) u_key_lhs_lane(.out(lhs_c_key));
  assign lhs_e = {lhs_b_const, lhs_c_key, lhs_d_const};

  DPStressReg #(.W(8)) u_reg_lane(.clk(clk), .out(reg_lane));
  DPStressKey #(.W(1), .VALUE(1'b1)) u_key_scalar(.out(scalar_key));
endmodule
