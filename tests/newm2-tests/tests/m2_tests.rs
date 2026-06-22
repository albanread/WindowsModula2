//! M2 end-to-end JIT tests.
//!
//! Every test follows the same pattern:
//!   1. Start I/O capture.
//!   2. JIT-compile and run the numbered `.mod` file at O0.
//!   3. Assert the captured output matches EXPECTED.
//!   4. Append the result (pass/fail, elapsed ns) to test-results.db.
//!
//! Run with:   cargo test -p newm2-tests
//! Update DB:  same — rows are appended on every run.
//! View log:   sqlite3 test-results.db "SELECT * FROM runs ORDER BY id DESC LIMIT 40;"

#[cfg(feature = "gc")]
use std::collections::HashMap;
#[cfg(feature = "gc")]
use std::sync::atomic::Ordering;
use std::time::Instant;
use newm2_tests::{check_test, run_test, run_test_m2heap, run_test_o2, testdb::{TestDb, TestRun}};
#[cfg(feature = "gc")]
use newm2_runtime::{gc_pressure_threshold, nm2_set_gc_pressure, HEAP_COUNTERS};

// ── helper ────────────────────────────────────────────────────────────────────

/// Run one test, assert output, log result to DB.  Returns the captured output
/// so the caller can make extra assertions if desired.
fn check(test_id: &str, expected: &str) -> String {
    check_with(test_id, expected, run_test)
}

/// Like [`check`] but compiles with `--m2-heap`, so NEW/DISPOSE route through
/// the self-hosted M2 `Heap` (force-linked).
fn check_m2heap(test_id: &str, expected: &str) -> String {
    check_with(test_id, expected, run_test_m2heap)
}

fn check_with(
    test_id: &str,
    expected: &str,
    runner: fn(&str) -> Result<String, String>,
) -> String {
    let db = TestDb::open_default().expect("open test-results.db");

    let t0 = Instant::now();
    let result = runner(test_id);
    let elapsed_ns = t0.elapsed().as_nanos() as u64;

    match &result {
        Ok(output) if output.as_str() == expected => {
            db.append(&TestRun {
                test_id:    test_id.to_string(),
                pass:       true,
                elapsed_ns,
                note:       String::new(),
                full_results: output.clone(),
            }).ok();
            output.clone()
        }
        Ok(output) => {
            let note = format!(
                "output mismatch\n  expected: {:?}\n  actual:   {:?}",
                expected, output
            );
            db.append(&TestRun {
                test_id:    test_id.to_string(),
                pass:       false,
                elapsed_ns,
                note:       note.clone(),
                full_results: output.clone(),
            }).ok();
            panic!("{note}");
        }
        Err(e) => {
            let note = format!("error: {e}");
            db.append(&TestRun {
                test_id:    test_id.to_string(),
                pass:       false,
                elapsed_ns,
                note:       note.clone(),
                full_results: e.clone(),
            }).ok();
            panic!("{note}");
        }
    }
}

/// Assert that running `test_id` fails (an uncaught exception or other run
/// error) and that the error text contains every fragment in `needles`.
fn check_run_error(test_id: &str, needles: &[&str]) -> String {
    let db = TestDb::open_default().expect("open test-results.db");
    let t0 = Instant::now();
    let result = run_test(test_id);
    let elapsed_ns = t0.elapsed().as_nanos() as u64;

    match &result {
        Err(e) if needles.iter().all(|n| e.contains(n)) => {
            db.append(&TestRun {
                test_id: test_id.to_string(),
                pass: true,
                elapsed_ns,
                note: String::new(),
                full_results: e.clone(),
            }).ok();
            e.clone()
        }
        Err(e) => {
            let note = format!("error text missing one of {needles:?}\n  actual: {e:?}");
            db.append(&TestRun {
                test_id: test_id.to_string(),
                pass: false,
                elapsed_ns,
                note: note.clone(),
                full_results: e.clone(),
            }).ok();
            panic!("{note}");
        }
        Ok(output) => {
            let note = format!("expected run error, got success: {output:?}");
            db.append(&TestRun {
                test_id: test_id.to_string(),
                pass: false,
                elapsed_ns,
                note: note.clone(),
                full_results: output.clone(),
            }).ok();
            panic!("{note}");
        }
    }
}

/// A negative test under `--strict`: type-checking the file with pedantic checks
/// on must fail with a diagnostic containing every needle. (Also asserts the
/// LENIENT default ACCEPTS it — the whole point of gating.)
fn check_strict_error(test_id: &str, needles: &[&str]) {
    let lenient = newm2_tests::check_test(test_id);
    assert!(
        lenient.is_ok(),
        "{test_id}: lenient (default) build should accept it, got {lenient:?}"
    );
    match newm2_tests::check_test_strict(test_id) {
        Err(e) if needles.iter().all(|n| e.contains(n)) => {}
        Err(e) => panic!("{test_id}: strict error missing one of {needles:?}\n  actual: {e:?}"),
        Ok(()) => panic!("{test_id}: expected a --strict error, but it type-checked clean"),
    }
}

#[cfg(feature = "gc")]
fn check_contains_all(test_id: &str, required: &[&str]) -> String {
    let db = TestDb::open_default().expect("open test-results.db");

    let t0 = Instant::now();
    let result = newm2_tests::run_test_gc(test_id);
    let elapsed_ns = t0.elapsed().as_nanos() as u64;

    match &result {
        Ok(output) => {
            let missing: Vec<&str> = required
                .iter()
                .copied()
                .filter(|needle| !output.contains(needle))
                .collect();
            if missing.is_empty() {
                db.append(&TestRun {
                    test_id: test_id.to_string(),
                    pass: true,
                    elapsed_ns,
                    note: String::new(),
                    full_results: output.clone(),
                }).ok();
                output.clone()
            } else {
                let note = format!(
                    "missing gc report markers: {:?}\nactual output: {:?}",
                    missing,
                    output,
                );
                db.append(&TestRun {
                    test_id: test_id.to_string(),
                    pass: false,
                    elapsed_ns,
                    note: note.clone(),
                    full_results: output.clone(),
                }).ok();
                panic!("{note}");
            }
        }
        Err(e) => {
            let note = format!("error: {e}");
            db.append(&TestRun {
                test_id: test_id.to_string(),
                pass: false,
                elapsed_ns,
                note: note.clone(),
                full_results: e.clone(),
            }).ok();
            panic!("{note}");
        }
    }
}

fn check_o2(test_id: &str, expected: &str) -> String {
    let db = TestDb::open_default().expect("open test-results.db");

    let t0 = Instant::now();
    let result = run_test_o2(test_id);
    let elapsed_ns = t0.elapsed().as_nanos() as u64;

    match &result {
        Ok(output) if output.as_str() == expected => {
            db.append(&TestRun {
                test_id: test_id.to_string(),
                pass: true,
                elapsed_ns,
                note: "opt_level=2".to_string(),
                full_results: output.clone(),
            }).ok();
            output.clone()
        }
        Ok(output) => {
            let note = format!(
                "opt_level=2 output mismatch\n  expected: {:?}\n  actual:   {:?}",
                expected, output
            );
            db.append(&TestRun {
                test_id: test_id.to_string(),
                pass: false,
                elapsed_ns,
                note: note.clone(),
                full_results: output.clone(),
            }).ok();
            panic!("{note}");
        }
        Err(e) => {
            let note = format!("opt_level=2 error: {e}");
            db.append(&TestRun {
                test_id: test_id.to_string(),
                pass: false,
                elapsed_ns,
                note: note.clone(),
                full_results: e.clone(),
            }).ok();
            panic!("{note}");
        }
    }
}

#[cfg(feature = "gc")]
struct GcPressureGuard {
    previous_threshold: u64,
}

#[cfg(feature = "gc")]
impl GcPressureGuard {
    fn set(threshold: u64) -> Self {
        let previous_threshold = gc_pressure_threshold();
        nm2_set_gc_pressure(threshold);
        Self { previous_threshold }
    }
}

#[cfg(feature = "gc")]
impl Drop for GcPressureGuard {
    fn drop(&mut self) {
        nm2_set_gc_pressure(self.previous_threshold);
    }
}

#[cfg(feature = "gc")]
fn run_test_with_pressure(test_id: &str, threshold: u64) -> Result<String, String> {
    let _guard = GcPressureGuard::set(threshold);
    newm2_tests::run_test_gc(test_id)
}

#[cfg(feature = "gc")]
fn parse_gc_metrics(output: &str) -> Result<HashMap<String, u64>, String> {
    let mut metrics = HashMap::new();
    for line in output.lines() {
        let Some((name, value)) = line.split_once('=') else {
            continue;
        };
        if !name.starts_with("gc.") {
            continue;
        }
        let parsed = value
            .trim()
            .parse::<u64>()
            .map_err(|e| format!("failed to parse {name}={value:?}: {e}"))?;
        metrics.insert(name.to_string(), parsed);
    }
    Ok(metrics)
}

#[cfg(feature = "gc")]
fn require_metric(metrics: &HashMap<String, u64>, name: &str) -> Result<u64, String> {
    metrics
        .get(name)
        .copied()
        .ok_or_else(|| format!("missing metric {name}"))
}

#[cfg(feature = "gc")]
fn check_gc_report(
    test_id: &str,
    pressure_threshold: Option<u64>,
    required: &[&str],
    validate: impl FnOnce(&HashMap<String, u64>, u64, u64, u64) -> Result<(), String>,
) -> String {
    let db = TestDb::open_default().expect("open test-results.db");
    let baseline_collect_cycles = HEAP_COUNTERS.collect_cycles.load(Ordering::Relaxed);
    let baseline_alloc_blocks = HEAP_COUNTERS.alloc_blocks_lifetime.load(Ordering::Relaxed);
    let baseline_grow_events = HEAP_COUNTERS.grow_events.load(Ordering::Relaxed);

    let t0 = Instant::now();
    let result = match pressure_threshold {
        Some(threshold) => run_test_with_pressure(test_id, threshold),
        None => newm2_tests::run_test_gc(test_id),
    };
    let elapsed_ns = t0.elapsed().as_nanos() as u64;

    match &result {
        Ok(output) => {
            let missing: Vec<&str> = required
                .iter()
                .copied()
                .filter(|needle| !output.contains(needle))
                .collect();
            let validation = if missing.is_empty() {
                parse_gc_metrics(output)
                    .and_then(|metrics| validate(
                        &metrics,
                        baseline_collect_cycles,
                        baseline_alloc_blocks,
                        baseline_grow_events,
                    ))
            } else {
                Err(format!("missing gc report markers: {:?}", missing))
            };

            match validation {
                Ok(()) => {
                    db.append(&TestRun {
                        test_id: test_id.to_string(),
                        pass: true,
                        elapsed_ns,
                        note: String::new(),
                        full_results: output.clone(),
                    }).ok();
                    output.clone()
                }
                Err(reason) => {
                    let note = format!("{reason}\nactual output: {:?}", output);
                    db.append(&TestRun {
                        test_id: test_id.to_string(),
                        pass: false,
                        elapsed_ns,
                        note: note.clone(),
                        full_results: output.clone(),
                    }).ok();
                    panic!("{note}");
                }
            }
        }
        Err(e) => {
            let note = format!("error: {e}");
            db.append(&TestRun {
                test_id: test_id.to_string(),
                pass: false,
                elapsed_ns,
                note: note.clone(),
                full_results: e.clone(),
            }).ok();
            panic!("{note}");
        }
    }
}

// ── Group 10 — Arithmetic ─────────────────────────────────────────────────────

#[test]
fn t10_010_const_arith() {
    check("t-10-010-const-arith.mod", "42\n");
}

#[test]
fn t10_020_divmod() {
    check("t-10-020-divmod.mod", "3\n1\n");
}

#[test]
fn t10_110_address_arith() {
    check("t-10-110-address-arith.mod", "add\nmod\nmul\n");
}

#[test]
fn t10_120_type_conversion() {
    check("t-10-120-type-conversion.mod", "300\n10\n66\nisnil\n");
}

#[test]
fn t10_130_max_real() {
    check("t-10-130-max-real.mod", "big\nsmall\n");
}

#[test]
fn t10_030_neg_arith() {
    check("t-10-030-neg-arith.mod", "-5\n10\n");
}

#[test]
fn t10_040_val_roundtrip() {
    check("t-10-040-val-roundtrip.mod", "42\n42\n");
}

#[test]
fn t10_050_system_cast() {
    check("t-10-050-system-cast.mod", "");
}

#[test]
fn t10_060_signed_narrow_arith() {
    // Sprint A: narrow signed widening (INTEGER8 -5 + 100 = 95, not 351) and
    // signed REM (-7 REM 3 = -1, not 0).
    check("t-10-060-signed-narrow-arith.mod", "95\n-1\n");
}

#[test]
fn t10_070_cap() {
    // Sprint A: CAP now lowers (was an undefined-ValueId codegen panic).
    check("t-10-070-cap.mod", "AZM5\n");
}

#[test]
fn t10_080_sys_addr() {
    // Sprint A: SYSTEM.ADDADR/SUBADR/DIFADR (were sema-1-arg + unlowered,
    // falling through to a nonexistent proc). ADDRESS is a pointer, so these
    // round-trip through int arithmetic.
    check("t-10-080-sys-addr.mod", "16 12 \n");
}

#[test]
fn t10_090_cardinal_cmp() {
    // Sprint G: a CARDINAL with the top bit set must compare/divide as unsigned
    // even against an INTEGER literal. MAX(CARDINAL) > 100 is "big" (not -1>100),
    // and MAX(CARDINAL) DIV 2 is a large positive "half-big".
    check("t-10-090-cardinal-cmp.mod", "big\nhalf-big\n");
}

