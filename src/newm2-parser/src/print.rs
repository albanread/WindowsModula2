//! AST pretty-printer used by `newm2 dump-ast`.
//!
//! Output is a stable indented textual tree designed for snapshot
//! testing. Layout invariants:
//! - Two-space indentation per nesting level.
//! - One node per line; child lines are deeper-indented.
//! - Spans omitted to keep diffs minimal across whitespace edits.

use crate::ast::*;
use std::fmt::Write;

pub fn format_module(m: &Module) -> String {
    let mut buf = String::new();
    write_module(&mut buf, m, 0);
    buf
}

fn indent(buf: &mut String, depth: usize) {
    for _ in 0..depth {
        buf.push_str("  ");
    }
}

fn line(buf: &mut String, depth: usize, s: &str) {
    indent(buf, depth);
    buf.push_str(s);
    buf.push('\n');
}

fn write_module(buf: &mut String, m: &Module, d: usize) {
    let kind = match m.kind {
        ModuleKind::Definition => "DefinitionModule",
        ModuleKind::Implementation => "ImplementationModule",
        ModuleKind::Program => "ProgramModule",
        ModuleKind::Local => "LocalModule",
    };
    line(buf, d, &format!("{kind} {}", m.name));
    for p in &m.pragmas {
        line(buf, d + 1, &format!("Pragma {:?}", p.body));
    }
    for imp in &m.imports {
        write_import(buf, imp, d + 1);
    }
    for decl in &m.decls {
        write_decl(buf, decl, d + 1);
    }
    if let Some(body) = &m.body {
        line(buf, d + 1, "Body");
        write_block(buf, body, d + 2);
    }
}

fn write_import(buf: &mut String, imp: &Import, d: usize) {
    match imp {
        Import::From { module, names, .. } => {
            if names.is_empty() {
                line(buf, d, &format!("FromImport {module} *"));
            } else {
                line(buf, d, &format!("FromImport {module} {}", names.join(", ")));
            }
        }
        Import::Plain { names, .. } => {
            let mut parts = Vec::new();
            for n in names {
                if let Some(a) = &n.alias {
                    parts.push(format!("{} := {a}", n.name));
                } else {
                    parts.push(n.name.clone());
                }
            }
            line(buf, d, &format!("Import {}", parts.join(", ")));
        }
    }
}

fn write_decl(buf: &mut String, decl: &Decl, d: usize) {
    match decl {
        Decl::Const(c) => {
            line(buf, d, &format!("Const {}{}", c.name, if c.exported { "*" } else { "" }));
            write_expr(buf, &c.value, d + 1);
        }
        Decl::Type(t) => {
            let mark = if t.exported { "*" } else { "" };
            line(buf, d, &format!("Type {}{}", t.name, mark));
            if let Some(ty) = &t.def {
                write_type(buf, ty, d + 1);
            } else {
                line(buf, d + 1, "Opaque");
            }
        }
        Decl::Var(v) => {
            let mark = if v.exported { "*" } else { "" };
            line(buf, d, &format!("Var {}{}", v.names.join(", "), mark));
            write_type(buf, &v.ty, d + 1);
            if let Some(addr) = &v.address {
                line(buf, d + 1, "At");
                write_expr(buf, addr, d + 2);
            }
        }
        Decl::Procedure(p) => {
            let mark = if p.exported { "*" } else { "" };
            let suffix = if p.is_forward { " FORWARD" } else { "" };
            line(buf, d, &format!("Procedure {}{}{}", p.name, mark, suffix));
            for param in &p.params {
                let mode = match param.mode {
                    ParamMode::Var => "VAR ",
                    ParamMode::Const => "CONST ",
                    ParamMode::Value => "",
                };
                line(
                    buf,
                    d + 1,
                    &format!("Param {}{}", mode, param.names.join(", ")),
                );
                write_type(buf, &param.ty, d + 2);
            }
            if let Some(rt) = &p.return_ty {
                line(buf, d + 1, "Returns");
                write_type(buf, rt, d + 2);
            }
            for a in &p.attrs {
                line(buf, d + 1, &format!("Attr {} ({:?})", a.name, a.args));
            }
            if let Some(body) = &p.body {
                line(buf, d + 1, "Body");
                for decl in &body.decls {
                    write_decl(buf, decl, d + 2);
                }
                write_block(buf, &body.body, d + 2);
            }
        }
        Decl::Pragma(p) => {
            line(buf, d, &format!("Pragma {:?}", p.body));
        }
        Decl::LocalModule(m) => {
            write_module(buf, m, d);
        }
        Decl::Export { qualified, names, .. } => {
            let q = if *qualified { "QUALIFIED " } else { "" };
            line(buf, d, &format!("Export {}{}", q, names.join(", ")));
        }
        Decl::Class(c) => {
            write_class(buf, c, d);
        }
    }
}

