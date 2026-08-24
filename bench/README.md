# Cross-driver benchmarks

Before 2.0, `test/perf/perf_gates.jl` asserted native-vs-Connector/C timing ratios inside
`Pkg.test`. Those ratio gates retired with the C backend; the in-repo §8.9 gates now assert
correctness, allocation budgets, and buffer limits, and print a wall-clock timing report.

This directory keeps the cross-driver comparison repeatable:

```sh
julia --project=. bench/run.jl
```

builds two temp environments — the current checkout (native) and `MySQL@1` (MariaDB
Connector/C) from the registry — starts the same Docker fixture servers the §8.9 gates use
(`mysql:8.4`, `--max-allowed-packet=128M`, TLS disabled), runs `bench/child.jl` once per
environment, and prints per-benchmark seconds plus the mysql@1/native ratio (>1x means the
native client is faster).

Reference numbers (macOS ARM, Docker, Julia 1.12, this harness after the 2.0 round-trip
perf round; ratio is mysql@1 time / native time, >1x = native faster):

| benchmark | native | mysql@1 (Connector/C) | speed |
|---|---|---|---|
| 100k executemany | 16.97s | 23.46s | 1.38x |
| 1M-row text scan | 0.4512s | 0.5098s | 1.13x |
| 1M tiny/NULL rows | 0.1780s | 0.2018s | 1.13x |
| 1M-row binary (prepared) scan | 0.2866s | 0.2978s | 1.04x |
| 64 MiB blob fetch | 0.0591s | 0.0551s | 0.93x |
| 10k round trips (plain) | 2.701s | 2.292s | 0.85x |

Per-command costs after the round: COM_PING 3 allocs, buffered `SELECT 1` 35 allocs,
repeated prepared execute 22 allocs (framed directly into the output buffer, cached
statement schema, lazy name lookup). The remaining round-trip gap vs the C client is
task-wakeup latency in the transport layer (a blocking `recv` wakes the C client directly;
the native client parks on the poller), not per-command CPU work.
