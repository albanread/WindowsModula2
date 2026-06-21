//! Context help: resolve the symbol under a cursor and emit **markdown**
//! describing it with facts a user cannot see from the single file they sit in.
//!
//! Where `completion` enumerates the members of a receiver, `describe` answers
//! "what is *this* name?" — drawn entirely from sema's fully-resolved module
//! graph: the real signature, the declaring module + import provenance, the
//! *shape* of a type declared in another module, that module's other exports,
//! a go-to-definition link, and (for COM) the interface IID + vtable slot.
//!
//! Like `completion`, the engine is read-only over a `SemaResult`: it never
//! re-runs analysis. The symbol at the cursor is found from the span-keyed
//! annotations sema already records (`resolved_names`, `designator_types`,
//! `selector_bindings`) — the tightest annotated span covering the offset.
//!
//! The markdown is the deliberate subset the IDE `MarkView` renderer supports:
//! `#`/`##`/`###` headings, fenced ```` ``` ```` code blocks, `- ` bullets, and
//! `[text](target)` links. A go-to-definition `target` is `sym:<file>#<line>`.

use newm2_loader::{ModuleGraph, ModuleId};

use crate::analyze::{SelectorBinding, SemaResult, SpanKey};
use crate::class::ClassSymbolId;
use crate::completion::{sig_detail, type_name};
use crate::scope::{SymbolKind, SymbolProvenance};
use crate::types::{TypeId, TypeKind};

/// Resolve the symbol at `cursor` (a byte offset) in `module`'s `source` and
/// render markdown describing it. Returns `None` if nothing sema annotated
/// covers the cursor.
pub fn describe_at(
    graph: &ModuleGraph,
    sema: &SemaResult,
    module: ModuleId,
    source: &str,
    cursor: usize,
) -> Option<String> {
    let hit = resolve_at(sema, module, source, cursor)?;
    Some(render(graph, sema, module, &hit))
}

/// What the cursor landed on: a resolved name (designator/identifier), and/or a
/// selector binding (a `.field` / `.method`), and/or a typed designator.
struct Hit {
    /// The literal source text of the matched span (the name as written) — used
    /// as the heading for a selector / bare-designator that has no resolved name.
    text: String,
    /// The resolved name, if the matched span carries one.
    resolved: Option<ResolvedHit>,
    /// A selector binding (field / method), if the matched span carries one.
    selector: Option<SelectorBinding>,
    /// The designator type, if the matched span carries one.
    designator_ty: Option<TypeId>,
}

/// A cloned-out copy of the fields we need from a `ResolvedName` (the borrow on
/// `sema.resolved_names` would otherwise pin `sema` for the whole render).
struct ResolvedHit {
    name: String,
    kind: SymbolKind,
    provenance: SymbolProvenance,
    declaration_span: newm2_lexer::Span,
}

/// Find the tightest annotated span (over `resolved_names`, `selector_bindings`,
/// `designator_types`) whose `[start, end)` covers `cursor`. "Tightest" = the
/// smallest `end - start`, so an inner selector wins over the outer designator
/// it is part of. The cursor convention matches `completion`: inclusive of
/// `end` so a cursor resting just past the last char of a word still resolves.
fn resolve_at(sema: &SemaResult, module: ModuleId, source: &str, cursor: usize) -> Option<Hit> {
    let covers = |k: &SpanKey| k.module == module && cursor >= k.start && cursor <= k.end;
    let width = |k: &SpanKey| k.end.saturating_sub(k.start);

    let mut best: Option<SpanKey> = None;
    let mut consider = |k: &SpanKey| {
        if !covers(k) {
            return;
        }
        // A zero-width span (start == end) carries no name text; skip it so an
        // adjacent real span is preferred.
        if k.end == k.start {
            return;
        }
        best = match best {
            Some(b) if width(&b) <= width(k) => Some(b),
            _ => Some(*k),
        };
    };
    for k in sema.resolved_names.keys() {
        consider(k);
    }
    for k in sema.selector_bindings.keys() {
        consider(k);
    }
    for k in sema.designator_types.keys() {
        consider(k);
    }
    let key = best?;

    let resolved = sema.resolved_names.get(&key).map(|r| ResolvedHit {
        name: r.name.clone(),
        kind: r.kind.clone(),
        provenance: r.provenance.clone(),
        declaration_span: r.declaration_span,
    });
    let text = source.get(key.start..key.end).unwrap_or("").to_string();
    Some(Hit {
        text,
        resolved,
        selector: sema.selector_bindings.get(&key).copied(),
        designator_ty: sema.designator_types.get(&key).copied(),
    })
}

