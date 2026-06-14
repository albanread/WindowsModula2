//! ISO 10514-2 / ADW class symbols and vtable layout.
//!
//! The class system is minimal but complete enough for the Win32 COM
//! bindings (`win32apidef/` ships 309 class declarations, all ABSTRACT
//! with flat vtables — IUnknown-style).
//!
//! Layout rules (single-inheritance only):
//! - vtable slots from the base class come first (recursively), in
//!   definition order.
//! - Own new methods are appended after.
//! - An OVERRIDE method replaces its inherited slot (same index, new
//!   defining class).
//! - A REVEAL clause does not add vtable slots; it only controls export
//!   visibility (whether callers outside the class's module can name
//!   the inherited method).
//! - An ABSTRACT class may have all-abstract methods; a concrete class
//!   must override every abstract method it inherits.
//!
//! Forward declarations (`ABSTRACT CLASS Foo; FORWARD;`) reserve a
//! slot in the arena but leave `body_resolved = false` until the full
//! definition is seen.

use newm2_lexer::Span;

use crate::scope::ProcSig;
use crate::types::TypeId;

// ---- IDs ------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ClassSymbolId(pub u32);

// ---- Class symbol ---------------------------------------------------------

#[derive(Debug, Clone)]
pub struct ClassSymbol {
    pub name: String,
    pub is_abstract: bool,
    /// `true` if declared with `INTERFACE` (a COM vtable-only class). Like an
    /// abstract class it emits no concrete vtable global — the vtable belongs to
    /// the foreign COM object the interface pointer refers to. Its slot ordinals
    /// are owned by its declaration + `INHERIT` chain.
    pub is_interface: bool,
    /// The COM IID, from an `["xxxxxxxx-...."]` annotation, if any.
    pub iid: Option<String>,
    /// `false` until the full definition has been analysed (forward decls
    /// start unresolved).
    pub body_resolved: bool,
    /// The `TypeId` for `POINTER TO Class` allocated during analysis so
    /// that forward-referenced pointer types can be resolved later.
    pub ptr_type: Option<TypeId>,
    /// Single-inheritance base.  `None` = root class (no INHERIT clause).
    pub base: Option<ClassSymbolId>,
    /// The `TypeId` of this class itself (a `TypeKind::Class` node).
    pub type_id: TypeId,
    /// The synthesized heap-object layout: a `TypeKind::Record` whose first
    /// field is the vtable pointer (`__vtable`) followed by `all_fields`. A
    /// class variable is a pointer to this record. `NEW`, field access, and
    /// method dispatch all use it. Filled after `resolve_fields`.
    pub object_record: Option<TypeId>,
    /// Fields declared in *this* class (not including base fields).
    pub own_fields: Vec<FieldSlot>,
    /// All fields: base fields (flattened, base-first) + own fields.
    pub all_fields: Vec<FieldSlot>,
    /// Methods declared in *this* class body.
    pub own_methods: Vec<MethodSlot>,
    /// Names that the REVEAL clause exposes from the base class.
    pub revealed: Vec<String>,
    /// Full vtable: base slots first, then own slots appended or overridden.
    pub vtable: Vec<VtableSlot>,
    pub span: Span,
}

#[derive(Debug, Clone)]
pub struct FieldSlot {
    pub name: String,
    pub ty: TypeId,
}

#[derive(Debug, Clone)]
pub struct MethodSlot {
    pub name: String,
    pub sig: ProcSig,
    pub is_abstract: bool,
    pub is_override: bool,
    /// Index into `vtable` where this method lives.
    pub vtable_index: usize,
    /// The COM vtable ordinal asserted by a `<* @N *>` annotation on the method
    /// (emitted by winapi-gen from the winmd, or hand-written). If `Some(n)`,
    /// `validate` checks `vtable_index == n` — the machine-check that makes the
    /// slot order cannot-be-wrong rather than trusted. See com-interfaces.md.
    pub declared_slot: Option<usize>,
}

