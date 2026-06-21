//! Autocomplete: resolve the receiver expression before a cursor and enumerate
//! the members available there.
//!
//! Three cases, covering "object method calls" in every flavour the dialect has:
//!   * `Module.`      -> the module's exported procs / consts / types / vars
//!   * `record.`      -> the record's fields (variant parts flattened)
//!   * `obj.` / `iface.` -> a CLASS / INTERFACE's fields + methods (inheritance
//!                          already flattened in `all_fields` / `vtable`), with
//!                          method signatures
//!   * no `.`         -> every identifier visible in the active scope chain
//!
//! The engine is read-only over a `SemaResult`: it never re-runs analysis. The
//! receiver chain is recovered from the source text by a small backward lexer
//! scan (so it works even when the rest of the line is mid-edit), then resolved
//! against the symbol table the way `analyse_designator` does, but without a
//! `Ctx` and without emitting diagnostics.

use newm2_loader::{ModuleGraph, ModuleId};
use newm2_parser::ast;

use crate::analyze::SemaResult;
use crate::class::ClassSymbolId;
use crate::scope::{ProcSig, ScopeId, SymbolKind};
use crate::types::{ParamMode, TypeId, TypeKind};

/// One completion candidate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Completion {
    pub name: String,
    /// A short kind tag for the UI ("module", "procedure", "field", "method", …).
    pub kind: String,
    /// A signature / type string for display (may be empty).
    pub detail: String,
}

fn is_ident_byte(b: u8) -> bool {
    b == b'_' || b.is_ascii_alphanumeric()
}

/// What the backward scan found at the cursor.
struct ReceiverScan {
    /// The dotted receiver parts left of the final `.` (empty = no receiver,
    /// i.e. a bare-identifier completion).
    parts: Vec<String>,
    /// The partial word being typed after the final `.` (the filter prefix).
    prefix: String,
    /// `true` if there was a `.` immediately before the prefix (member access).
    member: bool,
}

/// Scan left from `cursor` (a byte offset) to recover the receiver chain and the
/// partial word being completed.
fn scan_receiver(source: &str, cursor: usize) -> ReceiverScan {
    let b = source.as_bytes();
    let cursor = cursor.min(b.len());

    // The partial word immediately left of the cursor.
    let mut ps = cursor;
    while ps > 0 && is_ident_byte(b[ps - 1]) {
        ps -= 1;
    }
    let prefix = source[ps..cursor].to_string();

    // Is there a `.` immediately before the partial word?
    if ps == 0 || b[ps - 1] != b'.' {
        return ReceiverScan { parts: Vec::new(), prefix, member: false };
    }

    // Collect the maximal run of ident/`.` chars ending at the dot (exclusive of
    // the dot itself): the receiver designator text, e.g. "Terminal" or "a.b.c".
    let dot = ps - 1;
    let mut start = dot;
    while start > 0 && (is_ident_byte(b[start - 1]) || b[start - 1] == b'.') {
        start -= 1;
    }
    let recv = &source[start..dot];
    let parts: Vec<String> =
        recv.split('.').filter(|s| !s.is_empty()).map(|s| s.to_string()).collect();
    ReceiverScan { parts, prefix, member: true }
}

/// Convert a (1-based line, 0-based column) cursor to a byte offset in `source`.
/// Columns count bytes on the line (the IDE buffer is ASCII source).
pub fn line_col_to_offset(source: &str, line: usize, col: usize) -> usize {
    if line == 0 {
        return col.min(source.len());
    }
    let mut cur_line = 1usize;
    let mut off = 0usize;
    let b = source.as_bytes();
    while off < b.len() && cur_line < line {
        if b[off] == b'\n' {
            cur_line += 1;
        }
        off += 1;
    }
    // off is at the first byte of the target line; advance col bytes, but stop at EOL.
    let mut c = 0usize;
    while off < b.len() && b[off] != b'\n' && c < col {
        off += 1;
        c += 1;
    }
    off
}

