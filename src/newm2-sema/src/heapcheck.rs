//! Static NEW/DISPOSE analysis — the `analyze` pass.
//!
//! With no GC, NEW/DISPOSE correctness is the programmer's job, so this pass
//! warns (it never blocks a build) about the three classic mistakes:
//!   * **double DISPOSE** — `DISPOSE(p)` twice with no intervening `NEW(p)`.
//!   * **use after DISPOSE** — reading `p` or `p^` after `DISPOSE(p)` (dangling).
//!   * **leak** — a local pointer `NEW`-ed, used, never `DISPOSE`-d, and never
//!     handed off (returned / assigned away / passed to a procedure).
//!
//! It is intraprocedural and deliberately conservative: at control-flow joins a
//! touched variable's state becomes Unknown (so a DISPOSE in one IF arm never
//! mis-flags code after the IF), and a leak is reported only when the pointer
//! demonstrably never escapes. The runtime `--protect-heap` guard catches what
//! static analysis necessarily misses; together they cover the bug class.

use std::collections::HashMap;

use newm2_lexer::Span;
use newm2_loader::{ModuleGraph, ModuleId};
use newm2_parser::ast;

use crate::analyze::{Diagnostic, Severity};

#[derive(Clone, Copy, PartialEq, Eq)]
enum St {
    Alloc,    // NEW-ed, not yet disposed
    Disposed, // DISPOSE-d (now NIL / dangling)
    Unknown,  // reassigned, or merged across branches
}

/// Per-procedure tracking of simple pointer variables.
struct Vars {
    st: HashMap<String, St>,
    new_span: HashMap<String, Span>, // where it was NEW-ed (for the leak message)
    escaped: std::collections::HashSet<String>, // used as a bare value -> may be owned elsewhere
}

impl Vars {
    fn new() -> Self {
        Vars { st: HashMap::new(), new_span: HashMap::new(), escaped: Default::default() }
    }
}

struct Pass<'a> {
    mid: ModuleId,
    locals: &'a std::collections::HashSet<String>, // proc-local var names (leak candidates)
    diags: &'a mut Vec<Diagnostic>,
}

/// Run the pass over a whole module graph; returns warnings.
pub fn analyze_new_dispose(graph: &ModuleGraph) -> Vec<Diagnostic> {
    let mut diags = Vec::new();
    for &mid in &graph.topo_order {
        let node = graph.get(mid);
        if node.is_intrinsic {
            continue;
        }
        let Some(module) = node.impl_ast.as_ref().or(node.def_ast.as_ref()) else {
            continue;
        };
        // Module body vars are process-lifetime globals — not leak candidates;
        // still scan the body for double-dispose / use-after-dispose.
        if let Some(block) = &module.body {
            let empty = std::collections::HashSet::new();
            let mut p = Pass { mid, locals: &empty, diags: &mut diags };
            let mut v = Vars::new();
            p.scan_stmts(&block.stmts, &mut v);
        }
        scan_decls(mid, &module.decls, &mut diags);
    }
    diags
}

/// Walk declarations, analysing each procedure body (and nested procedures).
fn scan_decls(mid: ModuleId, decls: &[ast::Decl], diags: &mut Vec<Diagnostic>) {
    for d in decls {
        if let ast::Decl::Procedure(pd) = d {
            if let Some(body) = &pd.body {
                // local pointer-leak candidates: vars declared in this proc, minus params.
                let mut locals = std::collections::HashSet::new();
                collect_var_names(&body.decls, &mut locals);
                for prm in &pd.params {
                    for n in &prm.names {
                        locals.remove(n);
                    }
                }
                let mut v = Vars::new();
                {
                    let mut p = Pass { mid, locals: &locals, diags };
                    p.scan_stmts(&body.body.stmts, &mut v);
                    p.report_leaks(&v);
                }
                // nested procedures
                scan_decls(mid, &body.decls, diags);
            }
        }
    }
}

fn collect_var_names(decls: &[ast::Decl], out: &mut std::collections::HashSet<String>) {
    for d in decls {
        if let ast::Decl::Var(vd) = d {
            for n in &vd.names {
                out.insert(n.clone());
            }
        }
    }
}