#[test]
fn t10_100_shift_rotate() {
    // Sprint A tail: SYSTEM.SHIFT / SYSTEM.ROTATE. SHIFT left/right by a signed
    // count drops bits past the width; ROTATE wraps them. ROTATE(1,-1) on a
    // 64-bit CARDINAL lands in bit 63 (2^63) where SHIFT(1,-1) yields 0.
    check(
        "t-10-100-shift-rotate.mod",
        "shl=16\nshr=12\nrol=16\nror=4\nwrap=9223372036854775808\ndrop=0\n",
    );
}

// ── Group 20 — Control flow ───────────────────────────────────────────────────

#[test]
fn t20_010_while() {
    check("t-20-010-while.mod", "1\n2\n3\n4\n5\n");
}

#[test]
fn t20_020_for() {
    check("t-20-020-for.mod", "55\n");
}

#[test]
fn t20_030_if_else() {
    check("t-20-030-if-else.mod", "low\nmid\nhigh\n");
}

#[test]
fn t20_040_repeat() {
    check("t-20-040-repeat.mod", "0\n1\n2\n3\n");
}

#[test]
fn t20_080_for_loops() {
    // Sprint C: descending FOR (BY -1, BY -2) — was 0 iterations — and FOR over
    // CHAR (was sema-rejected). Ascending unchanged.
    check("t-20-080-for-loops.mod", "55\n30\nABCDE\n15\n");
}

#[test]
fn t20_090_case_range() {
    // Sprint C: CASE arm ranges are no longer truncated to 256 entries (280 and
    // 800 used to fall to ELSE). Explicit lo<=val<=hi checks now.
    check("t-20-090-case-range.mod", "LLHM?\n");
}

#[test]
fn t20_110_forward_decl() {
    check("t-20-110-forward-decl.mod", "even\nodd\n");
}

#[test]
fn t20_100_const_builtins() {
    // Sprint G: MAX/MIN/SIZE/TSIZE in CONST expressions now fold to real
    // type-derived values (were a 0 placeholder), including over enums and
    // subranges and inside folded arithmetic.
    check(
        "t-20-100-const-builtins.mod",
        "MaxI8=127\nMinI16=-32768\nSzI32=4\nSzChar=2\nMaxCol=3\nMaxDig=9\nMinDig=0\nSpan=10\n",
    );
}

#[test]
fn t20_050_nested_proc() {
    // Non-capturing nested procedures (incl. nested recursion) lowered as
    // module-qualified Funcs.
    check("t-20-050-nested-proc.mod", "120\n7\n");
}

#[test]
fn t20_060_case_char() {
    // CASE with CHAR range/list labels and with enumeration labels.
    check("t-20-060-case-char.mod", "RBG\nda.a\n");
}

#[test]
fn t20_070_nested_capture() {
    // Capturing nested procedure: a nested `put` mutates the enclosing `pos`
    // and writes through the enclosing open-array VAR param `dst`.
    check("t-20-070-nested-capture.mod", "*****\n5\n");
}

// ── Group 30 — Strings / I/O ─────────────────────────────────────────────────

#[test]
fn t30_010_write_str() {
    check("t-30-010-write-str.mod", "hello world\n");
}

#[test]
fn t30_020_import_module() {
    check("t-30-020-import-module.mod", "17\n22\n");
}

#[test]
fn t30_030_import_scalars() {
    check("t-30-030-import-scalars.mod", "15\n16\nA\n0\n1\n");
}

#[test]
fn t30_040_import_state() {
    check("t-30-040-import-state.mod", "-12\n21\nZ\n1\n");
}

#[test]
fn t30_050_deep_import_graph() {
    check("t-30-050-deep-import-graph.mod", "37\n41\n");
}

#[test]
fn t30_060_module_init() {
    // An imported module's initialization body runs before the importer's.
    check("t-30-060-module-init.mod", "100\n");
}

#[test]
fn t30_070_enum_explicit_dense() {
    // Sprint G: ADW-style explicit enum ordinals are accepted when each equals
    // its position; the enum stays dense. ORD(blue)=2, MAX(Color)=blue=2.
    check("t-30-070-enum-explicit.mod", "2 2\n");
}

#[test]
fn t30_080_enum_sparse() {
    // Sprint G: a sparse enumeration (ADW / C-enum form) keeps each member's
    // explicit ordinal; a member with no value takes previous+1. ORD/MAX/MIN
    // reflect the real values. Code = (ok=0, warn=5, fail=10, fatal[=11]).
    check(
        "t-30-080-enum-sparse.mod",
        "ord_c=5\nord_fail=10\nord_fatal=11\nmax=11\nmin=0\n",
    );
}

// ── Group 40 — Records / pointers / NEW ──────────────────────────────────────

#[test]
fn t40_010_new_record() {
    check("t-40-010-new-record.mod", "99\n198\n");
}

#[test]
#[ignore = "imported helper procedures with local pointer records still fail in LLVM lowering"]
fn t40_020_import_record() {
    check("t-40-020-import-record.mod", "8\n13\nQ\n21\n");
}

#[test]
fn t40_030_multidim_array() {
    // Sprint D: full multi-dim indexing a[i,j] (was using only the first index)
    // and non-zero-based array lower-bound subtraction (ARRAY[1..3]).
    check("t-40-030-multidim-array.mod", "0 12 23 \n100 200 300 \n");
}

#[test]
fn t40_040_variant_record() {
    // Sprint D: VARIANT records. Fixed field + tag + arm fields each get a real
    // struct slot (the variant part used to be ignored: payload got 0 bytes and
    // every arm field aliased field 0).
    check("t-40-040-variant-record.mod", "C0 42 \n1 10 20 \n");
}

#[test]
fn t40_050_array_maxbound() {
    // Sprint G: a static array bound derived from MAX(INTEGER8) now sizes the
    // array to 128 elements (was 1 when MAX folded to 0). FOR 0..MAX fills it;
    // sum of 0..127 = 8128, and the bounds check accepts every in-range index.
    check("t-40-050-array-maxbound.mod", "sum=8128\n");
}

#[test]
fn t40_070_module_finalization() {
    // Sprint E: a module-level FINALLY is a *finalizer* run at program
    // termination in reverse initialization order (ISO LIFO), not immediately
    // after init. T40070Res initializes (init-res), main runs (main), then
    // finalizers run reversed: final-main (entry) before final-res (import).
    check(
        "t-40-070-modfinal.mod",
        "init-res\nmain\nfinal-main\nfinal-res\n",
    );
}

#[test]
fn t40_080_aggregate_const() {
    check("t-40-080-aggregate-const.mod", "5 9\n42 3 4\nhi\n");
}

#[test]
fn t40_090_const_array_index() {
    check("t-40-090-const-array-index.mod", "20\n30\n99\n");
}

#[test]
fn t40_060_with() {
    // WITH statement: a bare field name inside WITH r DO ... END resolves
    // against r's record. Covers a simple record, an array-element designator,
    // and nested WITH (inner field belongs to the inner record).
    check(
        "t-40-060-with.mod",
        "p.x=3\np.y=4\npts1.y=10\npts2.x=2\nln.a.x=1\nln.b.y=6\n",
    );
}

// ── Group 60 — SET (256-bit) ──────────────────────────────────────────────────

#[test]
fn t60_010_set_basic() {
    // SET OF CHAR ranges + singletons + IN membership.
    check("t-60-010-set-basic.mod", "1\n0\n1\n1\n1\n0\n");
}

#[test]
fn t60_020_runtime_math() {
    // M2 -> NM2.* runtime primitive call path (Frexp/Ldexp via rtdef).
    check("t-60-020-runtime-math.mod", "4\n1\n");
}

#[test]
fn t60_040_wide_io() {
    // Windows-wide CHAR internally (UTF-16) + UTF-8 at the I/O boundary.
    check("t-60-040-wide-io.mod", "café\nü\n");
}

#[test]
fn t60_030_open_array() {
    // Open-array ABI: HIGH/LEN (fixed array, open-array param, string) + a[i]
    // element indexing of an open-array parameter (Sum -> 15).
    check("t-60-030-open-array.mod", "4\n4\n4\n5\n15\n");
}

#[test]
fn t60_050_strings() {
    // Thin ISO Strings over open-array CHAR: cross-module qualified calls,
    // CompareResults enum return, VAR open-array destinations, ORD/CHR, INC.
    check(
        "t-60-050-strings.mod",
        "5\neq\nne\nworld\n5\nfoobar\nHELLO\nabcd\nless\n",
    );
}

#[test]
fn t60_060_char_string() {
    // A single-character literal is dual-typed: a CHAR and a length-1 string
    // assignable to an ARRAY OF CHAR parameter.
    check("t-60-060-char-string.mod", "x\nabc\n");
}

#[test]
fn t60_070_realmath() {
    // ISO RealMath over the NM2Math runtime (sqrt/power/exp/ln), exercising
    // import aliasing, math runtime, and ABS/FLOAT/TRUNC/MIN/MAX lowering.
    check("t-60-070-realmath.mod", "4\n1024\n1\n0\n");
}

#[test]
fn t60_080_longmath() {
    // ISO LongMath (LONGREAL) over the NM2Math runtime.
    check("t-60-080-longmath.mod", "9\n81\n");
}

#[test]
fn t60_090_charclass() {
    // ISO CharClass (ASCII classification; xPOSIX branch removed).
    check("t-60-090-charclass.mod", "TFTTTT\n");
}

#[test]
fn t60_100_wholestr() {
    // ISO WholeStr (CARDINAL/INTEGER -> string), over ConvTypes/CharClass.
    check("t-60-100-wholestr.mod", "-42\n1000\n7\n");
}

#[test]
fn t60_110_wholeconv() {
    // ISO WholeConv string->number, exercising unsigned CARDINAL semantics
    // (the overflow guard `n > (MAX(CARDINAL)-ord) DIV 10`).
    check("t-60-110-wholeconv.mod", "123\n-42\n4567\n3\n");
}

#[test]
fn t60_015_set_incl_excl() {
    // INCL/EXCL pervasives, empty `BITSET{}` constructor, IN membership.
    check("t-60-015-set-incl-excl.mod", "ynyn\n");
}

#[test]
fn t60_016_set_arith() {
    // Sprint A: set + - * are union/difference/intersection (were lowered as
    // integer arithmetic on the bitmask). union=1110, isect=10, diff=10.
    check("t-60-016-set-arith.mod", "11101010\n");
}

#[test]
fn t60_017_bitset_arith() {
    check("t-60-017-bitset-arith.mod", "union-ok\ndiff-ok\ninter-ok\n");
}

#[test]
fn t60_018_bitset_constructor() {
    check("t-60-018-bitset-constructor.mod", "ctor-ok\n");
}

#[test]
fn t60_019_val_set_cardinal() {
    check("t-60-019-val-set-cardinal.mod", "2048\n7\n");
}

#[test]
fn t60_120_storage() {
    // ISO Storage ALLOCATE/DEALLOCATE + SYSTEM.TSIZE + SYSTEM.CAST to a record
    // pointer, with field read/write through the pointer.
    check("t-60-120-storage.mod", "42\n");
}

#[test]
fn t60_130_semaphores() {
    // ISO Semaphores Create/Claim/CondClaim/Release/Destroy — exercises
    // VAR-of-pointer params, by-value pointer params, and `^.field` access.
    check("t-60-130-semaphores.mod", "n\ny\n");
}

#[test]
fn t60_140_lowreal() {
    // ISO LowReal scale/intpart/exponent — REAL<->ordinal bit-punning via
    // SYSTEM.CAST.
    check("t-60-140-lowreal.mod", "8\n3\n1\n");
}

#[test]
fn t60_150_lowlong() {
    // ISO LowLong scale/intpart/exponent — LONGREAL<->ordinal bit-punning.
    check("t-60-150-lowlong.mod", "16\n9\n1\n");
}

#[test]
fn t60_160_sysclock() {
    // ISO SysClock IsValidDateTime — drives the nested `isLeap` helper across
    // leap/non-leap/century-rule years; GetClock fills a valid record.
    check("t-60-160-sysclock.mod", "y\nn\nn\ny\nn\nvalid\n");
}

#[test]
fn t60_170_realstr() {
    // ISO RealStr — REAL formatting/parsing via the XReal engine (which uses
    // capturing nested procs). RealToFixed + StrToReal round-trip.
    check("t-60-170-realstr.mod", "3.14\n2.5\n0.125\n125.0\n-3.5\n");
}

#[test]
fn t60_180_longstr() {
    // ISO LongStr — LONGREAL formatting/parsing via XReal.
    check("t-60-180-longstr.mod", "3.1416\n1000.5\n0.0625\n");
}

#[test]
fn t60_190_realconv() {
    // ISO RealConv — ValueReal (string→REAL) + LengthFixedReal.
    check("t-60-190-realconv.mod", "42.5\n4\n");
}

#[test]
fn t60_200_longconv() {
    // ISO LongConv — ValueReal (string→LONGREAL) + LengthFixedReal.
    check("t-60-200-longconv.mod", "6.25\n6\n");
}

#[test]
fn t60_210_complexmath() {
    // ISO ComplexMath — COMPLEX type, RE/IM/CMPLX, abs/conj/sqrt, and complex
    // equality against the exported CMPLX-CONST `zero`.
    check("t-60-210-complexmath.mod", "5.00\n3.00\n-4.00\n2.00\n0.00\nzero-ok\n");
}

#[test]
fn t60_220_longcomplexmath() {
    // ISO LongComplexMath — LONGCOMPLEX abs + scalarMult.
    check("t-60-220-longcomplexmath.mod", "13.00\n3.00\n6.00\n");
}

// ── Group 70 — Exceptions ────────────────────────────────────────────────────

#[test]
fn t70_010_except() {
    // Module-body EXCEPT catches a RAISE, dispatches on the (shared) source,
    // and reads CurrentExceptionNumber.
    check("t-70-010-except.mod", "guarded\nmysrc n=42\n");
}

#[test]
fn t70_020_finally() {
    // FINALLY runs after the protected region completes normally.
    check("t-70-020-finally.mod", "work\ncleanup\n");
}

