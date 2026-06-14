use newm2_tests::run_test_nogc;

/// Win32 API call materialized through the generated `library/NewM2` defs and
/// the JIT's DLL linkage. GetTickCount (KERNEL32) is better proof than Beep:
/// its result is observable — a non-zero, non-decreasing millisecond count.
#[cfg(windows)]
#[test]
fn win32_gettickcount_can_be_called_through_jit() {
    let output = run_test_nogc("t-50-061-win32-gettickcount.mod").unwrap();
    assert_eq!(output, "ok\n", "unexpected output: {output:?}");
}