fn write_class(buf: &mut String, c: &ClassDecl, d: usize) {
    let abs = if c.is_abstract { "Abstract" } else { "" };
    let exp = if c.exported { "*" } else { "" };
    let fwd = if c.is_forward { " FORWARD" } else { "" };
    line(buf, d, &format!("{abs}Class {}{}{}", c.name, exp, fwd));
    if let Some(base) = &c.inherit {
        line(buf, d + 1, &format!("Inherit {}", base.segments.join(".")));
    }
    if !c.reveal.is_empty() {
        line(buf, d + 1, &format!("Reveal {}", c.reveal.join(", ")));
    }
    for m in &c.members {
        write_class_member(buf, m, d + 1);
    }
}

fn write_class_member(buf: &mut String, m: &ClassMember, d: usize) {
    match m {
        ClassMember::Field(v) => {
            line(buf, d, &format!("Field {}", v.names.join(", ")));
            write_type(buf, &v.ty, d + 1);
        }
        ClassMember::Method(m) => {
            let kind = if m.is_abstract {
                "AbstractMethod"
            } else if m.is_override {
                "OverrideMethod"
            } else {
                "Method"
            };
            line(buf, d, &format!("{kind} {}", m.name));
            for p in &m.params {
                let mode = if matches!(p.mode, ParamMode::Var) { "VAR " } else { "" };
                line(buf, d + 1, &format!("Param {}{}", mode, p.names.join(", ")));
                write_type(buf, &p.ty, d + 2);
            }
            if let Some(rt) = &m.return_ty {
                line(buf, d + 1, "Returns");
                write_type(buf, rt, d + 2);
            }
        }
        ClassMember::Pragma(p) => {
            line(buf, d, &format!("Pragma {:?}", p.body));
        }
    }
}

fn write_type(buf: &mut String, ty: &TypeExpr, d: usize) {
    match ty {
        TypeExpr::Named(qn) => {
            line(buf, d, &format!("Named {}", qn.segments.join(".")));
        }
        TypeExpr::Subrange(lo, hi, _) => {
            line(buf, d, "Subrange");
            write_expr(buf, lo, d + 1);
            write_expr(buf, hi, d + 1);
        }
        TypeExpr::Enum(names, _, _) => {
            line(buf, d, &format!("Enum {}", names.join(", ")));
        }
        TypeExpr::Array(indices, base, _) => {
            line(buf, d, &format!("Array (rank {})", indices.len()));
            for i in indices {
                write_type(buf, i, d + 1);
            }
            line(buf, d + 1, "Of");
            write_type(buf, base, d + 2);
        }
        TypeExpr::OpenArray(base, _) => {
            line(buf, d, "OpenArray");
            write_type(buf, base, d + 1);
        }
        TypeExpr::Record(r) => {
            line(buf, d, "Record");
            for f in &r.fields {
                let mark = if f.exported { "*" } else { "" };
                line(buf, d + 1, &format!("Field {}{}", f.names.join(", "), mark));
                write_type(buf, &f.ty, d + 2);
            }
            if let Some(v) = &r.variant {
                write_variant_part(buf, v, d + 1);
            }
        }
        TypeExpr::Pointer(base, _) => {
            line(buf, d, "PointerTo");
            write_type(buf, base, d + 1);
        }
        TypeExpr::Proc(pt) => {
            line(buf, d, "ProcType");
            for p in &pt.params {
                let mode = if matches!(p.mode, ParamMode::Var) { "VAR " } else { "" };
                line(buf, d + 1, &format!("Param {}", mode));
                write_type(buf, &p.ty, d + 2);
            }
            if let Some(rt) = &pt.return_ty {
                line(buf, d + 1, "Returns");
                write_type(buf, rt, d + 2);
            }
        }
        TypeExpr::Set { packed, element, .. } => {
            line(buf, d, if *packed { "PackedSetOf" } else { "SetOf" });
            write_type(buf, element, d + 1);
        }
    }
}