#[test]
fn t70_030_retry() {
    // RETRY re-runs the protected region; a module counter persists across
    // attempts until the raise condition clears.
    check("t-70-030-retry.mod", "1\n2\n3\nok\n");
}

#[test]
fn t70_040_proc_except() {
    // Procedure-body EXCEPT in a FUNCTION: param/local shared with the outlined
    // protected fn, RETURN via the result slot, handler returns on raise.
    check("t-70-040-proc-except.mod", "10\n0\n");
}

#[test]
fn t70_050_proc_openarray() {
    // Procedure-body EXCEPT with an open-array param + VAR out-param shared
    // through the exception frame.
    check("t-70-050-proc-openarray.mod", "131\n9999\n");
}

#[test]
fn t70_060_iso_exceptions() {
    // ISO EXCEPTIONS module surface (thin M2 wrapper over NM2RT).
    check("t-70-060-iso-exceptions.mod", "try\ncaught 5\n");
}

#[test]
fn t70_070_message() {
    // A multi-char exception message round-trips (wide UTF-16) through RAISE
    // and EXCEPTIONS.GetMessage.
    check("t-70-070-message.mod", "file not found\n");
}

#[test]
fn t70_080_proc_retry() {
    // RETRY in a procedure handler re-uses the exception frame across re-runs
    // (freed only on final exit); a VAR counter persists across attempts.
    check("t-70-080-proc-retry.mod", "3\n");
}

#[test]
fn t70_090_general_exception() {
    // ISO GeneralUserExceptions: raise + catch via the EXCEPTIONS machinery.
    check("t-70-090-genexc.mod", "caught-general\n");
}

#[test]
fn t70_100_case_nomatch() {
    // Sprint F: a CASE selector matching no label and no ELSE raises a catchable
    // M2EXCEPTION.caseSelectException (was a silent fall-through). pick(1)='A',
    // pick(9) raises -> EXCEPT writes 'X'.
    check("t-70-100-case-nomatch.mod", "AX");
}

#[test]
fn t70_110_bounds_check() {
    // Sprint F: array index bounds check (on by default) raises a catchable
    // indexException. a[1]=20 (in bounds), a[5] raises -> EXCEPT writes " OOB".
    check("t-70-110-bounds-check.mod", "20 OOB");
}

#[test]
fn t70_120_m2exception() {
    // Sprint F: the M2EXCEPTION module — IsM2Exception() + M2Exception() let a
    // handler discriminate language exceptions. An OOB index raises and is
    // identified as M2EXCEPTION.indexException.
    check("t-70-120-m2exception.mod", "index\n");
}

#[test]
fn t70_130_div_zero() {
    // Sprint F: whole-number division by zero raises catchable wholeDivException.
    // 10 DIV 2 = 5, then 10 DIV 0 raises -> discriminated as wholeDivException.
    check("t-70-130-div-zero.mod", "5 divzero");
}

#[test]
fn t70_140_uncaught_diagnostic() {
    // Sprint F: an exception that escapes to the JIT entry boundary no longer
    // aborts silently — it surfaces a named diagnostic naming the M2EXCEPTION.
    // a[9] on ARRAY [0..3] raises an uncaught indexException.
    check_run_error(
        "t-70-140-uncaught.mod",
        &["unhandled exception", "M2EXCEPTION.indexException"],
    );
}

#[test]
fn t70_150_nil_deref() {
    // Sprint F: dereferencing NIL raises a catchable invalidLocation (ISO).
    // p := NIL; p^.value -> invalidLocation, discriminated via M2EXCEPTION.
    check("t-70-150-nil-deref.mod", "nilderef\n");
}

#[test]
fn t70_160_reraise() {
    // Sprint F: NM2RT.Reraise propagates the current exception to the caller's
    // handler with source/number intact. Inner handler notes it ("inner ") then
    // reraises; outer handler matches source+number 7 ("outer7").
    check("t-70-160-reraise.mod", "inner outer7\n");
}

// ── Group 61 — ISO library conformance (Sprint I) ────────────────────────────

#[test]
fn t61_010_conf_strings() {
    // Strings edge cases under-covered by t-60-*: Extract/Delete/Insert/Replace/FindNext.
    check("t-61-010-conf-strings.mod", "PASS\n");
}

#[test]
fn t61_020_conf_charclass() {
    // CharClass control/whitespace/boundary characters.
    check("t-61-020-conf-charclass.mod", "PASS\n");
}

#[test]
fn t61_030_conf_complexmath() {
    // ComplexMath arg / polarToComplex / scalarMult / power(i,2)=-1.
    check("t-61-030-conf-complexmath.mod", "PASS\n");
}

#[test]
fn t61_040_conf_semaphores() {
    // Semaphores CondClaim count semantics (single-threaded port).
    check("t-61-040-conf-semaphores.mod", "PASS\n");
}

#[test]
fn t61_050_conf_realmath() {
    // Sprint J fix: RealMath.round rounds to nearest (was floor) + trig.
    check("t-61-050-conf-realmath.mod", "PASS\n");
}

#[test]
fn t61_060_conf_sioresult() {
    // Sprint J fix: SIOResult resolves its def-only IOConsts import.
    check("t-61-060-conf-sioresult.mod", "notKnown\n");
}

#[test]
fn t61_070_conf_termination() {
    // Sprint J: HALT now runs module finalizers (ISO), and TERMINATION.HasHalted
    // observes it; "after-halt" is skipped.
    check("t-61-070-conf-termination.mod", "before\nhalted\n");
}

// ── Group 50 — GC / memory ───────────────────────────────────────────────────

#[test]
fn t50_010_gc_alloc() {
    // Last serial = (100-1) * 3 = 297
    check("t-50-010-gc-alloc.mod", "297\n");
}

#[test]
fn t50_090_byte_array_param() {
    check("t-50-090-byte-array-param.mod", "8\n2\n8\n");
}

#[test]
fn t50_100_system_word_int() {
    check("t-50-100-system-word-int.mod", "105\n66\n");
}

#[test]
#[ignore = "blocked on missing helper module \"Float\" (NearestToInt32/RaisedFPExceptions) in the test search path; SET-constructor lowering it once waited on now works"]
fn t50_070_float_library() {
    check_test("t-50-070-float-library.mod").unwrap();
}

#[test]
fn t11_010_const_overflow() {
    // Hardening (semantics audit #2): an overflowing constant expression must
    // produce a clean diagnostic, not panic the compiler. `check_test` returns
    // the joined diagnostics as Err.
    let err = check_test("t-11-010-const-overflow.mod")
        .expect_err("overflowing constant must be rejected");
    assert!(
        err.contains("constant overflow"),
        "expected a 'constant overflow' diagnostic, got: {err}"
    );
}

#[cfg(feature = "gc")]
#[test]
fn gc_system_collect_gcreport() {
    check_contains_all(
        "gc-system-collect-gcreport.mod",
        &[
            "gc.enabled=1",
            "gc.collect_cycles=",
            "gc.collect_last_nanos=",
            "gc.live_blocks=",
            "gc.live_bytes=",
            "gc.last.generation=",
        ],
    );
}

#[cfg(feature = "gc")]
#[test]
fn gc_report_reclaims_transient_allocations() {
    check_gc_report(
        "gc-report-transient-alloc.mod",
        None,
        &[
            "gc.collect_cycles=",
            "gc.collect_last_reclaimed_bytes=",
            "gc.last.bytes_freed=",
        ],
        |metrics, baseline_collect_cycles, baseline_alloc_blocks, _baseline_grow_events| {
            let collect_cycles = require_metric(metrics, "gc.collect_cycles")?;
            let alloc_blocks = require_metric(metrics, "gc.alloc_blocks_lifetime")?;
            let reclaimed = require_metric(metrics, "gc.collect_last_reclaimed_bytes")?;
            let freed = require_metric(metrics, "gc.last.bytes_freed")?;

            if collect_cycles <= baseline_collect_cycles {
                return Err(format!(
                    "expected gc.collect_cycles > {baseline_collect_cycles}, got {collect_cycles}"
                ));
            }
            if alloc_blocks <= baseline_alloc_blocks {
                return Err(format!(
                    "expected gc.alloc_blocks_lifetime > {baseline_alloc_blocks}, got {alloc_blocks}"
                ));
            }
            if reclaimed == 0 {
                return Err("expected gc.collect_last_reclaimed_bytes > 0".to_string());
            }
            if freed == 0 {
                return Err("expected gc.last.bytes_freed > 0".to_string());
            }
            Ok(())
        },
    );
}

#[cfg(feature = "gc")]
#[test]
fn gc_report_collects_multiple_explicit_waves() {
    check_gc_report(
        "gc-report-retained-live.mod",
        None,
        &[
            "gc.collect_cycles=",
            "gc.collect_last_reclaimed_bytes=",
            "gc.last.bytes_freed=",
        ],
        |metrics, baseline_collect_cycles, baseline_alloc_blocks, _baseline_grow_events| {
            let collect_cycles = require_metric(metrics, "gc.collect_cycles")?;
            let alloc_blocks = require_metric(metrics, "gc.alloc_blocks_lifetime")?;
            let reclaimed = require_metric(metrics, "gc.collect_last_reclaimed_bytes")?;
            let freed = require_metric(metrics, "gc.last.bytes_freed")?;

            if collect_cycles < baseline_collect_cycles + 2 {
                return Err(format!(
                    "expected gc.collect_cycles >= {}, got {collect_cycles}",
                    baseline_collect_cycles + 2,
                ));
            }
            if alloc_blocks <= baseline_alloc_blocks {
                return Err(format!(
                    "expected gc.alloc_blocks_lifetime > {baseline_alloc_blocks}, got {alloc_blocks}"
                ));
            }
            if reclaimed == 0 {
                return Err("expected gc.collect_last_reclaimed_bytes > 0".to_string());
            }
            if freed == 0 {
                return Err("expected gc.last.bytes_freed > 0".to_string());
            }
            Ok(())
        },
    );
}

#[cfg(feature = "gc")]
#[test]
fn gc_pressure_triggers_collection_during_allocation_churn() {
    const TEST_PRESSURE_THRESHOLD: u64 = 4 * 1024;

    check_gc_report(
        "gc-report-pressure-churn.mod",
        Some(TEST_PRESSURE_THRESHOLD),
        &[
            "gc.collect_cycles=",
            "gc.pressure_threshold=4096",
            "gc.grow_events=",
        ],
        |metrics, baseline_collect_cycles, baseline_alloc_blocks, _baseline_grow_events| {
            let collect_cycles = require_metric(metrics, "gc.collect_cycles")?;
            let alloc_blocks = require_metric(metrics, "gc.alloc_blocks_lifetime")?;
            let reported_threshold = require_metric(metrics, "gc.pressure_threshold")?;

            if collect_cycles <= baseline_collect_cycles {
                return Err(format!(
                    "expected gc.collect_cycles > {baseline_collect_cycles}, got {collect_cycles}"
                ));
            }
            if alloc_blocks <= baseline_alloc_blocks {
                return Err(format!(
                    "expected gc.alloc_blocks_lifetime > {baseline_alloc_blocks}, got {alloc_blocks}"
                ));
            }
            if reported_threshold != TEST_PRESSURE_THRESHOLD {
                return Err(format!(
                    "expected gc.pressure_threshold = {TEST_PRESSURE_THRESHOLD}, got {reported_threshold}"
                ));
            }
            Ok(())
        },
    );
}

#[cfg(feature = "gc")]
#[test]
fn gc_report_grows_clusters_for_large_live_graph() {
    check_gc_report(
        "gc-report-grow-clusters.mod",
        None,
        &[
            "gc.grow_events=",
            "gc.alloc_bytes_lifetime=",
        ],
        |metrics, _baseline_collect_cycles, baseline_alloc_blocks, baseline_grow_events| {
            let grow_events = require_metric(metrics, "gc.grow_events")?;
            let alloc_blocks = require_metric(metrics, "gc.alloc_blocks_lifetime")?;
            let alloc_bytes = require_metric(metrics, "gc.alloc_bytes_lifetime")?;

            if grow_events <= baseline_grow_events {
                return Err(format!(
                    "expected gc.grow_events > {baseline_grow_events}, got {grow_events}"
                ));
            }
            if alloc_blocks <= baseline_alloc_blocks {
                return Err(format!(
                    "expected gc.alloc_blocks_lifetime > {baseline_alloc_blocks}, got {alloc_blocks}"
                ));
            }
            if alloc_bytes < 1_048_576 {
                return Err(format!(
                    "expected gc.alloc_bytes_lifetime >= 1048576, got {alloc_bytes}"
                ));
            }
            Ok(())
        },
    );
}

#[cfg(feature = "gc")]
#[test]
#[ignore = "GC quarantined; oversized-allocation reclamation assertion needs revisiting if GC is revived"]
fn gc_report_frees_oversized_allocation_after_growth() {
    check_gc_report(
        "gc-report-grow-then-free.mod",
        None,
        &[
            "gc.grow_events=",
            "gc.collect_last_reclaimed_bytes=",
            "gc.live_bytes=",
            "gc.last.bytes_live_after=",
        ],
        |metrics, baseline_collect_cycles, baseline_alloc_blocks, baseline_grow_events| {
            let grow_events = require_metric(metrics, "gc.grow_events")?;
            let collect_cycles = require_metric(metrics, "gc.collect_cycles")?;
            let alloc_blocks = require_metric(metrics, "gc.alloc_blocks_lifetime")?;
            let reclaimed = require_metric(metrics, "gc.collect_last_reclaimed_bytes")?;
            let live_bytes = require_metric(metrics, "gc.live_bytes")?;
            let live_after = require_metric(metrics, "gc.last.bytes_live_after")?;

            if grow_events <= baseline_grow_events {
                return Err(format!(
                    "expected gc.grow_events > {baseline_grow_events}, got {grow_events}"
                ));
            }
            if collect_cycles <= baseline_collect_cycles {
                return Err(format!(
                    "expected gc.collect_cycles > {baseline_collect_cycles}, got {collect_cycles}"
                ));
            }
            if alloc_blocks <= baseline_alloc_blocks {
                return Err(format!(
                    "expected gc.alloc_blocks_lifetime > {baseline_alloc_blocks}, got {alloc_blocks}"
                ));
            }
            if reclaimed < 1_000_000 {
                return Err(format!(
                    "expected gc.collect_last_reclaimed_bytes >= 1000000, got {reclaimed}"
                ));
            }
            if live_bytes != 0 {
                return Err(format!(
                    "expected gc.live_bytes = 0 after collection, got {live_bytes}"
                ));
            }
            if live_after != 0 {
                return Err(format!(
                    "expected gc.last.bytes_live_after = 0 after collection, got {live_after}"
                ));
            }
            Ok(())
        },
    );
}

