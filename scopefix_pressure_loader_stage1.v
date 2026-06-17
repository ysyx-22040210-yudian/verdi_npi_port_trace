module SFPLoaderStage1 (
  input mid,
  output out
);
  wire bridge0;
  wire bridge1;

  assign bridge0 = mid;
  assign bridge1 = bridge0;
  assign out = bridge1;
endmodule
