//! Pretty-printers for `newm2 dump-ir` and `newm2 dump-cfg`.

use crate::func::Func;
use crate::inst::{BinOp, CastKind, ConstVal, Inst, SetOpKind, Terminator, UnaryOp};
use crate::module::{Global, IrModule, MemoryMode};

// ---- Public entry points -------------------------------------------------

/// Format an IR module for `newm2 dump-ir` (construction order).
pub fn format_ir(ir: &IrModule) -> String {
    let mut out = String::new();
    out.push_str(&format!("IR MODULE {}  [{}]\n\n", ir.name, mode_str(ir.memory_mode)));

    for g in &ir.globals {
        out.push_str(&format_global(g));
    }
    if !ir.globals.is_empty() {
        out.push('\n');
    }

    for func in &ir.funcs {
        format_func_ir(&mut out, func);
        out.push('\n');
    }
    out
}

/// Format a CFG for `newm2 dump-cfg` (RPO order, with predecessor lists).
pub fn format_cfg(ir: &IrModule) -> String {
    let mut out = String::new();
    out.push_str(&format!("CFG MODULE {}  [{}]\n\n", ir.name, mode_str(ir.memory_mode)));
    for func in &ir.funcs {
        format_func_cfg(&mut out, func);
        out.push('\n');
    }
    out
}

// ---- Internal helpers ----------------------------------------------------

fn mode_str(m: MemoryMode) -> &'static str {
    match m {
        MemoryMode::Gc => "gc",
        MemoryMode::NoGc => "no-gc",
    }
}

fn format_global(g: &Global) -> String {
    match g {
        Global::ExternFunc { name, .. } => format!("extern fn @{name}\n"),
        Global::Static { name, exported, .. } => {
            let exp = if *exported { " [exported]" } else { "" };
            format!("static @{name}{exp}\n")
        }
        Global::StringConst { name, value } => {
            format!("string @{name} = {value:?}\n")
        }
        Global::ClassDesc { class_name, vtable_slots } => {
            let slots = vtable_slots.join(", ");
            format!("vtable @{class_name}.vtable [{slots}]\n")
        }
    }
}

fn format_func_header(func: &Func) -> String {
    let params: Vec<String> = func
        .params
        .iter()
        .map(|p| {
            let var = if p.is_var { "VAR " } else { "" };
            format!("{var}{}: T{}", p.name, p.ty.0)
        })
        .collect();
    let ret = func
        .return_ty
        .map(|t| format!(" : T{}", t.0))
        .unwrap_or_default();
    let mode = mode_str(func.memory_mode);
    format!("fn {}({}){}  [{}]", func.name, params.join(", "), ret, mode)
}

fn format_func_ir(out: &mut String, func: &Func) {
    out.push_str(&format_func_header(func));
    out.push_str(" {\n");
    for block in func.construction_order() {
        let label = block.label.as_deref().unwrap_or("");
        let label_comment = if label.is_empty() {
            String::new()
        } else {
            format!("  ; {label}")
        };
        out.push_str(&format!("  B{}:{}\n", block.id.0, label_comment));
        for inst in &block.insts {
            out.push_str(&format!("    {}\n", format_inst(inst)));
        }
        out.push_str(&format!("    {}\n", format_term(&block.term)));
    }
    out.push_str("}\n");
}

fn format_func_cfg(out: &mut String, func: &Func) {
    // Compute predecessor sets.
    let n = func.blocks.len();
    let mut preds: Vec<Vec<u32>> = vec![vec![]; n];
    for b in func.construction_order() {
        for s in b.term.succs() {
            if (s.0 as usize) < n {
                preds[s.0 as usize].push(b.id.0);
            }
        }
    }

    out.push_str(&format_func_header(func));
    out.push_str(" {\n");

    for bid in func.rpo() {
        let block = func.get_block(bid);
        let label = block.label.as_deref().unwrap_or("");
        let pred_str = {
            let mut ps = preds[bid.0 as usize].clone();
            ps.sort_unstable();
            ps.iter().map(|p| format!("B{p}")).collect::<Vec<_>>().join(", ")
        };
        let pred_note = if pred_str.is_empty() {
            String::new()
        } else {
            format!("  ; preds: [{pred_str}]")
        };
        out.push_str(&format!("  B{}: {label}{pred_note}\n", bid.0));
        for inst in &block.insts {
            out.push_str(&format!("    {}\n", format_inst(inst)));
        }
        out.push_str(&format!("    {}\n", format_term(&block.term)));
    }

    out.push_str("}\n");
}