// ── Group 80 — ISO I/O channel stack ─────────────────────────────────────────

#[test]
fn t80_010_channel_io() {
    // TextIO/WholeIO writing through StdChans.OutChan() — exercises the full
    // device-dispatch stack (IOChan → IOLink DeviceTable proc-pointers →
    // StdChans console device → NM2IO runtime).
    check("t-80-010-channel-io.mod", "hello\n  1234\n-42\n");
}

#[test]
fn t80_020_simple_io() {
    // Simple I/O facades (STextIO/SWholeIO) over the default StdChans channels.
    check("t-80-020-simple-io.mod", "x=  7\n-5\n");
}

#[test]
fn t80_030_real_io() {
    // ISO RealIO fixed-point output over a channel (XReal engine + field
    // widths via the channel device stack).
    check("t-80-030-real-io.mod", "    3.14\n 0.500\n 100.0\n");
}

#[test]
fn t80_040_file_io() {
    // ISO SeqFile text round-trip: write to a file via a channel, reopen, read
    // back — the file device + NM2File runtime (UTF-16↔UTF-8 text path).
    check("t-80-040-file-io.mod", "file-roundtrip\n");
}

#[test]
fn t80_070_complex_arith() {
    // COMPLEX arithmetic (+ - * /) by component. (3+4i)+(1+2i)=4+6i,
    // -(1+2i)=2+2i, *(1+2i)=-5+10i, /(1+2i)=2.2-0.4i.
    check(
        "t-80-070-complex-arith.mod",
        " 4.0  6.0\n 2.0  2.0\n -5.0  10.0\n 2.2  -0.4\n",
    );
}

#[test]
fn t80_050_const_param() {
    // Sprint E: a CONST parameter accepts any argument expression (it used to be
    // VAR-like and reject non-designators). Sum(x, 5)=15, Sum(x+1, x*2)=31.
    check("t-80-050-const-param.mod", "15\n31\n");
}

#[test]
fn t80_060_const_readonly() {
    // Sprint E: assigning to a CONST parameter is a compile error.
    check_run_error("t-80-060-const-readonly.mod", &["cannot assign to a CONST parameter"]);
}

#[test]
fn t90_020_coroutine() {
    // Sprint H: SYSTEM.NEWPROCESS / TRANSFER via Win32 fibers. Main creates a
    // worker coroutine and ping-pongs control to it three times; the worker
    // prints the shared counter and yields back. Then main prints "done".
    check(
        "t-90-020-coroutine.mod",
        "worker 1\nworker 2\nworker 3\ndone\n",
    );
}

#[test]
fn t90_090_local_module() {
    // Sprint K: LOCAL MODULE — encapsulated static (count) shared by exported
    // procedures, import from the enclosing scope, and an init body that runs
    // before the enclosing BEGIN. 100 +1+1 = 102.
    check("t-90-090-local-module.mod", "102\n");
}

#[test]
fn t90_110_com_server() {
    // Sprint M: COM *server* proof. An M2 class implements IUnknown
    // (QueryInterface/AddRef/Release) + a custom Bump slot; NM2RT.ComDrive, an
    // external COM client in the runtime, loads the vtable from the object
    // pointer and calls the slots with the object as `this` — the COM ABI. So
    // an M2 object IS a callable COM interface. Witness 1201 = QI ok (1000),
    // AddRef->2 (200), Release->1 (1); refs balanced to 1; Bump mutated to 41.
    check("t-90-110-com-server.mod", "1201\n1\n41\n");
}

#[test]
fn t90_120_native_callback() {
    // Sprint M: native callback proof. An M2 procedure variable lowers to a raw
    // C function pointer; NM2RT.SortInts (runtime) sorts an INTEGER array in
    // place, calling back into the M2 comparator for every comparison — the
    // dual of the COM server (external code drives M2 via a function pointer).
    check("t-90-120-native-callback.mod", "1 2 4 5 8 \n8 5 4 2 1 \n");
}

#[test]
fn t90_130_libc_printf() {
    check("t-90-130-libc-printf.mod", "one\ntwo\n");
}

#[test]
fn t90_140_pim_libs() {
    check("t-90-140-pim-libs.mod", "pim libs\nequal\n5\n42\n");
}

#[test]
fn t90_150_m2rts_loc_builtins() {
    check("t-90-150-m2rts-loc-builtins.mod", "5\nasserts-ok\n");
}

#[test]
fn t90_160_complex_neg() {
    check("t-90-160-complex-neg.mod", "ok\n");
}

#[test]
fn t90_161_adr_string() {
    check("t-90-161-adr-string.mod", "11\n");
}

#[test]
fn t90_175_stdio() {
    check("t-90-175-stdio.mod", "hi\n");
}

#[test]
fn t90_176_module_global_var() {
    check("t-90-176-module-global-var.mod", "done\n");
}

#[test]
fn t90_177_fio() {
    check("t-90-177-fio.mod", "hello 42\n");
}

#[test]
fn t90_178_from_import_global() {
    check("t-90-178-from-import-global.mod", "t f\n");
}

#[test]
fn t90_179_max_min_set() {
    check("t-90-179-max-min-set.mod", "127 0\ncounted 128\n");
}

#[test]
fn t90_180_const_builtins() {
    check("t-90-180-const-builtins.mod", "1 0\n90\n11\n");
}

#[test]
fn t90_181_def_imports() {
    check("t-90-181-def-imports.mod", "8\n");
}

#[test]
fn t90_182_builtin_qualifier() {
    check("t-90-182-builtin-qualifier.mod", "5 9\n");
}

#[test]
fn t90_183_word_widths() {
    check("t-90-183-word-widths.mod", "2 4 8\n70000\n");
}

#[test]
fn t90_184_return_char_array() {
    check("t-90-184-return-char-array.mod", "hello world\n11\n");
}

#[test]
fn t90_185_system_throw() {
    check("t-90-185-system-throw.mod", "before\ncaught\n");
}

#[test]
fn t90_186_nested_aggregate_strings() {
    check("t-90-186-nested-aggregate-strings.mod", "12|34\n56|78\n");
}

#[test]
fn t90_187_local_module_import() {
    // A nested local module imports symbols from the enclosing scope (PIM
    // semantics) and exports a procedure back to it.
    check("t-90-187-local-module-import.mod", "outer\ninner 7\n");
}

#[test]
fn t90_188_inline_enum_members() {
    // Members of an anonymous enumeration used as an array element type are
    // visible as ordinal constants in the enclosing scope.
    check("t-90-188-inline-enum-members.mod", "2\n0\n");
}

#[test]
fn t90_189_empty_variant_arms() {
    // Empty variant arms (`|||`, `||`) are tolerated; the record still selects
    // the right field by tag.
    check("t-90-189-empty-variant-arms.mod", "65\n7\n");
}

#[test]
fn t90_190_min_max_of_variable() {
    // MIN(v) / MAX(v) accept a variable and yield its type's bounds.
    check("t-90-190-min-max-of-variable.mod", "10\n40\n");
}

#[test]
fn t90_191_for_char_step() {
    // A FOR loop over CHAR with an ordinal step `BY CHR(2)` steps by 2.
    check("t-90-191-for-char-step.mod", "ace\n13\n");
}

#[test]
fn t90_192_char_array_by_value_arg() {
    // A string/char literal passed by value to a fixed ARRAY OF CHAR parameter
    // is copied into the array.
    check("t-90-192-char-array-by-value-arg.mod", "z\nhi\n");
}

#[test]
fn t90_193_aggregate_open_array_arg() {
    // An aggregate constructor passed to an open ARRAY OF parameter is spilled
    // to a slot so the open-array ABI receives a data pointer.
    check("t-90-193-aggregate-open-array-arg.mod", "5\n10\n15\n");
}

#[test]
fn t90_194_partial_array_index() {
    // Indexing a multi-dim array with fewer indices than dimensions yields a
    // sub-array; chained `m[r][c]` reaches the same element as full `m[r,c]`.
    check("t-90-194-partial-array-index.mod", "7\nok\n");
}

#[test]
fn t90_196_storage_available() {
    // Storage.Available probes the heap for a request size.
    check("t-90-196-storage-available.mod", "yes\nyes\n");
}

#[test]
fn t90_198_enum_type_import_members() {
    // `FROM M IMPORT EnumType` surfaces the enumeration's member constants.
    check("t-90-198-enum-type-import-members.mod", "yes\nno\n");
}

#[test]
fn t90_199_address_cast_roundtrip() {
    // ADDRESS/CAST int<->ptr conversions lower without crashing codegen.
    check("t-90-199-address-cast-roundtrip.mod", "nonzero\nnil\n");
}

#[test]
fn t90_200_char_concat() {
    // `+` concatenates chars/strings (never arithmetic on chars); a constant
    // char concatenation passed to an open array carries the right length.
    check("t-90-200-char-concat.mod", "World 5\n2\n");
}

#[test]
fn t90_201_forward_const() {
    // A constant may reference constants declared later in the same scope.
    check("t-90-201-forward-const.mod", "hello world\n11\n");
}

#[test]
fn t90_202_char_indexed_array() {
    // An array indexed by a bare built-in ordinal type (`ARRAY CHAR OF …`) is
    // sized by the type's full cardinality, not collapsed to one element.
    check("t-90-202-char-indexed-array.mod", "198\nyes\n");
}

#[test]
fn t90_203_raw_byte_io() {
    // Raw channel I/O moves bytes verbatim: a 4-byte block (incl. a high byte
    // and an embedded NUL) round-trips through StreamFile RawWrite/RawRead. The
    // disk devices previously wired raw read/write to the UTF-16 text path,
    // corrupting bytes; doRawRead/doRawWrite now use the byte-oriented path.
    check("t-90-203-raw-byte-io.mod", "ok\n");
}

#[test]
fn t90_204_narrow_floats() {
    // True narrow IEEE floats: REAL32/SHORTREAL = f32 (SIZE 4), REAL16 = f16
    // (SIZE 2), distinct from REAL. f32/f16 arithmetic + TRUNC run end to end
    // through the JIT (f16 via the x86 F16C / soft-float conversion path).
    check("t-90-204-narrow-floats.mod", "6\n3\n4\n2\n");
}

#[test]
fn t90_205_simd_vectors() {
    // First-class SIMD lane vectors (Phase 1): REAL32X4 / REAL64X2 element-wise
    // arithmetic, scalar broadcast, lane read/write, and arrays of vectors —
    // lowered to LLVM <N x T> packed ops.
    check("t-90-205-simd-vectors.mod", "11\n44\n4\n30\n100\n400\n2\n");
}

#[test]
fn t90_206_simd_reductions() {
    // SIMD reductions + FMA (Phase 2): SUM (llvm.vector.reduce.fadd), DOT,
    // FMA (llvm.fma), ABS (llvm.fabs) over REAL32X4 / REAL64X2.
    check("t-90-206-simd-reductions.mod", "10\n100\n44\n14\n25\n");
}

#[test]
fn t90_207_simd_nested_lanes() {
    // Hardening: lane access through record fields / array elements
    // (rec.v[i], grid[k][i]) reads/writes the whole addressable vector via
    // extract/insertelement — no adjacent-lane corruption; plus packed fneg
    // and a mixed f32-lane * f64-literal.
    check("t-90-207-simd-nested-lanes.mod", "99\n3\n50\n6\n5\n");
}

#[test]
fn t90_208_winrt_crc() {
    // M2WINRT runtime library — GenCRC: reflected CRC-32 (zip/gzip/PNG). The
    // module-init table build, BXOR/SHR/BAND, hex literals and raw byte access
    // all run end to end; the known-answer vector CRC-32("123456789") =
    // 0CBF43926H and the incremental path agrees bit-for-bit.
    check("t-90-208-winrt-crc.mod", "3421780262\n3421780262\n");
}

#[test]
fn t90_209_winrt_conversions() {
    // M2WINRT runtime library — Conversions: whole<->string, decimal and base
    // 2..16, overflow-checked. Magnitude/sign split, VAR result params and
    // field-width padding.
    check(
        "t-90-209-winrt-conversions.mod",
        "255\nFF\n11111111\nDEADBEEF\n12345\n-678\n255\n10\n[   -42]\n",
    );
}

#[test]
fn t90_210_winrt_exstrings() {
    // M2WINRT runtime library — ExStrings: case-insensitive compare/search,
    // in-place case folding, appenders, and find/replace over CHAR-width-
    // neutral open arrays.
    check(
        "t-90-210-winrt-exstrings.mod",
        "Y\nN\nY\nY\n6\nmixedcase\nMIXEDCASE\nX42=00FF\nY\nthe dog sat\n11\n",
    );
}