/// Top-level: complete at `cursor` (byte offset) in `module`'s `source`.
pub fn complete_at(
    graph: &ModuleGraph,
    sema: &SemaResult,
    module: ModuleId,
    source: &str,
    cursor: usize,
) -> Vec<Completion> {
    let scan = scan_receiver(source, cursor);
    let scope = active_scope(graph, sema, module, cursor);
    let prefix_lc = scan.prefix.to_ascii_lowercase();

    let mut out: Vec<Completion> = Vec::new();
    if !scan.member {
        // Bare identifier: walk the scope chain to pervasive, inner shadows outer.
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut sc = Some(scope);
        while let Some(id) = sc {
            let s = sema.scopes.get(id);
            for sym in s.iter() {
                if seen.contains(&sym.name) {
                    continue;
                }
                if matches_prefix(&sym.name, &prefix_lc) {
                    out.push(symbol_completion(sema, &sym.name, &sym.kind));
                }
                seen.insert(sym.name.clone());
            }
            sc = s.parent;
        }
    } else if let Some(target) = resolve_receiver(sema, scope, &scan.parts) {
        match target {
            Target::Module(sid) => {
                for sym in sema.scopes.get(sid).iter() {
                    if !sym.exported {
                        continue; // a qualified `Mod.x` sees only Mod's exports
                    }
                    if matches_prefix(&sym.name, &prefix_lc) {
                        out.push(symbol_completion(sema, &sym.name, &sym.kind));
                    }
                }
            }
            Target::Type(ty) => enumerate_type_members(sema, ty, &prefix_lc, &mut out),
        }
    }

    out.sort_by(|a, b| a.name.to_ascii_lowercase().cmp(&b.name.to_ascii_lowercase()));
    out.dedup_by(|a, b| a.name == b.name && a.kind == b.kind);
    out.truncate(200);
    out
}

fn matches_prefix(name: &str, prefix_lc: &str) -> bool {
    prefix_lc.is_empty() || name.to_ascii_lowercase().starts_with(prefix_lc)
}

/// A resolved receiver: either a module (enumerate its exports) or a type
/// (enumerate its fields/methods).
enum Target {
    Module(ScopeId),
    Type(TypeId),
}

/// Resolve `parts` (e.g. ["a","b"]) starting from `scope` to a module or a type.
fn resolve_receiver(sema: &SemaResult, scope: ScopeId, parts: &[String]) -> Option<Target> {
    let first = parts.first()?;
    let sym = sema.scopes.lookup(scope, first)?;
    let mut cur = target_of_symbol(&sym.kind)?;

    for part in &parts[1..] {
        cur = match cur {
            Target::Module(sid) => {
                let sym = sema.scopes.get(sid).get(part)?;
                target_of_symbol(&sym.kind)?
            }
            Target::Type(ty) => Target::Type(member_type(sema, ty, part)?),
        };
    }
    Some(cur)
}

fn target_of_symbol(kind: &SymbolKind) -> Option<Target> {
    match kind {
        SymbolKind::Module(_, sid) => Some(Target::Module(*sid)),
        SymbolKind::Var { ty, .. } => Some(Target::Type(*ty)),
        SymbolKind::Const { ty, .. } => Some(Target::Type(*ty)),
        // A bare type name as a qualifier (e.g. an enum) has no member syntax in
        // M2; only value-typed receivers yield members.
        _ => None,
    }
}

/// Follow `POINTER TO` levels to the underlying aggregate.
fn strip_pointers(sema: &SemaResult, mut ty: TypeId) -> TypeId {
    let mut guard = 0;
    while let TypeKind::Pointer { base } = sema.types.get(ty) {
        ty = *base;
        guard += 1;
        if guard > 16 {
            break;
        }
    }
    ty
}