fn write_variant_part(buf: &mut String, v: &VariantPart, d: usize) {
    let tag_name = v.tag_name.as_deref().unwrap_or("_");
    let tag_type = v
        .tag_type
        .as_ref()
        .map(|t| t.segments.join("."))
        .unwrap_or_else(|| "?".to_string());
    line(buf, d, &format!("CaseVariant {} : {}", tag_name, tag_type));
    for arm in &v.arms {
        let mut labels = String::new();
        for (i, l) in arm.labels.iter().enumerate() {
            if i > 0 {
                labels.push_str(", ");
            }
            match l {
                CaseLabel::Single(e) => {
                    let _ = write!(labels, "{}", expr_inline(e));
                }
                CaseLabel::Range(a, b) => {
                    let _ = write!(labels, "{}..{}", expr_inline(a), expr_inline(b));
                }
            }
        }
        line(buf, d + 1, &format!("Arm {labels}"));
        for f in &arm.fields {
            line(buf, d + 2, &format!("Field {}", f.names.join(", ")));
            write_type(buf, &f.ty, d + 3);
        }
        if let Some(inner) = &arm.variant {
            write_variant_part(buf, inner, d + 2);
        }
    }
    if let Some(else_fields) = &v.else_arm {
        line(buf, d + 1, "Else");
        for f in else_fields {
            line(buf, d + 2, &format!("Field {}", f.names.join(", ")));
            write_type(buf, &f.ty, d + 3);
        }
    }
}

fn write_block(buf: &mut String, b: &Block, d: usize) {
    for s in &b.stmts {
        write_stmt(buf, s, d);
    }
    for arm in &b.except {
        let names = if arm.names.is_empty() {
            "(any)".into()
        } else {
            arm.names
                .iter()
                .map(|n| n.segments.join("."))
                .collect::<Vec<_>>()
                .join(", ")
        };
        line(buf, d, &format!("Except {names}"));
        for s in &arm.body {
            write_stmt(buf, s, d + 1);
        }
    }
    if let Some(f) = &b.finally {
        line(buf, d, "Finally");
        for s in f {
            write_stmt(buf, s, d + 1);
        }
    }
}

fn write_stmt(buf: &mut String, s: &Stmt, d: usize) {
    match s {
        Stmt::Empty(_) => line(buf, d, "Empty"),
        Stmt::Assign { target, value, .. } => {
            line(buf, d, &format!("Assign {}", designator_inline(target)));
            write_expr(buf, value, d + 1);
        }
        Stmt::Call(e, _) => {
            line(buf, d, "Call");
            write_expr(buf, e, d + 1);
        }
        Stmt::If { arms, else_arm, .. } => {
            line(buf, d, "If");
            for (cond, body) in arms {
                line(buf, d + 1, "Arm");
                write_expr(buf, cond, d + 2);
                for s in body {
                    write_stmt(buf, s, d + 2);
                }
            }
            if let Some(else_body) = else_arm {
                line(buf, d + 1, "Else");
                for s in else_body {
                    write_stmt(buf, s, d + 2);
                }
            }
        }
        Stmt::Guard { selector, arms, else_arm, .. } => {
            line(buf, d, "Guard");
            write_expr(buf, selector, d + 1);
            for a in arms {
                let lbl = match &a.denoter {
                    Some(n) => format!("Arm {} : {}", n, a.guarded_type.segments.join(".")),
                    None => format!("Arm {}", a.guarded_type.segments.join(".")),
                };
                line(buf, d + 1, &lbl);
                for s in &a.body {
                    write_stmt(buf, s, d + 2);
                }
            }
            if let Some(else_body) = else_arm {
                line(buf, d + 1, "Else");
                for s in else_body {
                    write_stmt(buf, s, d + 2);
                }
            }
        }
        Stmt::Case { scrutinee, arms, else_arm, .. } => {
            line(buf, d, "Case");
            write_expr(buf, scrutinee, d + 1);
            for a in arms {
                line(buf, d + 1, "Arm");
                for s in &a.body {
                    write_stmt(buf, s, d + 2);
                }
            }
            if let Some(else_body) = else_arm {
                line(buf, d + 1, "Else");
                for s in else_body {
                    write_stmt(buf, s, d + 2);
                }
            }
        }
        Stmt::While(c, body, _) => {
            line(buf, d, "While");
            write_expr(buf, c, d + 1);
            for s in body {
                write_stmt(buf, s, d + 1);
            }
        }
        Stmt::Repeat(body, c, _) => {
            line(buf, d, "Repeat");
            for s in body {
                write_stmt(buf, s, d + 1);
            }
            line(buf, d + 1, "Until");
            write_expr(buf, c, d + 2);
        }
        Stmt::For { var, start, end, step, body, .. } => {
            line(buf, d, &format!("For {var}"));
            write_expr(buf, start, d + 1);
            write_expr(buf, end, d + 1);
            if let Some(st) = step {
                line(buf, d + 1, "By");
                write_expr(buf, st, d + 2);
            }
            for s in body {
                write_stmt(buf, s, d + 1);
            }
        }
        Stmt::Loop(body, _) => {
            line(buf, d, "Loop");
            for s in body {
                write_stmt(buf, s, d + 1);
            }
        }
        Stmt::With(dz, body, _) => {
            line(buf, d, &format!("With {}", designator_inline(dz)));
            for s in body {
                write_stmt(buf, s, d + 1);
            }
        }
        Stmt::Exit(_) => line(buf, d, "Exit"),
        Stmt::Return(v, _) => {
            line(buf, d, "Return");
            if let Some(e) = v {
                write_expr(buf, e, d + 1);
            }
        }
        Stmt::Raise(v, _) => {
            line(buf, d, "Raise");
            if let Some(e) = v {
                write_expr(buf, e, d + 1);
            }
        }
        Stmt::Retry(_) => line(buf, d, "Retry"),
        Stmt::Block(b) => {
            line(buf, d, "Block");
            write_block(buf, b, d + 1);
        }
    }
}

