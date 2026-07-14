module DCP_ConstOne (
  output wire out
);
  assign out = 1'b1;
endmodule

module DCP_ConstZeroDecoy (
  output wire out
);
  assign out = 1'b0;
endmodule

module DCP_Top;
  reg sel;
  wire out;
  wire decoy_out;
  wire generate_out;
  wire param_out;
  wire implicit_inactive;
  wire ifdef_out;
  wire [1:0] desc;
  wire [0:7] asc;
  wire [0:7] asc_whole;
  wire [0:7] symbolic_asc;
  wire [7:0] desc_port_source;
  wire [0:7] asc_assign_from_desc;
  wire [0:7] asc_from_child_desc;
  wire [0:7] asc_decl_init = 8'b10000000;
  wire mux_out;

  assign desc_port_source = 8'b10000000;
  assign asc_assign_from_desc = desc_port_source;

  DCP_ConstOne u_one(.out(out));
  DCP_ConstZeroDecoy u_decoy(.out(decoy_out));
  DCP_GenerateSource #(.ONE(1)) u_generate(.out(generate_out));
  DCP_ParamSource #(.VALUE(1'b1)) u_param(.out(param_out));
  DCP_ImplicitGenerateSource #(.ONE(1'b0)) u_implicit(.inactive(implicit_inactive));
  DCP_IfdefSource u_ifdef(.out(ifdef_out));
  DCP_RangeSource u_range(.desc(desc), .asc(asc), .asc_whole(asc_whole));
  DCP_SymbolicAscSource #(.W(8)) u_symbolic_asc(.out(symbolic_asc));
  DCP_DescVectorSource u_desc_vector(.out(asc_from_child_desc));
  DCP_MuxSource u_mux(.sel(sel), .out(mux_out));

  DCP_Target u_target (
    .scope_const(out),
    .generate_const(generate_out),
    .param_const(param_out),
    .ifdef_const(ifdef_out),
    .range_bit0(desc[0]),
    .range_bit1(desc[1]),
    .asc_bit0(asc[0]),
    .asc_bit7(asc[7]),
    .asc_whole0(asc_whole[0]),
    .asc_whole7(asc_whole[7]),
    .symbolic_asc0(symbolic_asc[0]),
    .asc_port_from_desc(desc_port_source),
    .assign_map0(asc_assign_from_desc[0]),
    .assign_map7(asc_assign_from_desc[7]),
    .child_map0(asc_from_child_desc[0]),
    .child_map7(asc_from_child_desc[7]),
    .decl_init0(asc_decl_init[0]),
    .decl_init7(asc_decl_init[7]),
    .implicit_inactive(implicit_inactive),
    .mux_stop(mux_out)
  );
endmodule