/// The type that results from selecting `.name` on a value of type `ty` (for
/// chaining `a.b.c`). A method selector yields its return type.
fn member_type(sema: &SemaResult, ty: TypeId, name: &str) -> Option<TypeId> {
    let ty = strip_pointers(sema, ty);
    match sema.types.get(ty) {
        TypeKind::Record(layout) => {
            layout.flatten_fields().into_iter().find(|(n, _)| n == name).map(|(_, t)| t)
        }
        TypeKind::Class { symbol } => {
            let c = sema.classes.get(ClassSymbolId(*symbol));
            if let Some(f) = c.all_fields.iter().find(|f| f.name == name) {
                return Some(f.ty);
            }
            c.vtable.iter().find(|m| m.name == name).and_then(|m| m.sig.return_ty)
        }
        _ => None,
    }
}

fn enumerate_type_members(
    sema: &SemaResult,
    ty: TypeId,
    prefix_lc: &str,
    out: &mut Vec<Completion>,
) {
    let ty = strip_pointers(sema, ty);
    match sema.types.get(ty) {
        TypeKind::Record(layout) => {
            for (name, fty) in layout.flatten_fields() {
                if matches_prefix(&name, prefix_lc) {
                    out.push(Completion {
                        name,
                        kind: "field".to_string(),
                        detail: type_name(sema, fty, 0),
                    });
                }
            }
        }
        TypeKind::Class { symbol } => {
            let c = sema.classes.get(ClassSymbolId(*symbol));
            for f in &c.all_fields {
                if matches_prefix(&f.name, prefix_lc) {
                    out.push(Completion {
                        name: f.name.clone(),
                        kind: "field".to_string(),
                        detail: type_name(sema, f.ty, 0),
                    });
                }
            }
            for m in &c.vtable {
                if matches_prefix(&m.name, prefix_lc) {
                    out.push(Completion {
                        name: m.name.clone(),
                        kind: "method".to_string(),
                        detail: sig_detail(sema, &m.sig),
                    });
                }
            }
        }
        _ => {}
    }
}

fn symbol_completion(sema: &SemaResult, name: &str, kind: &SymbolKind) -> Completion {
    let detail = match kind {
        SymbolKind::Proc(sig) => sig_detail(sema, sig),
        SymbolKind::Var { ty, .. } | SymbolKind::Const { ty, .. } => type_name(sema, *ty, 0),
        SymbolKind::Type(ty) => type_name(sema, *ty, 0),
        SymbolKind::EnumMember { ty, .. } => type_name(sema, *ty, 0),
        SymbolKind::Class(cid) => sema.classes.get(*cid).name.clone(),
        SymbolKind::Module(..) => String::new(),
    };
    Completion { name: name.to_string(), kind: kind.kind_name().to_string(), detail }
}

/// A readable name for a type (for display only).
pub(crate) fn type_name(sema: &SemaResult, ty: TypeId, depth: u32) -> String {
    if depth > 6 {
        return "...".to_string();
    }
    match sema.types.get(ty) {
        TypeKind::Builtin(b) => b.name().to_string(),
        TypeKind::Enum { name: Some(n), .. } => n.clone(),
        TypeKind::Enum { name: None, .. } => "enum".to_string(),
        TypeKind::Record(layout) => layout.name.clone().unwrap_or_else(|| "RECORD".to_string()),
        TypeKind::Pointer { base } => format!("POINTER TO {}", type_name(sema, *base, depth + 1)),
        TypeKind::Array { base, .. } => format!("ARRAY OF {}", type_name(sema, *base, depth + 1)),
        TypeKind::OpenArray { base } => format!("ARRAY OF {}", type_name(sema, *base, depth + 1)),
        TypeKind::Class { symbol } => sema.classes.get(ClassSymbolId(*symbol)).name.clone(),
        TypeKind::Set { base, .. } => format!("SET OF {}", type_name(sema, *base, depth + 1)),
        TypeKind::Vector { lanes, base } => format!("{}x{}", type_name(sema, *base, depth + 1), lanes),
        TypeKind::Subrange { host, .. } => type_name(sema, *host, depth + 1),
        TypeKind::Proc { .. } => "PROCEDURE".to_string(),
        TypeKind::Unresolved => "?".to_string(),
    }
}