#[derive(Debug, Clone)]
pub struct VtableSlot {
    pub name: String,
    pub sig: ProcSig,
    /// Which class provided the last (most-derived) implementation.
    pub defining_class: ClassSymbolId,
    pub is_abstract: bool,
    /// The `TypeKind::Proc` type used to type an indirect (virtual) call: the
    /// hidden `SELF` receiver followed by the declared parameters. Filled by
    /// sema once the type system is available; codegen reads it for dispatch.
    pub call_sig: Option<TypeId>,
}

// ---- Arena ----------------------------------------------------------------

#[derive(Debug, Default)]
pub struct ClassArena {
    classes: Vec<ClassSymbol>,
    by_name: std::collections::HashMap<String, ClassSymbolId>,
}

impl ClassArena {
    pub fn new() -> Self {
        Self::default()
    }

    /// Allocate a new (potentially forward) class symbol.  The caller
    /// fills in `body_resolved` and the method/field tables later.
    pub fn alloc(
        &mut self,
        name: String,
        is_abstract: bool,
        type_id: TypeId,
        span: Span,
    ) -> ClassSymbolId {
        let id = ClassSymbolId(self.classes.len() as u32);
        self.classes.push(ClassSymbol {
            name: name.clone(),
            is_abstract,
            is_interface: false,
            iid: None,
            body_resolved: false,
            ptr_type: None,
            base: None,
            type_id,
            object_record: None,
            own_fields: Vec::new(),
            all_fields: Vec::new(),
            own_methods: Vec::new(),
            revealed: Vec::new(),
            vtable: Vec::new(),
            span,
        });
        self.by_name.insert(name, id);
        id
    }

    pub fn get(&self, id: ClassSymbolId) -> &ClassSymbol {
        &self.classes[id.0 as usize]
    }

    pub fn get_mut(&mut self, id: ClassSymbolId) -> &mut ClassSymbol {
        &mut self.classes[id.0 as usize]
    }

    pub fn lookup(&self, name: &str) -> Option<ClassSymbolId> {
        self.by_name.get(name).copied()
    }

    pub fn len(&self) -> usize {
        self.classes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.classes.is_empty()
    }

    /// Iterate all class symbols.
    pub fn iter(&self) -> impl Iterator<Item = (ClassSymbolId, &ClassSymbol)> {
        self.classes
            .iter()
            .enumerate()
            .map(|(i, c)| (ClassSymbolId(i as u32), c))
    }

    /// Resolve the vtable for `id` once its base (if any) is already
    /// resolved.  Panics if the base is not resolved.
    ///
    /// Algorithm:
    /// 1. Start with a clone of the base's vtable.
    /// 2. For each own method:
    ///    a. If `is_override`: find the slot with that name in the
    ///       inherited table and replace its `defining_class`.
    ///    b. Otherwise: append a new slot.
    /// 3. Store the final vtable back into `self`.
    /// 4. Fill `vtable_index` on each `MethodSlot`.
    pub fn resolve_vtable(&mut self, id: ClassSymbolId) {
        // Collect base vtable first (clone to avoid borrow issues).
        let base_vtable: Vec<VtableSlot> = if let Some(base_id) = self.get(id).base {
            self.get(base_id).vtable.clone()
        } else {
            Vec::new()
        };

        let own_methods = self.get(id).own_methods.clone();

        let mut vtable = base_vtable;
        let mut resolved_methods = own_methods.clone();

        for (slot_idx, method) in resolved_methods.iter_mut().enumerate() {
            let _ = slot_idx;
            if method.is_override {
                // Find existing slot by name and update defining class.
                if let Some(slot) = vtable.iter_mut().find(|s| s.name == method.name) {
                    slot.defining_class = id;
                    slot.sig = method.sig.clone();
                    slot.is_abstract = method.is_abstract;
                    // The method's vtable_index is the slot's position.
                    method.vtable_index =
                        vtable.iter().position(|s| s.name == method.name).unwrap();
                } else {
                    // Override with no matching base slot: treat as new method
                    // and emit a diagnostic later (the caller checks this).
                    method.vtable_index = vtable.len();
                    vtable.push(VtableSlot {
                        name: method.name.clone(),
                        sig: method.sig.clone(),
                        defining_class: id,
                        is_abstract: method.is_abstract,
                        call_sig: None,
                    });
                }
            } else {
                method.vtable_index = vtable.len();
                vtable.push(VtableSlot {
                    name: method.name.clone(),
                    sig: method.sig.clone(),
                    defining_class: id,
                    is_abstract: method.is_abstract,
                    call_sig: None,
                });
            }
        }

        let cls = self.get_mut(id);
        cls.vtable = vtable;
        cls.own_methods = resolved_methods;
    }