fn render(graph: &ModuleGraph, sema: &SemaResult, module: ModuleId, hit: &Hit) -> String {
    let mut md = String::new();

    // ---- A selector (`obj.field` / `obj.M`) at the cursor. -----------------
    // A selector binding is the most specific thing the cursor can land on, so
    // handle it first (it may coexist with a resolved name for the receiver).
    let title = if hit.text.is_empty() { "(expression)" } else { hit.text.as_str() };
    if hit.resolved.is_none() {
        if let Some(sel) = hit.selector {
            render_selector(&mut md, sema, sel, title);
            return md;
        }
        if let Some(ty) = hit.designator_ty {
            // A bare typed designator with no resolved name: show its type shape.
            md.push_str(&format!("## {}\n\n", title));
            md.push_str("```\n");
            md.push_str(&type_name(sema, ty, 0));
            md.push_str("\n```\n");
            append_type_shape(&mut md, sema, ty);
            return md;
        }
        return md;
    }

    let r = hit.resolved.as_ref().unwrap();

    // ---- Heading + signature ----------------------------------------------
    md.push_str(&format!("## {}\n\n", r.name));
    md.push_str("```\n");
    md.push_str(&signature_block(sema, &r.kind, &r.name));
    md.push_str("\n```\n");

    // ---- Module / provenance ----------------------------------------------
    append_provenance(&mut md, &r.provenance);

    // ---- Across-the-graph: the shape of a type declared elsewhere ----------
    // `append_type_shape` / `append_class_shape` emit the COM IID + the method
    // slots (the can't-see-from-here facts) for a class/interface themselves.
    if let Some(ty) = symbol_type(&r.kind) {
        append_type_shape(&mut md, sema, ty);
    }
    if let SymbolKind::Type(ty) = &r.kind {
        append_type_shape(&mut md, sema, *ty);
    }
    if let SymbolKind::Class(cid) = &r.kind {
        append_class_shape(&mut md, sema, *cid);
    }

    // ---- Sibling exports: "STextIO also exports: …" -----------------------
    append_sibling_exports(&mut md, sema, &r.provenance, &r.name);

    // ---- Go to definition --------------------------------------------------
    append_goto(&mut md, graph, sema, module, r);

    md
}

/// The display signature for a resolved symbol kind.
fn signature_block(sema: &SemaResult, kind: &SymbolKind, name: &str) -> String {
    match kind {
        SymbolKind::Proc(sig) => format!("PROCEDURE {}", sig_detail(sema, sig)),
        SymbolKind::Var { ty, .. } => format!("VAR {} : {}", name, type_name(sema, *ty, 0)),
        SymbolKind::Const { ty, .. } => format!("CONST {} : {}", name, type_name(sema, *ty, 0)),
        SymbolKind::Type(ty) => format!("TYPE {} = {}", name, type_name(sema, *ty, 0)),
        SymbolKind::Class(cid) => {
            let c = sema.classes.get(*cid);
            let word = if c.is_interface { "INTERFACE" } else { "CLASS" };
            format!("{} {}", word, c.name)
        }
        SymbolKind::EnumMember { ty, ord } => {
            format!("{} = {}  (* {} *)", name, type_name(sema, *ty, 0), ord)
        }
        SymbolKind::Module(..) => "module".to_string(),
    }
}

