module ScopeKeySrc(
  output out
);
  assign out = 1'b1;
endmodule

module ScopeKeyVecSrc #(
  parameter W = 8
) (
  output [W-1:0] out
);
  assign out = {W{1'b1}};
endmodule

module ScopeKeySink(
  input in
);
  wire used = in;
endmodule

module ScopeKeyVecSink #(
  parameter W = 8
) (
  input [W-1:0] in
);
  wire used = |in;
endmodule

module ScopeParent(
  output out
);
  ScopeKeySrc u_key_nested(
    .out(out)
  );
endmodule

module ScopeProducer(
  output out
);
  ScopeKeySrc u_key_sibling(
    .out(out)
  );
endmodule

module ScopePassWrap(
  input in,
  output out
);
  assign out = in;
endmodule

module ScopeVecParent(
  output [7:0] out
);
  ScopeKeyVecSrc #(.W(8)) u_vec_key(
    .out(out)
  );
endmodule

module ScopeGenParent(
  output [3:0] out
);
  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g
      ScopeKeySrc u_key_gen(
        .out(out[i])
      );
    end
  endgenerate
endmodule

module ScopeDecoy(
  output out
);
  ScopeKeySrc u_key_nested(
    .out(out)
  );
endmodule

module ScopeStressChild(
  input drv_parent,
  input drv_sibling,
  input drv_wrapper,
  input drv_slice_bit,
  input drv_concat_bit,
  input drv_gen,
  output load_plain,
  output [15:0] load_bus
);
endmodule

module ScopeFallbackStressTop;
  wire c_parent;
  wire b_parent;
  wire c_sibling;
  wire b_sibling;
  wire key_wrap;
  wire c_wrap;
  wire b_wrap;
  wire [7:0] c_vec;
  wire [7:0] b_slice;
  wire [1:0] c_hi;
  wire [1:0] c_lo;
  wire [3:0] b_concat;
  wire [3:0] gen_vec;
  wire c_gen;
  wire b_gen;
  wire load_plain;
  wire load_mid;
  wire [15:0] load_bus;
  wire [7:0] load_lo;
  wire [7:0] load_hi;

  ScopeParent u_parent(
    .out(c_parent)
  );
  assign b_parent = c_parent;

  ScopeProducer u_sibling_prod(
    .out(c_sibling)
  );
  assign b_sibling = c_sibling;

  ScopeKeySrc u_key_wrap_src(
    .out(key_wrap)
  );
  ScopePassWrap u_pass0(
    .in(key_wrap),
    .out(c_wrap)
  );
  assign b_wrap = c_wrap;

  ScopeVecParent u_vec_parent(
    .out(c_vec)
  );
  assign b_slice[7:0] = c_vec[7:0];

  ScopeKeyVecSrc #(.W(2)) u_key_hi(
    .out(c_hi)
  );
  assign c_lo = 2'b00;
  assign b_concat = {c_hi, c_lo};

  ScopeGenParent u_gen_parent(
    .out(gen_vec)
  );
  assign c_gen = gen_vec[2];
  assign b_gen = c_gen;

  ScopeStressChild u_child(
    .drv_parent(b_parent),
    .drv_sibling(b_sibling),
    .drv_wrapper(b_wrap),
    .drv_slice_bit(b_slice[2]),
    .drv_concat_bit(b_concat[3]),
    .drv_gen(b_gen),
    .load_plain(load_plain),
    .load_bus(load_bus)
  );

  assign load_mid = load_plain;
  ScopeKeySink u_load_sink(
    .in(load_mid)
  );

  assign load_lo = load_bus[7:0];
  assign load_hi = load_bus[15:8];
  ScopeKeyVecSink #(.W(8)) u_load_lo(
    .in(load_lo)
  );
  ScopeKeyVecSink #(.W(8)) u_load_hi(
    .in(load_hi)
  );
endmodule
