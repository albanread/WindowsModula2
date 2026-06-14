//! Win32 def finder — a tiny, fast index over the generated `library/NewM2`
//! Win32 API defs.
//!
//! Instead of decoding a monolithic pre-parsed pack (52 MB for the whole API),
//! the finder holds only two sorted lists:
//!
//!   * `defs`  — every generated module, as `(module_name, def_path)`.
//!   * `names` — every exported declaration name (PROCEDURE / TYPE / CONST) and
//!               every module name, each paired with an index into `defs`,
//!               sorted so a symbol resolves with a binary search.
//!
//! Resolution is: binary-search `names` for the symbol → index into `defs` →
//! parse that one `.def` on demand. So a program that calls a handful of Win32
//! procedures loads a handful of defs, not the entire API, and the finder is
//! authoritative — `WIN32` always resolves to our generated base, never a
//! same-named file elsewhere on the search path.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

use crate::loader::LoadError;

const WIN32_INDEX_FORMAT_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Win32Finder {
    /// `(module_name, relative def path under the NewM2 root)`, def-index order.
    defs: Vec<(String, String)>,
    /// `(name, def_index)` sorted by `name` for binary search. `name` is every
    /// exported declaration plus the module names themselves.
    names: Vec<(String, u32)>,
    /// Absolute root the relative def paths are joined against (not serialized;
    /// set on load).
    #[serde(skip)]
    root: PathBuf,
    format_version: u32,
}

impl Win32Finder {
    /// Resolve a module or symbol name to the def file that declares it.
    pub fn find(&self, name: &str) -> Option<PathBuf> {
        let idx = self
            .names
            .binary_search_by(|(n, _)| n.as_str().cmp(name))
            .ok()?;
        let def = self.names[idx].1 as usize;
        Some(self.root.join(&self.defs[def].1))
    }

    /// The module name declared by the def at `def_index` (for diagnostics).
    pub fn module_name_for(&self, name: &str) -> Option<&str> {
        let idx = self
            .names
            .binary_search_by(|(n, _)| n.as_str().cmp(name))
            .ok()?;
        Some(self.defs[self.names[idx].1 as usize].0.as_str())
    }
}

/// The Win32 index baked into the binary at build time (see `build.rs`).
static EMBEDDED_INDEX: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/win32_index.bin"));

/// The Win32 def finder baked into the binary — deserialized from the embedded
/// index exactly once (no index file, no disk read to resolve a symbol).
/// `newm2_root` is the runtime `library/NewM2` location the relative def paths
/// are joined against when a def is actually loaded.
pub fn embedded_finder(newm2_root: &Path) -> &'static Win32Finder {
    use std::sync::OnceLock;
    static CELL: OnceLock<Win32Finder> = OnceLock::new();
    CELL.get_or_init(|| {
        let (defs, names): (Vec<(String, String)>, Vec<(String, u32)>) =
            bincode::deserialize(EMBEDDED_INDEX).unwrap_or_default();
        Win32Finder {
            defs,
            names,
            root: newm2_root.to_path_buf(),
            format_version: WIN32_INDEX_FORMAT_VERSION,
        }
    })
}

/// Build the finder by scanning `library/NewM2/*_types.def`. The scan is
/// lightweight — it reads the regular generated text, not a full parse — so
/// rebuilding is cheap. Used for ad-hoc def trees (e.g. generated test
/// fixtures); the driver uses the baked-in [`embedded_finder`] instead.
pub fn build_win32_finder(newm2_root: &Path) -> Result<Win32Finder, LoadError> {
    let mut def_files: Vec<PathBuf> = Vec::new();
    for entry in fs::read_dir(newm2_root).map_err(|e| LoadError {
        message: format!("read failed: {e}"),
        path: Some(newm2_root.to_path_buf()),
    })? {
        let path = entry
            .map_err(|e| LoadError { message: format!("read failed: {e}"), path: None })?
            .path();
        if path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.ends_with("_types.def"))
        {
            def_files.push(path);
        }
    }
    def_files.sort();

    let mut defs: Vec<(String, String)> = Vec::with_capacity(def_files.len());
    let mut names: Vec<(String, u32)> = Vec::new();
    for (def_index, path) in def_files.iter().enumerate() {
        let text = fs::read_to_string(path).map_err(|e| LoadError {
            message: format!("read failed: {e}"),
            path: Some(path.clone()),
        })?;
        let module = scan_module_name(&text).unwrap_or_else(|| {
            // Fall back to the file stem minus the `_types` suffix.
            path.file_stem()
                .and_then(|s| s.to_str())
                .map(|s| s.trim_end_matches("_types").to_string())
                .unwrap_or_default()
        });
        let rel = path
            .strip_prefix(newm2_root)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/");
        let di = def_index as u32;
        // The module name resolves to its own def.
        names.push((module.clone(), di));
        for sym in scan_exported_names(&text) {
            names.push((sym, di));
        }
        defs.push((module, rel));
    }

    // Sort + dedup by name. A name exported by two namespaces keeps the first
    // def (deterministic by sorted def order); ambiguity is rare for Win32 and
    // module-qualified imports are unaffected.
    names.sort_by(|a, b| a.0.cmp(&b.0));
    names.dedup_by(|a, b| a.0 == b.0);

    Ok(Win32Finder {
        defs,
        names,
        root: newm2_root.to_path_buf(),
        format_version: WIN32_INDEX_FORMAT_VERSION,
    })
}

