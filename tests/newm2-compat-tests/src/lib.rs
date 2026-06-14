//! Snapshot tests against the textual dumps from each compiler phase
//! (`dump-tokens`, `dump-ast`, `dump-sema`, `dump-cfg`, `dump-ir`,
//! `dump-llvm`, `dump-asm`).
//!
//! Catches accidental phase-output drift over time.
//!
//! Phase 0 skeleton.

#[cfg(test)]
mod tests {
    #[test]
    fn placeholder() {}
}