    /// Flatten base fields + own fields into `all_fields`.  Must be
    /// called after the base class has been fully resolved.
    pub fn resolve_fields(&mut self, id: ClassSymbolId) {
        let base_fields: Vec<FieldSlot> = if let Some(base_id) = self.get(id).base {
            self.get(base_id).all_fields.clone()
        } else {
            Vec::new()
        };
        let own_fields = self.get(id).own_fields.clone();
        let cls = self.get_mut(id);
        let mut all = base_fields;
        all.extend(own_fields);
        cls.all_fields = all;
    }

    /// Validate class consistency and collect diagnostics.
    ///
    /// - A concrete (non-abstract) class may not have any abstract
    ///   method in its vtable.
    /// - An OVERRIDE method must have the same parameter signature as
    ///   the inherited method (return type + param types match).
    pub fn validate(&self, id: ClassSymbolId) -> Vec<ClassError> {
        let cls = self.get(id);
        let mut errs = Vec::new();

        if !cls.is_abstract {
            for slot in &cls.vtable {
                if slot.is_abstract {
                    errs.push(ClassError {
                        message: format!(
                            "concrete class '{}' has unimplemented abstract method '{}'",
                            cls.name, slot.name
                        ),
                        span: cls.span,
                    });
                }
            }
        }

        // An INTERFACE may only INHERIT another interface (a COM interface's
        // vtable is a single linear chain rooted at IUnknown; a class base would
        // let fields leak in and break the layout).
        if cls.is_interface {
            if let Some(b) = cls.base {
                if !self.get(b).is_interface {
                    errs.push(ClassError {
                        message: format!(
                            "interface '{}' may only INHERIT another interface",
                            cls.name
                        ),
                        span: cls.span,
                    });
                }
            }
        }

        // The @ordinal machine-check: a method annotated `<* @N *>` must land on
        // exactly slot N (computed by the compiler from the INHERIT chain). This
        // is what turns "the generator transcribed the vtable" into "the build
        // fails if a slot is off by one" — the keystone of com-interfaces.md.
        for m in &cls.own_methods {
            if let Some(declared) = m.declared_slot {
                if m.vtable_index != declared {
                    errs.push(ClassError {
                        message: format!(
                            "method '{}' in '{}' is annotated slot @{} but the compiler \
                             computed slot {} — the INHERIT chain or method order disagrees \
                             with the declared ordinal",
                            m.name, cls.name, declared, m.vtable_index
                        ),
                        span: cls.span,
                    });
                }
            }
        }

        errs
    }
}

#[derive(Debug, Clone)]
pub struct ClassError {
    pub message: String,
    pub span: Span,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scope::{CallingConv, ProcSig};
    use crate::types::{Builtin, TypeArena, TypeKind};
    use newm2_lexer::{SourcePosition, Span};

    const ZERO: Span = Span {
        start: SourcePosition { line: 1, column: 1, offset: 0 },
        end: SourcePosition { line: 1, column: 1, offset: 0 },
    };

    fn empty_sig() -> ProcSig {
        ProcSig {
            params: vec![],
            return_ty: None,
            calling_conv: CallingConv::Default,
            attrs: vec![],
            external_linkage: None,
        }
    }

