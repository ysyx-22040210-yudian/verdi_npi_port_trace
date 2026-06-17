module TAFSiblingParent1 #(parameter PID = 0) (
  input [20:0] c,
  output used
);
  wire [10:0] lo_slice;
  wire [9:0] hi_slice;
  wire [20:0] alias0;
  wire [20:0] alias1;
  wire [20:0] port_mid;
  wire sink_lo_used;
  wire sink_hi_used;
  wire sink_concat_used;
  wire sink_alias_used;
  wire sink_port_used;

  assign lo_slice = c[10:0];
  assign hi_slice = c[20:11];
  assign alias0 = c;
  assign alias1 = {alias0[20:11], alias0[10:0]};

  TAFKeySink #(.W(11)) u_sink_lo(.in(lo_slice), .used(sink_lo_used));
  TAFKeySink #(.W(10)) u_sink_hi(.in(hi_slice), .used(sink_hi_used));
  TAFKeySink #(.W(21)) u_sink_concat(.in({hi_slice, lo_slice}), .used(sink_concat_used));
  TAFKeySink #(.W(21)) u_sink_alias(.in(alias1), .used(sink_alias_used));
  TAFPass #(.W(21)) u_port_fanout(.i(c), .o(port_mid));
  TAFKeySink #(.W(21)) u_sink_port(.in(port_mid), .used(sink_port_used));

  assign used = sink_lo_used | sink_hi_used | sink_concat_used | sink_alias_used | sink_port_used;
endmodule