#[test]
fn t90_211_winrt_specialreals() {
    // M2WINRT (Phase 1) — SpecialReals: IEEE-754 f64 special values as CONST
    // CAST(REAL,<bits>) (exercising the const-fold bit-reinterpret fix) +
    // bit-pattern classification predicates. Cols: Fin NaN QNaN SNaN Inf +Inf -Inf -0.
    check(
        "t-90-211-winrt-specialreals.mod",
        "Inf  NNNNYYNN\n-Inf NNNNYNYN\nQNaN NYYNNNNN\nSNaN NYNYNNNN\n-0   YNNNNNNY\n3.5  YNNNNNNN\n",
    );
}

#[test]
fn t90_212_winrt_memutils() {
    // M2WINRT (Phase 1) — MemUtils: portable fill/zero/scan/compare and
    // overlap-safe move (the critical backward-copy case), plus SecureZeroMem
    // and constant-time EqualCT. Exercises CAST(ADDRESS<->CARDINAL), the giant
    // POINTER TO ARRAY OF BYTE type, and zero-count loop safety.
    check(
        "t-90-212-winrt-memutils.mod",
        "170 0\n52 18 52 18 52 18\n239 205 171 137 103 69 35 1\n2 0 5 1\n\
         1 2 1 2 3 4 5 6\n3 4 5 6 7 8 7 8\n2\n16\nY\nN\nY\n",
    );
}

#[test]
fn t90_213_winrt_sortlib() {
    // M2WINRT (Phase 1) — SortLib: all five abstract callback-driven sorts via
    // compare/swap/assign-by-index PROCEDURE parameters. Strong indirect-call /
    // nested-procedure stress test.
    check(
        "t-90-213-winrt-sortlib.mod",
        "Q 1 2 2 3 5 8 8 9\nH 1 2 2 3 5 8 8 9\nS 1 2 2 3 5 8 8 9\n\
         B 1 2 2 3 5 8 8 9\nM 1 2 2 3 5 8 8 9\n",
    );
}

#[test]
fn t90_214_winrt_money() {
    // M2WINRT (Phase 1) — Money: fixed-point currency with synthesized 128-bit
    // intermediate Mul/Div (the 1e6*1e6 product overflows 64-bit), half-up
    // rounding, sign handling, percentages, and string round-trips.
    check(
        "t-90-214-winrt-money.mod",
        "5.00\n2.75\n-2.75\n10.00\n0.0000\n0.0100\n2.50\n0.3333\n1000000000000.00\n\
         14.00\nparse ok=Y -> -1234.5678\n3.5000\n0.1235\ngarbage rejected=Y\n",
    );
}

#[test]
fn t90_215_compiler_semantics() {
    // Language-semantics regressions found by adversarial review of the
    // Phase-1 modules and fixed in the compiler: (1) AND/OR/& short-circuit;
    // (2) REAL `#` is unordered not-equal (NaN # NaN = TRUE); (3) CARDINAL
    // DIV/MOD by a non-negative named CONST is unsigned (bit-63 dividend).
    check(
        "t-90-215-compiler-semantics.mod",
        "sc 0 0 0\nnan N Y\nnegprop ok\nudiv 922337203685478 807\n",
    );
}

#[test]
fn t90_216_winrt_randomnumbers() {
    // M2WINRT (Phase 2) — RandomNumbers: the NON-crypto lagged-Fibonacci PRNG.
    // Known-answer (seed=1 raw words; seed=12345 Rnd(100)) cross-checked against
    // an independent reference; plus determinism.
    check(
        "t-90-216-winrt-randomnumbers.mod",
        "16826983207204404568\n11868665664293886290\n15636431333310144292\n\
         5703284894643461686\n7645942511238512128\n80 46 28 74 76 94 76 2\ndet Y\n",
    );
}

#[test]
fn t90_217_winrt_securerandom() {
    // M2WINRT (Phase 2) — SecureRandom: OS CSPRNG via a DIRECT Windows
    // BCryptGenRandom call from M2 (no Rust shim). Property assertions over the
    // non-deterministic RNG; also covers direct-Win32 binding at the JIT.
    check(
        "t-90-217-winrt-securerandom.mod",
        "fill ok: Y\ndistinct words: Y\nNextBelow(100) in range 1000/1000\n\
         NextRange(10,20) in range 1000/1000\nNextBelow(256) in range 1000/1000\n",
    );
}

#[test]
fn t90_218_winrt_timefunc() {
    // M2WINRT (Phase 2) — TimeFunc: proleptic-Gregorian calendar math over
    // SysClock.DateTime (weekday, ANSI-C time_t incl. the famous 1234567890,
    // DOS/FAT pack+unpack, ordering). Known-answer vs an independent reference.
    check(
        "t-90-218-winrt-timefunc.mod",
        "dow 4 6 4 4\n0\n1000000000\n1234567890\n1709208000\n\
         rt 2009-2-13 23:31:30\ndos 23757 29654\nundos 2026-6-13 14:30:44\ncmp -1 1 0\n",
    );
}

#[test]
fn t90_219_winrt_elapsedtime() {
    // M2WINRT (Phase 2) — ElapsedTime: high-resolution timing via DIRECT
    // QueryPerformanceCounter/Frequency + Sleep from M2 (no Rust shim).
    // Bulletproof timing properties only (Sleep never returns early).
    check(
        "t-90-219-winrt-elapsedtime.mod",
        "slept (>=10ms): Y\nmicros >= millis: Y\n",
    );
}

#[test]
fn t90_220_winrt_formatstring() {
    // M2WINRT (Phase 2) — FormatString: printf-style formatting via a
    // non-variadic typed-argument vector (NewM2 can't iterate C varargs).
    // %-spec grammar, width/justification, sign-aware zero-pad, %%, escapes,
    // and the fewer-args-than-specs -> FALSE contract.
    check(
        "t-90-220-winrt-formatstring.mod",
        "int=-42\nu=7\nhex=deadbeef HEX=DEADBEEF\nhi world!\n[    5][5    ][-0042]\n\
         ch=Q TRUE FALSE\n100% done\nn=1 s=world h=FF\nmissing-arg ok=N out=[a=1 b=]\n",
    );
}

#[test]
fn t90_221_winrt_environment() {
    // M2WINRT (Phase 3) — Environment: direct Win32 W-API calls from M2
    // (Get/SetEnvironmentVariableW, GetModuleFileNameW, GetCommandLineW).
    // 16-bit CHAR == WCHAR, so ARRAY OF CHAR is the wide-string buffer.
    check(
        "t-90-221-winrt-environment.mod",
        "set: Y\nget: Y [round-trip-value]\nafter-remove: N\nmissing: N\n\
         OS present: Y\nexepath: Y Y\ncmdline nonempty: Y\n",
    );
}

#[test]
fn t90_222_winrt_registry() {
    // M2WINRT (Phase 3) — Registry: typed wrapper over the advapi32 registry
    // W-APIs (direct from M2). String + DWORD round-trip through a HKCU subkey,
    // then value/key deletion (self-cleaning; HKCU-default per the P3 rule).
    check(
        "t-90-222-winrt-registry.mod",
        "setstr Y\ngetstr Y [hello-registry]\nsetcard Y\ngetcard Y 12345\n\
         delval Y\ngetstr-after-del N\ndelkey Y\n",
    );
}

#[test]
fn t90_223_winrt_filefunc() {
    // M2WINRT (Phase 3) — FileFunc: binary file abstraction over the Windows
    // file W-APIs (direct from M2). Create/write/read round-trip + verify,
    // size, seek, delete (self-cleaning temp file).
    check(
        "t-90-223-winrt-filefunc.mod",
        "create valid: Y\nwrite n=16\nsize=16\nread n=16\nmatch: Y\n\
         seek-read: 69 72\ndelete: Y\nexists-after: N\n",
    );
}

#[test]
fn t90_224_winrt_threads() {
    // M2WINRT (Phase 3) — Threads: real OS threads running M2 code + a recursive
    // CRITICAL_SECTION lock, all via direct Win32. 8 threads increment a shared
    // counter under the lock -> exactly 400000 (mutual exclusion, no lost
    // updates); every Join returns in time. (No GC in default/AOT mode makes a
    // foreign-thread M2 procedure safe.) Also covers the int->ptr FFI coercion
    // fix needed for the ADRCARD `dwStackSize` argument.
    check(
        "t-90-224-winrt-threads.mod",
        "joined all: Y\nmutual exclusion (400000): Y\n",
    );
}

#[test]
fn t90_225_winrt_hash() {
    // M2WINRT (Phase 4) — Hash: SHA-2 digests via the Windows CNG BCryptHash
    // façade (no roll-your-own). Known-answer vs FIPS-180: SHA-256("abc"),
    // SHA-256(""), SHA-384("abc"), SHA-512("abc").
    check(
        "t-90-225-winrt-hash.mod",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n\
         e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n\
         cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7\n\
         ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f\n",
    );
}

#[test]
fn t90_226_winrt_hmac() {
    // M2WINRT (Phase 4) — HMAC-SHA256 via CNG. RFC 4231 test case 1; Verify
    // accepts a good tag and rejects a tampered one (constant-time compare).
    check(
        "t-90-226-winrt-hmac.mod",
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7\n\
         verify-good: Y\nverify-tampered: N\n",
    );
}

#[test]
fn t90_227_winrt_cryptkey() {
    // M2WINRT (Phase 4) — CryptKey: PBKDF2-HMAC-SHA256 via CNG
    // (BCryptDeriveKeyPBKDF2). KAT (password/salt) verified vs Python hashlib:
    // c=1 and c=4096, 32-byte keys.
    check(
        "t-90-227-winrt-cryptkey.mod",
        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b\n\
         c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a\n",
    );
}

#[test]
fn t90_228_winrt_symcrypt() {
    // M2WINRT (Phase 4) — SymCrypt: AES-256-GCM AEAD via CNG. Encrypt/decrypt
    // round-trip (ciphertext != plaintext, decrypt restores it) and fail-closed
    // tag verification — decryption rejects a tampered ciphertext AND tampered
    // associated data.
    check(
        "t-90-228-winrt-symcrypt.mod",
        "encrypt: Y\nct=pt (should be N): N\ndecrypt: Y\nroundtrip match: Y\n\
         tampered ct decrypt (should be N): N\ntampered aad decrypt (should be N): N\n",
    );
}

#[test]
fn t90_229_winrt_com() {
    // M2WINRT (Phase 5) — Com: COM/OLE lifecycle + activation over ole32 (direct
    // from M2). The CLASS-as-COM-interface pattern consumes a real OS IMalloc:
    // Alloc/Free dispatch through the COM vtable via M2 virtual dispatch.
    check(
        "t-90-229-winrt-com.mod",
        "init: Y\ngetmalloc: Y\nalloc: Y\nfreed\n",
    );
}

#[test]
fn t90_230_winrt_guid() {
    // M2WINRT (Phase 5) — Guid: COM GUID parse/format/ProgID over ole32. Parse +
    // ToString round-trip of CLSID_ShellLink, equality, malformed rejection, and
    // resolving the Scripting.FileSystemObject ProgID.
    check(
        "t-90-230-winrt-guid.mod",
        "parse: Y\n{00021401-0000-0000-C000-000000000046}\nequal-same: Y\n\
         equal-diff: N\nbad-parse: N\nprogid: Y\n",
    );
}

#[test]
fn t90_231_winrt_dispatch() {
    // M2WINRT (Phase 5) — Dispatch: late-bound IDispatch COM Automation. Create
    // Scripting.Dictionary by ProgID, resolve a member name to a DISPID and
    // Invoke it (reads the empty dict's Count = VT_I4 0); a bogus name is
    // rejected (correct HRESULT severity-bit check on the virtual COM return).
    check(
        "t-90-231-winrt-dispatch.mod",
        "create: Y\ngetid Count: Y\nCount: 0\nbad-member: N\n",
    );
}

#[test]
fn t90_232_winrt_dispatch_str() {
    // M2WINRT (Phase 5) — Dispatch string marshalling: late-bound IDispatch
    // method calls with a string argument returning a string (BSTR) result.
    // Drives Scripting.FileSystemObject: GetExtensionName -> "gz", GetBaseName ->
    // "report". Exercises SysAllocString/Free, VT_BSTR VARIANT arg, BSTR result.
    check(
        "t-90-232-winrt-dispatch-str.mod",
        "create: Y\ngz\nreport\n",
    );
}

#[test]
fn t90_233_winrt_dispatch_args() {
    // M2WINRT (Phase 5) — the complete late-bound COM Automation client: drive a
    // live Scripting.Dictionary through the general VARIANT API — multi-arg
    // mixed-type methods (Add(string,int)), property-get (Count), a parameterized
    // property (Item(string)->int), and bool results (Exists).
    check(
        "t-90-233-winrt-dispatch-args.mod",
        "create: Y\ncount: 2\nitem foo: 42\nexists foo: Y\nexists zzz: N\n",
    );
}

#[test]
fn t90_234_heap() {
    // M2WINRT runtime — the self-hosted M2 boundary-tag heap (VirtualAlloc-backed,
    // free-list allocator written in Modula-2). 64 distinct-pattern blocks must
    // not overlap; free/re-alloc must not corrupt neighbours; freeing everything
    // must recoalesce enough for a 500 KB block; Validate() checks all invariants.
    check(
        "t-90-234-heap.mod",
        "intact: Y\nvalid: Y\nodds intact: Y\nvalid2: Y\nrefilled intact: Y\n\
         inuse0: Y\nvalid3: Y\nbigok: Y\nbigfill: Y\nvalidend: Y\n",
    );
}

#[test]
fn t90_235_heap_torture() {
    // M2WINRT runtime — heap torture: 4000 rounds of pseudo-random alloc/free over
    // 64 slots with per-block pattern verification and periodic Validate(); must
    // end with no corruption, zero bytes in use, and an intact structure.
    check(
        "t-90-235-heap-torture.mod",
        "corrupt: N\nvalidfail: N\nfinal ok: Y\ninuse0: Y\nvalidend: Y\n",
    );
}

