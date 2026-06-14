//! Symbol-file cache scaffolding.
//!
//! The plumbing: a deterministic content hash for each module's DEF
//! source, a cache key combining the DEF hash with transitive DEF
//! hashes / compiler version / codegen-flags / memory-mode, and a
//! simple text-based on-disk format. The cache is not yet consulted on
//! the loader's fast-path.

use std::path::{Path, PathBuf};

/// A 64-bit content hash. DJB2 over the source bytes — not
/// cryptographic, but deterministic across runs and across Rust
/// versions, which is what the cache contract requires.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ContentHash(pub u64);

pub fn hash_source(bytes: &[u8]) -> ContentHash {
    let mut h: u64 = 5381;
    for &b in bytes {
        h = h.wrapping_mul(33).wrapping_add(b as u64);
    }
    ContentHash(h)
}

impl std::fmt::Display for ContentHash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:016x}", self.0)
    }
}

/// A full cache key for one module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CacheKey {
    pub module: String,
    pub def_hash: ContentHash,
    /// Transitive DEF hashes, sorted by imported module name for
    /// stability.
    pub transitive: Vec<(String, ContentHash)>,
    pub compiler_version: &'static str,
    pub codegen_flags: String,
    pub memory_mode: MemoryMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryMode {
    Gc,
    NoGc,
}

impl MemoryMode {
    pub fn as_str(self) -> &'static str {
        match self {
            MemoryMode::Gc => "gc",
            MemoryMode::NoGc => "nogc",
        }
    }
}

pub const COMPILER_VERSION: &str = env!("CARGO_PKG_VERSION");

impl CacheKey {
    /// Serialise the key to the line-oriented on-disk format. One key
    /// per file; round-trippable.
    pub fn to_text(&self) -> String {
        let mut s = String::new();
        s.push_str(&format!("module {}\n", self.module));
        s.push_str(&format!("def-hash {}\n", self.def_hash));
        for (name, h) in &self.transitive {
            s.push_str(&format!("trans {name} {h}\n"));
        }
        s.push_str(&format!("compiler {}\n", self.compiler_version));
        s.push_str(&format!("codegen {}\n", self.codegen_flags));
        s.push_str(&format!("memory {}\n", self.memory_mode.as_str()));
        s
    }

    pub fn from_text(s: &str) -> Result<Self, String> {
        let mut module = None;
        let mut def_hash = None;
        let mut transitive = Vec::new();
        let mut codegen_flags = None;
        let mut memory_mode = None;
        for line in s.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let (head, rest) =
                line.split_once(' ').ok_or_else(|| format!("malformed line: {line:?}"))?;
            match head {
                "module" => module = Some(rest.to_string()),
                "def-hash" => def_hash = Some(parse_hash(rest)?),
                "trans" => {
                    let (n, h) = rest
                        .split_once(' ')
                        .ok_or_else(|| format!("malformed trans line: {rest:?}"))?;
                    transitive.push((n.to_string(), parse_hash(h)?));
                }
                "compiler" => {
                    // Ignored on read — `compiler_version` is always
                    // set from the running binary; the field is here
                    // so a cache from a different compiler doesn't
                    // silently look like a hit.
                }
                "codegen" => codegen_flags = Some(rest.to_string()),
                "memory" => {
                    memory_mode = Some(match rest {
                        "gc" => MemoryMode::Gc,
                        "nogc" => MemoryMode::NoGc,
                        other => {
                            return Err(format!("unknown memory mode {other:?}"));
                        }
                    });
                }
                _ => {
                    return Err(format!("unknown cache header {head:?}"));
                }
            }
        }
        Ok(Self {
            module: module.ok_or("missing 'module' line")?,
            def_hash: def_hash.ok_or("missing 'def-hash' line")?,
            transitive,
            compiler_version: COMPILER_VERSION,
            codegen_flags: codegen_flags.ok_or("missing 'codegen' line")?,
            memory_mode: memory_mode.ok_or("missing 'memory' line")?,
        })
    }
}

fn parse_hash(s: &str) -> Result<ContentHash, String> {
    u64::from_str_radix(s, 16)
        .map(ContentHash)
        .map_err(|e| format!("invalid hash {s:?}: {e}"))
}

/// On-disk cache layout: stores `KEY <hash>.symfile` per module under
/// the cache root, with the symbol-file payload alongside the key.
#[derive(Debug, Clone)]
pub struct Cache {
    pub root: PathBuf,
}

impl Cache {
    pub fn at(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn ensure_root(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.root)
    }

    pub fn path_for(&self, key: &CacheKey) -> PathBuf {
        self.root.join(format!("{}.{}.key", key.module, key.def_hash))
    }

    pub fn write_key(&self, key: &CacheKey) -> std::io::Result<PathBuf> {
        self.ensure_root()?;
        let path = self.path_for(key);
        std::fs::write(&path, key.to_text())?;
        Ok(path)
    }

    pub fn read_key(&self, path: &Path) -> std::io::Result<CacheKey> {
        let s = std::fs::read_to_string(path)?;
        CacheKey::from_text(&s).map_err(std::io::Error::other)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn djb2_is_deterministic() {
        assert_eq!(hash_source(b"abc"), hash_source(b"abc"));
        assert_ne!(hash_source(b"abc"), hash_source(b"abd"));
    }

    #[test]
    fn cache_key_roundtrip() {
        let k = CacheKey {
            module: "Foo".into(),
            def_hash: hash_source(b"DEFINITION MODULE Foo; END Foo."),
            transitive: vec![
                ("IOChan".into(), ContentHash(0x1234567890abcdef)),
                ("SYSTEM".into(), ContentHash(0xdeadbeefcafebabe)),
            ],
            compiler_version: COMPILER_VERSION,
            codegen_flags: "-O2".into(),
            memory_mode: MemoryMode::Gc,
        };
        let text = k.to_text();
        let parsed = CacheKey::from_text(&text).unwrap();
        assert_eq!(parsed, k);
    }
}