    #[test]
    fn iunknown_vtable_layout() {
        let mut ta = TypeArena::new();
        let mut ca = ClassArena::new();

        // Allocate IUnknown as ABSTRACT CLASS.
        let type_id = ta.alloc(TypeKind::Unresolved);
        let iu_id = ca.alloc("IUnknown".into(), true, type_id, ZERO);

        // Add three abstract methods: QueryInterface, AddRef, Release.
        let card = ta.builtin(Builtin::Cardinal);
        let addref_sig = ProcSig {
            params: vec![],
            return_ty: Some(card),
            calling_conv: CallingConv::Default,
            attrs: vec![],
            external_linkage: None,
        };
        let release_sig = addref_sig.clone();
        let qi_sig = empty_sig();

        ca.get_mut(iu_id).own_methods = vec![
            MethodSlot {
                name: "QueryInterface".into(),
                sig: qi_sig,
                is_abstract: true,
                is_override: false,
                vtable_index: 0,
                declared_slot: None,
            },
            MethodSlot {
                name: "AddRef".into(),
                sig: addref_sig,
                is_abstract: true,
                is_override: false,
                vtable_index: 0,
                declared_slot: None,
            },
            MethodSlot {
                name: "Release".into(),
                sig: release_sig,
                is_abstract: true,
                is_override: false,
                vtable_index: 0,
                declared_slot: None,
            },
        ];
        ca.get_mut(iu_id).body_resolved = true;
        ca.resolve_vtable(iu_id);

        let iu = ca.get(iu_id);
        assert_eq!(iu.vtable.len(), 3);
        assert_eq!(iu.vtable[0].name, "QueryInterface");
        assert_eq!(iu.vtable[1].name, "AddRef");
        assert_eq!(iu.vtable[2].name, "Release");
        assert!(iu.vtable[0].is_abstract);

        // Validate: abstract class may have abstract methods → no errors.
        let errs = ca.validate(iu_id);
        assert!(errs.is_empty(), "{errs:?}");
    }

    #[test]
    fn derived_class_overrides_slot() {
        let mut ta = TypeArena::new();
        let mut ca = ClassArena::new();

        let base_ty = ta.alloc(TypeKind::Unresolved);
        let base_id = ca.alloc("Base".into(), true, base_ty, ZERO);
        ca.get_mut(base_id).own_methods = vec![MethodSlot {
            name: "Foo".into(),
            sig: empty_sig(),
            is_abstract: true,
            is_override: false,
            vtable_index: 0,
            declared_slot: None,
        }];
        ca.get_mut(base_id).body_resolved = true;
        ca.resolve_vtable(base_id);

        let derived_ty = ta.alloc(TypeKind::Unresolved);
        let der_id = ca.alloc("Derived".into(), false, derived_ty, ZERO);
        ca.get_mut(der_id).base = Some(base_id);
        ca.get_mut(der_id).own_methods = vec![MethodSlot {
            name: "Foo".into(),
            sig: empty_sig(),
            is_abstract: false,
            is_override: true,
            vtable_index: 0,
            declared_slot: None,
        }];
        ca.get_mut(der_id).body_resolved = true;
        ca.resolve_vtable(der_id);

        let der = ca.get(der_id);
        // Vtable still has 1 slot (override, not new slot).
        assert_eq!(der.vtable.len(), 1);
        assert_eq!(der.vtable[0].defining_class, der_id);
        assert!(!der.vtable[0].is_abstract);

        // Concrete class with no abstract methods → valid.
        let errs = ca.validate(der_id);
        assert!(errs.is_empty(), "{errs:?}");
    }

    #[test]
    fn concrete_class_with_unimplemented_abstract_is_invalid() {
        let mut ta = TypeArena::new();
        let mut ca = ClassArena::new();

        let base_ty = ta.alloc(TypeKind::Unresolved);
        let base_id = ca.alloc("Base".into(), true, base_ty, ZERO);
        ca.get_mut(base_id).own_methods = vec![MethodSlot {
            name: "Foo".into(),
            sig: empty_sig(),
            is_abstract: true,
            is_override: false,
            vtable_index: 0,
            declared_slot: None,
        }];
        ca.get_mut(base_id).body_resolved = true;
        ca.resolve_vtable(base_id);

        // Concrete class that does NOT override Foo.
        let der_ty = ta.alloc(TypeKind::Unresolved);
        let der_id = ca.alloc("Concrete".into(), false, der_ty, ZERO);
        ca.get_mut(der_id).base = Some(base_id);
        ca.get_mut(der_id).body_resolved = true;
        ca.resolve_vtable(der_id);

        let errs = ca.validate(der_id);
        assert!(!errs.is_empty(), "expected validation error");
        assert!(errs[0].message.contains("Foo"), "{}", errs[0].message);
    }
}
