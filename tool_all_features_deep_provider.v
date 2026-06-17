module TAFDeepProvider (
  output [15:0] deep_e
);
  wire [3:0] lane_f_const;
  wire [3:0] lane_h_key;
  wire [3:0] lane_g_const;
  wire [3:0] lane_k_const;
  wire [15:0] pack0;
  wire [15:0] pack1;

  assign lane_f_const = 4'h1;
  assign lane_g_const = 4'h2;
  assign lane_k_const = 4'h3;
  TAFKeySrc #(.W(4), .VALUE(4'ha)) u_key_deep_h(.out(lane_h_key));

  assign pack0 = {lane_f_const, lane_h_key, lane_g_const, lane_k_const};
  assign pack1[3:0] = pack0[3:0];
  assign pack1[7:4] = pack0[7:4];
  assign pack1[11:8] = pack0[11:8];
  assign pack1[15:12] = pack0[15:12];
  assign deep_e = pack1;
endmodule