/// The value type carried by a var/const symbol (for type-shape expansion).
fn symbol_type(kind: &SymbolKind) -> Option<TypeId> {
    match kind {
        SymbolKind::Var { ty, .. } | SymbolKind::Const { ty, .. } => Some(*ty),
        _ => None,
    }
}

/// `**Module** X` / the import-provenance chain.
fn append_provenance(md: &mut String, prov: &SymbolProvenance) {
    match prov {
        SymbolProvenance::Pervasive => {
            md.push_str("\n**Module** _pervasive_ (built-in)\n");
        }
        SymbolProvenance::Declared { module_name, .. }
        | SymbolProvenance::Intrinsic { module_name, .. } => {
            md.push_str(&format!("\n**Module** {}\n", module_name));
        }
        SymbolProvenance::Imported {
            from_module_name,
            original_module_name,
            original_name,
            ..
        } => {
            md.push_str(&format!("\n**Module** imported here from {}\n", from_module_name));
            if let Some(orig) = original_module_name {
                if orig != from_module_name {
                    md.push_str(&format!(
                        "- originally declared in {} (as `{}`)\n",
                        orig, original_name
                    ));
                }
            }
            let chain = prov.import_chain();
            if chain.len() > 1 {
                let hops: Vec<String> =
                    chain.iter().map(|h| h.from_module_name.clone()).collect();
                md.push_str(&format!("- via {}\n", hops.join(" -> ")));
            }
        }
    }
}

/// Expand a type that is a record / class / interface into its fields/methods,
/// so the shape is visible without opening the defining `.def`.
fn append_type_shape(md: &mut String, sema: &SemaResult, ty: TypeId) {
    let ty = strip_pointers(sema, ty);
    match sema.types.get(ty) {
        TypeKind::Record(layout) => {
            let fields = layout.flatten_fields();
            if fields.is_empty() {
                return;
            }
            md.push_str("\n### Fields\n");
            for (name, fty) in fields {
                md.push_str(&format!("- `{} : {}`\n", name, type_name(sema, fty, 0)));
            }
        }
        TypeKind::Class { symbol } => {
            append_class_shape(md, sema, ClassSymbolId(*symbol));
        }
        _ => {}
    }
}

/// Fields + methods of a class/interface, with COM facts when applicable.
fn append_class_shape(md: &mut String, sema: &SemaResult, cid: ClassSymbolId) {
    let c = sema.classes.get(cid);
    append_class_com(md, sema, cid);

    if !c.all_fields.is_empty() {
        md.push_str("\n### Fields\n");
        for f in &c.all_fields {
            md.push_str(&format!("- `{} : {}`\n", f.name, type_name(sema, f.ty, 0)));
        }
    }
    if !c.vtable.is_empty() {
        md.push_str("\n### Methods\n");
        for (slot, m) in c.vtable.iter().enumerate() {
            md.push_str(&format!(
                "- `{}{}`  ·  slot @{}\n",
                m.name,
                sig_detail(sema, &m.sig),
                slot
            ));
        }
    }
}

/// The COM `**Interface** … · IID … ` line for a class/interface, when it has
/// an IID (i.e. it is a COM interface declared with an `[guid]` annotation).
fn append_class_com(md: &mut String, sema: &SemaResult, cid: ClassSymbolId) {
    let c = sema.classes.get(cid);
    if let Some(iid) = &c.iid {
        let word = if c.is_interface { "Interface" } else { "Class" };
        md.push_str(&format!("\n**{}** {} · IID {{{}}}\n", word, c.name, iid));
    }
}

