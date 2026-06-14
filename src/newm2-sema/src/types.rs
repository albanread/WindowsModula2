//! Type system: the arena, the `TypeId` handle, and the built-in
//! catalog covering PIM-4, ISO 10514-1, and ADW dialect additions.

use std::collections::HashMap;

/// Opaque handle into the type arena.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TypeId(pub u32);

/// Kinds of type in NewM2.
///
/// Built-in scalars carry their exact bit width and signedness so
/// later phases can pick LLVM types directly. CARDINAL is distinct
/// from INTEGER (PIM rule) even when their widths happen to match;
/// the difference shows up in assignment-compatibility checks.
#[derive(Debug, Clone, PartialEq)]
pub enum TypeKind {
    /// A placeholder used during forward-reference resolution. Sema
    /// must replace every Unresolved before a module is considered
    /// fully checked.
    Unresolved,

    /// PIM/ISO/ADW built-in scalar.
    Builtin(Builtin),

    /// Enumeration `(red, green, blue)`. Carries the ordered names and,
    /// parallel to them, each member's ordinal value. Ordinals are the
    /// positions for a normal (dense) enum, but ADW-imported C enums may
    /// assign explicit, possibly sparse, values (`(ok=0, fail=5, …)`), so
    /// the values are stored rather than assumed. Each enumeration is its
    /// own nominal type — two enums with the same names are distinct.
    Enum {
        name: Option<String>,
        names: Vec<String>,
        values: Vec<i128>,
    },

    /// Subrange `[lo..hi]` of an ordinal host type (INTEGER,
    /// CARDINAL, CHAR, or an enumeration).
    Subrange { host: TypeId, lo: i128, hi: i128 },

    /// `ARRAY idx_1, ..., idx_n OF base`. Closed (each index has a
    /// statically-known range).
    Array { indices: Vec<TypeId>, base: TypeId },

    /// `ARRAY OF base` (open). Allowed only in formal parameter
    /// position. Sema enforces this restriction.
    OpenArray { base: TypeId },

    /// Heap pointer `POINTER TO base`. `base` may be Unresolved
    /// during construction of self-referential pointers.
    Pointer { base: TypeId },

    /// Record type, optionally with a CASE variant part.
    Record(RecordLayout),

    /// `SET OF base` or `PACKEDSET OF base`. Base must be an ordinal
    /// with cardinality fitting in `set_max_bits`.
    Set { packed: bool, base: TypeId },

    /// A SIMD lane vector: `lanes` copies of a scalar float `base`, held
    /// as a single register-width value (`<lanes x base>` in LLVM).
    /// `lanes * SIZE(base)` is a hardware vector width (16 bytes for the
    /// REAL64X2 / REAL32X4 / REAL16X8 set). Element-wise arithmetic; a
    /// distinct nominal type (a REAL32X4 is not a REAL64X2).
    Vector { lanes: u32, base: TypeId },

    /// Procedure type (function pointer).
    Proc {
        params: Vec<ProcParam>,
        return_ty: Option<TypeId>,
    },

    /// ISO 10514-2 / ADW class. The class's full layout (vtable,
    /// fields, inherited methods, REVEAL widening) lives in the
    /// `Class` symbol; this type-kind variant just names the symbol
    /// so type expressions can refer to the class as a type.
    Class { symbol: u32 },
}

/// Built-in scalar types. The variants cover PIM (INTEGER, CARDINAL,
/// CHAR, BOOLEAN, REAL), ISO 10514-1 (COMPLEX, LONGCOMPLEX), and
/// the ADW exact-width family (INTEGER8/16/32/64, CARDINAL8/16/32/64,
/// BYTE/WORD/DWORD/QWORD, ADDRESS/ADRCARD, ACHAR/UCHAR).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Builtin {
    // PIM base types
    Boolean,
    Char,
    Integer,
    Cardinal,
    Real,
    LongInt,
    LongCard,
    LongReal,
    // Narrow IEEE floats — distinct types (true f32/f16), used for Win32 FLOAT
    // interop and SIMD/matrix work. Each is its own family (NOT interchangeable
    // with REAL/LONGREAL); conversions are explicit.
    Real32,
    Real16,
    Bitset,
    Proc, // PROC = PROCEDURE with no params, no result
    Nil,  // type of the literal NIL

    // ISO 10514-1 additions
    Complex,
    LongComplex,

    // ADW exact-width integers
    Integer8,
    Integer16,
    Integer32,
    Integer64,
    Cardinal8,
    Cardinal16,
    Cardinal32,
    Cardinal64,

    // ADW byte-oriented types
    Byte,
    Word,
    Dword,
    Qword,

    // ADW address arithmetic
    Address,
    Adrint,
    Adrcard,

    // ADW Unicode-aware characters
    Achar,
    Uchar,

    // SYSTEM module types
    SysAddress,
    SysLoc,
    SysByte,
    SysWord,
    SysBitset,
}

