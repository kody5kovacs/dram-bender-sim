# DRAM Bender sim harness

Runs DRAM Bender's own RTL (`softmc_pipeline`) and its unmodified C++ test programs with no FPGA. A behavioral DDR4 model with a read-disturbance fault model and a timing checker stands in for the PHY and DIMM.

```
program (DRAM Bender C++ API, unmodified)
  -> sim_shim/platform.h  (same SoftMCPlatform interface; execute() runs the sim)
  -> tb_sim.sv            (imem + DRAM Bender softmc_pipeline RTL)
  -> behavioral DDR4 model (data store, ACT-count fault model, tRCD/tRAS/tRP checker)
  -> READ data back to the program's own bitflip analysis
```

## Run
Needs g++ plus Icarus Verilog 12 and/or Verilator 5 (tested 5.020). The bundled `DRAM-Bender/` has the subset of sources needed.
```
make run ROWS=3 HC_FIRST=1500            # Icarus: 4-state (catches X), ~3.3 s/run
make run-verilator ROWS=3 HC_FIRST=1500  # Verilator: 2-state, ~0.04 s/run, same results
```

## Files
- `tb_sim.sv`: harness, instruction memory, and DDR4 model. Plusargs: `+PROG`, `+OUT`, `+HC_FIRST`.
- `stubs.v`: behavioral replacement for the `scratchpad` Block Memory IP (the only IP inside the pipeline).
- `sim_shim/platform.h`: drop-in for `api/platform.h`. Its `execute()` writes `program.hex`, runs `vvp`, and loads `readout.hex`.
- `run_cs1.cpp`: includes case study 1 (`test.cpp`) unchanged and only shrinks `NUM_ROWS`.

## Verified result (case study 1, VAVAV, 1000 hammers per aggressor, victim=0xFF.., aggressor=0x00..)
| HC_FIRST | flips per victim |
|---|---|
| 900  | 8 / 16 / 8 (edge victims single-sided, middle double-sided) |
| 1500 | 0 / 8 / 0 |
| 2500 | 0 / 0 / 0 |

Command counts match the program: 2008 ACT (2000 hammers + 5 init + 3 read), 640 WR, 384 RD, about 36k fabric cycles, about 4 s per run.

## Limits
- Not modeled: PHY, calibration, XDMA, frontend, readback engine, or maintenance controller (auto-refresh is off, same as `set_aref(false)`).
- The fault model is a placeholder: 8 hash-selected 1 to 0 flips per `HC_FIRST` crossing, with only ±1 neighbors. It has no RowPress (tAggON), no TRR, no retention model, no temperature dependence, and no data-pattern coupling beyond true cells.
- Only 64 rows per bank are modeled.
- The checker flags the first WRITE after each ACT at 8 vs 9 clocks for tRCD (init rows only). Either the case-study timing is one clock short, or the slot-to-DRAM-cycle mapping here is off. Confirm against the DDR4 PHY before trusting it.
- `wdata` word order assumes `ddr_wdata[32*i +: 32]` = wide-register word i. That isn't verified, and it only matters for non-uniform patterns.

## Next steps
1. Retention model: per-cell retention time and timestamps on write/ACT/REF. Run `apps/RetentionTest` through the shim.
2. RowPress: make the disturbance increment depend on how long the aggressor stays open (t_PRE - t_ACT).
3. A TRR stand-in, such as a sampler that refreshes neighbors of frequent aggressors on REF, to prototype U-TRR-style experiments.
4. For fuzzing: link the Verilator model into the C++ driver in-process (no per-run process or files), and add `--coverage` if the fuzzer is coverage-guided.
5. On real hardware, link against the real `api/platform.h`. The same programs run unchanged.
