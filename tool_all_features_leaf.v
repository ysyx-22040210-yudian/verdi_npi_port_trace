module TAFLeaf #(parameter LEAF_ID = 0, parameter BASE = 8) (
  input [15:0] leaf_in,
  output leaf_out
);
  wire [3:0] direct_slice;
  wire [15:0] alias0;
  wire [15:0] alias1;
  wire [3:0] alias_slice;
  wire [3:0] concat_fanout;
  wire [3:0] lhs_hi;
  wire [3:0] lhs_lo;
  wire [3:0] param_slice;
  wire [3:0] port_expr_mid;
  wire [15:0] gen_bus;
  wire sink_direct_used;
  wire sink_alias_used;
  wire sink_concat_used;
  wire sink_lhs_hi_used;
  wire sink_lhs_lo_used;
  wire sink_param_used;
  wire sink_port_used;
  wire sink_gen2_used;

  assign direct_slice = leaf_in[3:0];
  TAFKeySink #(.W(4)) u_sink_direct(.in(direct_slice), .used(sink_direct_used));

  assign alias0 = leaf_in;
  assign alias1 = alias0;
  assign alias_slice = alias1[7:4];
  TAFKeySink #(.W(4)) u_sink_alias(.in(alias_slice), .used(sink_alias_used));

  assign concat_fanout = {leaf_in[1:0], leaf_in[15:14]};
  TAFKeySink #(.W(4)) u_sink_concat(.in(concat_fanout), .used(sink_concat_used));

  assign {lhs_hi, lhs_lo} = leaf_in[7:0];
  TAFKeySink #(.W(4)) u_sink_lhs_hi(.in(lhs_hi), .used(sink_lhs_hi_used));
  TAFKeySink #(.W(4)) u_sink_lhs_lo(.in(lhs_lo), .used(sink_lhs_lo_used));

  assign param_slice = leaf_in[BASE +: 4];
  TAFKeySink #(.W(4)) u_sink_param(.in(param_slice), .used(sink_param_used));

  TAFPass #(.W(4)) u_port_expr(.i(leaf_in[15:12]), .o(port_expr_mid));
  TAFKeySink #(.W(4)) u_sink_port(.in(port_expr_mid), .used(sink_port_used));

  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g
      assign gen_bus[gi*4 +: 4] = leaf_in[gi*4 +: 4];
    end
  endgenerate
  TAFKeySink #(.W(4)) u_sink_gen2(.in(gen_bus[11:8]), .used(sink_gen2_used));

  assign leaf_out = leaf_in[0];
endmodule
