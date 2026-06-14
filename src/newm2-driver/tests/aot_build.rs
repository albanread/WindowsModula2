//! Sprint L — ahead-of-time (`.exe`) build end-to-end tests.
//!
//! Each test shells out to the real `newm2 build` driver to compile a fixture
//! `.mod` to a native Windows executable, runs it, and asserts its stdout.
//! This exercises the whole AOT path: object emission, constant vtables, the
//! runtime-forwarder bridge, the emitted `main` + init/final table, linking
//! against the runtime static library, and the `nm2_aot_run` orchestrator.
//!
//! These are skipped gracefully when the MSVC linker is unavailable (e.g. a
//! machine without the Visual Studio Build Tools), since the project otherwise
//! only needs `cargo`'s own linker setup.

use std::path::PathBuf;
use std::process::Command;

/// Build `<Mod/tests/{stem}.mod>` to a temp `.exe`, run it, return its stdout.
/// Returns `Err(reason)` if the MSVC linker is unavailable (the caller skips).
fn build_and_run(stem: &str) -> Result<String, String> {
    let driver = env!("CARGO_BIN_EXE_newm2-driver");
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let entry = manifest.join("../../Mod/tests").join(format!("{stem}.mod"));
    assert!(entry.is_file(), "fixture not found: {}", entry.display());

    let out_dir = std::env::temp_dir().join("newm2-aot-tests");
    std::fs::create_dir_all(&out_dir).expect("create temp out dir");
    let exe = out_dir.join(format!("{stem}.exe"));

    let build = Command::new(driver)
        .arg("build")
        .arg(&entry)
        .arg("--out")
        .arg(&exe)
        .output()
        .expect("spawn newm2 build");
    if !build.status.success() {
        let stderr = String::from_utf8_lossy(&build.stderr);
        // Skip rather than fail when the AOT toolchain isn't set up: no MSVC
        // linker, or the runtime static library hasn't been built yet (a bare
        // `cargo test -p newm2-driver` builds the rlib but not the staticlib;
        // a full `cargo test` / `cargo build` does).
        if stderr.contains("could not locate the MSVC linker")
            || stderr.contains("newm2_runtime.lib not found")
        {
            return Err(format!("skipped — AOT toolchain unavailable: {stderr}"));
        }
        panic!("newm2 build {stem} failed:\n{stderr}");
    }

    let run = Command::new(&exe)
        .output()
        .unwrap_or_else(|e| panic!("run {}: {e}", exe.display()));
    assert!(
        run.status.success(),
        "{stem}.exe exited with {}",
        run.status
    );
    Ok(String::from_utf8_lossy(&run.stdout).replace("\r\n", "\n"))
}

macro_rules! aot_test {
    ($name:ident, $stem:literal, $expected:literal) => {
        #[test]
        fn $name() {
            match build_and_run($stem) {
                Ok(out) => assert_eq!(out, $expected),
                Err(skip) => eprintln!("{skip}"),
            }
        }
    };
}

// Compile-time constant arithmetic → a native exe that prints 42.
aot_test!(aot_const_arith, "t-10-010-const-arith", "42\n");

// OO: inheritance + virtual dispatch resolved through *constant* vtables (the
// AOT path emits real function-pointer arrays the linker relocates).
aot_test!(aot_inheritance, "t-90-060-inheritance", "1\n2\n4\n9\n1\n2\n");

// EXCEPT/FINALLY inside a class method, exercised through the static
// nm2_aot_run orchestrator + the exception-runtime forwarders.
aot_test!(aot_method_except, "t-90-100-method-except", "5\n-1\n-1\n42\n8\n2\n");

// HALT unwinds to the AOT entry, which begins termination and runs the module
// finalizer (which observes HasHalted) — LIFO finalization end to end.
aot_test!(aot_termination, "t-61-070-conf-termination", "before\nhalted\n");

// COM server: an external COM client (the runtime) drives an M2-implemented
// IUnknown through the *constant* AOT vtable — a real COM client reads exactly
// this layout. Proves the AOT vtable is COM-callable from outside.
aot_test!(aot_com_server, "t-90-110-com-server", "1201\n1\n41\n");

// Native callback: the runtime sorts an INTEGER array by calling back into M2
// comparator procedures through raw function pointers, in a static binary.
aot_test!(aot_native_callback, "t-90-120-native-callback", "1 2 4 5 8 \n8 5 4 2 1 \n");