/// If `expr` is `NAME(arg0, …)` with a bare-identifier callee, return (NAME, args).
fn as_builtin_call(expr: &ast::Expr) -> Option<(&str, &[ast::Expr])> {
    if let ast::Expr::Call(callee, args, _) = expr {
        if let ast::Expr::Designator(d) = callee.as_ref() {
            if d.selectors.is_empty() && d.base.segments.len() == 1 {
                return Some((d.base.segments[0].as_str(), args.as_slice()));
            }
        }
    }
    None
}

/// A simple variable designator `p` (single name, no selectors) -> its name.
fn simple_var(expr: &ast::Expr) -> Option<(&str, Span)> {
    if let ast::Expr::Designator(d) = expr {
        if d.selectors.is_empty() && d.base.segments.len() == 1 {
            return Some((d.base.segments[0].as_str(), d.span));
        }
    }
    None
}

impl<'a> Pass<'a> {
    fn warn(&mut self, span: Span, msg: String) {
        self.diags.push(Diagnostic { severity: Severity::Warning, message: msg, span, module_id: self.mid });
    }

    fn scan_stmts(&mut self, stmts: &[ast::Stmt], v: &mut Vars) {
        for s in stmts {
            self.scan_stmt(s, v);
        }
    }

    fn scan_stmt(&mut self, s: &ast::Stmt, v: &mut Vars) {
        match s {
            ast::Stmt::Call(expr, _) => {
                if let Some((name, args)) = as_builtin_call(expr) {
                    if (name == "NEW") && !args.is_empty() {
                        if let Some((p, sp)) = simple_var(&args[0]) {
                            if v.st.get(p) == Some(&St::Alloc) {
                                self.warn(sp, format!("'{p}' is allocated again before the previous block is disposed — the old block leaks"));
                            }
                            let p = p.to_string();
                            v.st.insert(p.clone(), St::Alloc);
                            v.new_span.insert(p, sp);
                            // scan the remaining args (rare) for uses
                            for a in &args[1..] {
                                self.scan_expr(a, v);
                            }
                            return;
                        }
                    } else if (name == "DISPOSE" || name == "DESTROY") && !args.is_empty() {
                        if let Some((p, sp)) = simple_var(&args[0]) {
                            match v.st.get(p) {
                                Some(St::Disposed) => self.warn(sp, format!("double DISPOSE of '{p}' (already disposed)")),
                                _ => {}
                            }
                            v.st.insert(p.to_string(), St::Disposed);
                            for a in &args[1..] {
                                self.scan_expr(a, v);
                            }
                            return;
                        }
                    }
                }
                // any other call: its arguments are uses (and bare-var args escape)
                self.scan_expr(expr, v);
            }
            ast::Stmt::Assign { target, value, .. } => {
                self.scan_expr(value, v);
                self.scan_designator(target, v);
                if target.selectors.is_empty() && target.base.segments.len() == 1 {
                    // p := <expr>  — p is reassigned; we lose track of it.
                    v.st.insert(target.base.segments[0].clone(), St::Unknown);
                }
            }
            ast::Stmt::If { arms, else_arm, .. } => {
                let mut touched = std::collections::HashSet::new();
                for (cond, body) in arms {
                    self.scan_expr(cond, v);
                    self.scan_branch(body, v, &mut touched);
                }
                if let Some(body) = else_arm {
                    self.scan_branch(body, v, &mut touched);
                }
                for name in touched {
                    v.st.insert(name, St::Unknown);
                }
            }
            ast::Stmt::Case { scrutinee, arms, else_arm, .. } => {
                self.scan_expr(scrutinee, v);
                let mut touched = std::collections::HashSet::new();
                for arm in arms {
                    self.scan_branch(&arm.body, v, &mut touched);
                }
                if let Some(body) = else_arm {
                    self.scan_branch(body, v, &mut touched);
                }
                for name in touched {
                    v.st.insert(name, St::Unknown);
                }
            }
            ast::Stmt::Guard { selector, arms, else_arm, .. } => {
                self.scan_expr(selector, v);
                let mut touched = std::collections::HashSet::new();
                for arm in arms {
                    self.scan_branch(&arm.body, v, &mut touched);
                }
                if let Some(body) = else_arm {
                    self.scan_branch(body, v, &mut touched);
                }
                for name in touched {
                    v.st.insert(name, St::Unknown);
                }
            }
            ast::Stmt::While(cond, body, _) => {
                self.scan_expr(cond, v);
                let mut touched = std::collections::HashSet::new();
                self.scan_branch(body, v, &mut touched);
                for name in touched {
                    v.st.insert(name, St::Unknown);
                }
            }
            ast::Stmt::Repeat(body, cond, _) => {
                let mut touched = std::collections::HashSet::new();
                self.scan_branch(body, v, &mut touched);
                self.scan_expr(cond, v);
                for name in touched {
                    v.st.insert(name, St::Unknown);
                }
            }
            ast::Stmt::For { start, end, step, body, .. } => {
                self.scan_expr(start, v);
                self.scan_expr(end, v);
                if let Some(st) = step {
                    self.scan_expr(st, v);
                }
                let mut touched = std::collections::HashSet::new();
                self.scan_branch(body, v, &mut touched);
                for name in touched {
                    v.st.insert(name, St::Unknown);
                }
            }
            ast::Stmt::Loop(body, _) => {
                let mut touched = std::collections::HashSet::new();
                self.scan_branch(body, v, &mut touched);
                for name in touched {
                    v.st.insert(name, St::Unknown);
                }
            }
            ast::Stmt::With(desig, body, _) => {
                self.scan_designator(desig, v);
                let mut touched = std::collections::HashSet::new();
                self.scan_branch(body, v, &mut touched);
                for name in touched {
                    v.st.insert(name, St::Unknown);
                }
            }
            ast::Stmt::Return(Some(expr), _) => self.scan_expr(expr, v),
            ast::Stmt::Raise(Some(expr), _) => self.scan_expr(expr, v),
            ast::Stmt::Block(b) => self.scan_stmts(&b.stmts, v),
            _ => {}
        }
    }

