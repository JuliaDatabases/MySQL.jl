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

Reference numbers (macOS ARM, Docker, Julia 1.12, against the pre-2.0 dual-backend branch;
ratio is Connector/C time / native time):

| benchmark | native | Connector/C | native/C speed |
|---|---|---|---|
| 1M-row text scan | 0.5697s | 0.5527s | 0.97x |
| 1M-row binary (prepared) scan | 0.2347s | 0.2565s | 1.09x |
| 1M tiny/NULL rows | 0.1580s | 0.1676s | 1.06x |
| 64 MiB blob fetch | 0.0781s | 0.0800s | 1.02x |
| 100k executemany | 24.53s | 18.67s | 0.76x |
| 10k round trips (plain) | 2.571s | 1.483s | 0.58x |
| COM_PING floor | 151µs/ping | 116µs/ping | — |

The scan paths are at or above Connector/C. The round-trip-bound paths (one server round
trip per unit of work) trail on macOS because the per-command latency floor is ~35µs higher
than the C client's; on Linux CI they hold the 0.75x gate.
