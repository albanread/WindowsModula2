//! Runtime type information (RTTI) for native classes: the per-class
//! `{Class}.typeinfo` descriptor and the subclass-of-or-equal test that backs
//! `ISMEMBER` and the `GUARD` statement.
//!
//! RTTI is **native-class-only**: COM interfaces carry no `{Class}.typeinfo`
//! (they are discriminated by `QueryInterface`), so this module never touches
//! the COM ABI. Each native class — concrete *and* abstract — gets exactly one
//! `{Class}.typeinfo` constant global; the concrete class's vtable holds a
//! pointer to it at physical slot 0 (methods follow at slot 1+).

/// The per-class type descriptor. Layout is **frozen ABI**: codegen lays out
/// `{Class}.typeinfo` as `{ ptr, ptr, i64 }` to match this `#[repr(C)]` exactly.
#[repr(C)]
pub struct TypeInfo {
    /// Pointer to the base class's `{Base}.typeinfo`, or null at a root.
    pub parent: *const TypeInfo,
    /// Pointer to the interned, NUL-terminated class name (reflection substrate).
    pub name: *const u8,
    /// 0 at a root, `parent.depth + 1` otherwise — an ancestor-walk early-out.
    pub depth: u64,
}

/// Subclass-of-or-equal test: TRUE iff `cand`'s class is `target`'s class or a
/// descendant of it — a linear ancestor walk up the single-inheritance parent
/// chain.
///
/// Null-tolerant: a null candidate (a `NIL`/`EMPTY` object) is a member of
/// nothing, and a null target tests nothing — both yield FALSE. The `depth`
/// field gives a free early-out: once the walk rises strictly above the
/// target's depth without a pointer-identity match, no ancestor can be the
/// target.
///
/// # Safety
/// `cand` and `target` must each be null or point at a valid [`TypeInfo`] whose
/// `parent` chain is a null-terminated acyclic list — exactly what codegen
/// emits (deduped one-per-class globals, root parent = null).
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_rtti_isa(
    cand: *const TypeInfo,
    target: *const TypeInfo,
) -> bool {
    if cand.is_null() || target.is_null() {
        return false;
    }
    let target_depth = unsafe { (*target).depth };
    let mut p = cand;
    while !p.is_null() {
        let ti = unsafe { &*p };
        if ti.depth < target_depth {
            // We have risen above the target's level: the target (deeper or
            // equal) cannot be an ancestor of `cand` from here on.
            return false;
        }
        if std::ptr::eq(p, target) {
            return true;
        }
        p = ti.parent;
    }
    false
}

/// Null-safe extraction of an object's `{Class}.typeinfo` pointer, for
/// `ISMEMBER`/`GUARD` operands that are object values. `obj` is the object
/// reference: field 0 holds the vtable pointer (which points at the first
/// method — physical element 1), and the typeinfo pointer sits one slot before
/// it (`vtable[-1]`, physical element 0). Returns null for a null object or a
/// null vtable (a method-less class), so the following `nm2_rtti_isa` yields
/// FALSE.
///
/// # Safety
/// `obj` must be null or a valid object reference produced by `NEW` on a native
/// class (field 0 = a typeinfo-prefixed vtable pointer, as codegen emits).
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_typeinfo_of(obj: *const u8) -> *const TypeInfo {
    if obj.is_null() {
        return std::ptr::null();
    }
    // field 0 = the vtable pointer (points at element 1, the first method).
    let vptr = unsafe { *(obj as *const *const *const TypeInfo) };
    if vptr.is_null() {
        return std::ptr::null();
    }
    // element 0 (vtable[-1]) holds the {Class}.typeinfo pointer.
    unsafe { *vptr.sub(1) }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Build a 3-level chain Root -> Mid -> Leaf (depths 0,1,2) and a sibling
    // Other -> Root-level (depth 0) to check cross-subtree rejection.
    fn ti(parent: *const TypeInfo, depth: u64) -> Box<TypeInfo> {
        Box::new(TypeInfo { parent, name: std::ptr::null(), depth })
    }

    #[test]
    fn ancestor_walk() {
        let root = ti(std::ptr::null(), 0);
        let mid = ti(&*root as *const _, 1);
        let leaf = ti(&*mid as *const _, 2);
        let other = ti(std::ptr::null(), 0);

        let (rp, mp, lp, op) =
            (&*root as *const _, &*mid as *const _, &*leaf as *const _, &*other as *const _);

        unsafe {
            // reflexive + descendant -> ancestor
            assert!(nm2_rtti_isa(lp, lp));
            assert!(nm2_rtti_isa(lp, mp));
            assert!(nm2_rtti_isa(lp, rp));
            assert!(nm2_rtti_isa(mp, rp));
            // ancestor is NOT a member of its descendant
            assert!(!nm2_rtti_isa(rp, lp));
            assert!(!nm2_rtti_isa(mp, lp));
            // unrelated subtree
            assert!(!nm2_rtti_isa(lp, op));
            assert!(!nm2_rtti_isa(op, rp));
            // null tolerance
            assert!(!nm2_rtti_isa(std::ptr::null(), rp));
            assert!(!nm2_rtti_isa(lp, std::ptr::null()));
        }
    }
}