pub(crate) fn sig_detail(sema: &SemaResult, sig: &ProcSig) -> String {
    let mut s = String::from("(");
    for (i, p) in sig.params.iter().enumerate() {
        if i > 0 {
            s.push_str("; ");
        }
        match p.mode {
            ParamMode::Var => s.push_str("VAR "),
            ParamMode::Const => s.push_str("CONST "),
            ParamMode::Value => {}
        }
        if let Some(n) = &p.name {
            s.push_str(n);
            s.push_str(": ");
        }
        s.push_str(&type_name(sema, p.ty, 0));
    }
    s.push(')');
    if let Some(rt) = sig.return_ty {
        s.push_str(": ");
        s.push_str(&type_name(sema, rt, 0));
    }
    s
}

/// The `ScopeId` active at `cursor`: the innermost enclosing procedure body, or
/// the module scope. (Block / local-module scopes are not position-indexed, so
/// completion falls back to the enclosing procedure for those.)
fn active_scope(graph: &ModuleGraph, sema: &SemaResult, module: ModuleId, cursor: usize) -> ScopeId {
    let module_scope = sema.module_scopes.get(&module).copied();
    let node = graph.get(module);
    let ast = node.impl_ast.as_ref().or(node.def_ast.as_ref());
    if let Some(m) = ast {
        if let Some(name) = enclosing_proc(&m.decls, cursor) {
            if let Some(&psc) = sema.proc_scopes.get(&(module, name)) {
                return psc;
            }
        }
    }
    module_scope.unwrap_or(sema.pervasive)
}

fn span_contains(span: newm2_lexer::Span, off: usize) -> bool {
    off >= span.start.offset && off <= span.end.offset
}

/// The name of the innermost `ProcDecl` whose span contains `cursor`.
fn enclosing_proc(decls: &[ast::Decl], cursor: usize) -> Option<String> {
    for d in decls {
        if let ast::Decl::Procedure(p) = d {
            if span_contains(p.span, cursor) {
                if let Some(body) = &p.body {
                    if let Some(inner) = enclosing_proc(&body.decls, cursor) {
                        return Some(inner);
                    }
                }
                return Some(p.name.clone());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_member_access() {
        let src = "  rt.par";
        let s = scan_receiver(src, src.len());
        assert!(s.member);
        assert_eq!(s.parts, vec!["rt".to_string()]);
        assert_eq!(s.prefix, "par");
    }

    #[test]
    fn scan_trailing_dot() {
        let src = "  Terminal.";
        let s = scan_receiver(src, src.len());
        assert!(s.member);
        assert_eq!(s.parts, vec!["Terminal".to_string()]);
        assert_eq!(s.prefix, "");
    }

    #[test]
    fn scan_dotted_chain() {
        let src = "x := a.b.c.";
        let s = scan_receiver(src, src.len());
        assert_eq!(s.parts, vec!["a".to_string(), "b".to_string(), "c".to_string()]);
        assert_eq!(s.prefix, "");
    }

    #[test]
    fn scan_bare_identifier() {
        let src = "  Wri";
        let s = scan_receiver(src, src.len());
        assert!(!s.member);
        assert!(s.parts.is_empty());
        assert_eq!(s.prefix, "Wri");
    }

    #[test]
    fn line_col_offset_basic() {
        let src = "line1\nline2\nline3";
        // line 2, col 0 -> just after the first '\n'
        assert_eq!(line_col_to_offset(src, 2, 0), 6);
        assert_eq!(&src[line_col_to_offset(src, 2, 0)..line_col_to_offset(src, 2, 0) + 5], "line2");
        // col clamps to end of line, never crosses '\n'
        assert_eq!(line_col_to_offset(src, 1, 999), 5);
    }
}
