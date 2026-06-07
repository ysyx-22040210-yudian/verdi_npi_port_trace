module LPFanoutLeaf(
  input [31:0] leaf_in
);
  localparam integer PARAM_LO = 16;

  wire [7:0] direct_slice;
  wire [31:0] alias0;
  wire [31:0] alias1;
  wire [7:0] alias_slice;
  wire [7:0] concat_fanout;
  wire [7:0] lhs_hi;
  wire [7:0] lhs_lo;
  wire [7:0] param_slice;
  wire [7:0] port_expr_mid;
  wire [31:0] gen_bus;
  wire sink_direct_used;
  wire sink_alias_used;
  wire sink_concat_used;
  wire sink_lhs_hi_used;
  wire sink_lhs_lo_used;
  wire sink_param_used;
  wire sink_port_used;
  wire sink_gen2_used;

  assign direct_slice = leaf_in[7:0];
  LPKeySink8 u_sink_direct(
    .in(direct_slice),
    .used(sink_direct_used)
  );

  assign alias0 = leaf_in;
  assign alias1 = alias0;
  assign alias_slice = alias1[15:8];
  LPKeySink8 u_sink_alias(
    .in(alias_slice),
    .used(sink_alias_used)
  );

  assign concat_fanout = {leaf_in[3:0], leaf_in[31:28]};
  LPKeySink8 u_sink_concat(
    .in(concat_fanout),
    .used(sink_concat_used)
  );

  assign {lhs_hi, lhs_lo} = leaf_in[15:0];
  LPKeySink8 u_sink_lhs_hi(
    .in(lhs_hi),
    .used(sink_lhs_hi_used)
  );
  LPKeySink8 u_sink_lhs_lo(
    .in(lhs_lo),
    .used(sink_lhs_lo_used)
  );

  assign param_slice = leaf_in[PARAM_LO +: 8];
  LPKeySink8 u_sink_param(
    .in(param_slice),
    .used(sink_param_used)
  );

  LPPass8 u_port_expr(
    .in(leaf_in[31:24]),
    .out(port_expr_mid)
  );
  LPKeySink8 u_sink_port(
    .in(port_expr_mid),
    .used(sink_port_used)
  );

  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g
      assign gen_bus[gi*8 +: 8] = leaf_in[gi*8 +: 8];
    end
  endgenerate
  LPKeySink8 u_sink_gen2(
    .in(gen_bus[23:16]),
    .used(sink_gen2_used)
  );
endmodule