#[test]
fn t90_236_heap_guards() {
    // M2WINRT runtime — heap safety guards (regression for the adversarial audit):
    // an impossibly large request must fail with p := NIL (no rounding/blockNeed
    // wrap), and a double-free must be a safe no-op (no free-list re-insert, no
    // in-use underflow). Structure stays valid.
    check(
        "t-90-236-heap-guards.mod",
        "huge nil: Y\nmax nil: Y\nnormal ok: Y\nafter free inuse0: Y\n\
         double-free safe: Y\nvalid: Y\n",
    );
}

#[test]
fn t90_237_storage_heap() {
    // M2WINRT runtime — ISO Storage is backed by the self-hosted M2 Heap.
    // Allocating through the standard ISO façade (FROM Storage IMPORT ALLOCATE)
    // must be serviced by the M2 Heap engine (Heap.BytesInUse moves), give
    // zeroed/usable memory, and leave the heap valid. Storage -> Heap -> VirtualAlloc.
    check(
        "t-90-237-storage-heap.mod",
        "alloc nonnil: Y\nheap grew: Y\nzeroed: Y\nusable: Y\n\
         freed nil: Y\nheap back: Y\navail: Y\nvalid: Y\n",
    );
}

#[test]
fn t90_238_m2heap_new() {
    // M2WINRT runtime — with --m2-heap, the NEW builtin is serviced by the
    // self-hosted M2 Heap (Heap.BytesInUse moves up on NEW, back on DISPOSE).
    check_m2heap(
        "t-90-238-m2heap-new.mod",
        "new uses m2 heap: Y\nusable: Y\ndisposed: Y\nvalid: Y\n",
    );
}

#[test]
fn t90_239_m2heap_force() {
    // M2WINRT runtime — --m2-heap force-links Heap even with no import: a 10-node
    // linked list built with NEW and freed with DISPOSE runs on the M2 heap.
    check_m2heap("t-90-239-m2heap-force.mod", "sum: Y\nfreed: Y\n");
}

#[test]
fn t90_240_sysclock() {
    // Runtime self-hosting — ISO SysClock.GetClock calls Win32 GetSystemTime
    // directly (no Rust nm2_sysclock_now) and fills DateTime in M2; a fresh read
    // must be a valid, plausibly-current, UTC (zone 0) DateTime.
    check(
        "t-90-240-sysclock.mod",
        "valid: Y\nyear ok: Y\nutc zone: Y\n",
    );
}

#[test]
fn t90_241_runprog() {
    // Win32 helper library — RunProg: launch external programs via direct Win32
    // (CreateProcessW + wait + GetExitCodeProcess) in pure M2. PerformCommand runs
    // "%COMSPEC% /C exit N" synchronously; cmd's exit code is deterministic.
    check(
        "t-90-241-runprog.mod",
        "launched: Y\ncode42: 42\ncode7: 7\ncode0: 0\n",
    );
}

#[test]
fn t90_242_filemap() {
    // Win32 helper library — FileMap: memory-mapped files in pure M2 over direct
    // Win32. A named page-file mapping created by one MappedFile and opened by a
    // second shares memory — write through one view, read it through the other.
    check(
        "t-90-242-filemap.mod",
        "created: Y\nmapped1: Y\nopened: Y\nshared read: Y\nclosed: Y\n",
    );
}

#[test]
fn t90_243_winshell() {
    // GUI shell foundation — WinShell: a Win32 window whose window procedure is an
    // M2 native C-ABI callback dispatching to an M2 handler. Headlessly proven via
    // a message-only window (SendMessageW dispatches synchronously into the handler).
    check(
        "t-90-243-winshell.mod",
        "created: Y\nresult: 42\ncount: 1\nwparam: 21\ncount2: 2\ndestroyed: Y\n",
    );
}

#[test]
fn t90_244_terminal() {
    // TUI terminal model (rendered later with Direct2D/DirectWrite): a cell grid
    // with per-cell colour, fully observable by reading cells back. Covers
    // coloured text, cursor positioning+wrap, status bar, menu bar with a
    // highlighted selection, boxed text windows, and an editable input field.
    check(
        "t-90-244-terminal.mod",
        "size: Y\ntext: Y\ncolour: Y\nposcol: Y\ncursor: Y\nwrap: Y\nstatus: Y\n\
         menucnt: 3\nmenusel: Y\nbox: Y\npanel: Y\nfield text: Y\nfield edit: Y\n",
    );
}

#[test]
fn t90_247_terminal_ext() {
    // TUI terminal model — extended controller surface: editing the menu bar
    // (rename/insert/remove/enable+skip), drop-down menus (open over saved cells,
    // navigate, close+restore), the semantic event queue + HandleKey dispatcher,
    // field caret editing, and the area-drawing helpers. All observed headlessly.
    check(
        "t-90-247-terminal-ext.mod",
        "mcount: 4\nrename: Y\ninsert: Y\nremove: Y\nenabled: Y\nskipnext: Y\nskipprev: Y\n\
         items: 3\nopen: Y\npopbox: Y\nitemsel: Y\nitemtext: Y\nchoose: Y\nrestore: Y\n\
         menumove: Y\nopenkey: Y\nhasevt: Y\nevorder: Y\nevdrain: Y\n\
         fcaret: Y\nfchange: Y\nfsubmit: Y\ndraw: Y\n",
    );
}

#[test]
fn t90_245_dwrite() {
    // Modern Terminal rendering foundation — DirectWrite from pure M2: create the
    // DWrite factory and a monospaced text format via the CLASS-as-COM vtable
    // pattern. Also proves a FLOAT arg (font size) passes through a virtual COM
    // call — the enabler for Direct2D/DirectWrite rendering.
    check("t-90-245-dwrite.mod", "startup: Y\nformat: Y\n");
}

#[test]
fn t90_246_termrender() {
    // Direct2D/DirectWrite Terminal renderer foundation: create the D2D factory and
    // a DirectWrite monospaced text format (headless-safe). Exercises the big
    // ID2D1Factory/ID2D1HwndRenderTarget/ID2D1SolidColorBrush vtable declarations.
    check("t-90-246-termrender.mod", "d2d: Y\n");
}

#[test]
fn t90_248_interface_dispatch() {
    // COM INTERFACE consumer: the compiler assigns vtable slot ordinals by walking
    // the INHERIT chain (IUnknown 0/1/2, then derived methods appended in
    // declaration order). Dispatch through interface-typed vars lands DoThing at
    // slot 3 and Compute at slot 5 (three levels deep) — no hand-counted
    // placeholders, no +N-shift to get wrong. See docs/design/com-interfaces.md.
    check("t-90-248-interface-dispatch.mod", "50\n107\n");
}

#[test]
fn t90_249_narrow_achar_literal() {
    // A narrow (8-bit ACHAR) string literal `"..."A` — and a narrow string CONST
    // — assigned to an `ARRAY OF ACHAR` copies the BYTES, not the r-value pointer.
    // Regression: the string->array copy path was gated only on the WIDE array
    // kind, so an ACHAR target fell through to a plain Store of the literal's
    // pointer bits (garbage). Fixed via narrow_char_array_count + NM2Str.WNCopy.
    check("t-90-249-narrow-achar-literal.mod", "109 97 105 110 0\nmain\n104 105 0\n");
}

#[test]
fn t90_250_text_rope() {
    // The rope text buffer (library/utilmod/TextRope): NEW/DISPOSE of tree nodes,
    // recursive split/concat/balance, string fragments. Insert/append/delete by
    // index, then many front-inserts + rebalance — content preserved, depth shrinks.
    check(
        "t-90-250-text-rope.mod",
        "hello, world\nhello, world!\nhello world!\nlen=201 balanced=yes\nABCDEFGHIJ\n",
    );
}

#[test]
fn t90_251_expr_eval() {
    // Recursive-descent expression evaluator (engine of demos/calculator.mod):
    // in-module forward references / mutual recursion, operator precedence, unary
    // minus, parentheses, RealMath functions, ISO real<->string conversion.
    check(
        "t-90-251-expr-eval.mod",
        "1+2*3 = 7\n(1+2)*3 = 9\n100-58 = 42\n2*-3+5 = -1\n10/4 = 2.5\n\
         3*(4+5)-6/2 = 24\nsqrt(16) = 4\nabs(-5) = 5\n2.5*4 = 10\n1/0 = Error\n2+ = Error\n",
    );
}

#[test]
fn t90_252_system_process() {
    // PIM coroutines via SYSTEM using the SYSTEM.PROCESS handle type (now exported,
    // mapped to the same address-sized handle as COROUTINES.COROUTINE). NEWPROCESS
    // + TRANSFER ping-pong control to a worker.
    check("t-90-252-system-process.mod", "tick 1\ntick 2\ndone\n");
}

#[test]
fn t90_260_paneshell_smoke() {
    // PaneShell Sprint 0 scaffolding: the new library/uidef + library/uimod (UI)
    // family exists, compiles, is auto-discovered (zero driver/loader/test
    // registration), and links cross-family to winrt (WinShell). Declaring a
    // Surface.Backend var forces the abstract CLASS-as-vtable through codegen.
    check("t-90-260-paneshell-smoke.mod", "paneshell-scaffolding-ok\n");
}

#[test]
fn t90_260b_paneshell_badref() {
    // Negative: a reference to a non-existent UI-family module must fail to
    // resolve — auto-discovery is by real file presence, not magic.
    check_run_error("t-90-260b-paneshell-badref.mod", &["not found in search path"]);
}

#[test]
fn t90_261_terminal_instance() {
    // PaneShell S1: Terminal is instanceable — two independent text-grid
    // instances of different sizes hold distinct cell content simultaneously
    // (coexistence), read back per-instance via CellCharOf; per-instance state
    // is heap-allocated so the module still loads under JIT. The default
    // (singleton) instance is untouched by writes routed to explicit instances.
    check(
        "t-90-261-terminal-instance.mod",
        "a00: A\nb00: B\nacols: 20\nbcols: 40\ndefok: Y\n",
    );
}

#[test]
fn t90_261b_terminal_shim() {
    // PaneShell S1, D4 shim-equivalence gate (sprints amendment K): the
    // singleton API is a behavioural shim over the current instance — the same
    // ops give identical cells on the default vs an explicit instance, and a
    // singleton write after Use(x) lands in x, not the default.
    check(
        "t-90-261b-terminal-shim.mod",
        "shim-eq: Y\nlanded: Y\ndefault-clean: Y\n",
    );
}

#[test]
fn t90_261c_termrender_instance() {
    // PaneShell S1: TermRender is instanceable to construction level — two
    // renderer instances each create their own DirectWrite text format from the
    // shared factory (headless; Attach/Paint need a real window, manual demo).
    // The DWrite factory is now idempotent so the instances don't clobber it.
    check("t-90-261c-termrender-instance.mod", "two-formats: Y\n");
}

#[test]
fn t90_262_raster_instance() {
    // PaneShell S2: RasterView is instanceable — two independent RGBA
    // framebuffers of different sizes hold distinct pixel content simultaneously,
    // read back per-instance via PixelAt (fully headless CPU buffers). Each
    // ~4 MiB buffer is heap-allocated (§0.4), so the module still loads under JIT.
    check(
        "t-90-262-raster-instance.mod",
        "a-dot: 65280\nb-bg: 255\na-bg: 16711680\na-width: 64\n",
    );
}

#[test]
fn t90_262b_canvas_construct() {
    // PaneShell S2: Canvas2D is instanceable to construction level — two canvas
    // instances each create their own DirectWrite text format from the shared
    // factory (headless; Attach/draw need a real window, manual demo). The DWrite
    // factory is idempotent so the instances don't clobber it.
    check("t-90-262b-canvas-construct.mod", "two-canvas: Y\n");
}

#[test]
fn t90_263_gameview_instance() {
    // PaneShell S3: GameView is instanceable — two independent indexed
    // framebuffers hold distinct content simultaneously, read back per-instance
    // via IndexAt (headless CPU buffers); the big buffers are heap-allocated
    // (§0.4) so the module still loads under JIT.
    check(
        "t-90-263-gameview-instance.mod",
        "a-dot: 9\na-bg: 4\nb-bg: 7\na-width: 64\n",
    );
}

#[test]
fn t90_263b_shader_construct() {
    // PaneShell S3: ShaderView (D3D11) is instanceable — two instances coexist
    // at construction level (distinct, non-NIL, freeable). Attach creates the
    // device/swapchain (needs a real window), so present coexistence is the
    // manual demo; S4's GameViewGpu owns one ShaderView instance per game.
    check("t-90-263b-shader-construct.mod", "two-shaders: Y\nfreed: Y\n");
}

#[test]
fn t90_264_gameviewgpu_construct() {
    // PaneShell S4 (closes P1): GameViewGpu is instanceable and owns no device
    // of its own — two instances coexist, each owning a DISTINCT ShaderView
    // instance (its GPU device). Headless construction; Attach needs a real
    // window (manual demo). This is the load-bearing intra-P1 edge.
    check(
        "t-90-264-gameviewgpu-construct.mod",
        "two-gpu: Y\ndistinct-renderers: Y\n",
    );
}

#[test]
fn t90_265_surface_backend() {
    // PaneShell S5 (P2 part 1/2): Surface.Backend ABSTRACT CLASS is the one
    // polymorphic handle — each concrete adapter wraps an instanced renderer, and
    // a virtual KindOf() on a single Backend variable dispatches to the right
    // surface. Construction + KindOf + Close are headless; real Attach/Paint (S7).
    check(
        "t-90-265-surface-backend.mod",
        "textgrid: 0\nraster: 1\ncanvas: 2\nindexed: 3\nindexedgpu: 3\nshader: 4\npoly-tg: 0\npoly-cv: 2\n",
    );
}