impl Builtin {
    pub fn name(self) -> &'static str {
        use Builtin::*;
        match self {
            Boolean => "BOOLEAN",
            Char => "CHAR",
            Integer => "INTEGER",
            Cardinal => "CARDINAL",
            Real => "REAL",
            LongInt => "LONGINT",
            LongCard => "LONGCARD",
            LongReal => "LONGREAL",
            Real32 => "REAL32",
            Real16 => "REAL16",
            Bitset => "BITSET",
            Proc => "PROC",
            Nil => "NIL",
            Complex => "COMPLEX",
            LongComplex => "LONGCOMPLEX",
            Integer8 => "INTEGER8",
            Integer16 => "INTEGER16",
            Integer32 => "INTEGER32",
            Integer64 => "INTEGER64",
            Cardinal8 => "CARDINAL8",
            Cardinal16 => "CARDINAL16",
            Cardinal32 => "CARDINAL32",
            Cardinal64 => "CARDINAL64",
            Byte => "BYTE",
            Word => "WORD",
            Dword => "DWORD",
            Qword => "QWORD",
            Address => "ADDRESS",
            Adrint => "ADRINT",
            Adrcard => "ADRCARD",
            Achar => "ACHAR",
            Uchar => "UCHAR",
            SysAddress => "ADDRESS",
            SysLoc => "LOC",
            SysByte => "BYTE",
            SysWord => "WORD",
            SysBitset => "BITSET",
        }
    }

    /// `true` if the type is an ordinal — usable as an array index, a
    /// CASE selector, a subrange host, or a SET element.
    pub fn is_ordinal(self) -> bool {
        use Builtin::*;
        matches!(
            self,
            Boolean
                | Char
                | Achar
                | Uchar
                | Integer
                | Cardinal
                | LongInt
                | LongCard
                | Integer8
                | Integer16
                | Integer32
                | Integer64
                | Cardinal8
                | Cardinal16
                | Cardinal32
                | Cardinal64
                | Byte
                | Word
                | Dword
                | Qword
                | Address
                | Adrint
                | Adrcard
        )
    }

    /// `true` if assignment between two values of these scalar types
    /// requires no explicit conversion in PIM. Distinct integer
    /// families (CARDINAL vs INTEGER) are NOT compatible.
    pub fn is_same_family(self, other: Builtin) -> bool {
        use Builtin::*;
        match (self, other) {
            (a, b) if a == b => true,
            // CARDINAL family
            (Cardinal | Cardinal8 | Cardinal16 | Cardinal32 | Cardinal64 | LongCard,
             Cardinal | Cardinal8 | Cardinal16 | Cardinal32 | Cardinal64 | LongCard) => true,
            // INTEGER family
            (Integer | Integer8 | Integer16 | Integer32 | Integer64 | LongInt,
             Integer | Integer8 | Integer16 | Integer32 | Integer64 | LongInt) => true,
            // Real family
            (Real | LongReal, Real | LongReal) => true,
            // Complex family (COMPLEX / LONGCOMPLEX share the {re,im} layout)
            (Complex | LongComplex, Complex | LongComplex) => true,
            // Char family (CHAR, ACHAR, UCHAR all hold character codes)
            (Char | Achar | Uchar, Char | Achar | Uchar) => true,
            // ADDRESS family
            (Address | Adrint | Adrcard | SysAddress, Address | Adrint | Adrcard | SysAddress) => true,
            // NIL is the null address — assignment-compatible with the ADDRESS
            // family (ported from M2NEW). Typed-pointer/NIL is handled separately.
            (Nil, Address | Adrint | Adrcard | SysAddress)
            | (Address | Adrint | Adrcard | SysAddress, Nil) => true,
            _ => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProcParam {
    pub mode: ParamMode,
    pub ty: TypeId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamMode {
    Value,
    Var,
    /// `CONST` (ADW): read-only. Passed by value (so it accepts any argument
    /// expression) but the body may not assign to it.
    Const,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RecordLayout {
    pub name: Option<String>,
    pub fields: Vec<RecordFieldSlot>,
    pub variant: Option<VariantLayout>,
}

impl RecordLayout {
    /// The complete struct-member order used by codegen and field-index
    /// resolution alike: the fixed fields, then (for a variant part) the named
    /// tag, then every arm's fields, then the ELSE arm's fields. Variant arms
    /// are laid out sequentially (non-overlapping); this is correct for normal
    /// tag-discriminated use, but does not support type-punning across arms.
    pub fn flatten_fields(&self) -> Vec<(String, TypeId)> {
        let mut out: Vec<(String, TypeId)> =
            self.fields.iter().map(|f| (f.name.clone(), f.ty)).collect();
        if let Some(v) = &self.variant {
            if let Some(tag) = &v.tag_field {
                out.push((tag.clone(), v.tag_type));
            }
            for arm in &v.arms {
                for f in &arm.fields {
                    out.push((f.name.clone(), f.ty));
                }
            }
            for f in &v.else_fields {
                out.push((f.name.clone(), f.ty));
            }
        }
        out
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RecordFieldSlot {
    pub name: String,
    pub ty: TypeId,
}

#[derive(Debug, Clone, PartialEq)]
pub struct VariantLayout {
    /// `None` when the source used the anonymous `CASE : T OF` form.
    pub tag_field: Option<String>,
    pub tag_type: TypeId,
    pub arms: Vec<VariantArmLayout>,
    /// Fields of the `ELSE` arm, if any.
    pub else_fields: Vec<RecordFieldSlot>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct VariantArmLayout {
    pub labels: Vec<VariantLabel>,
    pub fields: Vec<RecordFieldSlot>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum VariantLabel {
    Single(i128),
    Range(i128, i128),
}

/// Arena that owns all `TypeKind` instances. Built-ins are pre-
/// interned at construction. Constructed types (arrays, records,
/// pointers, classes) are added as sema discovers them.
#[derive(Debug, Default)]
pub struct TypeArena {
    types: Vec<TypeKind>,
    /// Map from `Builtin` to its pre-allocated `TypeId`. Allows
    /// `arena.builtin(Builtin::Integer)` in constant time.
    builtins: HashMap<Builtin, TypeId>,
}

impl TypeArena {
    pub fn new() -> Self {
        let mut a = Self::default();
        a.intern_builtins();
        a
    }

    fn intern_builtins(&mut self) {
        use Builtin::*;
        let all: &[Builtin] = &[
            Boolean, Char, Integer, Cardinal, Real, LongInt, LongCard, LongReal,
            Real32, Real16,
            Bitset, Proc, Nil, Complex, LongComplex, Integer8, Integer16,
            Integer32, Integer64, Cardinal8, Cardinal16, Cardinal32, Cardinal64,
            Byte, Word, Dword, Qword, Address, Adrint, Adrcard, Achar, Uchar,
            SysAddress, SysLoc, SysByte, SysWord, SysBitset,
        ];
        for &b in all {
            let id = self.alloc(TypeKind::Builtin(b));
            self.builtins.insert(b, id);
        }
    }

    /// Pre-allocate a slot for a forward-referenced type. Returns a
    /// stable `TypeId` whose kind starts out as `Unresolved`; sema
    /// patches the slot when the real definition becomes available.
    pub fn alloc_unresolved(&mut self) -> TypeId {
        self.alloc(TypeKind::Unresolved)
    }

    pub fn alloc(&mut self, kind: TypeKind) -> TypeId {
        let id = TypeId(self.types.len() as u32);
        self.types.push(kind);
        id
    }

    pub fn set(&mut self, id: TypeId, kind: TypeKind) {
        self.types[id.0 as usize] = kind;
    }

    pub fn get(&self, id: TypeId) -> &TypeKind {
        &self.types[id.0 as usize]
    }

    pub fn builtin(&self, b: Builtin) -> TypeId {
        self.builtins[&b]
    }

    /// Look up a pre-interned builtin by its source name (e.g. "INTEGER32").
    /// Used when re-interning a cached interface, where types arrive as names.
    pub fn builtin_by_name(&self, name: &str) -> Option<TypeId> {
        self.builtins.iter().find(|(b, _)| b.name() == name).map(|(_, &id)| id)
    }

    pub fn len(&self) -> usize {
        self.types.len()
    }

    pub fn is_empty(&self) -> bool {
        self.types.is_empty()
    }

    /// Inclusive `(MIN, MAX)` ordinal bounds of `ty`, or `None` for a
    /// non-ordinal (REAL, COMPLEX, a non-set/array, …). The single source of
    /// truth shared by sema, IR lowering, and codegen — so an array indexed by
    /// a bare built-in ordinal type (`ARRAY CHAR OF …`, `ARRAY BOOLEAN OF …`)
    /// is sized consistently everywhere.
    pub fn ordinal_bounds(&self, ty: TypeId) -> Option<(i128, i128)> {
        match self.get(ty) {
            TypeKind::Subrange { lo, hi, .. } => Some((*lo, *hi)),
            TypeKind::Enum { values, .. } => {
                let lo = values.iter().copied().min()?;
                let hi = values.iter().copied().max()?;
                Some((lo, hi))
            }
            // MIN/MAX of a SET type range over its element (base) type.
            TypeKind::Set { base, .. } => self.ordinal_bounds(*base),
            TypeKind::Builtin(b) => builtin_ordinal_bounds(*b),
            _ => None,
        }
    }

    /// Number of distinct values of an ordinal type, or `None` for a
    /// non-ordinal.
    pub fn ordinal_cardinality(&self, ty: TypeId) -> Option<i128> {
        self.ordinal_bounds(ty).and_then(|(lo, hi)| (hi - lo).checked_add(1))
    }
}

/// `(MIN, MAX)` for an ordinal built-in, matching codegen's widths. `None` for
/// a non-ordinal (REAL, COMPLEX, BITSET-as-value, …).
pub fn builtin_ordinal_bounds(b: Builtin) -> Option<(i128, i128)> {
    use Builtin::*;
    Some(match b {
        Boolean => (0, 1),
        Char | Uchar => (0, 0xFFFF),
        Achar | Byte | SysByte | SysLoc | Cardinal8 => (0, 0xFF),
        Integer8 => (-128, 127),
        Cardinal16 | Word => (0, 0xFFFF),
        Integer16 => (-32768, 32767),
        Cardinal32 | Dword => (0, 0xFFFF_FFFF),
        Integer32 => (-2_147_483_648, 2_147_483_647),
        Cardinal | Cardinal64 | Qword | LongCard | Address | Adrcard | SysAddress => {
            (0, u64::MAX as i128)
        }
        Integer | Integer64 | LongInt | Adrint => (i64::MIN as i128, i64::MAX as i128),
        // BITSET is the i256 bitmask: elements 0..255.
        Bitset | SysBitset => (0, 255),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arena_preinterns_every_builtin() {
        let a = TypeArena::new();
        // Every Builtin variant must have an entry; lookup must not
        // panic.
        for b in [Builtin::Integer, Builtin::Cardinal, Builtin::Char,
                  Builtin::Boolean, Builtin::Real, Builtin::SysAddress] {
            let id = a.builtin(b);
            assert!(matches!(a.get(id), TypeKind::Builtin(_)));
        }
    }

    #[test]
    fn cardinal_and_integer_are_distinct_families() {
        assert!(!Builtin::Cardinal.is_same_family(Builtin::Integer));
        assert!(Builtin::Cardinal.is_same_family(Builtin::Cardinal32));
        assert!(Builtin::Integer.is_same_family(Builtin::Integer64));
    }

    #[test]
    fn ordinals_recognised() {
        assert!(Builtin::Integer.is_ordinal());
        assert!(Builtin::Char.is_ordinal());
        assert!(Builtin::Boolean.is_ordinal());
        assert!(!Builtin::Real.is_ordinal());
    }

    #[test]
    fn alloc_then_set_pointer() {
        let mut a = TypeArena::new();
        let p = a.alloc_unresolved();
        let int_id = a.builtin(Builtin::Integer);
        a.set(p, TypeKind::Pointer { base: int_id });
        match a.get(p) {
            TypeKind::Pointer { base } => assert_eq!(*base, int_id),
            other => panic!("expected Pointer, got {other:?}"),
        }
    }
}
