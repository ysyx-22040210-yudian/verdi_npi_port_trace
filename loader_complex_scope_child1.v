module LCSChild1 (
  input clk,
  input rst_n,
  input b,
  input [20:0] bus_i,
  output used
);
  wire local_b;
  wire [10:0] low_slice;
  wire [9:0] high_slice;
  wire [10:0] low_alias;
  wire [9:0] high_alias;
  wire key_b_used;
  wire key_low_used;
  wire key_high_used;
  reg rb;
  reg [9:0] reg_high;

  assign local_b = b;
  assign low_slice = bus_i[10:0];
  assign high_slice = bus_i[20:11];
  assign low_alias = low_slice;
  assign high_alias = high_slice;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rb <= 1'b0;
      reg_high <= 10'h0;
    end else begin
      rb <= local_b;
      reg_high <= high_alias;
    end
  end

  LCSKeyBit u_key_b (
    .in(local_b),
    .used(key_b_used)
  );

  LCSKeyVec #(.W(11)) u_key_low (
    .in(low_alias),
    .used(key_low_used)
  );

  LCSKeyVec #(.W(10)) u_key_high (
    .in(high_alias),
    .used(key_high_used)
  );

  assign used = rb | key_b_used | key_low_used | key_high_used | ^reg_high;
endmodule
