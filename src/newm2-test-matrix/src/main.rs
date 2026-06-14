//! NewM2 test matrix probe generator.
//!
//! Reads a Rust-array manifest of probes and emits a `.def`+`.mod`
//! fixture per row into `mod-tests/Matrix/` plus a single
//! `tests/newm2-tests/src/tests/matrix_generated.rs` with one
//! `#[test]` per cell.
//!
//! Each probe carries:
//!   { module_name, test_name, spec_section, description,
//!     expected_value, m2_source, mode_filter, ignored }
//!
//! Skeleton: no probes are seeded yet, so the manifest is empty.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModeFilter {
    Both,
    GcOnly,
    NoGcOnly,
}

#[derive(Debug, Clone)]
pub struct Probe {
    pub module_name: &'static str,
    pub test_name: &'static str,
    pub spec_section: &'static str,
    pub description: &'static str,
    pub expected_value: &'static str,
    pub m2_source: &'static str,
    pub mode_filter: ModeFilter,
    pub ignored: bool,
}

const PROBES: &[Probe] = &[];

fn main() {
    println!("newm2-test-matrix-gen — Phase 0 stub");
    println!("  manifest size: {}", PROBES.len());
    println!("  TODO: emit fixtures into ../../mod-tests/Matrix/");
    println!("  TODO: emit ../../tests/newm2-tests/src/tests/matrix_generated.rs");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_empty_at_phase_0() {
        assert!(PROBES.is_empty());
    }

    #[test]
    fn mode_filter_variants() {
        let all = [ModeFilter::Both, ModeFilter::GcOnly, ModeFilter::NoGcOnly];
        assert_eq!(all.len(), 3);
    }
}
