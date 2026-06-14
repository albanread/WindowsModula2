//! Textual dump of semantic analysis results for `newm2 dump-sema`.
//!
//! Output format:
//!
//! ```text
//! MODULE Foo  [scope S3]
//!   CONST max : INTEGER = 100
//!   TYPE Color = ENUM(red=0, green=1, blue=2)
//!   TYPE Point = RECORD { x: INTEGER; y: INTEGER }
//!   VAR origin : Point
//!   PROC Bar(n: INTEGER; VAR r: REAL) : BOOLEAN  [Windows]
//!   CLASS IUnknown  [ABSTRACT]
//!     vtable[0] QueryInterface()
//!     vtable[1] AddRef() : CARDINAL
//!     vtable[2] Release() : CARDINAL
//! ```

use crate::{
    analyze::{SemaResult, Severity},
    class::ClassSymbolId,
    scope::{CallingConv, NamedParam, ProcSig, ScopeId, SymbolKind},
    types::{TypeId, TypeKind},
};
use newm2_loader::{ModuleGraph, ModuleId};

/// Format the full sema result for `newm2 dump-sema`.
pub fn format_sema(result: &SemaResult, graph: &ModuleGraph) -> String {
    let mut out = String::new();

    // Walk modules in topological order.
    for &mid in &graph.topo_order {
        let node = graph.get(mid);
        if node.is_intrinsic {
            continue;
        }
        let Some(&scope_id) = result.module_scopes.get(&mid) else {
            continue;
        };

        out.push_str(&format!("MODULE {}  [scope S{}]\n", node.name, scope_id.0));
        format_scope(result, scope_id, 2, &mut out);
        out.push('\n');
    }

    // Print diagnostics at the end.
    if !result.diagnostics.is_empty() {
        out.push_str("--- Diagnostics ---\n");
        for d in &result.diagnostics {
            let sev = match d.severity {
                Severity::Error => "error",
                Severity::Warning => "warning",
            };
            let node = graph.get(d.module_id);
            out.push_str(&format!(
                "  [{sev}] {}:{}: {}\n",
                node.name, d.span.start.line, d.message
            ));
        }
    }

    out
}

/// Render a single module's *exported interface* in a canonical, context-
/// independent form: exported symbols only, rendered structurally (no arena
/// ids), sorted by name. Two compiles of the same DEF — regardless of what
/// else is in the module graph, and regardless of the arena indices the
/// symbols happen to land on — produce byte-identical output. This string is
/// the identity of a module's interface: it is what a separate-compilation
/// symbol cache keys on and what a cache hit must reproduce.
pub fn format_module_interface(result: &SemaResult, graph: &ModuleGraph, mid: ModuleId) -> String {
    let _ = graph;
    let mut lines: Vec<String> = Vec::new();
    if let Some(&scope_id) = result.module_scopes.get(&mid) {
        for sym in result.scopes.get(scope_id).iter() {
            if !sym.exported {
                continue;
            }
            let line = match &sym.kind {
                SymbolKind::Const { ty, value } => format!(
                    "CONST {} : {} = {}",
                    sym.name,
                    format_type(result, *ty),
                    format_const_value(value)
                ),
                SymbolKind::Type(ty_id) => {
                    format!("TYPE {} = {}", sym.name, format_type_full(result, *ty_id))
                }
                SymbolKind::Var { ty, .. } => {
                    format!("VAR {} : {}", sym.name, format_type(result, *ty))
                }
                SymbolKind::Proc(sig) => {
                    format!("PROC {} {}", sym.name, format_proc_sig(result, sig))
                }
                SymbolKind::EnumMember { ord, .. } => format!("MEMBER {} = {}", sym.name, ord),
                SymbolKind::Class(cid) => format!("CLASS {}", result.classes.get(*cid).name),
                // IMPORT bindings are not part of a module's own interface.
                SymbolKind::Module(_, _) => continue,
            };
            lines.push(line);
        }
    }
    lines.sort();
    let mut out = String::new();
    for l in lines {
        out.push_str(&l);
        out.push('\n');
    }
    out
}