/// Render a selector binding: `obj.field` shows the field type; `obj.M` shows
/// the method signature + the COM IID/slot of its declaring interface. `title`
/// is the source text under the cursor (the field/method name as written).
fn render_selector(md: &mut String, sema: &SemaResult, sel: SelectorBinding, title: &str) {
    match sel {
        SelectorBinding::Field { ty, .. } => {
            md.push_str(&format!("## {}\n\n", title));
            md.push_str("```\n");
            md.push_str(&type_name(sema, ty, 0));
            md.push_str("\n```\n");
            append_type_shape(md, sema, ty);
        }
        SelectorBinding::Method { vtable_index, class, .. } => {
            let c = sema.classes.get(class);
            let m = c.vtable.get(vtable_index as usize);
            let name = m.map(|m| m.name.as_str()).unwrap_or(title);
            md.push_str(&format!("## {}\n\n", name));
            md.push_str("```\n");
            if let Some(m) = m {
                md.push_str(&format!("PROCEDURE {}{}", name, sig_detail(sema, &m.sig)));
            } else {
                md.push_str(name);
            }
            md.push_str("\n```\n");
            // The declaring interface + IID + the resolved slot — the COM facts
            // a single-file view cannot show.
            let word = if c.is_interface { "Interface" } else { "Class" };
            if let Some(iid) = &c.iid {
                md.push_str(&format!(
                    "\n**{}** {} · IID {{{}}} · slot @{}\n",
                    word, c.name, iid, vtable_index
                ));
            } else {
                md.push_str(&format!("\n**{}** {} · slot @{}\n", word, c.name, vtable_index));
            }
        }
    }
}

/// "STextIO also exports: WriteChar, WriteLn, SkipLine, …" — iterate the
/// declaring module's exported scope (discovery you cannot get from one file).
fn append_sibling_exports(
    md: &mut String,
    sema: &SemaResult,
    prov: &SymbolProvenance,
    self_name: &str,
) {
    let Some((mid, mod_name)) = prov.declaring_module() else {
        return;
    };
    let Some(&sid) = sema.module_scopes.get(&mid) else {
        return;
    };
    let mut names: Vec<String> = sema
        .scopes
        .get(sid)
        .iter()
        .filter(|s| s.exported && s.name != self_name)
        .map(|s| s.name.clone())
        .collect();
    if names.is_empty() {
        return;
    }
    names.sort_by(|a, b| a.to_ascii_lowercase().cmp(&b.to_ascii_lowercase()));
    names.dedup();
    let shown = 24usize;
    let more = names.len().saturating_sub(shown);
    names.truncate(shown);
    let mut line = format!("\n**{} also exports:** {}", mod_name, names.join(", "));
    if more > 0 {
        line.push_str(&format!(", … (+{} more)", more));
    }
    line.push('\n');
    md.push_str(&line);
}

/// A `[go to definition](sym:<file>#<line>)` link, from the declaration span and
/// the declaring module's source path. Falls back to nothing if no path is known
/// (intrinsics / pervasive have no on-disk source).
fn append_goto(
    md: &mut String,
    graph: &ModuleGraph,
    _sema: &SemaResult,
    module: ModuleId,
    r: &ResolvedHit,
) {
    // The defining file: prefer the declaring module's DEF (where exported names
    // are declared); fall back to its IMPL, then to the current module's path.
    let def_mid = r.provenance.declaring_module().map(|(m, _)| m).unwrap_or(module);
    let node = graph.get(def_mid);
    let path = node
        .def_path
        .as_ref()
        .or(node.impl_path.as_ref())
        .or_else(|| {
            let cur = graph.get(module);
            cur.def_path.as_ref().or(cur.impl_path.as_ref())
        });
    let Some(path) = path else {
        return;
    };
    let line = r.declaration_span.start.line.max(1);
    // Use a forward-slashed, lossy path so the link target is a stable string the
    // IDE can parse: `sym:<file>#<line>`.
    let file = path.to_string_lossy().replace('\\', "/");
    md.push_str(&format!("\n[go to definition](sym:{}#{})\n", file, line));
}