/// Build the finder, caching it at `index_path`; rebuild only when a def is
/// newer than the cache.
pub fn ensure_win32_finder(
    newm2_root: &Path,
    index_path: &Path,
) -> Result<Win32Finder, LoadError> {
    if !index_needs_rebuild(newm2_root, index_path)? {
        if let Ok(finder) = load_win32_finder(newm2_root, index_path) {
            return Ok(finder);
        }
    }
    let finder = build_win32_finder(newm2_root)?;
    save_win32_finder(&finder, index_path)?;
    Ok(finder)
}

fn load_win32_finder(newm2_root: &Path, index_path: &Path) -> Result<Win32Finder, LoadError> {
    let bytes = fs::read(index_path).map_err(|e| LoadError {
        message: format!("read failed: {e}"),
        path: Some(index_path.to_path_buf()),
    })?;
    let mut finder: Win32Finder = bincode::deserialize(&bytes).map_err(|e| LoadError {
        message: format!("win32 index decode failed: {e}"),
        path: Some(index_path.to_path_buf()),
    })?;
    if finder.format_version != WIN32_INDEX_FORMAT_VERSION {
        return Err(LoadError {
            message: "win32 index version mismatch".into(),
            path: Some(index_path.to_path_buf()),
        });
    }
    finder.root = newm2_root.to_path_buf();
    Ok(finder)
}

fn save_win32_finder(finder: &Win32Finder, index_path: &Path) -> Result<(), LoadError> {
    let bytes = bincode::serialize(finder).map_err(|e| LoadError {
        message: format!("win32 index encode failed: {e}"),
        path: Some(index_path.to_path_buf()),
    })?;
    if let Some(parent) = index_path.parent() {
        fs::create_dir_all(parent).map_err(|e| LoadError {
            message: format!("create dir failed: {e}"),
            path: Some(parent.to_path_buf()),
        })?;
    }
    let tmp = index_path.with_extension(format!("tmp.{}", std::process::id()));
    fs::write(&tmp, bytes).map_err(|e| LoadError {
        message: format!("write failed: {e}"),
        path: Some(tmp.clone()),
    })?;
    fs::rename(&tmp, index_path).map_err(|e| LoadError {
        message: format!("rename failed: {e}"),
        path: Some(index_path.to_path_buf()),
    })?;
    Ok(())
}

fn index_needs_rebuild(newm2_root: &Path, index_path: &Path) -> Result<bool, LoadError> {
    let Ok(index_meta) = fs::metadata(index_path) else {
        return Ok(true);
    };
    let Ok(index_mtime) = index_meta.modified() else {
        return Ok(true);
    };
    for entry in fs::read_dir(newm2_root).map_err(|e| LoadError {
        message: format!("read failed: {e}"),
        path: Some(newm2_root.to_path_buf()),
    })? {
        let path = entry
            .map_err(|e| LoadError { message: format!("read failed: {e}"), path: None })?
            .path();
        if path.extension().and_then(|e| e.to_str()) == Some("def") {
            if let Ok(m) = fs::metadata(&path).and_then(|md| md.modified()) {
                if m > index_mtime {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

/// `DEFINITION MODULE <name>;`
fn scan_module_name(text: &str) -> Option<String> {
    for line in text.lines() {
        let line = line.trim_start();
        if let Some(rest) = line.strip_prefix("DEFINITION MODULE ") {
            return Some(rest.trim_end_matches(';').trim().to_string());
        }
    }
    None
}

/// Every top-level exported declaration name in a generated def: `PROCEDURE X…`,
/// and 4-space-indented `X = …` (a CONST or TYPE). Record fields (`name : T`,
/// deeper indent) and import lists are skipped.
fn scan_exported_names(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("PROCEDURE ") {
            if let Some(name) = take_ident(rest) {
                out.push(name);
            }
        } else if let Some(rest) = line.strip_prefix("    ") {
            // Top-level CONST/TYPE: exactly 4 spaces, an identifier, then `=`.
            if !rest.starts_with(' ')
                && let Some(name) = take_ident(rest)
                && rest[name.len()..].trim_start().starts_with('=')
            {
                out.push(name);
            }
        }
    }
    out
}

fn take_ident(s: &str) -> Option<String> {
    let mut end = 0;
    for (i, c) in s.char_indices() {
        if c.is_alphanumeric() || c == '_' {
            end = i + c.len_utf8();
        } else {
            break;
        }
    }
    (end > 0).then(|| s[..end].to_string())
}
