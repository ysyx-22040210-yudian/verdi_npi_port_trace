module SFPDriverWrap0 (
  input in,
  output out
);
  wire net;

  SFPDriverLeaf u_leaf(
    .drv_stage_i(in),
    .drv_stage_o(net)
  );

  assign out = net;
endmodule