fn format_scope(result: &SemaResult, scope_id: ScopeId, indent: usize, out: &mut String) {
    let pad = " ".repeat(indent);
    let scope = result.scopes.get(scope_id);
    for sym in scope.iter() {
        match &sym.kind {
            SymbolKind::Const { ty, value } => {
                let ty_name = format_type(result, *ty);
                out.push_str(&format!(
                    "{pad}CONST {} : {} = {}\n",
                    sym.name,
                    ty_name,
                    format_const_value(value)
                ));
            }
            SymbolKind::Type(ty_id) => {
                let ty_desc = format_type_full(result, *ty_id);
                out.push_str(&format!("{pad}TYPE {} = {ty_desc}\n", sym.name));
            }
            SymbolKind::Var { ty, param_mode } => {
                let ty_name = format_type(result, *ty);
                let exported = if sym.exported { " [exported]" } else { "" };
                let prefix = match param_mode {
                    Some(crate::types::ParamMode::Var) => "PARAM VAR",
                    Some(crate::types::ParamMode::Const) => "PARAM CONST",
                    Some(crate::types::ParamMode::Value) => "PARAM",
                    None => "VAR",
                };
                out.push_str(&format!("{pad}{prefix} {} : {ty_name}{exported}\n", sym.name));
            }
            SymbolKind::Proc(sig) => {
                let sig_str = format_proc_sig(result, sig);
                let exported = if sym.exported { " [exported]" } else { "" };
                out.push_str(&format!("{pad}PROC {} {sig_str}{exported}\n", sym.name));
            }
            SymbolKind::Module(_, _) => {
                out.push_str(&format!("{pad}IMPORT {}\n", sym.name));
            }
            SymbolKind::Class(cid) => {
                format_class(result, *cid, indent, out);
            }
            SymbolKind::EnumMember { ty: _, ord } => {
                out.push_str(&format!("{pad}MEMBER {} = {ord}\n", sym.name));
            }
        }
    }
}

fn format_class(result: &SemaResult, cid: ClassSymbolId, indent: usize, out: &mut String) {
    let pad = " ".repeat(indent);
    let cls = result.classes.get(cid);
    let abs = if cls.is_abstract { " [ABSTRACT]" } else { "" };
    let base_str = if let Some(base_id) = cls.base {
        format!(" INHERIT {}", result.classes.get(base_id).name)
    } else {
        String::new()
    };
    out.push_str(&format!("{pad}CLASS {}{abs}{base_str}\n", cls.name));

    let inner = " ".repeat(indent + 2);
    // Fields.
    for f in &cls.own_fields {
        let ty = format_type(result, f.ty);
        out.push_str(&format!("{inner}FIELD {} : {ty}\n", f.name));
    }
    // Vtable slots.
    for (i, slot) in cls.vtable.iter().enumerate() {
        let sig = format_proc_sig(result, &slot.sig);
        let abs = if slot.is_abstract { " [abstract]" } else { "" };
        let owner = result.classes.get(slot.defining_class).name.as_str();
        out.push_str(&format!(
            "{inner}vtable[{i}] {}{sig}{abs}  [{}]\n",
            slot.name, owner
        ));
    }
    if !cls.revealed.is_empty() {
        out.push_str(&format!("{inner}REVEAL {}\n", cls.revealed.join(", ")));
    }
}

fn format_proc_sig(result: &SemaResult, sig: &ProcSig) -> String {
    let params = sig
        .params
        .iter()
        .map(|p| format_named_param(result, p))
        .collect::<Vec<_>>()
        .join("; ");
    let ret = if let Some(rt) = sig.return_ty {
        format!(" : {}", format_type(result, rt))
    } else {
        String::new()
    };
    let cc = match sig.calling_conv {
        CallingConv::Default => "",
        CallingConv::Windows => " [Windows]",
        CallingConv::Cdecl => " [CDECL]",
        CallingConv::Asm => " [Asm]",
    };
    format!("({params}){ret}{cc}")
}

fn format_named_param(result: &SemaResult, p: &NamedParam) -> String {
    let mode = match p.mode {
        crate::types::ParamMode::Var => "VAR ",
        crate::types::ParamMode::Const => "CONST ",
        crate::types::ParamMode::Value => "",
    };
    let ty = format_type(result, p.ty);
    if let Some(name) = &p.name {
        format!("{mode}{name}: {ty}")
    } else {
        format!("{mode}{ty}")
    }
}

