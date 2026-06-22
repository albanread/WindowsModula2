//! Value identifiers, IR-level constants, instructions, and terminators.

use newm2_sema::types::TypeId;

/// IR-level constant values. Extends sema's `ConstValue` with `FuncRef`
/// so that extern procedures can be represented as first-class values.
#[derive(Debug, Clone)]
pub enum ConstVal {
    Int(i128),
    Real(f64),
    Bool(bool),
    Char(char),
    /// String literal — the full content; codegen interns it as a global.
    Str(String),
    /// Reference to a named function (external or local).
    FuncRef(String),
    /// Address of a named global/static value.
    GlobalRef { name: String, ty: TypeId },
    /// Byte size of a type — `SYSTEM.TSIZE(T)` / `SIZE(x)`. Codegen resolves
    /// it to the target ABI size of the type's LLVM representation.
    SizeOf(TypeId),
    /// A RECORD/ARRAY structured-constructor constant — carries the folded
    /// sema value and its type, which codegen materialises as an LLVM constant
    /// struct/array.
    Aggregate { value: newm2_sema::ConstValue, ty: TypeId },
    Nil,
}

/// A virtual register / SSA-style value produced by an instruction.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ValueId(pub u32);

/// A basic-block identifier within a function.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BlockId(pub u32);

/// Binary operators — full Modula-2 set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinOp {
    // Integer arithmetic.
    Add,
    Sub,
    Mul,
    /// Wirth-style floored division (`DIV` keyword, integer operands).
    Div,
    /// Wirth MOD (always non-negative).
    Mod,
    /// C-style truncating division (for CARDINAL / unsigned contexts).
    Quot,
    /// C-style remainder (unsigned).
    Rem,
    /// Signed truncated remainder (ISO `REM` on signed operands; the sign of
    /// the result follows the dividend).
    SRem,
    // Bitwise.
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
    // Comparison — produce a boolean result. The plain forms are signed;
    // the `U`-prefixed forms are unsigned (CARDINAL / ADDRESS / CHAR …).
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    ULt,
    ULe,
    UGt,
    UGe,
    // Logical (short-circuit behaviour is handled at CFG level by sema).
    And,
    Or,
    // Real arithmetic.
    FAdd,
    FSub,
    FMul,
    FDiv,
}

/// Unary operators.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnaryOp {
    /// Integer negation.
    Neg,
    /// Float negation.
    FNeg,
    /// Boolean NOT or bitwise complement.
    Not,
    /// ABS — absolute value.
    Abs,
    /// CAP — upper-case an ASCII letter (a..z → A..Z), else unchanged.
    Cap,
}

/// SET operations (lowered from Modula-2 set expressions).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetOpKind {
    Union,        // +
    Difference,   // -
    Intersection, // *
    SymDiff,      // /
    /// `x IN S` — element membership, produces a BOOLEAN.
    Member,
}

/// Type conversion / reinterpretation kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CastKind {
    IntTrunc,
    IntZeroExt,
    IntSignExt,
    IntToFloat,
    FloatToInt,
    FloatExt,
    FloatTrunc,
    BitCast,
    OrdToChar,
    CharToOrd,
    /// Pointer → integer (`SYSTEM.CAST(CARDINAL, addr)` and friends).
    PtrToInt,
    /// Integer → pointer (`SYSTEM.CAST(ADDRESS, n)` and friends).
    IntToPtr,
    /// A `SYSTEM.CAST` where one operand is an aggregate (RECORD / closed ARRAY):
    /// a bit-level memory reinterpret (alloca a slot, store the source bits, load
    /// the target type) — not a scalar conversion or a pointer cast.
    MemReinterpret,
}

/// SIMD lane-vector intrinsic operations (lowered to `llvm.*`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VecIntrin {
    /// `SUM(v)` — horizontal add of all lanes → scalar (`llvm.vector.reduce.fadd`).
    ReduceAdd,
    /// `FMA(a, b, c)` — fused lane-wise `a*b + c` (`llvm.fma`).
    Fma,
    /// `ABS(v)` — lane-wise absolute value (`llvm.fabs`).
    Fabs,
}

