module DPStressParent0 (
  input [31:0] deep_in,
  input [31:0] precise_in,
  input [31:0] bridge_in,
  input [7:0] lhs_in,
  input [7:0] reg_in,
  input scalar_in
);
  wire [31:0] deep_alias0;
  wire [31:0] deep_alias1;
  wire [31:0] precise_alias0;
  wire [31:0] precise_alias1;
  wire [31:0] bridge_alias0;
  wire [31:0] bridge_alias1;
  wire [7:0] lhs_alias0;
  wire [7:0] reg_alias0;
  wire scalar_alias0;
  wire scalar_alias1;

  assign deep_alias0 = deep_in[31:0];
  assign deep_alias1 = deep_alias0;

  assign precise_alias0 = precise_in[31:0];
  assign precise_alias1[10:0] = precise_alias0[10:0];
  assign precise_alias1[31:11] = precise_alias0[31:11];

  assign bridge_alias0 = bridge_in;
  assign bridge_alias1[7:0] = bridge_alias0[7:0];
  assign bridge_alias1[15:8] = bridge_alias0[15:8];
  assign bridge_alias1[23:16] = bridge_alias0[23:16];
  assign bridge_alias1[31:24] = bridge_alias0[31:24];

  assign lhs_alias0 = lhs_in[7:0];
  assign reg_alias0 = reg_in[7:0];
  assign scalar_alias0 = scalar_in;
  assign scalar_alias1 = scalar_alias0;

  DPStressChild u_child(
    .deep_bus(deep_alias1[31:0]),
    .precise_bus(precise_alias1[31:0]),
    .bridge_bus(bridge_alias1[31:0]),
    .lhs_lane(lhs_alias0[7:0]),
    .reg_lane(reg_alias0[7:0]),
    .scalar_passthru(scalar_alias1)
  );
endmodule

module DPStressParent1 (
  input [31:0] deep_from_sub,
  input [31:0] precise_from_sub,
  input [31:0] bridge_from_sub,
  input [7:0] lhs_from_sub,
  input [7:0] reg_from_sub,
  input scalar_from_sub
);
  wire [31:0] deep_mid0;
  wire [31:0] precise_mid0;
  wire [31:0] bridge_mid0;
  wire [7:0] lhs_mid0;
  wire [7:0] reg_mid0;
  wire scalar_mid0;

  assign deep_mid0 = deep_from_sub;
  assign precise_mid0 = precise_from_sub;
  assign bridge_mid0 = bridge_from_sub;
  assign lhs_mid0 = lhs_from_sub;
  assign reg_mid0 = reg_from_sub;
  assign scalar_mid0 = scalar_from_sub;

  DPStressParent0 u_p0(
    .deep_in(deep_mid0[31:0]),
    .precise_in(precise_mid0[31:0]),
    .bridge_in(bridge_mid0[31:0]),
    .lhs_in(lhs_mid0[7:0]),
    .reg_in(reg_mid0[7:0]),
    .scalar_in(scalar_mid0)
  );
endmodule
