module LPMidBridge(
  input [31:0] mid_in,
  output [31:0] mid_out
);
  wire [31:0] mid_stage0;
  wire [31:0] mid_stage1;

  assign mid_stage0 = mid_in;
  assign mid_stage1 = mid_stage0;
  assign mid_out = mid_stage1;
endmodule

module LPSubsystem(
  input [31:0] sub_in
);
  wire [31:0] sub_alias0;
  wire [31:0] sub_alias1;

  assign sub_alias0 = sub_in;
  assign sub_alias1 = sub_alias0;

  LPFanoutLeaf u_leaf(
    .leaf_in(sub_alias1)
  );
endmodule

module LPRootWrap(
  input [31:0] root_in
);
  wire [31:0] root_alias0;
  wire [31:0] root_alias1;
  wire [31:0] bridge_out;

  assign root_alias0 = root_in;
  assign root_alias1 = root_alias0;

  LPMidBridge u_mid(
    .mid_in(root_alias1),
    .mid_out(bridge_out)
  );

  LPSubsystem u_sub(
    .sub_in(bridge_out)
  );
endmodule
