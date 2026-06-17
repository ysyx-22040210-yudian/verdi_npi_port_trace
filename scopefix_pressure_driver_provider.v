module SFPDriverProvider (
  output drv_chain,
  output drv_concat_bit,
  output drv_nested_bit,
  output drv_const_chain,
  output drv_decoy_bit
);
  wire key_scalar;
  wire key_after_pass;
  wire [7:0] key_vec0;
  wire [7:0] key_vec1;
  wire [7:0] concat_l0;
  wire [7:0] concat_l1;
  wire [3:0] low_noise;
  wire [3:0] high_noise;
  wire c;
  wire b;
  wire d;
  wire [3:0] nested_l0;
  wire [3:0] nested_l1;
  wire [3:0] nested_l2;
  wire [3:0] nested_l3;
  wire [15:0] nested_pack0;
  wire [15:0] nested_pack1;
  wire const_mid0;
  wire const_mid1;
  wire decoy_mid0;
  wire decoy_mid1;

  SFPKeySrc #(.ID(1), .WIDTH(1)) u_key_scalar(
    .out(key_scalar)
  );

  SFPPass1 u_pass_scalar(
    .in(key_scalar),
    .out(key_after_pass)
  );

  SFPDriverWrap1 u_wrap1(
    .in(key_after_pass),
    .out(drv_chain)
  );

  SFPKeySrc #(.ID(2), .WIDTH(8)) u_key_vec0(
    .out(key_vec0)
  );

  SFPKeySrc #(.ID(3), .WIDTH(8)) u_key_vec1(
    .out(key_vec1)
  );

  assign low_noise = 4'b0011;
  assign high_noise = 4'b1100;
  assign concat_l0 = {key_vec0[2:0], 1'b0, low_noise};
  assign concat_l1 = {high_noise, key_vec1[3:1], concat_l0[3]};
  assign {b, c, d} = {concat_l1[7], concat_l1[3], concat_l0[0]};
  assign drv_concat_bit = c;

  SFPKeySrc #(.ID(4), .WIDTH(4)) u_key_nested(
    .out(nested_l0)
  );

  assign nested_pack0 = {4'b0101, nested_l0, 4'b1010, 4'b0010};
  assign nested_l1 = nested_pack0[11:8];
  assign nested_pack1 = {nested_l1, 4'b1110, 4'b0001, 4'b0110};
  assign {nested_l2, nested_l3, drv_nested_bit, const_mid0, const_mid1, decoy_mid0, decoy_mid1, drv_const_chain} =
         {nested_pack1[15:12], nested_pack1[11:8], nested_pack1[14], 1'b0, 1'b1, nested_pack1[1], nested_pack1[0], 1'b0};

  assign drv_decoy_bit = decoy_mid0 & decoy_mid1;
endmodule
