// Runs DRAM Bender's unmodified case study 1 (rowhammer interleaving pattern)
// against the RTL simulation. Only NUM_ROWS is reduced so the sweep is short.
#define main cs1_main
#include "test.cpp"
#undef main

int main(int argc, char **argv) {
  NUM_ROWS = argc > 1 ? atoi(argv[1]) : 3;   // rows to sweep (real run: 32768)
  char a0[] = "cs1", hc[] = "1000", cascade[] = "1000", pat[] = "1", out[] = "cs1_results.txt";
  char *args[] = {a0, hc, cascade, pat, out};
  return cs1_main(5, args);
}