#[test]
fn t90_266_control_backend() {
    // PaneShell S6 (P2 part 2/2, closes P2): native controls as the simplest leaf
    // — a control Backend Attaches a real Win32 child control (message-window-safe),
    // KindOf=NativeControl (5), the generic value API SetText/GetText round-trips
    // through the control HWND (via a class CAST downcast — see the is_pointer_like
    // codegen fix), and an app-defined Backend reports Kind.Custom (6).
    check(
        "t-90-266-control-backend.mod",
        "btn-kind: 5\nattach-btn: Y\nedit-text: hello\ncustom-kind: 6\n",
    );
}

#[test]
fn t90_267_pane_tree() {
    // PaneShell S7 (P3) slice 1: the universal Pane as a heap tree node — leaves
    // under an arrangement, the named-pane registry (PaneByName/BackendOf), rects
    // (SetRect/RectOf), and the DumpTree introspection probe. Fully headless; host
    // HWNDs, the event router, channel + Layout class land in later S7 slices.
    check(
        "t-90-267-pane-tree.mod",
        "found-console: Y\nfound-missing: Y\nleaf-backend: Y\narrange-backend: Y\na-rect: 0,0,70,50\ndump: root:A(0,0,100,50)[canvas:L(0,0,70,50) console:L(70,0,30,50)]\n",
    );
}

#[test]
fn t90_267b_pane_hosts() {
    // PaneShell S7 (P3) slice 2: the host-HWND tree is a projection of the Pane
    // tree. OpenWindow builds a host HWND per Pane (WS_CHILD|WS_CLIPCHILDREN);
    // Win32 GetParent proves root-under-frame, mid-under-root, leaf-under-mid —
    // the §4/§5 central bet. Leaf backends attach to their host (RasterView).
    check(
        "t-90-267b-pane-hosts.mod",
        "frame: Y\nroot-host: Y\nleaf-host: Y\nroot-under-frame: Y\nmid-under-root: Y\nleaf-under-mid: Y\nclosed: Y\n",
    );
}

#[test]
fn t90_267c_event_router() {
    // PaneShell S7 (P3) slice 3: the one event router. Every host HWND shares the
    // WNDPROC; it recovers the Pane (GWLP_USERDATA), packages WM_* into a semantic
    // Event keyed to that Pane, updates the polled-input snapshot, and fans the
    // Event to the window Handler. Driven headlessly via synthesized SendMessage.
    check(
        "t-90-267c-event-router.mod",
        "cmd-kind: 12\ncmd-pane: Y\ncmd-id: 42\nkey-kind: 3\nkey-val: 65\nchar-kind: 4\nchar-ch: X\nmouse-kind: 5\nmouse-ev: 11,22\nevcount: 4\n",
    );
}

#[test]
fn t90_267d_channel() {
    // PaneShell S7 (P3) slice 4a: the per-pane channel — a lock-guarded FIFO ring
    // (CRITICAL_SECTION-bounded per amendment C, drained inline, D2). Submit /
    // ChannelDepth / ChannelNext (FIFO); SetThreaded is the callable dark seam
    // that does not change behaviour until P8.
    check(
        "t-90-267d-channel.mod",
        "depth: 3\npop1: Y\npop2: Y\npop3: Y\ndepth0: 0\nempty: Y\nthreaded-submit: Y\nthreaded-pop: Y\n",
    );
}

#[test]
fn t90_267e_layout() {
    // PaneShell S7 (P3) slice 4b: the Layout ABSTRACT CLASS (D7). Retile delegates
    // child placement to a pane's Layout (proven with an app-defined HalfSplit
    // strategy); a pane with no Layout is left untouched (the non-Layout guard).
    check(
        "t-90-267e-layout.mod",
        "a-rect: 0,0,50,40\nb-rect: 50,0,50,40\nc-rect: 7,7,7,7\n",
    );
}

#[test]
fn t90_268_rect_solver() {
    // PaneShell S8 (P4 1/2): the PaneLayout reactive rect solver. Split + Stack as
    // PaneShell.Layout strategies; Retile delegates to them. A 70/30 Split over a
    // nested 3-way vertical Stack; SetWeight+Retile re-solves with min-size clamps
    // (D1 mutate-then-Retile); SetHidden redistributes the Stack.
    check(
        "t-90-268-rect-solver.mod",
        "a: 0,0,700,600\nstk: 700,0,300,600\nc: 700,0,300,200\nd: 700,200,300,200\ne: 700,400,300,200\na-min: 0,0,240,600\na-max: 0,0,840,600\nstk-max: 840,0,160,600\nd-hidden: 700,0,300,300\n",
    );
}

#[test]
fn t90_269_splitter_tabs() {
    // PaneShell S9 (P4 2/2, closes P4): draggable splitter divider + fixed tabs as
    // Layout strategies. SplitLayout.HitTest finds the divider (0) / misses (MAX);
    // Drag re-weights (700->750) and raises EvSplitterMoved. TabLayout shows the
    // active tab's child below a 24px strip; SelectTab switches it + raises
    // EvTabChanged. Semantic events are LATCHED (the real frame's WM_SIZE ->
    // EvResize would otherwise clobber a last-kind read).
    check(
        "t-90-269-splitter-tabs.mod",
        "a0: 0,0,700,600\nhit: Y\nmiss: Y\na1: 0,0,750,600\nsplit-evt: Y\nt0-active: 0,24,200,76\nt1-hidden: 0,0,0,0\nactive0: 0\nt1-active: 0,24,200,76\nactive1: 1\ntab-evt: Y\n",
    );
}

#[test]
fn t90_270_loop_drag() {
    // PaneShell S10 (P5): the real message loop + multi-window + a mouse splitter
    // drag routed through the WNDPROC by the parent-walk (the divider is occluded
    // by child hosts). SendMessage drives down/move/up; SplitLayout.Drag re-weights
    // (700->750) and raises EvSplitterMoved (latched). RunBounded proves the loop
    // runs and terminates; Quit latches the workspace + posts WM_QUIT. A second
    // OpenWindow registers with the workspace (WindowCount=2).
    check(
        "t-90-270-loop-drag.mod",
        "b0: 700,0,300,600\nb1: 750,0,250,600\na1: 0,0,750,600\nsplit-evt: Y\nwins: 2\nquit-ok: Y\n",
    );
}

#[test]
fn t90_270b_nested_close() {
    // PaneShell S10 hardening (post adversarial review): (1) ancestor-walk drag — a
    // grandchild press over the OUTER split's divider climbs B->s2(miss)->s1(hit)
    // and re-weights the outer split (A 500->550); (2) CloseWindow unregisters from
    // the workspace (swap-remove) so WindowCount stays honest (4->3) and the later
    // RunBounded's ShowWorkspace cannot dereference the freed window (the UAF the
    // review found).
    check(
        "t-90-270b-nested-close.mod",
        "A0: 0,0,500,600\nA1: 0,0,550,600\nnested-evt: Y\nwins4: 4\nwins-after-close: 3\nran-ok: Y\n",
    );
}

#[test]
fn t90_271_mdi_dock() {
    // PaneShell S11 (P6 part 1): MDIContainer = DockLayout, an MDI document area as
    // just ANOTHER PaneShell.Layout over the same Pane tree. Tiled (2x2 grid),
    // Tabbed (active doc below a 24px strip, others 0-rect), Cascaded (offset
    // stack). Documents are Panes with stable id = child index; Activate raises
    // EvDocActivated (latched); CloseDocument hides a doc and the rest redistribute.
    check(
        "t-90-271-mdi-dock.mod",
        "ids: 0,1,2,3\nd0: 0,0,400,300\nd1: 400,0,400,300\nd2: 0,300,400,300\nd3: 400,300,400,300\ne1-active: 0,24,400,276\ne0-hidden: 0,0,0,0\nactive: 1\ndoc-evt: Y\nf0: 0,0,740,540\nf1: 30,30,740,540\nf2: 60,60,740,540\nf1-closed: 0,0,0,0\nf0-recascade: 0,0,770,570\n",
    );
}

#[test]
fn t90_272_float_dock() {
    // PaneShell S12 slice 1 (P6 part 2): MDI float/dock re-parenting + dock zones.
    // DockLayout.DropAt classifies a drop point into a DropZone (25% edge bands,
    // nearest edge wins; centre tabs) + target rect. Float pops a doc into its own
    // top-level window (substrate ReparentToNewWindow, destroy+rebuild repoints
    // win/host across the subtree); Dock is the inverse (ReparentInto + close the
    // empty frame). Stable doc ids (registry). EvDocFloated/EvDocDocked latched.
    check(
        "t-90-272-float-dock.mod",
        "drop-left: 1 0,0,400,600\ndrop-right: 2 400,0,400,600\ndrop-top: 3 0,0,800,300\ndrop-bottom: 4 0,300,800,300\ndrop-centre: 5 0,0,800,600\ndrop-outside-nodrop: Y\nwins-before: 1\nwins-after-float: 2\ndoc0-detached: Y\ndoc0-float: 0,0,400,300\nfloat-evt: Y\nwins-after-dock: 1\ndoc0-redocked: Y\ndock-evt: Y\n",
    );
}

#[test]
fn t90_272b_float_hardening() {
    // PaneShell S12 slice 1 hardening (post adversarial review): (1) Realize hosts a
    // runtime-added doc (d2 tiles into the grid); (2) floating the active doc advances
    // `active` so a Tabbed container stays visible (a1 fills, not blank); (3) floating
    // a doc in a non-windowed container is refused before Detach (no orphan); (4)
    // CloseDocument on a floated doc closes its window (count 3->2, no leak).
    check(
        "t-90-272b-float-hardening.mod",
        "d2-hosted: Y\nd2-realized: 0,300,400,300\nactive-after-float: 1\na1-visible: 0,24,400,276\nrefused-safe: Y\nwins-before-close: 3\nwins-after-close: 2\nclose-evt: Y\n",
    );
}

#[test]
fn t90_273_mdi_persist() {
    // PaneShell S12 slice 2a (P6): MDI re-arrange commands (Tile/Cascade switch the
    // DockLayout style) + arrangement persistence (SaveLayout -> versioned text blob
    // PSL1;..., LoadLayout re-applies style/active/closed) + the float-window
    // lifecycle safety (CloseWindow nils owned panes' host/win, so closing a float
    // directly then Dock-ing rebuilds instead of double-freeing).
    check(
        "t-90-273-mdi-persist.mod",
        "tile-a0: 0,0,400,300\ntile-a3: 400,300,400,300\ncasc-a0: 0,0,710,510\ncasc-a1: 30,30,710,510\nsave-blob: PSL1;s=0;a=2;n=3;c=010;\nload-ok: Y\nactive-restored: 2\ne2-active: 0,24,400,276\ne1-hidden: 0,0,0,0\nf0-win-cleared: Y\nf0-redocked: Y\ndock-safe: Y\n",
    );
}

#[test]
fn t90_273b_persist_robust() {
    // PaneShell S12 slice 2a hardening (post review): the arrangement serializer fails
    // safe. SaveLayout into a too-small buffer returns FALSE (truncation signalled);
    // LoadLayout of a wrong-magic blob is rejected with no mutation; LoadLayout of a
    // valid-magic but truncated bit field is rejected (validated before applying) — so
    // `active` survives both rejected loads.
    check(
        "t-90-273b-persist-robust.mod",
        "trunc-signaled: Y\nbad-magic-rejected: Y\ntruncated-rejected: Y\nactive-intact: 2\n",
    );
}

#[test]
fn t90_274_lifecycle_dockinto() {
    // PaneShell S12 slice 2b: window-close lifecycle + DockInto drop-apply. CloseWindow
    // raises EvWindowClosed; the frame carries GWLP_USERDATA=root so a title-bar WM_CLOSE
    // raises EvCloseRequest and is swallowed (frame survives, app controls close — IsWindow
    // proves it). DockInto(NewFloat) pops a doc to its own window (count 1->2, detached);
    // DockInto(DockCentre) re-docks it (2->1); DockInto(NoDrop) is a no-op (FALSE).
    check(
        "t-90-274-lifecycle-dockinto.mod",
        "win-closed-evt: Y\nclose-req-evt: Y\nframe-alive: Y\nwins0: 1\nafter-float: 2\nfloat-detached: Y\nafter-dock: 1\nredocked: Y\nnodrop-false: Y\n",
    );
}

#[test]
fn t90_274b_close_reentrancy() {
    // PaneShell S12 slice 2b hardening (post review): CloseWindow is re-entrancy-safe.
    // A handler that re-closes the same window from inside its own EvWindowClosed (via a
    // second alias) must no-op (a `closing` guard + detach-before-notify), not double-free.
    check(
        "t-90-274b-close-reentrancy.mod",
        "closed-evt: Y\nreentry-safe: Y\nwins: 0\n",
    );
}

#[test]
fn t90_275_ptcl() {
    // ptcl interpreter (library/uidef + library/uimod/Ptcl): a small Tcl dialect —
    // variables, $ / [] / "" substitution (incl. nested command sub), set/puts builtins,
    // host-verb registration + dispatch. Pins the 6 adversarial-review fixes: errors in
    // [command] PROPAGATE (propagate/undefvar=ERR), re-entrant host recursion is bounded
    // (recur=ERR, no crash), ArgInt overflow saturates, >MaxArgs words drop the tail
    // (maxargs=3, no spurious command), NUL-safe Eq dispatch.
    check(
        "t-90-275-ptcl.mod",
        "x=5\ny=7\nquote=x is 5 and y is 7\nnested=13\npropagate=ERR\nundefvar=ERR\nrecur=ERR\nmaxargs=3\n",
    );
}

#[test]
fn t90_276_ptcl_control() {
    // ptcl control flow: expr (precedence-climbing infix with $/[] substitution), if/while/
    // incr, and proc (user commands; params save/restore -> recursion works). The recurse
    // case is factorial(5)=120 via a recursive proc with [..] command sub inside expr.
    check(
        "t-90-276-ptcl-control.mod",
        "prec=11\nparens=14\nexprvar=25\nifthen=big\nifelse=small\nwhile=15\nproc=49\nrecurse=120\nifcmd=ELSE\ndupparm=7\n",
    );
}

