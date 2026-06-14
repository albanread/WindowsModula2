//! On-disk separate-compilation symbol cache: store a module's exported
//! interface keyed by a [`CacheKey`] (its DEF hash + every transitive DEF hash
//! + compiler version + codegen flags + memory mode), and reload it on a later
//! compile to skip re-checking that interface.
//!
//! Correctness contract: changing a DEF changes
//! its hash and the hash appears in every importer's key, so all importers miss
//! and re-check; changing only a `.mod` *body* changes no DEF hash, so importers
//! hit. The cache only ever skips work — a miss or a decode failure falls back
//! to the full check.

use crate::iface::{IFACE_FORMAT_VERSION, ModuleInterface};
use newm2_loader::cache::COMPILER_VERSION;
use newm2_loader::{CacheKey, MemoryMode, ModuleGraph, ModuleId};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::PathBuf;

/// How the checker should use the cache for this compile.
#[derive(Debug, Clone)]
pub struct CacheConfig {
    pub dir: PathBuf,
    pub codegen_flags: String,
    pub memory_mode: MemoryMode,
    /// Reload interfaces from the cache (skip re-checking on a hit).
    pub read: bool,
    /// Write freshly-checked interfaces back to the cache.
    pub write: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct CachedIface {
    /// The full cache key, as text — compared on load to reject a stale entry
    /// (a transitive DEF changed, or a different compiler/flags/memory mode).
    key_text: String,
    iface: ModuleInterface,
}

/// The cache key for module `mid`: its own DEF hash plus the hash of every
/// transitively imported DEF (sorted by name), the compiler version, the
/// codegen flags, and the memory mode. `None` for modules with no DEF (a
/// program) or intrinsics — those are never cached as interfaces.
pub fn cache_key(graph: &ModuleGraph, mid: ModuleId, cfg: &CacheConfig) -> Option<CacheKey> {
    let node = graph.get(mid);
    if node.is_intrinsic {
        return None;
    }
    let def_hash = node.def_hash?;
    let mut transitive = Vec::new();
    let mut seen = HashSet::new();
    let mut stack: Vec<ModuleId> = node.imports.clone();
    while let Some(m) = stack.pop() {
        if !seen.insert(m) {
            continue;
        }
        let n = graph.get(m);
        if let Some(h) = n.def_hash {
            transitive.push((n.name.clone(), h));
        }
        stack.extend(n.imports.iter().copied());
    }
    transitive.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.0.cmp(&b.1.0)));
    Some(CacheKey {
        module: node.name.clone(),
        def_hash,
        transitive,
        compiler_version: COMPILER_VERSION,
        codegen_flags: cfg.codegen_flags.clone(),
        memory_mode: cfg.memory_mode,
    })
}

fn path_for(cfg: &CacheConfig, name: &str, def_hash: newm2_loader::ContentHash) -> PathBuf {
    cfg.dir.join(format!("{name}.{def_hash}.iface"))
}

/// Load `mid`'s cached interface if present and still valid for this compile.
pub fn load_valid_interface(
    graph: &ModuleGraph,
    mid: ModuleId,
    cfg: &CacheConfig,
) -> Option<ModuleInterface> {
    let node = graph.get(mid);
    let def_hash = node.def_hash?;
    let key = cache_key(graph, mid, cfg)?;
    let bytes = std::fs::read(path_for(cfg, &node.name, def_hash)).ok()?;
    let cached: CachedIface = bincode::deserialize(&bytes).ok()?;
    if cached.key_text != key.to_text() {
        return None; // a transitive DEF / flag / compiler changed → stale.
    }
    if cached.iface.format_version != IFACE_FORMAT_VERSION {
        return None;
    }
    Some(cached.iface)
}

/// Write `mid`'s freshly-checked interface to the cache. Best-effort: any I/O
/// or encode error is swallowed (the cache is an optimisation).
pub fn store_interface(
    graph: &ModuleGraph,
    mid: ModuleId,
    cfg: &CacheConfig,
    iface: &ModuleInterface,
) {
    let node = graph.get(mid);
    let Some(def_hash) = node.def_hash else { return };
    let Some(key) = cache_key(graph, mid, cfg) else { return };
    if std::fs::create_dir_all(&cfg.dir).is_err() {
        return;
    }
    let cached = CachedIface { key_text: key.to_text(), iface: iface.clone() };
    if let Ok(bytes) = bincode::serialize(&cached) {
        let _ = std::fs::write(path_for(cfg, &node.name, def_hash), bytes);
    }
}