/// Short type name (for display in symbol listings).
fn format_type(result: &SemaResult, ty: TypeId) -> String {
    match result.types.get(ty) {
        TypeKind::Builtin(b) => b.name().to_string(),
        TypeKind::Unresolved => "<unresolved>".into(),
        TypeKind::Pointer { base } => format!("POINTER TO {}", format_type(result, *base)),
        TypeKind::Array { base, .. } => format!("ARRAY OF {}", format_type(result, *base)),
        TypeKind::OpenArray { base } => format!("ARRAY OF {}", format_type(result, *base)),
        TypeKind::Set { packed, base } => {
            let kw = if *packed { "PACKEDSET" } else { "SET" };
            format!("{kw} OF {}", format_type(result, *base))
        }
        TypeKind::Vector { lanes, base } => {
            format!("VECTOR {lanes} OF {}", format_type(result, *base))
        }
        TypeKind::Enum { names, .. } => format!("ENUM({})", names.join(", ")),
        TypeKind::Record(_) => "RECORD".into(),
        TypeKind::Proc { .. } => "PROCEDURE".into(),
        TypeKind::Subrange { lo, hi, .. } => format!("[{lo}..{hi}]"),
        TypeKind::Class { symbol } => {
            result.classes.get(crate::class::ClassSymbolId(*symbol)).name.clone()
        }
    }
}

/// Detailed type description for TYPE declarations.
fn format_type_full(result: &SemaResult, ty: TypeId) -> String {
    match result.types.get(ty) {
        TypeKind::Unresolved => "<opaque>".into(),
        TypeKind::Enum { names, .. } => {
            let members = names
                .iter()
                .enumerate()
                .map(|(i, n)| format!("{n}={i}"))
                .collect::<Vec<_>>()
                .join(", ");
            format!("ENUM({members})")
        }
        TypeKind::Record(layout) => {
            let fields = layout
                .fields
                .iter()
                .map(|f| format!("{}: {}", f.name, format_type(result, f.ty)))
                .collect::<Vec<_>>()
                .join("; ");
            let variant_str = if layout.variant.is_some() { " + CASE" } else { "" };
            format!("RECORD {{ {fields}{variant_str} }}")
        }
        TypeKind::Subrange { lo, hi, .. } => format!("[{lo}..{hi}]"),
        TypeKind::Array { indices, base } => {
            let idx_str = indices
                .iter()
                .map(|i| format_type(result, *i))
                .collect::<Vec<_>>()
                .join(", ");
            format!("ARRAY {} OF {}", idx_str, format_type(result, *base))
        }
        other => format_type_inner(result, ty, other),
    }
}

fn format_type_inner(result: &SemaResult, ty: TypeId, kind: &TypeKind) -> String {
    let _ = ty;
    match kind {
        TypeKind::Builtin(b) => b.name().to_string(),
        TypeKind::Pointer { base } => format!("POINTER TO {}", format_type(result, *base)),
        TypeKind::OpenArray { base } => format!("ARRAY OF {}", format_type(result, *base)),
        TypeKind::Set { packed, base } => {
            let kw = if *packed { "PACKEDSET" } else { "SET" };
            format!("{kw} OF {}", format_type(result, *base))
        }
        TypeKind::Vector { lanes, base } => {
            format!("VECTOR {lanes} OF {}", format_type(result, *base))
        }
        TypeKind::Proc { params, return_ty } => {
            let ps = params
                .iter()
                .map(|p| {
                    let m = match p.mode {
                        crate::types::ParamMode::Var => "VAR ",
                        crate::types::ParamMode::Const => "CONST ",
                        crate::types::ParamMode::Value => "",
                    };
                    format!("{m}{}", format_type(result, p.ty))
                })
                .collect::<Vec<_>>()
                .join("; ");
            let ret = return_ty.map(|r| format!(" : {}", format_type(result, r))).unwrap_or_default();
            format!("PROCEDURE ({ps}){ret}")
        }
        TypeKind::Class { symbol } => {
            result.classes.get(ClassSymbolId(*symbol)).name.clone()
        }
        _ => format_type(result, ty),
    }
}