    /// Scan a nested branch on a CLONE of the per-variable STATE (so a DISPOSE in
    /// one arm doesn't deterministically apply after the join), recording which
    /// variables it touched. Escapes and NEW-sites are monotonic, so fold them
    /// back into `v` (a value that escaped in a branch really did escape).
    fn scan_branch(&mut self, body: &[ast::Stmt], v: &mut Vars, touched: &mut std::collections::HashSet<String>) {
        let mut clone = Vars {
            st: v.st.clone(),
            new_span: v.new_span.clone(),
            escaped: v.escaped.clone(),
        };
        let before: HashMap<String, St> = clone.st.clone();
        self.scan_stmts(body, &mut clone);
        for (k, val) in &clone.st {
            if before.get(k) != Some(val) {
                touched.insert(k.clone());
            }
        }
        for e in clone.escaped {
            v.escaped.insert(e);
        }
        for (k, sp) in clone.new_span {
            v.new_span.entry(k).or_insert(sp);
        }
    }

    /// Walk an expression; flag uses of disposed pointers, and mark bare pointer
    /// values as escaped (so they aren't leak-reported).
    fn scan_expr(&mut self, e: &ast::Expr, v: &mut Vars) {
        match e {
            ast::Expr::Designator(d) => self.scan_designator(d, v),
            ast::Expr::Call(callee, args, _) => {
                // a bare-identifier callee is the procedure name, not a use
                if !matches!(callee.as_ref(), ast::Expr::Designator(d) if d.selectors.is_empty() && d.base.segments.len() == 1)
                {
                    self.scan_expr(callee, v);
                }
                for a in args {
                    self.scan_expr(a, v);
                }
            }
            ast::Expr::Binary(_, l, r, _) => {
                self.scan_expr(l, v);
                self.scan_expr(r, v);
            }
            ast::Expr::Unary(_, x, _) => self.scan_expr(x, v),
            _ => {}
        }
    }