fn format_inst(inst: &Inst) -> String {
    match inst {
        Inst::Const { dst, val } => format!("v{} = {}", dst.0, format_const(val)),
        Inst::Copy { dst, src } => format!("v{} = v{}", dst.0, src.0),
        Inst::Alloca { dst, ty } => format!("v{} = alloca T{}", dst.0, ty.0),
        Inst::Load { dst, ptr } => format!("v{} = load *v{}", dst.0, ptr.0),
        Inst::Store { ptr, val } => format!("*v{} = v{}", ptr.0, val.0),
        Inst::FieldPtr { dst, base, field } => {
            format!("v{} = &v{}.{}", dst.0, base.0, field)
        }
        Inst::IndexPtr { dst, base, index, .. } => {
            format!("v{} = &v{}[v{}]", dst.0, base.0, index.0)
        }
        Inst::TypedPtr { dst, src, ty } => {
            format!("v{} = typed v{} : T{}", dst.0, src.0, ty.0)
        }
        Inst::Unary { dst, op, val } => {
            format!("v{} = {} v{}", dst.0, format_unary(*op), val.0)
        }
        Inst::Binary { dst, op, lhs, rhs } => {
            format!("v{} = v{} {} v{}", dst.0, lhs.0, format_binop(*op), rhs.0)
        }
        Inst::Cast { dst, kind, val, ty } => {
            format!("v{} = cast({}, v{}) : T{}", dst.0, format_cast(*kind), val.0, ty.0)
        }
        Inst::Call { dst, callee, args } => {
            let args_str = args.iter().map(|a| format!("v{}", a.0)).collect::<Vec<_>>().join(", ");
            let lhs = dst.map(|d| format!("v{} = ", d.0)).unwrap_or_default();
            format!("{lhs}call v{}({})", callee.0, args_str)
        }
        Inst::IndCall { dst, callee, args, .. } => {
            let args_str = args.iter().map(|a| format!("v{}", a.0)).collect::<Vec<_>>().join(", ");
            let lhs = dst.map(|d| format!("v{} = ", d.0)).unwrap_or_default();
            format!("{lhs}icall v{}({})", callee.0, args_str)
        }
        Inst::SetOp { dst, op, lhs, rhs } => {
            format!("v{} = v{} {} v{}", dst.0, lhs.0, format_setop(*op), rhs.0)
        }
        Inst::Allocate { dst, ty } => format!("v{} = allocate T{}", dst.0, ty.0),
        Inst::Deallocate { ptr } => format!("deallocate v{}", ptr.0),
        Inst::GcRoot { ptr } => format!("gcroot v{}", ptr.0),
        Inst::GcSafePoint => "gc.safepoint".into(),
        Inst::Pin { ptr } => format!("pin v{}", ptr.0),
        Inst::Unpin { ptr } => format!("unpin v{}", ptr.0),
        Inst::NewProcess { proc_val, adr, size, dst } => {
            format!("v{} = newprocess v{}, v{}, v{}", dst.0, proc_val.0, adr.0, size.0)
        }
        Inst::Transfer { src, dst } => format!("transfer v{}, v{}", src.0, dst.0),
        Inst::VecBuild { dst, lanes, ty } => {
            let ls: Vec<String> = lanes.iter().map(|l| format!("v{}", l.0)).collect();
            format!("v{} = vec T{} {{{}}}", dst.0, ty.0, ls.join(", "))
        }
        Inst::VecExtract { dst, vec, lane } => {
            format!("v{} = v{}[v{}]", dst.0, vec.0, lane.0)
        }
        Inst::VecInsert { dst, vec, lane, val } => {
            format!("v{} = insert v{}[v{}] := v{}", dst.0, vec.0, lane.0, val.0)
        }
        Inst::VecIntrinsic { dst, op, args, .. } => {
            let a: Vec<String> = args.iter().map(|x| format!("v{}", x.0)).collect();
            format!("v{} = vec.{:?}({})", dst.0, op, a.join(", "))
        }
    }
}

