`timescale 1ns/1ps
`include "parameters.vh"
// Simulation harness for DRAM Bender's softmc_pipeline.
// - Emulates the frontend's instruction memory (program loaded from +PROG=<hex>)
// - Feeds the 4-slot DDR command bus into a behavioral DDR4 bank model
// - Model has a read-disturbance fault model (+HC_FIRST) and a JEDEC timing checker
// - READ data is dumped to +OUT=<hex> as 16 x 32-bit words per burst (word 0 first)
module tb_sim;
  localparam NROW_MODEL = 64;          // rows modeled per bank (rows >= this are ignored)
  localparam NBURST     = 128;         // 8KB row / 64B burst
  // JEDEC DDR4-1333 style timing in DRAM clocks (tCK = 1.5 ns)
  localparam T_RCD = 9, T_RAS = 24, T_RP = 9;

  reg clk = 0, rst = 1;
  always #3 clk = ~clk;                // 6 ns fabric clock (4:1 to DRAM clock)

  // ---------------- instruction memory (frontend stand-in) ----------------
  reg [63:0] imem [0:2047];
  wire [`IMEM_ADDR_WIDTH-1:0] addr_out;
  wire valid_out;
  reg  [63:0] data_in = 0;
  reg  valid_in = 0;
  reg  [`IMEM_ADDR_WIDTH-1:0] addr_in = 0;
  always @(posedge clk) begin
    valid_in <= valid_out & ~rst;
    data_in  <= imem[addr_out];
    addr_in  <= addr_out;
  end

  wire softmc_end;
  wire [11:0] read_size; wire read_seq_incoming;
  wire [3:0] ddr_write, ddr_read, ddr_pre, ddr_act, ddr_ref, ddr_sre, ddr_srx,
             ddr_zq, ddr_nop, ddr_ap, ddr_pall, ddr_half_bl, ddr_rank;
  wire [4*`HBM_CH_WIDTH-1:0] hbm_ch;
  wire [4*`BG_WIDTH-1:0]   ddr_bg;
  wire [4*`BANK_WIDTH-1:0] ddr_bank;
  wire [4*`COL_WIDTH-1:0]  ddr_col;
  wire [4*`ROW_WIDTH-1:0]  ddr_row;
  wire [511:0] ddr_wdata;

  softmc_pipeline dut(
    .clk(clk), .rst(rst), .softmc_end(softmc_end),
    .read_size(read_size), .read_seq_incoming(read_seq_incoming),
    .buffer_space(12'hFFF),
    .addr_out(addr_out), .valid_out(valid_out),
    .data_in(data_in), .valid_in(valid_in), .addr_in(addr_in), .ready_out(~rst),
    .ddr_write(ddr_write), .ddr_read(ddr_read), .ddr_pre(ddr_pre), .ddr_act(ddr_act),
    .ddr_ref(ddr_ref), .ddr_sre(ddr_sre), .ddr_srx(ddr_srx), .ddr_zq(ddr_zq),
    .ddr_nop(ddr_nop), .ddr_ap(ddr_ap), .ddr_pall(ddr_pall), .ddr_half_bl(ddr_half_bl),
    .ddr_rank(ddr_rank), .hbm_ch(hbm_ch), .ddr_bg(ddr_bg), .ddr_bank(ddr_bank),
    .ddr_col(ddr_col), .ddr_row(ddr_row), .ddr_wdata(ddr_wdata));

  // ---------------- behavioral DDR4 model ----------------
  reg [511:0] mem     [0:16*NROW_MODEL*NBURST-1];
  integer     disturb [0:16*NROW_MODEL-1];   // aggressor ACTs seen by each row since its last ACT/REF
  integer     open_row[0:15];
  longint     t_act [0:15], t_pre [0:15];
  integer     hc_first, fd_out, n_act, n_rd, n_wr, n_viol, n_flips;
  longint     cyc;
  string      prog_file, out_file;

  function automatic integer idx_row(input integer b, input integer r); idx_row = b*NROW_MODEL + r; endfunction
  function automatic integer idx_mem(input integer b, input integer r, input integer c); idx_mem = (b*NROW_MODEL + r)*NBURST + c; endfunction

  // Read-disturb fault model: each time a victim's count crosses a multiple of
  // hc_first, flip 8 hash-selected charged cells (1 -> 0, true-cell convention).
  task automatic disturb_row(input integer b, input integer r);
    integer k, c, bit_i, h;
    if (r >= 0 && r < NROW_MODEL) begin
    disturb[idx_row(b,r)] += 1;
    if (disturb[idx_row(b,r)] % hc_first == 0) begin
      for (k = 0; k < 8; k++) begin
        h = (r*7919 + b*104729 + (disturb[idx_row(b,r)]/hc_first)*31 + k*2654435) & 32'h7fffffff;
        c = h % NBURST; bit_i = (h / NBURST) % 512;
        if (mem[idx_mem(b,r,c)][bit_i] === 1'b1) begin
          mem[idx_mem(b,r,c)][bit_i] = 1'b0; n_flips++;
        end
      end
    end
    end
  endtask

  task automatic do_cmd(input integer s);
    integer b, r, c, i; longint t;
    t = cyc*4 + s;
    b = {ddr_bg[s*`BG_WIDTH +: `BG_WIDTH], ddr_bank[s*`BANK_WIDTH +: `BANK_WIDTH]};
    r = ddr_row[s*`ROW_WIDTH +: `ROW_WIDTH];
    c = ddr_col[s*`COL_WIDTH +: `COL_WIDTH] >> 3;
    if (ddr_act[s]) begin
      if (open_row[b] != -1) begin $display("[%0t] PROTOCOL: ACT to open bank %0d", $time, b); n_viol++; end
      if (t - t_pre[b] < T_RP) begin $display("[%0t] TIMING: tRP violated bank %0d (%0d < %0d)", $time, b, t-t_pre[b], T_RP); n_viol++; end
      open_row[b] = r; t_act[b] = t; n_act++;
      if (r < NROW_MODEL) disturb[idx_row(b,r)] = 0;   // activation restores the row's charge
      disturb_row(b, r-1); disturb_row(b, r+1);
    end
    if (ddr_pre[s] || ddr_pall[s]) begin
      for (i = 0; i < 16; i++) if ((ddr_pall[s] || i == b) && open_row[i] != -1) begin
        if (t - t_act[i] < T_RAS) begin $display("[%0t] TIMING: tRAS violated bank %0d (%0d < %0d)", $time, i, t-t_act[i], T_RAS); n_viol++; end
        open_row[i] = -1; t_pre[i] = t;
      end
    end
    if (ddr_write[s] || ddr_read[s]) begin
      if (open_row[b] == -1) begin $display("[%0t] PROTOCOL: RD/WR to closed bank %0d", $time, b); n_viol++; end
      else if (t - t_act[b] < T_RCD) begin $display("[%0t] TIMING: tRCD violated bank %0d (%0d < %0d)", $time, b, t-t_act[b], T_RCD); n_viol++; end
      if (open_row[b] >= 0 && open_row[b] < NROW_MODEL) begin
        if (ddr_write[s]) begin mem[idx_mem(b,open_row[b],c)] = ddr_wdata; n_wr++; end
        else begin
          for (i = 0; i < 16; i++) $fwrite(fd_out, "%08h\n", mem[idx_mem(b,open_row[b],c)][32*i +: 32]);
          n_rd++;
        end
      end
    end
    if (ddr_ref[s]) for (i = 0; i < 16*NROW_MODEL; i++) disturb[i] = 0;
  endtask

  integer s, i;
  initial begin
    if (!$value$plusargs("PROG=%s", prog_file)) prog_file = "program.hex";
    if (!$value$plusargs("OUT=%s",  out_file))  out_file  = "readout.hex";
    if (!$value$plusargs("HC_FIRST=%d", hc_first)) hc_first = 1500;
    for (i = 0; i < 2048; i++) imem[i] = 0;
    $readmemh(prog_file, imem);
    for (i = 0; i < 16*NROW_MODEL; i++) disturb[i] = 0;
    for (i = 0; i < 16; i++) begin open_row[i] = -1; t_act[i] = -1000; t_pre[i] = -1000; end
    n_act = 0; n_rd = 0; n_wr = 0; n_viol = 0; n_flips = 0; cyc = 0;
    fd_out = $fopen(out_file, "w");
    #60 rst = 0;
  end

  always @(posedge clk) if (!rst) begin
    for (s = 0; s < 4; s++) do_cmd(s);
    cyc++;
    if (softmc_end || cyc > 5_000_000) begin
      $display("SIM_DONE cycles=%0d ACT=%0d WR=%0d RD=%0d violations=%0d injected_flips=%0d%s",
               cyc, n_act, n_wr, n_rd, n_viol, n_flips, softmc_end ? "" : " (TIMEOUT)");
      $fclose(fd_out); $finish;
    end
  end
endmodule