/// A single non-terminator IR instruction.
#[derive(Debug, Clone)]
pub enum Inst {
    /// `dst = constant`
    Const { dst: ValueId, val: ConstVal },
    /// `dst = src`
    Copy { dst: ValueId, src: ValueId },
    /// `dst = alloca(ty)` — allocate a stack slot for a local variable.
    Alloca { dst: ValueId, ty: TypeId },
    /// `dst = *ptr`
    Load { dst: ValueId, ptr: ValueId },
    /// `*ptr = val`
    Store { ptr: ValueId, val: ValueId },
    /// `memmove(*dst <- *src)` of `ty` bytes — a whole-aggregate (RECORD / ARRAY)
    /// copy by address, avoiding a by-value aggregate load/store (which LLVM's
    /// SelectionDAG cannot legalise for >64K-element aggregates → segfault).
    MemCopy { dst: ValueId, src: ValueId, ty: TypeId },
    /// `dst = &(base->field_index)` — address of a record field.
    FieldPtr { dst: ValueId, base: ValueId, field: u32 },
    /// `dst = &(base[index])` — address of an array element. `elem_ty` is the
    /// element type so codegen GEPs as `elem_ty*` uniformly for fixed arrays
    /// (base = &array[0]) and open-array data pointers.
    IndexPtr { dst: ValueId, base: ValueId, index: ValueId, elem_ty: TypeId },
    /// `dst = src` (same pointer value) but annotated as pointing to `ty`, so
    /// codegen records the pointee element type. Used to re-type a pointer that
    /// was loaded from an untyped slot (e.g. a protected region's local
    /// reconstructed from its exception frame).
    TypedPtr { dst: ValueId, src: ValueId, ty: TypeId },
    /// `dst = op val`
    Unary { dst: ValueId, op: UnaryOp, val: ValueId },
    /// `dst = lhs op rhs`
    Binary { dst: ValueId, op: BinOp, lhs: ValueId, rhs: ValueId },
    /// `dst = cast(kind, val) : ty`
    Cast { dst: ValueId, kind: CastKind, val: ValueId, ty: TypeId },
    /// `(optional dst) = call callee(args...)` — direct call.
    Call { dst: Option<ValueId>, callee: ValueId, args: Vec<ValueId> },
    /// Indirect call through a procedure-typed variable.
    IndCall { dst: Option<ValueId>, callee: ValueId, sig: TypeId, args: Vec<ValueId> },
    /// `dst = set_op(lhs, rhs)` — SET operation.
    SetOp { dst: ValueId, op: SetOpKind, lhs: ValueId, rhs: ValueId },
    /// `dst = allocate(ty)` — NEW / Storage.ALLOCATE.
    Allocate { dst: ValueId, ty: TypeId },
    /// DISPOSE / Storage.DEALLOCATE.
    Deallocate { ptr: ValueId },
    /// GC mode: register `ptr` as a stack root for the collector.
    GcRoot { ptr: ValueId },
    /// GC mode: safe point (at calls, loop back-edges, pragma sites).
    GcSafePoint,
    /// SYSTEM.PIN.
    Pin { ptr: ValueId },
    /// SYSTEM.UNPIN.
    Unpin { ptr: ValueId },
    /// SYSTEM.NEWPROCESS(proc, adr, size, dst_coroutine).
    NewProcess { proc_val: ValueId, adr: ValueId, size: ValueId, dst: ValueId },
    /// SYSTEM.TRANSFER(src, dst).
    Transfer { src: ValueId, dst: ValueId },

    /// `dst = <ty>{ lanes... }` — build a SIMD lane vector from per-lane values.
    /// A single lane value is a broadcast/splat across all lanes. `ty` is the
    /// `TypeKind::Vector` so codegen knows the LLVM vector type.
    VecBuild { dst: ValueId, lanes: Vec<ValueId>, ty: TypeId },
    /// `dst = vec[lane]` — extract one lane (extractelement).
    VecExtract { dst: ValueId, vec: ValueId, lane: ValueId },
    /// `dst = insert(vec, lane := val)` — yield `vec` with one lane replaced
    /// (insertelement). Used for `v[i] := val`.
    VecInsert { dst: ValueId, vec: ValueId, lane: ValueId, val: ValueId },
    /// `dst = vec_intrinsic(op, args...)` — a SIMD reduction / FMA / element-wise
    /// math op. `ty` is the vector type (drives the `llvm.*` overload).
    VecIntrinsic { dst: ValueId, op: VecIntrin, args: Vec<ValueId>, ty: TypeId },
}

/// Block terminator — exactly one per basic block.
#[derive(Debug, Clone)]
pub enum Terminator {
    /// Unconditional jump.
    Goto(BlockId),
    /// Two-way conditional branch.
    CondBr { cond: ValueId, t_block: BlockId, f_block: BlockId },
    /// Multi-way switch (CASE statement; dense ranges expand here).
    Switch { val: ValueId, arms: Vec<(i128, BlockId)>, default: BlockId },
    /// Return from procedure, optionally with a value.
    Return(Option<ValueId>),
    /// RAISE exception value.
    Raise(ValueId),
    /// HALT — terminates the program.
    Halt,
    /// Placeholder only; replaced during CFG construction before `finish()`.
    Unreachable,
}

impl Terminator {
    /// Successor block IDs this terminator may jump to.
    pub fn succs(&self) -> Vec<BlockId> {
        match self {
            Terminator::Goto(b) => vec![*b],
            Terminator::CondBr { t_block, f_block, .. } => vec![*t_block, *f_block],
            Terminator::Switch { arms, default, .. } => {
                let mut v: Vec<BlockId> = arms.iter().map(|(_, b)| *b).collect();
                v.push(*default);
                v.sort_unstable_by_key(|b| b.0);
                v.dedup();
                v
            }
            Terminator::Return(_)
            | Terminator::Raise(_)
            | Terminator::Halt
            | Terminator::Unreachable => vec![],
        }
    }
}