    /// A designator references a variable. `p` (no selectors) is the bare pointer
    /// value (escapes); `p^…` dereferences it (a use, doesn't escape). Either way,
    /// touching a Disposed pointer is a use-after-free.
    fn scan_designator(&mut self, d: &ast::Designator, v: &mut Vars) {
        if d.base.segments.len() == 1 {
            let name = &d.base.segments[0];
            if v.st.get(name) == Some(&St::Disposed) {
                self.warn(d.span, format!("use of '{name}' after DISPOSE (dangling pointer)"));
            }
            if d.selectors.is_empty() {
                // the bare pointer value is read -> it may be stored/owned elsewhere
                v.escaped.insert(name.clone());
            }
        }
        // scan index expressions (they may use other pointers)
        for sel in &d.selectors {
            if let ast::Selector::Index(idx, _) = sel {
                for e in idx {
                    self.scan_expr(e, v);
                }
            }
        }
    }

    fn report_leaks(&mut self, v: &Vars) {
        let mut names: Vec<&String> = v.st.keys().collect();
        names.sort();
        for name in names {
            if v.st.get(name) == Some(&St::Alloc)
                && self.locals.contains(name)
                && !v.escaped.contains(name)
            {
                if let Some(sp) = v.new_span.get(name) {
                    self.warn(*sp, format!("'{name}' is allocated here but never disposed (memory leak)"));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use newm2_loader::{SearchPath, build_module_graph};
    use std::fs;

    fn run(name: &str, src: &str) -> Vec<String> {
        let mut dir = std::env::temp_dir();
        dir.push(format!("newm2-heapcheck-{name}"));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let f = dir.join("T.mod");
        fs::write(&f, src).unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&f, &sp).unwrap();
        analyze_new_dispose(&graph).iter().map(|d| d.message.clone()).collect()
    }

    #[test]
    fn detects_leak_double_dispose_use_after() {
        let msgs = run(
            "bugs",
            "MODULE T;\n\
             TYPE P = POINTER TO INTEGER;\n\
             PROCEDURE Leak; VAR p: P; BEGIN NEW(p); p^ := 1 END Leak;\n\
             PROCEDURE Dbl; VAR p: P; BEGIN NEW(p); DISPOSE(p); DISPOSE(p) END Dbl;\n\
             PROCEDURE Uaf; VAR p: P; x: INTEGER; BEGIN NEW(p); DISPOSE(p); x := p^ END Uaf;\n\
             PROCEDURE Clean; VAR p: P; BEGIN NEW(p); p^ := 5; DISPOSE(p) END Clean;\n\
             PROCEDURE Esc(): P; VAR p: P; BEGIN NEW(p); RETURN p END Esc;\n\
             BEGIN END T.\n",
        );
        assert_eq!(msgs.len(), 3, "expected exactly 3 findings, got: {msgs:?}");
        assert!(msgs.iter().any(|m| m.contains("never disposed")), "leak missing: {msgs:?}");
        assert!(msgs.iter().any(|m| m.contains("double DISPOSE")), "double-dispose missing: {msgs:?}");
        assert!(msgs.iter().any(|m| m.contains("after DISPOSE")), "use-after-dispose missing: {msgs:?}");
    }

    #[test]
    fn clean_code_is_silent() {
        let msgs = run(
            "clean",
            "MODULE T;\n\
             TYPE P = POINTER TO INTEGER;\n\
             PROCEDURE Ok; VAR p: P; BEGIN NEW(p); p^ := 1; DISPOSE(p) END Ok;\n\
             BEGIN END T.\n",
        );
        assert!(msgs.is_empty(), "expected no findings, got: {msgs:?}");
    }

    #[test]
    fn dispose_in_one_if_arm_is_not_use_after() {
        // conservative joins: a DISPOSE inside one IF arm must not flag code after the IF
        let msgs = run(
            "join",
            "MODULE T;\n\
             TYPE P = POINTER TO INTEGER;\n\
             PROCEDURE F (b: BOOLEAN); VAR p: P; BEGIN\n\
               NEW(p); IF b THEN DISPOSE(p) ELSE DISPOSE(p) END\n\
             END F;\n\
             BEGIN END T.\n",
        );
        assert!(msgs.is_empty(), "expected no findings, got: {msgs:?}");
    }
}
