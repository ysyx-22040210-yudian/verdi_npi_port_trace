module KeySrc(output out);
  assign out = 1'b1;
endmodule

module KeySrcVec2(output [1:0] out);
  assign out = 2'b10;
endmodule

module NoiseSrc(output [6:0] b, output [2:0] d);
  assign b = 7'h2a;
  assign d = 3'h5;
endmodule

module KeySink(input [2:0] in, output out);
  assign out = ^in;
endmodule

module KeySinkVec(input [10:0] in, output out);
  assign out = ^in;
endmodule

module KeySinkVec10(input [9:0] in, output out);
  assign out = ^in;
endmodule

module KeySink1(input in, output out);
  assign out = in;
endmodule

module NoiseSinkVec(input [9:0] in, output out);
  assign out = ^in;
endmodule

module EdgeTarget(
  input [2:0] concat_from_module,
  input false_from_mixed,
  input shifted_from_range,
  output [3:0] loader_chain_out
);
  assign loader_chain_out = {concat_from_module[1], false_from_mixed, shifted_from_range, 1'b0};
endmodule

module TraceTarget(
  input [10:0] A,
  input P,
  input [3:0] S,
  input [3:0] R,
  input [1:0] C,
  input [1:0] G,
  output [20:0] L,
  output Q
);
  assign L = 21'h155555;
  assign Q = P;
endmodule

module BitAssignTop;
  wire [10:0] A;
  wire [20:0] L;
  wire P;
  wire Q;
  wire [3:0] S;
  wire [3:0] R;
  wire [1:0] C;
  wire [1:0] G;
  wire [6:0] b_noise;
  wire [2:0] d_noise;
  wire c_key;
  wire plain_key;
  wire plain_mid;
  wire plain_load_mid;
  wire [1:0] split_hi;
  wire [1:0] split_lo;
  wire [3:0] recur_mid;
  wire [1:0] recur_hi;
  wire [1:0] recur_lo;
  wire recur_hi_a;
  wire recur_hi_b;
  wire recur_lo_a;
  wire recur_lo_b;
  reg clk;
  reg reg_combo_src;

  wire [2:0] load_concat;
  wire [2:0] load_concat_l2;
  wire [2:0] load_concat_l3;
  wire [10:0] load_b0;
  wire [10:0] load_b0_l2;
  wire [10:0] load_b0_l3;
  wire [9:0] load_b1;
  wire [9:0] load_b1_l2;
  wire [9:0] load_b1_l3;
  wire key_concat_keep;
  wire key_concat_deep_keep;
  wire key_b0_keep;
  wire key_b0_deep_keep;
  wire key_b1_keep;
  wire key_b1_deep_keep;
  wire key_plain_keep;
  wire noise_b1_keep;
  wire [2:0] edge_concat;
  wire [1:0] false_mixed_key;
  wire [1:0] mixed_bus;
  wire false_from_mixed;
  wire [15:0] shifted_bus;
  wire shifted_from_range;
  wire [3:0] edge_loader;
  wire edge_loader_mid0;
  wire edge_loader_mid1;
  wire edge_load_keep;

  KeySrc u_key_src(.out(c_key));
  KeySrc u_key_src_plain(.out(plain_key));
  KeySrcVec2 u_key_split_hi(.out(split_hi));
  KeySrcVec2 u_key_split_lo(.out(split_lo));
  KeySrc u_key_recur_hi_a(.out(recur_hi_a));
  KeySrc u_key_recur_hi_b(.out(recur_hi_b));
  KeySrc u_key_recur_lo_a(.out(recur_lo_a));
  KeySrc u_key_recur_lo_b(.out(recur_lo_b));
  KeySrcVec2 u_key_false_mixed(.out(false_mixed_key));
  NoiseSrc u_noise_src(.b(b_noise), .d(d_noise));

  assign A[10:0] = {d_noise[2:0], c_key, b_noise[6:0]};
  assign plain_mid = plain_key;
  assign P = plain_mid;
  assign S = {split_hi, split_lo};
  assign recur_hi = {recur_hi_a, recur_hi_b};
  assign recur_lo = {recur_lo_a, recur_lo_b};
  assign recur_mid = {recur_hi, recur_lo};
  assign R = {recur_mid[3:2], recur_mid[1:0]};
  assign C = {1'b0, plain_key};
  initial begin
    clk = 1'b0;
  end
  always @(posedge clk) begin
    reg_combo_src <= plain_key;
  end
  assign G = {reg_combo_src, plain_key};

  TraceTarget u_target(.A(A), .P(P), .S(S), .R(R), .C(C), .G(G), .L(L), .Q(Q));

  assign edge_concat = {1'b0, L[7], 1'b1};
  assign mixed_bus[0] = b_noise[0];
  assign mixed_bus[1] = false_mixed_key[0];
  assign false_from_mixed = mixed_bus[0];
  assign shifted_bus[15:8] = {4'b0, split_hi, split_lo};
  assign shifted_bus[7:0] = 8'h00;
  assign shifted_from_range = shifted_bus[9];
  EdgeTarget u_edge_target(
    .concat_from_module(edge_concat),
    .false_from_mixed(false_from_mixed),
    .shifted_from_range(shifted_from_range),
    .loader_chain_out(edge_loader)
  );
  assign edge_loader_mid0 = edge_loader[2];
  assign edge_loader_mid1 = edge_loader_mid0;
  KeySink1 u_key_sink_edge_load(.in(edge_loader_mid1), .out(edge_load_keep));

  assign load_concat = {1'b0, L[7], 1'b1};
  assign load_concat_l2 = load_concat;
  assign load_concat_l3 = load_concat_l2;
  assign load_b0 = L[10:0];
  assign load_b0_l2 = load_b0;
  assign load_b0_l3 = {load_b0_l2[10:0]};
  assign load_b1 = L[20:11];
  assign load_b1_l2 = load_b1;
  assign load_b1_l3 = {load_b1_l2[9:0]};
  assign plain_load_mid = Q;

  KeySink u_key_sink_concat(.in(load_concat), .out(key_concat_keep));
  KeySink u_key_sink_concat_deep(.in(load_concat_l3), .out(key_concat_deep_keep));
  KeySinkVec u_key_sink_b0(.in(load_b0), .out(key_b0_keep));
  KeySinkVec u_key_sink_b0_deep(.in(load_b0_l3), .out(key_b0_deep_keep));
  KeySinkVec10 u_key_sink_b1(.in(load_b1), .out(key_b1_keep));
  KeySinkVec10 u_key_sink_b1_deep(.in(load_b1_l3), .out(key_b1_deep_keep));
  KeySink1 u_key_sink_plain(.in(plain_load_mid), .out(key_plain_keep));
  NoiseSinkVec u_noise_sink_b1(.in(load_b1), .out(noise_b1_keep));
endmodule