#[test]
fn t91_010_subrange_range_reject() {
    // Negative: a constant out of the subrange's range must be rejected.
    check_run_error("t-91-010-subrange-range-reject.mod", &["out of range"]);
}

#[test]
fn t91_011_case_duplicate_reject() {
    // Negative: a duplicate CASE label must be rejected.
    check_run_error("t-91-011-case-duplicate-reject.mod", &["CASE label"]);
}

#[test]
fn t91_012_cyclic_type_reject() {
    // Negative: an infinite pure-alias type cycle must be rejected.
    check_run_error("t-91-012-cyclic-type-reject.mod", &["cyclic type"]);
}

#[test]
fn t91_013_assign_enum_member_reject() {
    // Negative: assigning to an enumeration member (a constant) must be rejected.
    check_run_error("t-91-013-assign-enum-member-reject.mod", &["constant"]);
}

#[test]
fn t91_014_array_length_mismatch_reject() {
    // Negative: arrays of different lengths are not assignment-compatible.
    check_run_error("t-91-014-array-length-mismatch-reject.mod", &["array types"]);
}

#[test]
fn t91_015_defimpl_sig_mismatch_reject() {
    // Negative: a procedure whose IMPLEMENTATION header disagrees with its
    // DEFINITION header (CARDINAL vs CHAR) must be rejected. Helper pair:
    // T91BadSig.def / T91BadSig.mod.
    check_run_error("T91BadSig.mod", &["does not match its DEFINITION"]);
}

#[test]
fn t91_016_set_compare_reject() {
    // Negative: comparing a set with a non-set value must be rejected.
    check_run_error("t-91-016-set-compare-reject.mod", &["set"]);
}

#[test]
fn t91_017_incl_element_reject() {
    // Negative: INCL's element must be compatible with the set's base type.
    check_run_error("t-91-017-incl-element-reject.mod", &["element type"]);
}

#[test]
fn t91_018_for_step_reject() {
    // Negative: a FOR-loop BY step that is a variable (not a constant).
    check_run_error("t-91-018-for-step-reject.mod", &["step must be a constant"]);
}

#[test]
fn t91_019_proctype_assign_reject() {
    // Negative: assigning a procedure to a procedure variable of a different
    // signature must be rejected.
    check_run_error("t-91-019-proctype-assign-reject.mod", &["procedure type"]);
}

#[test]
fn t91_020_size_literal_reject() {
    // Negative: SIZE requires a type name or a variable; SIZE(1) is a type error.
    check_run_error(
        "t-91-020-size-literal-reject.mod",
        &["requires a type name or a variable"],
    );
}

#[test]
fn t91_021_duplicate_import_reject() {
    // Negative: the same name imported twice in one import list.
    check_run_error(
        "t-91-021-duplicate-import-reject.mod",
        &["imported more than once"],
    );
}

#[test]
fn t91_022_nil_call_reject() {
    // Negative: NIL is a constant, not a procedure; NIL(c) is not a call.
    check_run_error("t-91-022-nil-call-reject.mod", &["NIL is not a procedure"]);
}

#[test]
fn t91_023_duplicate_var_reject() {
    // Negative: the same variable name declared twice in one scope.
    check_run_error("t-91-023-duplicate-var-reject.mod", &["already declared"]);
}

#[test]
fn t91_024_duplicate_field_reject() {
    // Negative: the same record field name declared twice.
    check_run_error("t-91-024-duplicate-field-reject.mod", &["already declared"]);
}

#[test]
fn t91_025_duplicate_enum_reject() {
    // Negative: an enumeration member name declared by two enum types in scope.
    check_run_error("t-91-025-duplicate-enum-reject.mod", &["already declared"]);
}

#[test]
fn t91_026_proc_compare_int_reject() {
    // Negative: a procedure value compared with an integer.
    check_run_error(
        "t-91-026-proc-compare-int-reject.mod",
        &["procedure value with a non-procedure"],
    );
}

#[test]
fn t91_027_set_in_set_reject() {
    // Negative: a set on the left of the IN operator.
    check_run_error(
        "t-91-027-set-in-set-reject.mod",
        &["left operand of IN must be an element"],
    );
}

#[test]
fn t91_028_interface_slot_mismatch_reject() {
    // Negative: the @ordinal machine-check. A method annotated <* @5 *> that the
    // compiler computes to be slot 3 (first method after IUnknown) must be
    // rejected — the keystone that makes generated vtable slots cannot-be-wrong.
    check_run_error(
        "t-91-028-interface-slot-mismatch.mod",
        &["annotated slot @5 but the compiler computed slot 3"],
    );
}

#[test]
fn t91_029_const_index_oob_reject() {
    // A compile-time-constant array index outside the declared dimension is a
    // STATIC error only under --strict (a[4] for ARRAY [0..3]); the lenient
    // default accepts it (and traps at run time). This asserts both halves.
    check_strict_error("t-91-029-const-index-oob.mod", &["out of bounds"]);
}

#[test]
fn t90_174_const_char_array_fill() {
    check(
        "t-90-174-const-char-array-fill.mod",
        "A Z\nABCDEFGHIJKLMNOPQRSTUVWXYZ\n",
    );
}

#[test]
fn t90_173_mathlib0() {
    check("t-90-173-mathlib0.mod", "2 -3 4 3\n");
}

#[test]
fn t90_172_set_shift_rotate() {
    check("t-90-172-set-shift-rotate.mod", "rotate-ok\nshift-ok\n");
}

#[test]
fn t90_171_tbitsize() {
    check("t-90-171-tbitsize.mod", "16 2 64 8\n");
}

#[test]
fn t90_170_string_array_assign() {
    check(
        "t-90-170-string-array-assign.mod",
        "ABCD\n65 66 67 68\nxyz\n",
    );
}

#[test]
fn t90_169_inout() {
    check("t-90-169-inout.mod", "hello\n   42\n-7\n10\n  FF\n");
}

#[test]
fn t90_168_const_aggregate_forward_type() {
    check(
        "t-90-168-const-aggregate-forward-type.mod",
        "12 34 56 78\n",
    );
}

#[test]
fn t90_167_aggregate_constructor() {
    check(
        "t-90-167-aggregate-constructor.mod",
        "1623 6 19\n10 20 30\n",
    );
}

#[test]
fn t90_166_builtins_math() {
    check("t-90-166-builtins-math.mod", "3 7 1024 12\n");
}

#[test]
fn t90_165_system_bitsperloc() {
    check("t-90-165-system-bitsperloc.mod", "8 1 8 64\n");
}

#[test]
fn t90_164_fpuio() {
    check(
        "t-90-164-fpuio.mod",
        "|    3.14|\n|   2.5|\n|   42|\n",
    );
}

#[test]
fn t90_163_for_final_value() {
    check(
        "t-90-163-for-final-value.mod",
        "asc 95 1176\ndesc 2 7\nexact 10 3\nempty 5 0\nsingle 7 1\n",
    );
}

#[test]
fn t90_162_halt_exit_code() {
    // HALT(7) carries its argument as the exit status; the post-HALT statement
    // is unreachable, so output stops at "before-halt".
    let (out, code) = newm2_tests::run_test_status("t-90-162-halt-exit-code.mod")
        .expect("run t-90-162");
    assert_eq!(out, "before-halt\n");
    assert_eq!(code, 7);
}

#[test]
fn t90_100_method_except() {
    // Sprint K: EXCEPT/FINALLY inside a CLASS method. SafeDiv's protected body
    // raises on divide-by-zero; the EXCEPT handler sets a sentinel field and
    // RETURNs (-1). Touch's FINALLY bumps a field on the normal path. SELF and
    // params are threaded through the protected exception frame, and the
    // implicit WITH SELF is re-established in both protected fn and handler.
    check(
        "t-90-100-method-except.mod",
        "5\n-1\n-1\n42\n8\n2\n",
    );
}

#[test]
fn t90_080_com_malloc() {
    // COM interop: NewM2 class dispatch IS the COM ABI. An M2 abstract class
    // declares IMalloc's methods in IUnknown order; a real OS IMalloc pointer
    // (from CoGetMalloc, via the windows-sys crate) is held in a class variable
    // and Alloc/Free are invoked through ordinary virtual dispatch -> the OS
    // vtable functions.
    check("t-90-080-com-malloc.mod", "alloc-ok\nfreed\n");
}

#[test]
fn t90_070_class_builtins() {
    // OO CP4: SELF as a value (Me returns SELF, so m aliases n -> m.v=42),
    // EMPTY (the null class reference: n := EMPTY then n = EMPTY), and DESTROY
    // (frees the instance).
    check("t-90-070-class-builtins.mod", "42\nempty\nfreed\n");
}

#[test]
fn t90_060_inheritance() {
    // OO CP3: single inheritance + OVERRIDE + polymorphism. Dog inherits
    // Animal, overrides Speak, adds its own field/method. Virtual dispatch
    // through a base-typed parameter (SpeakOf) calls the override. Inherited
    // method Legs reads the inherited field. 1/2/4/9/1/2.
    check("t-90-060-inheritance.mod", "1\n2\n4\n9\n1\n2\n");
}

#[test]
fn t90_050_class_methods() {
    // OO CP2: method bodies + SELF + virtual dispatch. Init uses a bare field
    // (implicit SELF), Bump uses explicit SELF.n, Add takes a param and returns
    // a value. Methods dispatch through the object's vtable. 10 +1+1+1 = 13,
    // +7 = 20 (returned and read directly).
    check("t-90-050-class-methods.mod", "20\n20\n");
}

#[test]
fn t90_040_class_fields() {
    // OO CP1: a class instance is a heap object { vtable, fields }. NEW(p)
    // allocates it; p.x/p.y read+write through the implicit reference deref;
    // q := p aliases the object (reference semantics), so q.x := 7 shows as p.x.
    check("t-90-040-class-fields.mod", "42\n101\n7\n");
}

#[test]
fn t90_030_iso_coroutine() {
    // Sprint H: the ISO COROUTINES module — NEWCOROUTINE / TRANSFER / CURRENT
    // over the same fiber runtime. main := CURRENT(); a worker coroutine prints
    // the shared counter and yields back twice, then main prints "end".
    check("t-90-030-iso-coroutine.mod", "co 1\nco 2\nend\n");
}

#[test]
fn t90_010_enum_var_store() {
    // Regression: a cross-module enum member assigned to a VAR enum param
    // must be stored at the enum's 4-byte width, not the default i64
    // register width. The over-wide store otherwise clobbers the caller's
    // adjacent open-array `$high` companion, making HIGH() read 0 (which
    // broke TextIO.ReadToken and the ProgramArgs read loop). "hello len=5"
    // proves HIGH(s) stayed intact across the channel-style calls.
    // (Before the fix this miscompiled to "h len=888".)
    check("t-90-010-enum-var-store.mod", "hello len=5\n");
}

#[test]
fn perf_factorial_o2() {
    check_o2("perf-factorial-o2.mod", "573000000\n");
}

#[test]
fn perf_fib_o2() {
    check_o2("perf-fib-o2.mod", "766400000\n");
}

#[test]
fn perf_primes_o2() {
    check_o2("perf-primes-o2.mod", "4545000\n");
}

#[test]
fn perf_sieve_o2() {
    check_o2("perf-sieve-o2.mod", "10152000\n");
}

#[test]
fn t90_277_cast_aggregate() {
    // SYSTEM.CAST with an aggregate operand (RECORD / closed ARRAY) is a memory
    // reinterpret — regression for the "undefined ValueId" / StructValue codegen
    // panics (scalar<->record, record<->ADDRESS, scalar<->array).
    check("t-90-277-cast-aggregate.mod", "12345\n65\n");
}

#[test]
fn t90_278_large_array_copy() {
    // Whole-aggregate copy of a >64K-element array / large record lowers to
    // memmove, not a by-value load/store — regression for the LLVM SelectionDAG
    // segfault on large by-value aggregates.
    check("t-90-278-large-array-copy.mod", "65\n90\n90\n7\n");
}

#[test]
fn t90_280_ismember() {
    // ISMEMBER (OO RTTI) across a 3-level hierarchy with an abstract base, all
    // four value/type operand combinations + the (TYPE,TYPE) compile-time fold.
    check("t-90-280-ismember.mod", "YYYN\nYYNN\nY\nYN\n");
}

#[test]
fn t90_281_guard() {
    // GUARD: dynamic-type dispatch, read-only narrowed binding (field + method
    // through it), first-match-wins, and the ELSE arm for an unmatched subclass.
    check(
        "t-90-281-guard.mod",
        "circle r=5 area=75\nsquare s=4\nunknown\n",
    );
}

#[test]
fn t90_282_guard_nested() {
    // GUARD: a base-class catch-all arm after a specific arm (first-match-wins)
    // and a nested GUARD inside an arm body.
    check("t-90-282-guard-nested.mod", "branch 42\nnode 7\n");
}

#[test]
fn t90_283_guard_nomatch() {
    // GUARD with no matching arm and no ELSE raises the NewM2 guardException.
    check_run_error("t-90-283-guard-nomatch.mod", &["GUARD selector matched no arm"]);
}

#[test]
fn t90_284_guard_softkw() {
    // GUARD/AS/ISMEMBER are soft keywords — identifiers with those spellings
    // still parse as ordinary variables.
    check("t-90-284-guard-softkw.mod", "30\n15\n");
}

#[test]
fn t90_285_rtti_methodless() {
    // RTTI on a field-only (method-less) class hierarchy answers correctly
    // (method-less concrete classes still carry typeinfo). Review finding B1.
    check("t-90-285-rtti-methodless.mod", "YYY\nleaf\n");
}

#[test]
fn t91_030_guard_interface_reject() {
    // GUARD on an interface selector is a compile error (RTTI is native-only).
    check_run_error("t-91-030-guard-interface-reject.mod", &["interface selector"]);
}
