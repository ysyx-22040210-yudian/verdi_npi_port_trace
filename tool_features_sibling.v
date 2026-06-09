module TFSiblingParent0 #(parameter PID = 0) (
  input [20:0] in,
  output [20:0] out
);
  assign out = in;
endmodule

module TFSiblingParent1 #(parameter PID = 0) (
  input [20:0] c,
  output used
);
  wire [10:0] lo_slice;
  wire [9:0] hi_slice;
  wire [20:0] alias0;
  wire [20:0] alias1;
  wire sink_lo_used;
  wire sink_hi_used;
  wire sink_concat_used;
  wire sink_alias_used;

  assign lo_slice = c[10:0];
  assign hi_slice = c[20:11];
  assign alias0 = c;
  assign alias1 = {alias0[20:11], alias0[10:0]};

  TFKeySink #(.W(11)) u_sink_lo(.in(lo_slice), .used(sink_lo_used));
  TFKeySink #(.W(10)) u_sink_hi(.in(hi_slice), .used(sink_hi_used));
  TFKeySink #(.W(21)) u_sink_concat(.in({hi_slice, lo_slice}), .used(sink_concat_used));
  TFKeySink #(.W(21)) u_sink_alias(.in(alias1), .used(sink_alias_used));

  assign used = sink_lo_used | sink_hi_used | sink_concat_used | sink_alias_used;
endmodule
