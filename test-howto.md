# NewM2 Test Howto

This project now records each `newm2-tests` run as a numbered batch in `test-results.db`.

## Run the numbered M2 suite

```powershell
cargo test -p newm2-tests -- --test-threads=1
```

Parallel runs also work, but serial output is easier to read while debugging failures.

## Search path and windows pack

The `newm2-tests` harness does not only look in `Mod/tests`.

- It adds the repo `library/**` definition directories first, so helper-module overrides like `Float` resolve the same way they do in the normal driver.
- It loads the `packs/windows_api.pack` windows snapshot for both JIT-backed tests and compile-only `check`-style tests.
- It also adds the reference library definition roots used by the existing corpus.

That means a numbered test can exercise the real library-override plus windows-pack flow without passing extra flags on the command line.

## Query the latest batch

Show one test's latest result from the latest batch:

```powershell
cargo run -p newm2-tests --bin newm2-test-results -- --test-result t-40-010-new-record.mod
```

Show a summary of the latest batch:

```powershell
cargo run -p newm2-tests --bin newm2-test-results -- --test-metrics
```

List only the failed test ids from the latest batch:

```powershell
cargo run -p newm2-tests --bin newm2-test-results -- --test-failures
```

Compare two historical batches:

```powershell
cargo run -p newm2-tests --bin newm2-test-results -- --compare 12 13
```

## O2 performance corpus

The test corpus now includes a small O2 JIT performance slice:

- `perf-factorial-o2.mod`
- `perf-fib-o2.mod`
- `perf-sieve-o2.mod`
- `perf-primes-o2.mod`

These tests still verify a deterministic checksum, but they run through the JIT at opt-level 2 and are tuned to take roughly 1 second each on the current machine so `elapsed_ns` is useful for trend tracking.

Use the normal metrics flow to inspect them over time:

```powershell
cargo run -p newm2-tests --bin newm2-test-results -- --test-result perf-factorial-o2.mod
cargo run -p newm2-tests --bin newm2-test-results -- --test-metrics
```

## Stored fields

Each test row stores:

- `batch_no`: monotonically increasing batch number for the test process
- `run_ts`: UTC timestamp
- `test_id`: test file id
- `pass`: pass/fail bit
- `elapsed_ns`: wall-clock runtime in nanoseconds
- `note`: short failure summary
- `full_results`: full captured output or full error text

## Schema reset

The old `runs` table layout has been dropped automatically. When the database opens with the old schema, it is recreated with the batch-aware layout.

## Practical workflow

1. Run the suite.
2. Use `--test-metrics` to see the latest batch summary.
3. Use `--test-failures` to list failures without scanning terminal output.
4. Use `--test-result <testid>` to inspect full captured output or the full error.
5. Use `--compare <batch1> <batch2>` to see regressions, fixes, and timing changes over time.