fn format_term(term: &Terminator) -> String {
    match term {
        Terminator::Goto(b) => format!("goto B{}", b.0),
        Terminator::CondBr { cond, t_block, f_block } => {
            format!("condbr v{} → B{} | B{}", cond.0, t_block.0, f_block.0)
        }
        Terminator::Switch { val, arms, default } => {
            let arms_str = arms
                .iter()
                .map(|(v, b)| format!("{v}→B{}", b.0))
                .collect::<Vec<_>>()
                .join(", ");
            format!("switch v{} [{}] default→B{}", val.0, arms_str, default.0)
        }
        Terminator::Return(Some(v)) => format!("return v{}", v.0),
        Terminator::Return(None) => "return".into(),
        Terminator::Raise(v) => format!("raise v{}", v.0),
        Terminator::Halt => "halt".into(),
        Terminator::Unreachable => "unreachable".into(),
    }
}

fn format_const(val: &ConstVal) -> String {
    match val {
        ConstVal::Int(n) => format!("int {n}"),
        ConstVal::Real(f) => format!("real {f}"),
        ConstVal::Bool(b) => format!("bool {b}"),
        ConstVal::Char(c) => format!("char {c:?}"),
        ConstVal::Str(s) => format!("str {s:?}"),
        ConstVal::FuncRef(n) => format!("fn @{n}"),
        ConstVal::GlobalRef { name, .. } => format!("global @{name}"),
        ConstVal::SizeOf(ty) => format!("sizeof T{}", ty.0),
        ConstVal::Aggregate { ty, .. } => format!("aggregate T{}", ty.0),
        ConstVal::Nil => "nil".into(),
    }
}

fn format_binop(op: BinOp) -> &'static str {
    match op {
        BinOp::Add => "+",
        BinOp::Sub => "-",
        BinOp::Mul => "*",
        BinOp::Div => "DIV",
        BinOp::Mod => "MOD",
        BinOp::Quot => "/",
        BinOp::Rem => "REM",
        BinOp::SRem => "SREM",
        BinOp::BitAnd => "&",
        BinOp::BitOr => "|",
        BinOp::BitXor => "^",
        BinOp::Shl => "<<",
        BinOp::Shr => ">>",
        BinOp::Eq => "=",
        BinOp::Ne => "#",
        BinOp::Lt => "<",
        BinOp::Le => "<=",
        BinOp::Gt => ">",
        BinOp::Ge => ">=",
        BinOp::ULt => "u<",
        BinOp::ULe => "u<=",
        BinOp::UGt => "u>",
        BinOp::UGe => "u>=",
        BinOp::And => "AND",
        BinOp::Or => "OR",
        BinOp::FAdd => "f+",
        BinOp::FSub => "f-",
        BinOp::FMul => "f*",
        BinOp::FDiv => "f/",
    }
}

fn format_unary(op: UnaryOp) -> &'static str {
    match op {
        UnaryOp::Neg => "-",
        UnaryOp::FNeg => "f-",
        UnaryOp::Not => "NOT",
        UnaryOp::Abs => "ABS",
        UnaryOp::Cap => "CAP",
    }
}

fn format_setop(op: SetOpKind) -> &'static str {
    match op {
        SetOpKind::Union => "+",
        SetOpKind::Difference => "-",
        SetOpKind::Intersection => "*",
        SetOpKind::SymDiff => "/",
        SetOpKind::Member => "IN",
    }
}

fn format_cast(kind: CastKind) -> &'static str {
    match kind {
        CastKind::IntTrunc => "trunc",
        CastKind::IntZeroExt => "zext",
        CastKind::IntSignExt => "sext",
        CastKind::IntToFloat => "itof",
        CastKind::FloatToInt => "ftoi",
        CastKind::FloatExt => "fext",
        CastKind::FloatTrunc => "ftrunc",
        CastKind::BitCast => "bitcast",
        CastKind::OrdToChar => "ord2char",
        CastKind::CharToOrd => "char2ord",
        CastKind::PtrToInt => "ptr2int",
        CastKind::IntToPtr => "int2ptr",
    }
}