fn format_const_value(val: &crate::constant::ConstValue) -> String {
    match val {
        crate::constant::ConstValue::Int(n) => n.to_string(),
        crate::constant::ConstValue::Real(f) => format!("{f}"),
        crate::constant::ConstValue::Bool(b) => if *b { "TRUE".into() } else { "FALSE".into() },
        crate::constant::ConstValue::Char(c) => format!("{c:?}"),
        crate::constant::ConstValue::Str(s) => format!("{s:?}"),
        crate::constant::ConstValue::Set(members) => {
            let s = members.iter().map(|n| n.to_string()).collect::<Vec<_>>().join(", ");
            format!("{{{s}}}")
        }
        crate::constant::ConstValue::Nil => "NIL".into(),
        crate::constant::ConstValue::FuncRef(name) => name.clone(),
        crate::constant::ConstValue::Complex(re, im) => format!("CMPLX({re}, {im})"),
        crate::constant::ConstValue::Aggregate(items) => {
            let s = items.iter().map(format_const_value).collect::<Vec<_>>().join(", ");
            format!("{{{s}}}")
        }
    }
}

#[cfg(test)]
mod interface_determinism {
    use super::format_module_interface;
    use crate::analyze::check_module_graph;
    use newm2_loader::{build_module_graph, SearchPath};
    use std::fs;
    use std::path::{Path, PathBuf};

    fn tmpdir(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("newm2-iface-{name}"));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    fn iface_of(dir: &Path, entry: &str, module: &str) -> String {
        let mut sp = SearchPath::new();
        sp.push(dir);
        let graph = build_module_graph(&dir.join(entry), &sp).expect("graph builds");
        let sema = check_module_graph(&graph);
        let mid = graph.lookup(module).expect("module present in graph");
        format_module_interface(&sema, &graph, mid)
    }

    // A module's interface render is the cache's identity: it must depend ONLY
    // on the module's own source, never on what else is being compiled. Here
    // `Lib` is byte-identical in both contexts, but context 2 first pulls in
    // `Extra`, whose declarations are interned into the shared type arena
    // BEFORE Lib — shifting every arena index Lib's types occupy. A structural
    // (id-free) interface must be unaffected; an id-based one would not be.
    #[test]
    fn module_interface_is_context_independent() {
        let lib = "DEFINITION MODULE Lib;\n\
                   CONST Max = 100;\n\
                   TYPE Pair = RECORD a, b: INTEGER; END;\n\
                   PROCEDURE Twice (n: INTEGER): INTEGER;\n\
                   END Lib.\n";

        let d1 = tmpdir("ctx1");
        fs::write(d1.join("Lib.def"), lib).unwrap();
        fs::write(d1.join("P.mod"), "MODULE P;\nFROM Lib IMPORT Max;\nBEGIN\nEND P.\n").unwrap();
        let i1 = iface_of(&d1, "P.mod", "Lib");

        let d2 = tmpdir("ctx2");
        fs::write(d2.join("Lib.def"), lib).unwrap();
        fs::write(
            d2.join("Extra.def"),
            "DEFINITION MODULE Extra;\n\
             TYPE A = RECORD p, q, r: INTEGER; END;\n\
             TYPE B = ARRAY [0..9] OF CHAR;\n\
             TYPE C = POINTER TO A;\n\
             CONST K = 7;\n\
             END Extra.\n",
        )
        .unwrap();
        fs::write(
            d2.join("P.mod"),
            "MODULE P;\nFROM Extra IMPORT K;\nFROM Lib IMPORT Max;\nBEGIN\nEND P.\n",
        )
        .unwrap();
        let i2 = iface_of(&d2, "P.mod", "Lib");

        assert!(!i1.is_empty(), "interface should be non-empty");
        assert_eq!(
            i1, i2,
            "Lib's interface must be identical across compile contexts\n--- ctx1 ---\n{i1}\n--- ctx2 ---\n{i2}"
        );
        // The exported surface is present, rendered structurally.
        assert!(i1.contains("CONST Max"), "missing const:\n{i1}");
        assert!(i1.contains("TYPE Pair = RECORD"), "missing type:\n{i1}");
        assert!(i1.contains("PROC Twice"), "missing proc:\n{i1}");
    }
}
