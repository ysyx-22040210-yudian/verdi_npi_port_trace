module DPStressSubsystem (
  input clk,
  input [31:0] top_bridge_in,
  input top_scalar_in
);
  wire [31:0] deep_provider_bus;
  wire [31:0] bridge_provider_bus;
  wire [23:0] lhs_e;
  wire [7:0] reg_provider_lane;
  wire provider_scalar_key;

  wire [7:0] lhs_b;
  wire [7:0] lhs_c;
  wire [7:0] lhs_d;

  wire [31:0] precise_bus;
  wire [31:0] precise_alias0;
  wire [6:0] precise_b;
  wire precise_c;
  wire [2:0] precise_d;
  wire [3:0] precise_c_vec;

  wire [31:0] deep_sub_alias0;
  wire [31:0] deep_sub_alias1;
  wire [31:0] bridge_sub_alias0;
  wire [31:0] bridge_sub_alias1;
  wire [7:0] lhs_sub_alias0;
  wire [7:0] reg_sub_alias0;
  wire scalar_sub_alias0;
  wire scalar_sub_alias1;

  DPStressProvider u_local_provider(
    .clk(clk),
    .deep_bus(deep_provider_bus),
    .bridge_bus(bridge_provider_bus),
    .lhs_e(lhs_e),
    .reg_lane(reg_provider_lane),
    .scalar_key(provider_scalar_key)
  );

  assign {lhs_b, lhs_c, lhs_d} = lhs_e;

  assign precise_b = 7'b0101010;
  assign precise_d = 3'b101;
  DPStressKey #(.W(4), .VALUE(4'h9)) u_key_precise(.out(precise_c_vec));
  assign precise_c = precise_c_vec[0];
  assign precise_bus[10:0] = {precise_d[2:0], precise_c, precise_b[6:0]};
  assign precise_bus[31:11] = {deep_provider_bus[31:24], bridge_provider_bus[23:16], 5'b10101};
  assign precise_alias0 = precise_bus[31:0];

  assign deep_sub_alias0 = deep_provider_bus;
  assign deep_sub_alias1 = deep_sub_alias0;

  assign bridge_sub_alias0 = top_bridge_in[31:0];
  assign bridge_sub_alias1 = bridge_sub_alias0;

  assign lhs_sub_alias0 = lhs_c[7:0];
  assign reg_sub_alias0 = reg_provider_lane[7:0];
  assign scalar_sub_alias0 = provider_scalar_key;
  assign scalar_sub_alias1 = scalar_sub_alias0;

  DPStressParent1 u_p1(
    .deep_from_sub(deep_sub_alias1[31:0]),
    .precise_from_sub(precise_alias0[31:0]),
    .bridge_from_sub(bridge_sub_alias1[31:0]),
    .lhs_from_sub(lhs_sub_alias0[7:0]),
    .reg_from_sub(reg_sub_alias0[7:0]),
    .scalar_from_sub(scalar_sub_alias1)
  );
endmodule

module DPStressTop;
  reg clk;
  wire [31:0] top_deep_unused;
  wire [31:0] top_bridge_bus;
  wire [23:0] top_lhs_unused;
  wire [7:0] top_reg_unused;
  wire top_scalar_key;

  initial begin
    clk = 1'b0;
  end

  always #5 clk = ~clk;

  DPStressProvider u_top_provider(
    .clk(clk),
    .deep_bus(top_deep_unused),
    .bridge_bus(top_bridge_bus),
    .lhs_e(top_lhs_unused),
    .reg_lane(top_reg_unused),
    .scalar_key(top_scalar_key)
  );

  DPStressSubsystem u_sub(
    .clk(clk),
    .top_bridge_in(top_bridge_bus[31:0]),
    .top_scalar_in(top_scalar_key)
  );
endmodule