/// Follow `POINTER TO` levels to the underlying aggregate (mirrors completion).
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

#[cfg(test)]
mod tests {
    use super::*;
    use newm2_loader::SearchPath;

    /// Build a graph + sema from inline source written to a temp dir, then
    /// describe at a (line, col) cursor. Returns the markdown (or None).
    fn describe_src(modules: &[(&str, &str)], entry: &str, line: usize, col: usize) -> Option<String> {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir()
            .join(format!("nm2_describe_test_{}_{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        let mut entry_path = dir.join(entry);
        for (name, src) in modules {
            let p = dir.join(name);
            std::fs::write(&p, src).unwrap();
            if *name == entry {
                entry_path = p;
            }
        }
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let env = newm2_lexer::Env::target_default();
        let graph = newm2_loader::build_module_graph_with_env(&entry_path, &sp, &env)
            .expect("graph builds");
        let sema = crate::check_module_graph(&graph);
        // entry module = last topo
        let mid = *graph.topo_order.last().unwrap();
        let source = std::fs::read_to_string(&entry_path).unwrap();
        let cursor = crate::line_col_to_offset(&source, line, col);
        let out = describe_at(&graph, &sema, mid, &source, cursor);
        let _ = std::fs::remove_dir_all(&dir);
        out
    }

    #[test]
    fn describes_imported_proc_with_module_and_siblings() {
        let def = "DEFINITION MODULE Lib;\n\
                   PROCEDURE WriteIt(s: ARRAY OF CHAR);\n\
                   PROCEDURE WriteLn;\n\
                   PROCEDURE SkipIt;\n\
                   END Lib.\n";
        let prog = "MODULE P;\n\
                    FROM Lib IMPORT WriteIt, WriteLn;\n\
                    BEGIN\n\
                    WriteIt(\"hi\")\n\
                    END P.\n";
        // line 4, col 2 lands inside "WriteIt" at the call site.
        let md = describe_src(&[("Lib.def", def), ("P.mod", prog)], "P.mod", 4, 2)
            .expect("resolves the call");
        assert!(md.contains("## WriteIt"), "heading: {md}");
        assert!(md.contains("PROCEDURE"), "signature: {md}");
        assert!(md.contains("imported here from Lib"), "provenance: {md}");
        assert!(md.contains("also exports"), "siblings: {md}");
        assert!(md.contains("SkipIt"), "lists a sibling export: {md}");
        assert!(md.contains("[go to definition](sym:"), "goto: {md}");
    }

    #[test]
    fn describes_record_field_shape_from_another_module() {
        let def = "DEFINITION MODULE Geo;\n\
                   TYPE Point = RECORD x, y: INTEGER END;\n\
                   END Geo.\n";
        let prog = "MODULE P;\n\
                    FROM Geo IMPORT Point;\n\
                    VAR p: Point;\n\
                    BEGIN\n\
                    p.x := 1\n\
                    END P.\n";
        // line 3, col 8 lands inside "Point" in "VAR p: Point".
        let md = describe_src(&[("Geo.def", def), ("P.mod", prog)], "P.mod", 3, 8)
            .expect("resolves the type");
        assert!(md.contains("## Point"), "heading: {md}");
        assert!(md.contains("### Fields"), "field shape: {md}");
        assert!(md.contains("`x : INTEGER`") || md.contains("x : INTEGER"), "field x: {md}");
    }

    #[test]
    fn none_when_cursor_on_whitespace() {
        let prog = "MODULE P;\n\
                    VAR i: INTEGER;\n\
                    BEGIN\n\
                          \n\
                    i := 1\n\
                    END P.\n";
        // line 4 is all blanks.
        let md = describe_src(&[("P.mod", prog)], "P.mod", 4, 2);
        assert!(md.is_none(), "expected None on blank line, got {md:?}");
    }
}