fn write_expr(buf: &mut String, e: &Expr, d: usize) {
    line(buf, d, &expr_inline(e));
}

fn expr_inline(e: &Expr) -> String {
    match e {
        Expr::Integer(v, _) => format!("Integer({v})"),
        Expr::Real(v, _) => format!("Real({v})"),
        Expr::Char(c, _) => format!("Char({:?}{})", c.value, c.flavor.suffix()),
        Expr::String(s, _) => format!("String({:?}{})", s.value, s.flavor.suffix()),
        Expr::Nil(_) => "Nil".to_string(),
        Expr::Designator(dz) => designator_inline(dz),
        Expr::Call(callee, args, _) => {
            let mut s = String::from("Call ");
            s.push_str(&expr_inline(callee));
            s.push('(');
            for (i, a) in args.iter().enumerate() {
                if i > 0 {
                    s.push_str(", ");
                }
                s.push_str(&expr_inline(a));
            }
            s.push(')');
            s
        }
        Expr::Binary(op, l, r, _) => {
            format!("({} {:?} {})", expr_inline(l), op, expr_inline(r))
        }
        Expr::Unary(op, x, _) => format!("({:?} {})", op, expr_inline(x)),
        Expr::Set { type_name, elements, .. } => {
            let mut s = type_name
                .as_ref()
                .map(|qn| qn.segments.join("."))
                .unwrap_or_default();
            s.push('{');
            for (i, el) in elements.iter().enumerate() {
                if i > 0 {
                    s.push_str(", ");
                }
                match el {
                    SetElem::Single(e) => s.push_str(&expr_inline(e)),
                    SetElem::Range(a, b) => {
                        let _ = write!(s, "{}..{}", expr_inline(a), expr_inline(b));
                    }
                }
            }
            s.push('}');
            s
        }
    }
}

fn designator_inline(dz: &Designator) -> String {
    let mut s = dz.base.segments.join(".");
    for sel in &dz.selectors {
        match sel {
            Selector::Field(f, _) => {
                let _ = write!(s, ".{f}");
            }
            Selector::Index(es, _) => {
                s.push('[');
                for (i, e) in es.iter().enumerate() {
                    if i > 0 {
                        s.push_str(", ");
                    }
                    s.push_str(&expr_inline(e));
                }
                s.push(']');
            }
            Selector::Deref(_) => s.push('^'),
            Selector::TypeGuard(qn, _) => {
                let _ = write!(s, "({})", qn.segments.join("."));
            }
        }
    }
    s
}
