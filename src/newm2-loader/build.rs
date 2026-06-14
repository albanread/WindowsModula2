//! Bake the Win32 def-finder index into the binary.
//!
//! At build time we scan the committed generated defs in `library/NewM2` and
//! serialize a sorted symbol index (`name -> def`) into `OUT_DIR`, which
//! `win32_finder.rs` embeds via `include_bytes!`. So at run time the finder
//! deserializes from memory — no index file, no disk I/O to find a Win32 API
//! symbol. The scan reruns only when a def changes.

use std::path::{Path, PathBuf};

fn main() {
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let out_path = out_dir.join("win32_index.bin");

    // src/newm2-loader -> <workspace>/library/NewM2
    let newm2 = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .map(|ws| ws.join("library").join("NewM2"))
        .filter(|p| p.is_dir());

    let (defs, names) = match &newm2 {
        Some(root) => {
            println!("cargo:rerun-if-changed={}", root.display());
            scan_index(root)
        }
        // No defs present (e.g. a packaging build without the library tree):
        // bake an empty index so the binary still links.
        None => (Vec::new(), Vec::new()),
    };

    let data: (Vec<(String, String)>, Vec<(String, u32)>) = (defs, names);
    let bytes = bincode::serialize(&data).expect("serialize win32 index");
    std::fs::write(&out_path, bytes).expect("write win32 index");
}

/// Returns `(defs, names)` where `defs[i] = (module, relative_path)` and
/// `names` is the sorted, deduped `(name, def_index)` list.
fn scan_index(root: &Path) -> (Vec<(String, String)>, Vec<(String, u32)>) {
    let mut def_files: Vec<PathBuf> = std::fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with("_types.def"))
        })
        .collect();
    def_files.sort();

    let mut defs: Vec<(String, String)> = Vec::with_capacity(def_files.len());
    let mut names: Vec<(String, u32)> = Vec::new();
    for (def_index, path) in def_files.iter().enumerate() {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        let module = scan_module_name(&text).unwrap_or_else(|| {
            path.file_stem()
                .and_then(|s| s.to_str())
                .map(|s| s.trim_end_matches("_types").to_string())
                .unwrap_or_default()
        });
        let rel = path
            .strip_prefix(root)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/");
        let di = def_index as u32;
        names.push((module.clone(), di));
        for sym in scan_exported_names(&text) {
            names.push((sym, di));
        }
        defs.push((module, rel));
    }
    names.sort_by(|a, b| a.0.cmp(&b.0));
    names.dedup_by(|a, b| a.0 == b.0);
    (defs, names)
}

fn scan_module_name(text: &str) -> Option<String> {
    for line in text.lines() {
        if let Some(rest) = line.trim_start().strip_prefix("DEFINITION MODULE ") {
            return Some(rest.trim_end_matches(';').trim().to_string());
        }
    }
    None
}

fn scan_exported_names(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("PROCEDURE ") {
            if let Some(name) = take_ident(rest) {
                out.push(name);
            }
        } else if let Some(rest) = line.strip_prefix("    ") {
            if !rest.starts_with(' ') {
                if let Some(name) = take_ident(rest) {
                    if rest[name.len()..].trim_start().starts_with('=') {
                        out.push(name);
                    }
                }
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
