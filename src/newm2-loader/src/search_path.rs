//! Module search-path resolution.
//!
//! The search path is a list of directories scanned in order. For a
//! given module name `Foo`, the loader looks for `Foo.def` in each
//! directory and uses the first match. The implementation file is
//! found by:
//!  1. `<same-dir>/Foo.mod`, or
//!  2. the sibling directory where the last `def` path component is
//!     replaced by `mod` (e.g. `isodef/Foo.def` → `isomod/Foo.mod`,
//!     `def/Foo.def` → `mod/Foo.mod`).

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default)]
pub struct SearchPath {
    entries: Vec<PathBuf>,
}

impl SearchPath {
    pub fn new() -> Self {
        Self { entries: Vec::new() }
    }

    pub fn push(&mut self, dir: impl Into<PathBuf>) {
        self.entries.push(dir.into());
    }

    pub fn entries(&self) -> &[PathBuf] {
        &self.entries
    }

    /// Find a module's DEF file by walking the search path. Returns
    /// the first match.
    pub fn find_def(&self, module: &str) -> Option<PathBuf> {
        // A hand-written `<Module>.def` takes precedence; a generated
        // `<Module>_types.def` (our own Win32 API defs under `library/NewM2`,
        // and the reduced windows_api snapshot) is the fallback.
        for dir in &self.entries {
            for filename in [format!("{module}.def"), format!("{module}_types.def")] {
                let p = dir.join(&filename);
                if p.is_file() {
                    return Some(p);
                }
            }
        }
        None
    }

    /// Given a DEF path, locate the matching IMPLEMENTATION MODULE
    /// source. Returns None when the body isn't present in the search
    /// tree (e.g. for compiler-provided / runtime-implemented modules).
    pub fn find_impl_for_def(&self, def_path: &Path) -> Option<PathBuf> {
        // Strategy 1: same directory, .mod extension.
        let mut candidate = def_path.to_path_buf();
        candidate.set_extension("mod");
        if candidate.is_file() {
            return Some(candidate);
        }
        // Strategy 2: sibling directory rewriting *def → *mod in the
        // immediate parent name (isodef → isomod, def → mod, …).
        let parent = def_path.parent()?;
        let parent_name = parent.file_name()?.to_str()?;
        if !parent_name.ends_with("def") {
            return None;
        }
        let sibling = format!("{}mod", &parent_name[..parent_name.len() - 3]);
        let basename = def_path.file_stem()?;
        let alt = parent.parent()?.join(&sibling).join(format!(
            "{}.mod",
            basename.to_str()?
        ));
        if alt.is_file() { Some(alt) } else { None }
    }
}
