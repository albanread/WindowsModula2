//! IR -> LLVM IR lowering for NewM2.
//!
//! Takes a fully-analysed [`IrModule`] (produced by `newm2-ir`) and emits
//! an `inkwell::module::Module` ready for JIT compilation or object-file
//! emission.
//!
//! ## Scope (`--no-gc`)
//!
//! - Scalars: INTEGER (i64), CARDINAL (i64/unsigned ops), BOOLEAN (i1),
//!   CHAR/ACHAR/UCHAR (i8/i16), REAL/LONGREAL (f64), ADDRESS (ptr).
//! - Arithmetic: Add/Sub/Mul (signed + unsigned), Div/Mod (Wirth floored),
//!   Quot/Rem (C-truncating), bitwise ops, comparisons.
//! - Control flow: Goto, CondBr, Switch, Return, Halt (trap).
//! - Calls: direct + indirect, VAR param marshalling (pass pointer).
//! - Aggregates: Alloca + Store for locals (params pre-stored in prologue).
//! - Globals: StringConst -> global [N x i8]; StaticVar -> global.
//! - GC instructions (GcRoot, GcSafePoint, Pin/Unpin): no-ops under --no-gc.
//!
//! ## Param convention
//! The IR lowers every procedure parameter to an Alloca slot in the entry
//! block. The first `func.params.len()` allocas in block 0 are parameter
//! slots; codegen emits `store param_i -> alloca_i` in the entry prologue so
//! that downstream `Load { ptr: alloca_i }` correctly retrieves the parameter.

use std::collections::HashMap;

use new_asm;
use inkwell::FloatPredicate;
use inkwell::IntPredicate;
use inkwell::builder::Builder;
use inkwell::context::Context;
use inkwell::module::Module;
use inkwell::targets::{CodeModel, InitializationConfig, RelocMode, Target, TargetMachine};
use inkwell::OptimizationLevel;
use inkwell::types::{BasicMetadataTypeEnum, BasicType, BasicTypeEnum, FunctionType};
use inkwell::values::{BasicMetadataValueEnum, BasicValueEnum, FunctionValue, PointerValue};
use newm2_ir::{
    BinOp, CastKind, ConstVal, Func, IrModule, MemoryMode, SetOpKind, Terminator, UnaryOp,
    ValueId,
};
use newm2_ir::inst::{Inst, VecIntrin};
use newm2_sema::types::{Builtin, TypeKind};
use newm2_sema::{ConstValue, SemaResult, TypeArena};

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

/// Options controlling the LLVM codegen pass.
#[derive(Debug, Clone, Copy)]
pub struct CodegenOptions {
    pub memory_mode: MemoryMode,
    /// Optimisation level passed to the JIT / MC layer (0-3).
    pub opt_level: u32,
    /// Ahead-of-time object emission (vs. JIT). In AOT mode class vtables are
    /// emitted as constant function-pointer arrays the static linker resolves
    /// (the JIT path instead patches zero-initialized vtables post-compile).
    pub aot: bool,
    /// Route NEW/DISPOSE through the self-hosted Modula-2 heap (`Heap.Alloc` /
    /// `Heap.Free`) instead of the Rust runtime allocator (`nm2_alloc` /
    /// `nm2_free`). Manual (non-GC) mode only; the driver force-links the `Heap`
    /// module when this is set. Off by default.
    pub m2_heap: bool,
    /// `--protect-heap`: emit a `nm2_heap_guard_force_on()` call at program entry so
    /// the AOT exe self-enables the runtime heap guard (no NM2_PROTECT_HEAP needed).
    pub protect_heap: bool,
}

impl Default for CodegenOptions {
    fn default() -> Self {
        CodegenOptions {
            memory_mode: MemoryMode::NoGc,
            opt_level: 0,
            aot: false,
            m2_heap: false,
            protect_heap: false,
        }
    }
}

/// Initialise LLVM native target once per process.
pub fn init_llvm() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        use llvm_sys::execution_engine::LLVMLinkInMCJIT;
        unsafe { LLVMLinkInMCJIT() };
        Target::initialize_native(&InitializationConfig::default())
            .expect("LLVM native target init failed");
    });
}

/// Lower a single IrModule into an `inkwell::module::Module`.
///
/// The returned module is owned by `ctx` - both must outlive the JIT engine.
pub fn emit_module<'ctx>(
    ctx: &'ctx Context,
    ir: &IrModule,
    sema: &SemaResult,
    opts: CodegenOptions,
) -> Module<'ctx> {
    init_llvm();
    let module = ctx.create_module(&ir.name);
    // Stamp the host target's data layout (and triple) onto the module. Without
    // it, the IR optimization pipeline (--opt) computes struct field offsets and
    // alignments with LLVM's *default* layout (e.g. i64 4-aligned), which disagrees
    // with the Windows-x64 target layout the backend uses (i64 8-aligned) — so
    // optimizer-folded GEPs on mixed-width records land on the wrong bytes. With the
    // layout present, the optimizer and backend agree at every opt level.
    {
        let triple = TargetMachine::get_default_triple();
        if let Ok(target) = Target::from_triple(&triple) {
            if let Some(tm) = target.create_target_machine(
                &triple,
                "generic",
                "",
                OptimizationLevel::Default,
                RelocMode::Default,
                CodeModel::Default,
            ) {
                module.set_data_layout(&tm.get_target_data().get_data_layout());
                module.set_triple(&triple);
            }
        }
    }
    let builder = ctx.create_builder();
    let types = &sema.types;
    let cg = Codegen { ctx, module: &module, builder: &builder, types, ir, opts };

    // Pass 1: declare all globals (functions + static vars + string consts).
    cg.declare_globals();

    // Pass 2: lower all function bodies.
    let funcs: Vec<&Func> = ir.funcs.iter().filter(|f| !f.is_extern).collect();
    for func in funcs {
        cg.emit_func(func);
    }

    // Pass 3 (GC mode only): emit `{mod}.init_roots` — registers all
    // pointer-typed module-level static globals with the GC root table.
    // When module-level VARs are stack-allocated there are no Static globals,
    // so we emit an empty registration (name only) — the call site in lib.rs
    // is then safe to invoke unconditionally.
    if opts.memory_mode == MemoryMode::Gc {
        cg.emit_init_roots();
    }

    // Pass 4: emit ASM procedure bodies as `module asm` blobs and add
    // matching `declare`s for type-checked call sites.
    for proc in &ir.asm_procs {
        let asm_str = new_asm::build_module_asm_string(proc);
        unsafe {
            inkwell::llvm_sys::core::LLVMAppendModuleInlineAsm(
                module.as_mut_ptr(),
                asm_str.as_ptr() as *const std::ffi::c_char,
                asm_str.len(),
            );
        }
        emit_asm_proc_declare(&module, ctx, proc);
    }

    drop(cg);
    module
}

fn emit_asm_proc_declare<'ctx>(
    module: &Module<'ctx>,
    ctx: &'ctx Context,
    proc: &new_asm::AsmProc,
) {
    let i64_t = ctx.i64_type();
    let f64_t = ctx.f64_type();
    let f32x4_t = ctx.f32_type().vec_type(4);
    let f32x8_t = ctx.f32_type().vec_type(8);
    let param_types: Vec<inkwell::types::BasicMetadataTypeEnum<'ctx>> = proc.params.iter()
        .map(|p| match p.ty {
            new_asm::AsmType::Float => f64_t.into(),
            new_asm::AsmType::FQuad => f32x4_t.into(),
            new_asm::AsmType::FOct => f32x8_t.into(),
            new_asm::AsmType::Word => i64_t.into(),
        })
        .collect();
    let fn_type = match proc.return_type {
        new_asm::AsmRetType::Void => ctx.void_type().fn_type(&param_types, false),
        new_asm::AsmRetType::Float => f64_t.fn_type(&param_types, false),
        new_asm::AsmRetType::FQuad => f32x4_t.fn_type(&param_types, false),
        new_asm::AsmRetType::FOct => f32x8_t.fn_type(&param_types, false),
        new_asm::AsmRetType::Word => i64_t.fn_type(&param_types, false),
    };
    let f = module.add_function(&proc.name, fn_type, None);
    let kind_id = inkwell::attributes::Attribute::get_named_enum_kind_id("uwtable");
    let attr = ctx.create_enum_attribute(kind_id, 2);
    f.add_attribute(inkwell::attributes::AttributeLoc::Function, attr);
}

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

struct Codegen<'ctx, 'ir> {
    ctx: &'ctx Context,
    module: &'ir Module<'ctx>,
    builder: &'ir Builder<'ctx>,
    types: &'ir TypeArena,
    ir: &'ir IrModule,
    opts: CodegenOptions,
}

impl<'ctx, 'ir> Codegen<'ctx, 'ir> {
    // ---- Type mapping -------------------------------------------------------

    fn llvm_type(&self, ty: newm2_sema::TypeId) -> BasicTypeEnum<'ctx> {
        let kind = self.types.get(ty);
        match kind {
            TypeKind::Builtin(b) => self.builtin_type(*b),
            TypeKind::Pointer { .. } | TypeKind::Proc { .. } => {
                self.ctx.ptr_type(inkwell::AddressSpace::default()).into()
            }
            TypeKind::Array { indices, base } => {
                let elem = self.llvm_type(*base);
                // Use the shared ordinal cardinality so the allocated storage
                // matches sema's `type_size_bytes` for *every* index type — a
                // subrange, an enumeration, or a bare built-in ordinal
                // (`ARRAY CHAR OF …` = 65536, was wrongly collapsed to 1).
                // LLVM array arity is u32, so saturate rather than truncate: a
                // count past u32::MAX would `as u32` wrap (e.g. to 0 → a
                // zero-sized global → out-of-bounds writes). Sema rejects such
                // oversized arrays up front (see type formation); this is the
                // belt-and-suspenders floor so codegen never silently 0-sizes.
                let mut count: u128 = 1;
                for &idx in indices {
                    let dim = self.types.ordinal_cardinality(idx).unwrap_or(1).max(0) as u128;
                    count = count.saturating_mul(dim);
                }
                let count = count.min(u32::MAX as u128) as u32;
                elem.array_type(count).into()
            }
            TypeKind::Record(layout) => {
                // Flattened order = fixed fields, tag, arm fields, else fields —
                // so the variant part occupies real struct slots (was ignored,
                // giving the payload zero bytes and aliasing field 0).
                let fields: Vec<BasicTypeEnum<'ctx>> = layout
                    .flatten_fields()
                    .iter()
                    .map(|(_, ty)| self.llvm_type(*ty))
                    .collect();
                self.ctx.struct_type(&fields, false).into()
            }
            TypeKind::Enum { .. } => self.ctx.i32_type().into(),
            TypeKind::Subrange { host, .. } => self.llvm_type(*host),
            // SET values (incl. SET OF CHAR over the full 0..255 range) are a
            // single 256-bit integer; LLVM lowers i256 set ops to wide SIMD on
            // capable x86_64 and to i64 sequences elsewhere.
            TypeKind::Set { .. } => self.set_int_type().into(),
            // SIMD lane vector: `<lanes x base>`. The base is a float builtin, so
            // its LLVM type is a FloatType we can vectorise directly.
            TypeKind::Vector { lanes, base } => {
                let elem = self.llvm_type(*base);
                match elem {
                    BasicTypeEnum::FloatType(ft) => ft.vec_type(*lanes).into(),
                    BasicTypeEnum::IntType(it) => it.vec_type(*lanes).into(),
                    // Non-numeric lane element — should be rejected by sema.
                    other => other,
                }
            }
            TypeKind::OpenArray { .. } => {
                self.ctx.ptr_type(inkwell::AddressSpace::default()).into()
            }
            TypeKind::Class { .. } => {
                self.ctx.ptr_type(inkwell::AddressSpace::default()).into()
            }
            TypeKind::Unresolved => {
                self.ctx.ptr_type(inkwell::AddressSpace::default()).into()
            }
        }
    }

    /// The integer type backing every SET value — a single 256-bit integer,
    /// wide enough for `SET OF CHAR` over the full 0..255 range. BITSET shares
    /// it so set operations never hit a width mismatch.
    fn set_int_type(&self) -> inkwell::types::IntType<'ctx> {
        self.ctx
            .custom_width_int_type(std::num::NonZero::new(256u32).expect("non-zero"))
            .unwrap()
    }

    fn builtin_type(&self, b: Builtin) -> BasicTypeEnum<'ctx> {
        use Builtin::*;
        match b {
            Boolean => self.ctx.bool_type().into(),
            // CHAR is a Windows-wide (UTF-16) code unit on this Windows-aimed
            // build; ACHAR stays the 8-bit narrow unit.
            Char | Uchar => self.ctx.i16_type().into(),
            Byte | SysByte | Achar => self.ctx.i8_type().into(),
            Integer8 | Cardinal8 => self.ctx.i8_type().into(),
            Integer16 | Cardinal16 | Word => self.ctx.i16_type().into(),
            Integer32 | Cardinal32 | Dword => self.ctx.i32_type().into(),
            Integer | Cardinal | Integer64 | Cardinal64 | Qword | LongInt | LongCard => {
                self.ctx.i64_type().into()
            }
            // BITSET / SYSTEM.BITSET share the 256-bit set representation so
            // they interoperate with `SET OF` values (e.g. SET OF CHAR) in
            // set operations without width mismatches. See TypeKind::Set.
            Bitset | SysBitset => self.set_int_type().into(),
            Real | LongReal => self.ctx.f64_type().into(),
            // True narrow IEEE floats (Win32 FLOAT, SIMD/matrix).
            Real32 => self.ctx.f32_type().into(),
            Real16 => self.ctx.f16_type().into(),
            Address | SysAddress | SysLoc | Adrint | Adrcard | Nil | Proc => {
                self.ctx.ptr_type(inkwell::AddressSpace::default()).into()
            }
            Complex | LongComplex => self
                .ctx
                .struct_type(
                    &[self.ctx.f64_type().into(), self.ctx.f64_type().into()],
                    false,
                )
                .into(),
            SysWord => self.ctx.i64_type().into(),
        }
    }

    fn llvm_fn_type(
        &self,
        params: &[newm2_ir::IrParam],
        return_ty: Option<newm2_sema::TypeId>,
    ) -> FunctionType<'ctx> {
        self.llvm_fn_type_with_abi(params, return_ty, false)
    }

    /// Like `llvm_fn_type`, but honours a foreign-C-ABI flag. NewModula2's
    /// native ABI expands each open-array param to a `(ptr, i64)` pair — the
    /// pointer plus the synthesised HIGH companion. `EXTERNAL FROM "x.dll"`
    /// procedures use the bare C ABI (no companion). When lowering already
    /// emitted an explicit `name$high` companion param it is taken as-is on
    /// the next iteration rather than auto-added here.
    fn llvm_fn_type_with_abi(
        &self,
        params: &[newm2_ir::IrParam],
        return_ty: Option<newm2_sema::TypeId>,
        foreign_c_abi: bool,
    ) -> FunctionType<'ctx> {
        self.llvm_fn_type_with_abi_var(params, return_ty, foreign_c_abi, false)
    }

    /// Like `llvm_fn_type_with_abi`, but `variadic` declares the LLVM function
    /// type `isVarArg` (for C-style variadic externs such as `printf`).
    fn llvm_fn_type_with_abi_var(
        &self,
        params: &[newm2_ir::IrParam],
        return_ty: Option<newm2_sema::TypeId>,
        foreign_c_abi: bool,
        variadic: bool,
    ) -> FunctionType<'ctx> {
        let i64_ty = self.ctx.i64_type();
        let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
        let mut param_types: Vec<BasicMetadataTypeEnum<'ctx>> =
            Vec::with_capacity(params.len());
        let mut idx = 0;
        while idx < params.len() {
            let p = &params[idx];
            let is_open_array =
                matches!(self.types.get(p.ty), TypeKind::OpenArray { .. });
            if p.is_var {
                param_types.push(ptr_ty.into());
            } else {
                param_types.push(self.llvm_type(p.ty).into());
            }
            if is_open_array && !foreign_c_abi {
                let next_is_companion = params
                    .get(idx + 1)
                    .map(|q| q.name.ends_with("$high"))
                    .unwrap_or(false);
                if !next_is_companion {
                    param_types.push(i64_ty.into());
                }
            }
            idx += 1;
        }
        match return_ty {
            None => self.ctx.void_type().fn_type(&param_types, variadic),
            Some(ty) => self.llvm_type(ty).fn_type(&param_types, variadic),
        }
    }

    /// Function type for an indirect (procedure-pointer) call, derived from the
    /// PROCEDURE type `sig`. Matches the native ABI used for direct calls: a
    /// VAR param is a pointer, an open-array param is a (ptr, i64-HIGH) pair.
    fn indirect_fn_type(&self, sig: newm2_sema::TypeId) -> FunctionType<'ctx> {
        let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
        let i64_ty = self.ctx.i64_type();
        if let TypeKind::Proc { params, return_ty } = self.types.get(sig) {
            let mut param_types: Vec<BasicMetadataTypeEnum<'ctx>> = Vec::new();
            for p in params {
                let is_open = matches!(self.types.get(p.ty), TypeKind::OpenArray { .. });
                if p.mode == newm2_sema::types::ParamMode::Var {
                    param_types.push(ptr_ty.into());
                } else {
                    param_types.push(self.llvm_type(p.ty).into());
                }
                if is_open {
                    param_types.push(i64_ty.into());
                }
            }
            match return_ty {
                None => self.ctx.void_type().fn_type(&param_types, false),
                Some(t) => self.llvm_type(*t).fn_type(&param_types, false),
            }
        } else {
            // Unknown signature: fall back to a variadic i64(...) type.
            i64_ty.fn_type(&[], true)
        }
    }

    // ---- Global declarations ------------------------------------------------

    fn declare_globals(&self) {
        use newm2_ir::module::Global;
        let defined_funcs: std::collections::HashSet<&str> = self
            .ir
            .funcs
            .iter()
            .map(|f| f.name.as_str())
            .collect();

        // RTTI pre-pass: declare every {Class}.typeinfo global (so a vtable's
        // physical slot 0 can reference it below), then fill initializers (a
        // typeinfo's `parent` field references another, possibly cross-module,
        // {Base}.typeinfo). Layout `{ ptr parent, ptr name, i64 depth }` matches
        // newm2_runtime::rtti::TypeInfo exactly.
        {
            use newm2_ir::module::Global;
            let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
            let i64_t = self.ctx.i64_type();
            let i8_t = self.ctx.i8_type();
            let ti_struct =
                self.ctx.struct_type(&[ptr_ty.into(), ptr_ty.into(), i64_t.into()], false);
            // 1. declare all (one-per-class, coalescing) so cross-refs resolve.
            for g in &self.ir.globals {
                if let Global::TypeInfo { class_name, .. } = g {
                    let name = format!("{}.typeinfo", class_name);
                    if self.module.get_global(&name).is_none() {
                        let gv = self.module.add_global(ti_struct, None, &name);
                        gv.set_constant(true);
                        // weak_odr: an ABSTRACT class (e.g. a COM-interface mirror
                        // like IMalloc) is independently redeclared in several
                        // modules, each emitting its typeinfo — so the linkage must
                        // COALESCE (external would multiply-define at link). After
                        // LLVMLinkModules2 coalesces the duplicates, the JIT path
                        // promotes the survivor back to external (see
                        // promote_typeinfo_linkage) so RTDyld materialises it.
                        gv.set_linkage(inkwell::module::Linkage::WeakODR);
                    }
                }
            }
            // 2. initialize { parent, name, depth }.
            for g in &self.ir.globals {
                if let Global::TypeInfo { class_name, parent_name, depth } = g {
                    let Some(gv) = self.module.get_global(&format!("{}.typeinfo", class_name))
                    else {
                        continue;
                    };
                    let parent_ptr = match parent_name {
                        Some(pn) => {
                            let pname = format!("{}.typeinfo", pn);
                            let pg = self.module.get_global(&pname).unwrap_or_else(|| {
                                // cross-module base: an external declaration,
                                // resolved at link (AOT) / JIT to its module.
                                let g2 = self.module.add_global(ti_struct, None, &pname);
                                g2.set_linkage(inkwell::module::Linkage::External);
                                g2
                            });
                            pg.as_pointer_value()
                        }
                        None => ptr_ty.const_null(),
                    };
                    // The class name as a private NUL-terminated UTF-8 byte array
                    // (reflection substrate; not read by nm2_rtti_isa).
                    let name_bytes: Vec<u8> =
                        class_name.bytes().chain(std::iter::once(0u8)).collect();
                    let name_arr_ty = i8_t.array_type(name_bytes.len() as u32);
                    let name_gv = self.module.add_global(
                        name_arr_ty,
                        None,
                        &format!("{}.typeinfo.name", class_name),
                    );
                    let name_vals: Vec<_> =
                        name_bytes.iter().map(|&b| i8_t.const_int(b as u64, false)).collect();
                    name_gv.set_initializer(&i8_t.const_array(&name_vals));
                    name_gv.set_constant(true);
                    name_gv.set_linkage(inkwell::module::Linkage::Private);
                    let depth_val = i64_t.const_int(*depth, false);
                    gv.set_initializer(&ti_struct.const_named_struct(&[
                        parent_ptr.into(),
                        name_gv.as_pointer_value().into(),
                        depth_val.into(),
                    ]));
                }
            }
        }

        for g in &self.ir.globals {
            match g {
                Global::ExternFunc { name, params, return_ty, dll_name, is_variadic, .. } => {
                    if defined_funcs.contains(name.as_str()) {
                        continue;
                    }
                    if self.module.get_function(name).is_none() {
                        if params.is_none() {
                            let fty = self.ctx.i64_type().fn_type(&[], true);
                            self.module.add_function(name, fty, None);
                        } else {
                            // EXTERNAL FROM "dll" → bare C ABI (no HIGH companion).
                            let foreign_c = dll_name.is_some();
                            let fty = self.llvm_fn_type_with_abi_var(
                                params.as_deref().unwrap_or(&[]),
                                *return_ty,
                                foreign_c,
                                *is_variadic,
                            );
                            self.module.add_function(name, fty, None);
                        }
                    }
                }
                Global::Static { name, ty, init, exported: _ } => {
                    let llty = self.llvm_type(*ty);
                    let gv = self.module.add_global(llty, None, name);
                    match init {
                        None => gv.set_initializer(&llty.const_zero()),
                        Some(cv) => {
                            if let Some(lv) = self.const_val_to_llvm(cv, *ty) {
                                gv.set_initializer(&lv);
                            } else {
                                gv.set_initializer(&llty.const_zero());
                            }
                        }
                    }
                }
                Global::StringConst { name, value } => {
                    // Windows-wide internal model: string literals are stored
                    // as UTF-16 (CHAR = i16), wide-NUL terminated. I/O converts
                    // to UTF-8 at the boundary.
                    let units: Vec<u16> =
                        value.encode_utf16().chain(std::iter::once(0u16)).collect();
                    let i16_t = self.ctx.i16_type();
                    let arr_ty = i16_t.array_type(units.len() as u32);
                    let gv = self.module.add_global(arr_ty, None, name);
                    let init: Vec<_> = units
                        .iter()
                        .map(|&u| i16_t.const_int(u as u64, false))
                        .collect();
                    gv.set_initializer(&i16_t.const_array(&init));
                    gv.set_constant(true);
                    // Module-local literal: private linkage so equally-named
                    // `str.N` globals from different modules don't collide when
                    // the per-module LLVM modules are linked together.
                    gv.set_linkage(inkwell::module::Linkage::Private);
                }
                Global::ClassDesc { class_name, vtable_slots, has_typeinfo } => {
                    // Declare {class_name}.vtable as a mutable [E+N x ptr] global,
                    // where physical slot 0 (when has_typeinfo) holds the
                    // {class}.typeinfo pointer (a DATA pointer — MCJIT-safe in a
                    // constant initializer) and the N method slots follow at 1+.
                    // Method slots stay null and are written post-JIT via
                    // LLVMGetPointerToGlobal (see lib.rs: patch_vtables); MCJIT
                    // can't relocate function pointers in constant initializers.
                    // A method-less class still emits a [typeinfo]-only vtable.
                    if vtable_slots.is_empty() && !*has_typeinfo {
                        continue;
                    }
                    let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
                    let extra = if *has_typeinfo { 1 } else { 0 };
                    let total = vtable_slots.len() + extra;
                    let vtable_ty = ptr_ty.array_type(total as u32);
                    let vtable_name = format!("{}.vtable", class_name);
                    if self.module.get_global(&vtable_name).is_none() {
                        let gv = self.module.add_global(vtable_ty, None, &vtable_name);
                        if *has_typeinfo {
                            let ti_ptr = self
                                .module
                                .get_global(&format!("{}.typeinfo", class_name))
                                .map(|g| g.as_pointer_value())
                                .unwrap_or_else(|| ptr_ty.const_null());
                            let mut init = Vec::with_capacity(total);
                            init.push(ti_ptr);
                            for _ in 0..vtable_slots.len() {
                                init.push(ptr_ty.const_null());
                            }
                            gv.set_initializer(&ptr_ty.const_array(&init));
                        } else {
                            gv.set_initializer(&vtable_ty.const_zero());
                        }
                        gv.set_constant(false);
                    }
                }
                Global::TypeInfo { .. } => {
                    // Declared + initialized in the RTTI pre-pass above.
                }
            }
        }

        // Pre-declare all functions so forward calls work.
        for func in &self.ir.funcs {
            if self.module.get_function(&func.name).is_none() {
                let fty = self.llvm_fn_type(&func.params, func.return_ty);
                self.module.add_function(&func.name, fty, None);
            }
        }

        // AOT: fill each class vtable with a *constant* function-pointer array.
        // The JIT can't relocate function pointers inside constant initializers
        // (hence the zero-init + post-JIT patch in lib.rs::patch_vtables), but a
        // static linker resolves them via ordinary relocations — so for an
        // object-file build we materialise the real initializer now that every
        // method function is declared. An abstract / empty slot stays null.
        if self.opts.aot {
            let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
            for g in &self.ir.globals {
                let Global::ClassDesc { class_name, vtable_slots, has_typeinfo } = g else {
                    continue;
                };
                if vtable_slots.is_empty() && !*has_typeinfo {
                    continue;
                }
                let vtable_name = format!("{}.vtable", class_name);
                let Some(vt_gv) = self.module.get_global(&vtable_name) else { continue };
                let mut slots: Vec<inkwell::values::PointerValue<'ctx>> = Vec::new();
                if *has_typeinfo {
                    // physical slot 0 = &{class}.typeinfo
                    let ti_ptr = self
                        .module
                        .get_global(&format!("{}.typeinfo", class_name))
                        .map(|g| g.as_pointer_value())
                        .unwrap_or_else(|| ptr_ty.const_null());
                    slots.push(ti_ptr);
                }
                slots.extend(vtable_slots.iter().map(|fn_name| {
                    if fn_name.is_empty() {
                        ptr_ty.const_null()
                    } else if let Some(fv) = self.module.get_function(fn_name) {
                        fv.as_global_value().as_pointer_value()
                    } else {
                        ptr_ty.const_null()
                    }
                }));
                vt_gv.set_initializer(&ptr_ty.const_array(&slots));
            }
        }

        // @llvm.used - anchor all vtable method functions against LLVM DCE.
        //
        // MCJIT only emits functions reachable from a call site or marked
        // used.  Vtable initializer references don't count as a call-site use.
        // Without this, methods that appear only as vtable entries are
        // dead-code-eliminated before JIT emission and LLVMGetPointerToGlobal
        // returns 0 for them.
        //
        // appending linkage + section "llvm.metadata" is the canonical
        // LLVM way to express "emit this symbol, do not eliminate it".
        let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
        let mut anchored: Vec<inkwell::values::PointerValue<'ctx>> = Vec::new();
        for g in &self.ir.globals {
            if let Global::ClassDesc { vtable_slots, .. } = g {
                for fn_name in vtable_slots {
                    if fn_name.is_empty() {
                        continue; // abstract slot - no body
                    }
                    if let Some(fn_val) = self.module.get_function(fn_name) {
                        anchored.push(fn_val.as_global_value().as_pointer_value());
                    }
                }
            }
        }
        // Anchor every {Class}.typeinfo too: an abstract base's typeinfo is
        // reachable only through other typeinfos' `parent` fields (no vtable, no
        // call site), so DCE would drop it and break `nm2_rtti_isa`'s walk / an
        // `AS AbstractBase` arm. (Its name string is kept transitively.)
        for g in &self.ir.globals {
            if let Global::TypeInfo { class_name, .. } = g {
                if let Some(gv) = self.module.get_global(&format!("{}.typeinfo", class_name)) {
                    anchored.push(gv.as_pointer_value());
                }
            }
        }
        if !anchored.is_empty() {
            let used_arr_ty = ptr_ty.array_type(anchored.len() as u32);
            let used_init = ptr_ty.const_array(&anchored);
            let used_gv = self.module.add_global(used_arr_ty, None, "llvm.used");
            used_gv.set_linkage(inkwell::module::Linkage::Appending);
            used_gv.set_initializer(&used_init);
            used_gv.set_section(Some("llvm.metadata"));
        }
    }

    fn const_val_to_llvm(
        &self,
        cv: &ConstValue,
        ty: newm2_sema::TypeId,
    ) -> Option<BasicValueEnum<'ctx>> {
        match cv {
            ConstValue::Int(n) => {
                let llty = self.llvm_type(ty);
                if let BasicTypeEnum::IntType(it) = llty {
                    Some(it.const_int(*n as u64, true).into())
                } else {
                    None
                }
            }
            ConstValue::Real(f) => {
                let llty = self.llvm_type(ty);
                if let BasicTypeEnum::FloatType(ft) = llty {
                    Some(ft.const_float(*f).into())
                } else {
                    None
                }
            }
            ConstValue::Bool(b) => Some(
                self.ctx
                    .bool_type()
                    .const_int(if *b { 1 } else { 0 }, false)
                    .into(),
            ),
            ConstValue::Char(c) => {
                Some(self.ctx.i8_type().const_int(*c as u64, false).into())
            }
            ConstValue::Set(members) => {
                // Build a 256-bit constant: bit `m` set for each member. Four
                // i64 words (little-endian) so members 0..255 are all captured
                // (a plain u64 would drop chars >= 64, e.g. 'A' = 65).
                let mut words = [0u64; 4];
                for &m in members {
                    let m = (m as usize) & 255;
                    words[m / 64] |= 1u64 << (m % 64);
                }
                Some(self.set_int_type().const_int_arbitrary_precision(&words).into())
            }
            ConstValue::FuncRef(name) => {
                if let Some(f) = self.module.get_function(name) {
                    Some(f.as_global_value().as_pointer_value().into())
                } else {
                    None
                }
            }
            ConstValue::Complex(re, im) => {
                let f64t = self.ctx.f64_type();
                Some(
                    self.ctx
                        .const_struct(
                            &[f64t.const_float(*re).into(), f64t.const_float(*im).into()],
                            false,
                        )
                        .into(),
                )
            }
            ConstValue::Aggregate(items) => self.const_aggregate_to_llvm(items, ty),
            ConstValue::Str(_) | ConstValue::Nil => None,
        }
    }

    /// Materialise a RECORD/ARRAY aggregate constant as an LLVM constant — a
    /// `const_struct` for records, a typed `const_array` for arrays — recursing
    /// per field/element. Returns `None` if any element cannot be materialised.
    fn const_aggregate_to_llvm(
        &self,
        items: &[ConstValue],
        ty: newm2_sema::TypeId,
    ) -> Option<BasicValueEnum<'ctx>> {
        match self.types.get(ty) {
            TypeKind::Record(layout) => {
                let fields = layout.flatten_fields();
                let mut vals = Vec::with_capacity(items.len());
                for (item, (_, fty)) in items.iter().zip(fields.iter()) {
                    vals.push(self.const_val_to_llvm(item, *fty)?);
                }
                Some(self.ctx.const_struct(&vals, false).into())
            }
            TypeKind::Array { base, .. } => {
                let base = *base;
                let elem_llty = self.llvm_type(base);
                let mut vals = Vec::with_capacity(items.len());
                for item in items {
                    // Coerce each element to the array's element type so the
                    // constant array is homogeneous (e.g. CHAR width).
                    let v = self.coerce_int(self.const_val_to_llvm(item, base)?, elem_llty);
                    vals.push(v);
                }
                self.const_array_of(elem_llty, &vals)
            }
            _ => None,
        }
    }

    /// Build a homogeneous LLVM constant array of `elem_ty` from `vals`.
    fn const_array_of(
        &self,
        elem_ty: BasicTypeEnum<'ctx>,
        vals: &[BasicValueEnum<'ctx>],
    ) -> Option<BasicValueEnum<'ctx>> {
        Some(match elem_ty {
            BasicTypeEnum::IntType(it) => {
                let v: Vec<_> = vals.iter().map(|x| x.into_int_value()).collect();
                it.const_array(&v).into()
            }
            BasicTypeEnum::FloatType(ft) => {
                let v: Vec<_> = vals.iter().map(|x| x.into_float_value()).collect();
                ft.const_array(&v).into()
            }
            BasicTypeEnum::StructType(st) => {
                let v: Vec<_> = vals.iter().map(|x| x.into_struct_value()).collect();
                st.const_array(&v).into()
            }
            BasicTypeEnum::ArrayType(at) => {
                let v: Vec<_> = vals.iter().map(|x| x.into_array_value()).collect();
                at.const_array(&v).into()
            }
            BasicTypeEnum::PointerType(pt) => {
                let v: Vec<_> = vals.iter().map(|x| x.into_pointer_value()).collect();
                pt.const_array(&v).into()
            }
            _ => return None,
        })
    }

    // ---- GC root registration -------------------------------------------

    /// Emit `{mod}.init_roots` — a void() function that calls
    /// `nm2_register_module_roots` to register all pointer-typed module-level
    /// static globals as GC roots.
    ///
    /// Signature of the runtime function:
    /// ```c
    /// void nm2_register_module_roots(
    ///     const char *name,
    ///     const uint8_t *var_base,
    ///     const intptr_t *offsets,
    ///     size_t count);
    /// ```
    ///
    /// When module-level VARs are stack-allocated `count` is 0 here; promoting
    /// pointer VARs to LLVM globals fills the offsets array.  The function is
    /// always emitted so `lib.rs` can call it unconditionally without an
    /// address-zero check.
    fn emit_init_roots(&self) {
        use newm2_ir::module::Global;

        let ptr_ty  = self.ctx.ptr_type(inkwell::AddressSpace::default());
        let i64_ty  = self.ctx.i64_type();
        let void_ty = self.ctx.void_type();

        // Declare nm2_register_module_roots if not already present.
        let reg_fn = if let Some(f) = self.module.get_function("nm2_register_module_roots") {
            f
        } else {
            // (ptr, ptr, ptr, i64) -> void
            let fty = void_ty.fn_type(
                &[ptr_ty.into(), ptr_ty.into(), ptr_ty.into(), i64_ty.into()],
                false,
            );
            self.module.add_function("nm2_register_module_roots", fty, None)
        };

        // Collect pointer-typed Static globals — these are the GC root slots.
        let ptr_slots: Vec<_> = self.ir.globals.iter().filter_map(|g| {
            if let Global::Static { name, ty, .. } = g {
                use newm2_sema::types::TypeKind;
                if matches!(self.types.get(*ty), TypeKind::Pointer { .. }) {
                    return self.module.get_global(name);
                }
            }
            None
        }).collect();

        // Module name as a NUL-terminated global string constant.
        let name_bytes: Vec<u8> = self.ir.name.bytes()
            .chain(std::iter::once(0u8)).collect();
        let name_arr_ty = self.ctx.i8_type().array_type(name_bytes.len() as u32);
        let name_gv = self.module.add_global(name_arr_ty, None,
            &format!("{}.roots_name", self.ir.name));
        let name_init: Vec<_> = name_bytes.iter()
            .map(|&b| self.ctx.i8_type().const_int(b as u64, false))
            .collect();
        name_gv.set_initializer(&self.ctx.i8_type().const_array(&name_init));
        name_gv.set_constant(true);

        // If there are pointer slots, emit an offsets array global.
        // Each entry is the byte offset of that slot from address 0 — for
        // individually-addressed LLVM globals that means we store the global's
        // address directly (var_base = null, offset = absolute address).
        // We use a dedicated i64 array; `nm2_register_module_roots` interprets
        // offset 0 with null base as an absolute pointer.
        //
        // With no pointer statics this is an empty array, count = 0.
        let count = ptr_slots.len() as u64;
        let (offsets_ptr, var_base_ptr) = if count == 0 {
            (ptr_ty.const_null(), ptr_ty.const_null())
        } else {
            let offsets_vals: Vec<_> = ptr_slots.iter().map(|gv| {
                // Store each global's address as an i64 absolute offset;
                // var_base is null so the scanner reads *(offset as *const *mut u8).
                gv.as_pointer_value()
                    .const_to_int(i64_ty)
            }).collect();
            let arr_ty = i64_ty.array_type(count as u32);
            let arr_gv = self.module.add_global(arr_ty, None,
                &format!("{}.roots_offsets", self.ir.name));
            arr_gv.set_initializer(&i64_ty.const_array(&offsets_vals));
            arr_gv.set_constant(true);
            (arr_gv.as_pointer_value(), ptr_ty.const_null())
        };

        // Emit the init_roots function: void().
        let fn_name = format!("{}.init_roots", self.ir.name);
        let fty = void_ty.fn_type(&[], false);
        let init_fn = self.module.add_function(&fn_name, fty, None);

        // uwtable=2 so Windows SEH can unwind through this frame.
        let uwtable_id = inkwell::attributes::Attribute::get_named_enum_kind_id("uwtable");
        init_fn.add_attribute(
            inkwell::attributes::AttributeLoc::Function,
            self.ctx.create_enum_attribute(uwtable_id, 2),
        );

        let entry_bb = self.ctx.append_basic_block(init_fn, "entry");
        self.builder.position_at_end(entry_bb);

        let name_ptr = name_gv.as_pointer_value();
        self.builder.build_call(
            reg_fn,
            &[
                name_ptr.into(),
                var_base_ptr.into(),
                offsets_ptr.into(),
                i64_ty.const_int(count, false).into(),
            ],
            "reg_roots",
        ).unwrap();
        self.builder.build_return(None).unwrap();
    }

    // ---- Function emission --------------------------------------------------

    fn emit_func(&self, func: &Func) {
        let llvm_fn = self
            .module
            .get_function(&func.name)
            .expect("function must be pre-declared");

        // uwtable=2 (async) forces LLVM 22 to emit .pdata/.xdata for every
        // function unconditionally.  uwtable=1 (sync) allows LLVM to elide
        // unwind info for "leaf-ish" sequences — functions it considers
        // trivially non-throwing.  Since any JIT'd M2 frame may be unwound
        // through by a Rust panic in a runtime helper, we need info present
        // for all of them.
        let uwtable =
            inkwell::attributes::Attribute::get_named_enum_kind_id("uwtable");
        llvm_fn.add_attribute(
            inkwell::attributes::AttributeLoc::Function,
            self.ctx.create_enum_attribute(uwtable, 2),
        );

        // Create one LLVM basic block per IR basic block.
        let llvm_blocks: Vec<_> = func
            .blocks
            .iter()
            .map(|bb| {
                let label = bb.label.as_deref().unwrap_or("bb");
                self.ctx.append_basic_block(llvm_fn, label)
            })
            .collect();

        // SSA value map.
        let mut vals: HashMap<ValueId, BasicValueEnum<'ctx>> = HashMap::new();

        // Alloca map: ValueId -> (PointerValue, element BasicTypeEnum).
        let mut allocas: HashMap<ValueId, (PointerValue<'ctx>, BasicTypeEnum<'ctx>)> =
            HashMap::new();

        // For pointer-typed SSA values (e.g. result of Allocate), track the
        // pointed-to LLVM type so FieldPtr/IndexPtr can build correct GEPs.
        let mut ptr_elem_types: HashMap<ValueId, BasicTypeEnum<'ctx>> = HashMap::new();

        // FuncRef name map for direct-call resolution.
        let mut funcref_names: HashMap<ValueId, String> = HashMap::new();

        // For a pointer that addresses a *pointer-typed* slot (e.g. a GlobalRef
        // to `VAR p: POINTER TO T`), the pointee type to attach to the value
        // produced by loading it — so a subsequent deref/FieldPtr through that
        // loaded pointer uses T rather than guessing. Allocas get this via the
        // store→load propagation (they share a ValueId); globals create a fresh
        // ValueId per access, so the propagation can't reach the load.
        let mut loaded_pointee: HashMap<ValueId, BasicTypeEnum<'ctx>> = HashMap::new();

        // Position builder at entry block for alloca emission.
        self.builder
            .position_at_end(llvm_blocks[func.entry.0 as usize]);

        // Emit allocas in entry block first (LLVM convention: all allocas at
        // the top of the entry block to enable mem2reg).
        let param_count = func.params.len();
        let mut alloca_index = 0usize;
        for bb in &func.blocks {
            for inst in &bb.insts {
                if let Inst::Alloca { dst, ty } = inst {
                    let llty = self.llvm_type(*ty);
                    let slot = self.builder.build_alloca(llty, "local").unwrap();
                    allocas.insert(*dst, (slot, llty));
                    // An alloca's SSA value is its address; expose it in `vals`
                    // so it can be used as a pointer value (e.g. stored into an
                    // exception frame), not just via the alloca element-type map.
                    vals.insert(*dst, slot.into());
                    // Store incoming function argument into its alloca slot.
                    if alloca_index < param_count {
                        if let Some(pv) = llvm_fn.get_nth_param(alloca_index as u32) {
                            self.builder.build_store(slot, pv).unwrap();
                        }
                    }
                    alloca_index += 1;
                }
            }
        }

        // Emit all basic blocks.
        for (bb_idx, bb) in func.blocks.iter().enumerate() {
            self.builder.position_at_end(llvm_blocks[bb_idx]);
            for inst in &bb.insts {
                self.emit_inst(
                    inst,
                    &mut vals,
                    &allocas,
                    &mut ptr_elem_types,
                    &mut funcref_names,
                    &mut loaded_pointee,
                );
            }
            self.emit_terminator(&bb.term, &vals, &llvm_blocks);
        }
    }

    // ---- Instruction emission -----------------------------------------------

    fn emit_inst(
        &self,
        inst: &Inst,
        vals: &mut HashMap<ValueId, BasicValueEnum<'ctx>>,
        allocas: &HashMap<ValueId, (PointerValue<'ctx>, BasicTypeEnum<'ctx>)>,
        ptr_elem_types: &mut HashMap<ValueId, BasicTypeEnum<'ctx>>,
        funcref_names: &mut HashMap<ValueId, String>,
        loaded_pointee: &mut HashMap<ValueId, BasicTypeEnum<'ctx>>,
    ) {
        match inst {
            Inst::Alloca { .. } => {
                // Handled in prologue; skip here.
            }
            Inst::Const { dst, val } => {
                // Track FuncRef names for later direct-call lookup.
                if let ConstVal::FuncRef(name) = val {
                    funcref_names.insert(*dst, name.clone());
                }
                if let ConstVal::GlobalRef { ty, .. } = val {
                    ptr_elem_types.insert(*dst, self.llvm_type(*ty));
                    // If the global itself holds a pointer, remember its pointee
                    // so loading the global yields a correctly-typed pointer.
                    if let TypeKind::Pointer { base } = self.types.get(*ty) {
                        loaded_pointee.insert(*dst, self.llvm_type(*base));
                    }
                }
                let v = self.emit_const(val);
                vals.insert(*dst, v);
            }
            Inst::Copy { dst, src } => {
                if let Some(&v) = vals.get(src) {
                    vals.insert(*dst, v);
                    // Propagate pointer element type through copy.
                    if let Some(&et) = ptr_elem_types.get(src) {
                        ptr_elem_types.insert(*dst, et);
                    }
                }
            }
            Inst::Load { dst, ptr } => {
                let (ptr_val, elem_ty) =
                    self.ptr_of(ptr, vals, allocas, ptr_elem_types);
                let loaded = self
                    .builder
                    .build_load(elem_ty, ptr_val, "load")
                    .unwrap();
                vals.insert(*dst, loaded);
                // Propagate the loaded pointer's pointee type so a subsequent
                // deref / FieldPtr GEP is correctly typed. A pointer-typed
                // global records its pointee in `loaded_pointee` (its slot's
                // own type would be the opaque pointer, not the pointee); an
                // alloca/Allocate carries the pointee in `ptr_elem_types`
                // through the store→load on the same slot ValueId.
                if let Some(&pointee) = loaded_pointee.get(ptr) {
                    ptr_elem_types.insert(*dst, pointee);
                } else if let Some(&inner_ty) = ptr_elem_types.get(ptr) {
                    ptr_elem_types.insert(*dst, inner_ty);
                }
            }
            Inst::Store { ptr, val } => {
                // Resolve the destination pointer *and* whether its element
                // type is genuinely known (a real alloca type or an explicitly
                // recorded pointee). `ptr_of` masks "unknown" as an i64
                // fallback, which we must not coerce toward.
                let (ptr_val, elem_ty, elem_known) =
                    if let Some(&(p, ty)) = allocas.get(ptr) {
                        (p, ty, true)
                    } else {
                        let p = self.val_of(ptr, vals).into_pointer_value();
                        match ptr_elem_types.get(ptr).copied() {
                            Some(ty) => (p, ty, true),
                            None => (p, self.ctx.i64_type().into(), false),
                        }
                    };
                let mut src_val = self.val_of(val, vals);
                // Narrow/widen the integer value to the destination slot's
                // width. A width-less ordinal constant (e.g. an enum member)
                // lowers at the default i64 register width; storing it raw into
                // a narrower slot (enum = i32) overruns by 4 bytes and silently
                // clobbers whatever is adjacent — e.g. an open-array `$high`
                // companion, making HIGH() read 0. Mirrors the call-arg
                // coercion. Only when the slot's type is actually known.
                if elem_known {
                    src_val = self.coerce_int(src_val, elem_ty);
                    src_val = self.coerce_float(src_val, elem_ty);
                }
                self.builder.build_store(ptr_val, src_val).unwrap();
                // Propagate: if val carries a known element type, associate it
                // with the destination slot so future loads can use it.
                if let Some(&et) = ptr_elem_types.get(val) {
                    ptr_elem_types.insert(*ptr, et);
                }
            }
            Inst::MemCopy { dst, src, ty } => {
                // Whole-aggregate copy by address — memmove (handles self/overlap)
                // instead of a by-value aggregate load/store that LLVM can't
                // legalise for huge aggregates.
                let (dptr, _) = self.ptr_of(dst, vals, allocas, ptr_elem_types);
                let (sptr, _) = self.ptr_of(src, vals, allocas, ptr_elem_types);
                let size = self
                    .llvm_type(*ty)
                    .size_of()
                    .unwrap_or_else(|| self.ctx.i64_type().const_zero());
                self.builder.build_memmove(dptr, 1, sptr, 1, size).unwrap();
            }
            Inst::FieldPtr { dst, base, field } => {
                let (base_ptr, base_ty) =
                    self.ptr_of(base, vals, allocas, ptr_elem_types);
                let gep = unsafe {
                    self.builder
                        .build_in_bounds_gep(
                            base_ty,
                            base_ptr,
                            &[
                                self.ctx.i32_type().const_zero(),
                                self.ctx.i32_type().const_int(*field as u64, false),
                            ],
                            "field_ptr",
                        )
                        .unwrap()
                };
                vals.insert(*dst, gep.into());
                // Record the field's own type so a following Load/Store uses it
                // (not codegen's conservative i64 fallback) — needed for any
                // non-i64 field: REAL, CHAR, COMPLEX component, nested record…
                if let BasicTypeEnum::StructType(st) = base_ty
                    && let Some(fty) = st.get_field_type_at_index(*field)
                {
                    ptr_elem_types.insert(*dst, fty);
                }
            }
            Inst::TypedPtr { dst, src, ty } => {
                let v = self.val_of(src, vals);
                vals.insert(*dst, v);
                ptr_elem_types.insert(*dst, self.llvm_type(*ty));
                // When the annotated pointee is itself a pointer type, record
                // what *it* points to, so loading through this pointer yields a
                // value whose own pointee (for a later deref / field GEP) is the
                // base type rather than the opaque `ptr`.
                if let TypeKind::Pointer { base } = self.types.get(*ty) {
                    loaded_pointee.insert(*dst, self.llvm_type(*base));
                }
            }
            Inst::IndexPtr { dst, base, index, elem_ty } => {
                let (base_ptr, _) =
                    self.ptr_of(base, vals, allocas, ptr_elem_types);
                let idx_val = self.val_of(index, vals);
                // GEP uniformly as `elem_ty*` from the element-0 address: works
                // for a fixed array (alloca = &array[0]) and an open-array data
                // pointer alike, and gives the correct per-element stride
                // (e.g. CHAR = i16) instead of defaulting to i64.
                let elem_llty = self.llvm_type(*elem_ty);
                let gep = unsafe {
                    self.builder
                        .build_in_bounds_gep(
                            elem_llty,
                            base_ptr,
                            &[idx_val.into_int_value()],
                            "idx_ptr",
                        )
                        .unwrap()
                };
                ptr_elem_types.insert(*dst, elem_llty);
                vals.insert(*dst, gep.into());
            }
            Inst::Unary { dst, op, val } => {
                let v = self.val_of(val, vals);
                let result = self.emit_unary(*op, v);
                vals.insert(*dst, result);
            }
            Inst::Binary { dst, op, lhs, rhs } => {
                let l = self.val_of(lhs, vals);
                let r = self.val_of(rhs, vals);
                let result = self.emit_binary(*op, l, r);
                vals.insert(*dst, result);
            }
            Inst::Cast { dst, kind, val, ty } => {
                let v = self.val_of(val, vals);
                let target_ty = self.llvm_type(*ty);
                let result = self.emit_cast(*kind, v, target_ty);
                vals.insert(*dst, result);
            }
            Inst::Call { dst, callee, args } => {
                let raw_args: Vec<BasicValueEnum<'ctx>> = args
                    .iter()
                    .map(|a| {
                        if let Some((ptr, _)) = allocas.get(a) {
                            (*ptr).into()
                        } else {
                            self.val_of(a, vals)
                        }
                    })
                    .collect();
                let arg_vals: Vec<BasicMetadataValueEnum<'ctx>> =
                    raw_args.iter().map(|v| (*v).into()).collect();

                // Resolve callee via funcref_names -> named function lookup.
                if let Some(name) = funcref_names.get(callee) {
                    let fn_name = name.clone();
                    if let Some(callee_fn) = self.module.get_function(&fn_name) {
                        // Coerce integer argument widths to the callee's
                        // declared parameter types (e.g. an enum literal lowers
                        // at the default int width but the parameter is i32).
                        let ptys = callee_fn.get_type().get_param_types();
                        let coerced: Vec<BasicMetadataValueEnum<'ctx>> = raw_args
                            .iter()
                            .enumerate()
                            .map(|(i, v)| match ptys.get(i) {
                                Some(BasicMetadataTypeEnum::IntType(it)) => {
                                    self.coerce_int(*v, (*it).into()).into()
                                }
                                // An integer passed to a pointer-typed parameter
                                // reinterprets via inttoptr (C FFI). ADRCARD /
                                // ADRINT params lower to `ptr`, so e.g. a literal
                                // `0` for `dwStackSize: ADRCARD` (CreateThread)
                                // becomes a null pointer rather than an i64 that
                                // fails the LLVM verifier.
                                Some(BasicMetadataTypeEnum::PointerType(pt))
                                    if v.is_int_value() =>
                                {
                                    self.builder
                                        .build_int_to_ptr(v.into_int_value(), *pt, "arg_i2p")
                                        .unwrap()
                                        .into()
                                }
                                _ => (*v).into(),
                            })
                            .collect();
                        let call = self
                            .builder
                            .build_call(callee_fn, &coerced, "call")
                            .unwrap();
                        if let Some(d) = dst {
                            if let Some(ret) = call.try_as_basic_value().basic() {
                                vals.insert(*d, ret);
                            }
                        }
                        self.emit_safepoint_if_gc();
                        return;
                    }
                }

                // Fallback: indirect call through the pointer value.
                let fn_ptr = self.val_of(callee, vals).into_pointer_value();
                let fty = self.ctx.i64_type().fn_type(&[], true);
                let call = self
                    .builder
                    .build_indirect_call(fty, fn_ptr, &arg_vals, "indcall_fb")
                    .unwrap();
                if let Some(d) = dst {
                    if let Some(ret) = call.try_as_basic_value().basic() {
                        vals.insert(*d, ret);
                    }
                }
                self.emit_safepoint_if_gc();
            }
            Inst::IndCall { dst, callee, sig, args } => {
                let fn_ptr = self.val_of(callee, vals).into_pointer_value();
                let arg_vals: Vec<BasicMetadataValueEnum<'ctx>> =
                    args.iter().map(|a| self.val_of(a, vals).into()).collect();
                // Build the call's function type from the procedure-pointer's
                // signature so the ABI matches the callee exactly (a variadic
                // i64(...) fallback corrupts the Windows x64 stack for
                // by-reference args — the device-dispatch / scanner case).
                let fty = self.indirect_fn_type(*sig);
                let call = self
                    .builder
                    .build_indirect_call(fty, fn_ptr, &arg_vals, "indcall")
                    .unwrap();
                if let Some(d) = dst {
                    if let Some(ret) = call.try_as_basic_value().basic() {
                        vals.insert(*d, ret);
                    }
                }
                self.emit_safepoint_if_gc();
            }
            Inst::SetOp { dst, op, lhs, rhs } => {
                let l = self.val_of(lhs, vals).into_int_value();
                let r = self.val_of(rhs, vals).into_int_value();
                let result: BasicValueEnum<'ctx> = match op {
                    SetOpKind::Union => {
                        self.builder.build_or(l, r, "set_union").unwrap().into()
                    }
                    SetOpKind::Intersection => {
                        self.builder.build_and(l, r, "set_isect").unwrap().into()
                    }
                    SetOpKind::Difference => {
                        let not_r = self.builder.build_not(r, "not_r").unwrap();
                        self.builder
                            .build_and(l, not_r, "set_diff")
                            .unwrap()
                            .into()
                    }
                    SetOpKind::SymDiff => {
                        self.builder.build_xor(l, r, "set_symd").unwrap().into()
                    }
                    SetOpKind::Member => {
                        // `l IN r`: l is the element ordinal, r is the set
                        // (i256). Widen l to the set width so the shift type
                        // checks, then test `(1 << l) & r != 0`.
                        let set_ty = r.get_type();
                        let l_wide = self
                            .builder
                            .build_int_z_extend(l, set_ty, "elem_widen")
                            .unwrap();
                        let one = set_ty.const_int(1, false);
                        let bit =
                            self.builder.build_left_shift(one, l_wide, "set_bit").unwrap();
                        let masked =
                            self.builder.build_and(r, bit, "set_mem").unwrap();
                        let zero = set_ty.const_zero();
                        self.builder
                            .build_int_compare(IntPredicate::NE, masked, zero, "in_set")
                            .unwrap()
                            .into()
                    }
                };
                vals.insert(*dst, result);
            }
            Inst::Allocate { dst, ty } => {
                let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());

                // Resolve the pointed-to base type (Allocate ty is always
                // POINTER TO T, so we dereference once).
                let base_ty = match self.types.get(*ty) {
                    TypeKind::Pointer { base } => *base,
                    _ => *ty,
                };
                let payload_llvm = self.llvm_type(base_ty);

                if self.opts.memory_mode == MemoryMode::Gc {
                    let desc_ptr =
                        self.get_or_emit_typedesc(payload_llvm, base_ty.0);
                    let new_rec_ty = ptr_ty.fn_type(&[ptr_ty.into()], false);
                    let new_rec = self
                        .module
                        .get_function("nm2_new_rec")
                        .unwrap_or_else(|| {
                            self.module.add_function("nm2_new_rec", new_rec_ty, None)
                        });
                    let call = self
                        .builder
                        .build_call(new_rec, &[desc_ptr.into()], "new_rec")
                        .unwrap();
                    let ptr = call.try_as_basic_value().basic().unwrap();
                    vals.insert(*dst, ptr);
                } else {
                    // Manual mode: the runtime allocator (Rust nm2_alloc), or
                    // the self-hosted M2 heap (Heap.Alloc) under --m2-heap. Both
                    // are (i64 size) -> ptr and return a zeroed block.
                    let alloc_name = if self.opts.m2_heap { "Heap.Alloc" } else { "nm2_alloc" };
                    let alloc_ty =
                        ptr_ty.fn_type(&[self.ctx.i64_type().into()], false);
                    let alloc = self
                        .module
                        .get_function(alloc_name)
                        .unwrap_or_else(|| {
                            self.module.add_function(alloc_name, alloc_ty, None)
                        });
                    let size = payload_llvm
                        .size_of()
                        .unwrap_or(self.ctx.i64_type().const_int(16, false));
                    let call = self
                        .builder
                        .build_call(alloc, &[size.into()], "allocate")
                        .unwrap();
                    let ptr = call.try_as_basic_value().basic().unwrap();
                    vals.insert(*dst, ptr);
                }

                // Record the payload struct type so downstream FieldPtr GEPs
                // use the correct element type rather than the i64 fallback.
                ptr_elem_types.insert(*dst, payload_llvm);
            }
            Inst::Deallocate { ptr } => {
                // Rust nm2_free, or the M2 heap's Heap.Free under --m2-heap
                // (GC mode keeps the runtime free; DISPOSE is a hint there).
                let free_name = if self.opts.m2_heap && self.opts.memory_mode != MemoryMode::Gc {
                    "Heap.Free"
                } else {
                    "nm2_free"
                };
                let free_ty = self.ctx.void_type().fn_type(
                    &[self.ctx.ptr_type(inkwell::AddressSpace::default()).into()],
                    false,
                );
                let free = self
                    .module
                    .get_function(free_name)
                    .unwrap_or_else(|| self.module.add_function(free_name, free_ty, None));
                let ptr_val = self.val_of(ptr, vals).into_pointer_value();
                self.builder.build_call(free, &[ptr_val.into()], "").unwrap();
            }

            // GC instructions.
            Inst::GcSafePoint => {
                self.emit_safepoint_if_gc();
            }
            Inst::GcRoot { ptr } => {
                if self.opts.memory_mode == MemoryMode::Gc {
                    let (ptr_val, _) =
                        self.ptr_of(ptr, vals, allocas, ptr_elem_types);
                    let f = self.gc_push_root_fn();
                    self.builder.build_call(f, &[ptr_val.into()], "").unwrap();
                }
            }

            // SYSTEM.PIN / UNPIN.
            Inst::Pin { ptr } => {
                if self.opts.memory_mode == MemoryMode::Gc {
                    let (ptr_val, _) =
                        self.ptr_of(ptr, vals, allocas, ptr_elem_types);
                    let f = self.pin_fn();
                    self.builder.build_call(f, &[ptr_val.into()], "").unwrap();
                }
            }
            Inst::Unpin { ptr } => {
                if self.opts.memory_mode == MemoryMode::Gc {
                    let (ptr_val, _) =
                        self.ptr_of(ptr, vals, allocas, ptr_elem_types);
                    let f = self.unpin_fn();
                    self.builder.build_call(f, &[ptr_val.into()], "").unwrap();
                }
            }

            // Coroutines - not yet implemented; trap.
            Inst::NewProcess { .. } | Inst::Transfer { .. } => {
                let trap_ty = self.ctx.void_type().fn_type(&[], false);
                let trap = self
                    .module
                    .get_function("llvm.trap")
                    .unwrap_or_else(|| {
                        self.module.add_function("llvm.trap", trap_ty, None)
                    });
                self.builder.build_call(trap, &[], "").unwrap();
            }
            // `REAL32X4{e0,..}` builds a lane vector by inserting each lane (a
            // single lane value broadcasts to all lanes). Lane values narrow to
            // the lane element type (an f64 literal → f32 for REAL32X4).
            Inst::VecBuild { dst, lanes, ty } => {
                let vty = self.llvm_type(*ty).into_vector_type();
                let n = vty.get_size();
                let elem_ty = vty.get_element_type();
                let i32t = self.ctx.i32_type();
                let mut vec = vty.get_undef();
                if lanes.len() == 1 {
                    let e = self.coerce_float(self.val_of(&lanes[0], vals), elem_ty);
                    for i in 0..n {
                        let idx = i32t.const_int(i as u64, false);
                        vec = self.builder.build_insert_element(vec, e, idx, "vsplat").unwrap();
                    }
                } else {
                    for (i, l) in lanes.iter().enumerate() {
                        let e = self.coerce_float(self.val_of(l, vals), elem_ty);
                        let idx = i32t.const_int(i as u64, false);
                        vec = self.builder.build_insert_element(vec, e, idx, "vins").unwrap();
                    }
                }
                vals.insert(*dst, vec.into());
            }
            Inst::VecExtract { dst, vec, lane } => {
                let v = self.val_of(vec, vals).into_vector_value();
                let idx = self.val_of(lane, vals).into_int_value();
                let e = self.builder.build_extract_element(v, idx, "vext").unwrap();
                vals.insert(*dst, e);
            }
            Inst::VecInsert { dst, vec, lane, val } => {
                let v = self.val_of(vec, vals).into_vector_value();
                let idx = self.val_of(lane, vals).into_int_value();
                let elem_ty = v.get_type().get_element_type();
                let e = self.coerce_float(self.val_of(val, vals), elem_ty);
                let nv = self.builder.build_insert_element(v, e, idx, "vinsel").unwrap();
                vals.insert(*dst, nv.into());
            }
            // SIMD reductions / fused multiply-add → `llvm.*` intrinsics. inkwell's
            // Intrinsic::get_declaration mangles the overload from the vector type.
            Inst::VecIntrinsic { dst, op, args, ty } => {
                use inkwell::intrinsics::Intrinsic;
                let vty = self.llvm_type(*ty);
                let argvals: Vec<_> = args.iter().map(|a| self.val_of(a, vals)).collect();
                let (name, call_args): (&str, Vec<_>) = match op {
                    VecIntrin::ReduceAdd => {
                        // `T @llvm.vector.reduce.fadd(T start, <N x T> v)`. A 0.0
                        // start gives the (strict, left-to-right) lane sum.
                        let elem = vty.into_vector_type().get_element_type().into_float_type();
                        let start = elem.const_zero();
                        ("llvm.vector.reduce.fadd", vec![start.into(), argvals[0].into()])
                    }
                    VecIntrin::Fma => (
                        "llvm.fma",
                        vec![argvals[0].into(), argvals[1].into(), argvals[2].into()],
                    ),
                    VecIntrin::Fabs => ("llvm.fabs", vec![argvals[0].into()]),
                };
                let intr = Intrinsic::find(name)
                    .unwrap_or_else(|| panic!("unknown intrinsic {name}"));
                let f = intr
                    .get_declaration(self.module, &[vty])
                    .unwrap_or_else(|| panic!("no declaration for {name}"));
                let r = self
                    .builder
                    .build_call(f, &call_args, "vintr")
                    .unwrap()
                    .try_as_basic_value()
                    .basic()
                    .expect("vector intrinsic returns a value");
                vals.insert(*dst, r);
            }
        }
    }

    // ---- Terminator emission ------------------------------------------------

    fn emit_terminator(
        &self,
        term: &Terminator,
        vals: &HashMap<ValueId, BasicValueEnum<'ctx>>,
        llvm_blocks: &[inkwell::basic_block::BasicBlock<'ctx>],
    ) {
        match term {
            Terminator::Goto(b) => {
                self.builder
                    .build_unconditional_branch(llvm_blocks[b.0 as usize])
                    .unwrap();
            }
            Terminator::CondBr { cond, t_block, f_block } => {
                let c = self.val_of(cond, vals).into_int_value();
                self.builder
                    .build_conditional_branch(
                        c,
                        llvm_blocks[t_block.0 as usize],
                        llvm_blocks[f_block.0 as usize],
                    )
                    .unwrap();
            }
            Terminator::Switch { val, arms, default } => {
                let v = self.val_of(val, vals).into_int_value();
                let cases: Vec<_> = arms
                    .iter()
                    .map(|(k, b)| {
                        let case_val = v.get_type().const_int(*k as u64, true);
                        (case_val, llvm_blocks[b.0 as usize])
                    })
                    .collect();
                self.builder
                    .build_switch(v, llvm_blocks[default.0 as usize], &cases)
                    .unwrap();
            }
            Terminator::Return(None) => {
                self.builder.build_return(None).unwrap();
            }
            Terminator::Return(Some(v)) => {
                let mut rv = self.val_of(v, vals);
                // Coerce integer return values to the function's declared width.
                // Enum ordinals lower as the default int (i64) but enums are
                // i32, CHAR is i16, subranges narrower, etc.
                if let Some(ret_ty) = self
                    .builder
                    .get_insert_block()
                    .and_then(|b| b.get_parent())
                    .and_then(|f| f.get_type().get_return_type())
                {
                    rv = self.coerce_int(rv, ret_ty);
                }
                self.builder.build_return(Some(&rv)).unwrap();
            }
            Terminator::Raise(_) | Terminator::Halt | Terminator::Unreachable => {
                let trap_ty = self.ctx.void_type().fn_type(&[], false);
                let trap = self
                    .module
                    .get_function("llvm.trap")
                    .unwrap_or_else(|| {
                        self.module.add_function("llvm.trap", trap_ty, None)
                    });
                self.builder.build_call(trap, &[], "").unwrap();
                self.builder.build_unreachable().unwrap();
            }
        }
    }

    // ---- Helpers ------------------------------------------------------------

    fn val_of(
        &self,
        v: &ValueId,
        vals: &HashMap<ValueId, BasicValueEnum<'ctx>>,
    ) -> BasicValueEnum<'ctx> {
        *vals
            .get(v)
            .unwrap_or_else(|| panic!("undefined ValueId({}) in codegen", v.0))
    }

    /// Return `(pointer, element_type)` for a Load/Store/GEP source.
    ///
    /// - Alloca slots carry their element type directly.
    /// - SSA values produced by `Allocate` carry the payload struct type via
    ///   `ptr_elem_types` (and propagation through Store/Load/Copy).
    /// - All other pointer values fall back to `i64` (conservative).
    fn ptr_of(
        &self,
        v: &ValueId,
        vals: &HashMap<ValueId, BasicValueEnum<'ctx>>,
        allocas: &HashMap<ValueId, (PointerValue<'ctx>, BasicTypeEnum<'ctx>)>,
        ptr_elem_types: &HashMap<ValueId, BasicTypeEnum<'ctx>>,
    ) -> (PointerValue<'ctx>, BasicTypeEnum<'ctx>) {
        if let Some(&(ptr, ty)) = allocas.get(v) {
            return (ptr, ty);
        }
        let ptr = match self.val_of(v, vals) {
            BasicValueEnum::PointerValue(p) => p,
            // A descriptor `{ptr, len}` (open array / DynamicString) used as a
            // Load/Store/GEP base: its data pointer is field 0.
            BasicValueEnum::StructValue(sv) => self
                .builder
                .build_extract_value(sv, 0, "desc.ptr")
                .unwrap()
                .into_pointer_value(),
            other => other.into_pointer_value(),
        };
        let ty = ptr_elem_types
            .get(v)
            .copied()
            .unwrap_or_else(|| self.ctx.i64_type().into());
        (ptr, ty)
    }

    // ---- Safepoint helpers --------------------------------------------------

    #[inline]
    fn emit_safepoint_if_gc(&self) {
        if self.opts.memory_mode == MemoryMode::Gc {
            let f = self.safepoint_fn();
            self.builder.build_call(f, &[], "").unwrap();
        }
    }

    fn safepoint_fn(&self) -> FunctionValue<'ctx> {
        let fty = self.ctx.void_type().fn_type(&[], false);
        self.module
            .get_function("nm2_safepoint")
            .unwrap_or_else(|| self.module.add_function("nm2_safepoint", fty, None))
    }

    fn gc_push_root_fn(&self) -> FunctionValue<'ctx> {
        let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
        let fty = self.ctx.void_type().fn_type(&[ptr_ty.into()], false);
        self.module
            .get_function("nm2_gc_push_root")
            .unwrap_or_else(|| {
                self.module.add_function("nm2_gc_push_root", fty, None)
            })
    }

    fn pin_fn(&self) -> FunctionValue<'ctx> {
        let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
        let fty = self.ctx.void_type().fn_type(&[ptr_ty.into()], false);
        self.module
            .get_function("nm2_pin")
            .unwrap_or_else(|| self.module.add_function("nm2_pin", fty, None))
    }

    fn unpin_fn(&self) -> FunctionValue<'ctx> {
        let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
        let fty = self.ctx.void_type().fn_type(&[ptr_ty.into()], false);
        self.module
            .get_function("nm2_unpin")
            .unwrap_or_else(|| self.module.add_function("nm2_unpin", fty, None))
    }

    // ---- TypeDesc -----------------------------------------------------------

    /// Get-or-create a TypeDesc global for the given payload LLVM type.
    ///
    /// TypeDesc layout (frozen - must match `newm2_runtime::gc::TypeDesc`):
    /// ```text
    /// { i64 size, ptr module, ptr finalizer, ptr base,
    ///   ptr vtable, i64 vtable_len, ptr name, [1 x i64] ptroffs }
    /// ```
    ///
    /// The `ptroffs` array is initialised with the sentinel `[-1]` meaning no
    /// pointer fields are tracked (conservative scanning finds all roots).
    fn get_or_emit_typedesc(
        &self,
        payload_ty: BasicTypeEnum<'ctx>,
        ty_id_raw: u32,
    ) -> PointerValue<'ctx> {
        let desc_name = format!("__nm2_typedesc.{}", ty_id_raw);
        if let Some(gv) = self.module.get_global(&desc_name) {
            return gv.as_pointer_value();
        }
        let i64_ty = self.ctx.i64_type();
        let ptr_ty = self.ctx.ptr_type(inkwell::AddressSpace::default());
        let ptroffs_ty = i64_ty.array_type(1);
        let desc_ty = self.ctx.struct_type(
            &[
                i64_ty.into(),     // size
                ptr_ty.into(),     // module
                ptr_ty.into(),     // finalizer
                ptr_ty.into(),     // base
                ptr_ty.into(),     // vtable
                i64_ty.into(),     // vtable_len
                ptr_ty.into(),     // name
                ptroffs_ty.into(), // ptroffs[0] = sentinel
            ],
            false,
        );

        let size_val = payload_ty
            .size_of()
            .unwrap_or(i64_ty.const_int(0, false));
        let ptroffs_init = i64_ty.const_array(&[i64_ty.const_all_ones()]); // -1 sentinel

        let init = desc_ty.const_named_struct(&[
            size_val.into(),
            ptr_ty.const_null().into(), // module
            ptr_ty.const_null().into(), // finalizer
            ptr_ty.const_null().into(), // base
            ptr_ty.const_null().into(), // vtable
            i64_ty.const_zero().into(), // vtable_len
            ptr_ty.const_null().into(), // name
            ptroffs_init.into(),        // ptroffs[-1]
        ]);

        let gv = self.module.add_global(desc_ty, None, &desc_name);
        gv.set_initializer(&init);
        gv.set_constant(false); // runtime may patch finalizer later
        gv.as_pointer_value()
    }

    // ---- Constant emission --------------------------------------------------

    fn emit_const(&self, cv: &ConstVal) -> BasicValueEnum<'ctx> {
        match cv {
            ConstVal::Int(n) => self.ctx.i64_type().const_int(*n as u64, true).into(),
            ConstVal::Real(f) => self.ctx.f64_type().const_float(*f).into(),
            ConstVal::Bool(b) => self
                .ctx
                .bool_type()
                .const_int(if *b { 1 } else { 0 }, false)
                .into(),
            // CHAR is a Windows-wide (UTF-16) code unit: i16.
            ConstVal::Char(c) => self.ctx.i16_type().const_int(*c as u64, false).into(),
            ConstVal::Str(s) => {
                // UTF-16, wide-NUL terminated (see StringConst global).
                let units: Vec<u16> =
                    s.encode_utf16().chain(std::iter::once(0u16)).collect();
                let i16_t = self.ctx.i16_type();
                let arr_ty = i16_t.array_type(units.len() as u32);
                let gv = self.module.add_global(arr_ty, None, ".str");
                let init: Vec<_> = units
                    .iter()
                    .map(|&u| i16_t.const_int(u as u64, false))
                    .collect();
                gv.set_initializer(&i16_t.const_array(&init));
                gv.set_constant(true);
                gv.set_linkage(inkwell::module::Linkage::Private);
                gv.as_pointer_value().into()
            }
            ConstVal::FuncRef(name) => {
                if let Some(f) = self.module.get_function(name) {
                    f.as_global_value().as_pointer_value().into()
                } else {
                    // Forward-declare as variadic i64(...) so any call-site
                    // arg count is valid LLVM IR.
                    let fty = self.ctx.i64_type().fn_type(&[], true);
                    let f = self.module.add_function(name, fty, None);
                    f.as_global_value().as_pointer_value().into()
                }
            }
            ConstVal::GlobalRef { name, ty } => self
                .module
                .get_global(name)
                .unwrap_or_else(|| {
                    // A cross-module reference to an exported variable: the
                    // global is defined in another JIT module. Forward-declare
                    // it here (no initializer = external linkage); the JIT
                    // linker resolves it to the defining module's storage.
                    let llty = self.llvm_type(*ty);
                    self.module.add_global(llty, None, name)
                })
                .as_pointer_value()
                .into(),
            ConstVal::SizeOf(ty) => self
                .llvm_type(*ty)
                .size_of()
                .expect("type has no compile-time size")
                .into(),
            ConstVal::Aggregate { value, ty } => self
                .const_val_to_llvm(value, *ty)
                .unwrap_or_else(|| self.llvm_type(*ty).const_zero()),
            ConstVal::Nil => self
                .ctx
                .ptr_type(inkwell::AddressSpace::default())
                .const_null()
                .into(),
        }
    }

    // ---- Unary / Binary / Cast ----------------------------------------------

    fn emit_unary(&self, op: UnaryOp, v: BasicValueEnum<'ctx>) -> BasicValueEnum<'ctx> {
        match op {
            UnaryOp::Neg => self
                .builder
                .build_int_neg(v.into_int_value(), "neg")
                .unwrap()
                .into(),
            // Float negation is vector-aware: `-v` on a REAL32X4 is a packed fneg.
            UnaryOp::FNeg if v.is_vector_value() => self
                .builder
                .build_float_neg(v.into_vector_value(), "fneg")
                .unwrap()
                .into(),
            UnaryOp::FNeg => self
                .builder
                .build_float_neg(v.into_float_value(), "fneg")
                .unwrap()
                .into(),
            UnaryOp::Not => self
                .builder
                .build_not(v.into_int_value(), "not")
                .unwrap()
                .into(),
            UnaryOp::Abs => {
                if let BasicValueEnum::FloatValue(fv) = v {
                    // REAL / LONGREAL → llvm.fabs.
                    let intrinsic = inkwell::intrinsics::Intrinsic::find("llvm.fabs")
                        .expect("llvm.fabs intrinsic available");
                    let decl = intrinsic
                        .get_declaration(self.module, &[fv.get_type().into()])
                        .expect("llvm.fabs declaration");
                    self.builder
                        .build_call(decl, &[fv.into()], "fabs")
                        .unwrap()
                        .try_as_basic_value()
                        .basic()
                        .expect("fabs returns a value")
                } else {
                    let iv = v.into_int_value();
                    let zero = iv.get_type().const_zero();
                    let neg = self.builder.build_int_neg(iv, "abs_neg").unwrap();
                    let cmp = self
                        .builder
                        .build_int_compare(IntPredicate::SGE, iv, zero, "abs_cmp")
                        .unwrap();
                    self.builder.build_select(cmp, iv, neg, "abs").unwrap()
                }
            }
            UnaryOp::Cap => {
                // ASCII upper-case: (ch >= 'a' & ch <= 'z') ? ch - 32 : ch.
                let ch = v.into_int_value();
                let ty = ch.get_type();
                let lo = ty.const_int('a' as u64, false);
                let hi = ty.const_int('z' as u64, false);
                let ge = self
                    .builder
                    .build_int_compare(IntPredicate::UGE, ch, lo, "cap_ge")
                    .unwrap();
                let le = self
                    .builder
                    .build_int_compare(IntPredicate::ULE, ch, hi, "cap_le")
                    .unwrap();
                let in_range = self.builder.build_and(ge, le, "cap_in").unwrap();
                let upper = self
                    .builder
                    .build_int_sub(ch, ty.const_int(32, false), "cap_up")
                    .unwrap();
                self.builder.build_select(in_range, upper, ch, "cap").unwrap()
            }
        }
    }

    /// Relational comparison that dispatches on operand representation:
    /// floating-point operands (REAL / LONGREAL) use an ordered float
    /// compare, everything else (integers, chars, enums, pointers, sets)
    /// uses an integer compare.
    fn emit_compare(
        &self,
        lhs: BasicValueEnum<'ctx>,
        rhs: BasicValueEnum<'ctx>,
        int_pred: IntPredicate,
        float_pred: FloatPredicate,
    ) -> BasicValueEnum<'ctx> {
        if lhs.is_float_value() || rhs.is_float_value() {
            self.builder
                .build_float_compare(
                    float_pred,
                    lhs.into_float_value(),
                    rhs.into_float_value(),
                    "fcmp",
                )
                .unwrap()
                .into()
        } else if lhs.is_pointer_value() || rhs.is_pointer_value() {
            // Pointer comparison (e.g. `p = NIL`, `p # q`): compare as integers.
            let i64t = self.ctx.i64_type();
            let to_int = |v: BasicValueEnum<'ctx>| match v {
                BasicValueEnum::PointerValue(p) => {
                    self.builder.build_ptr_to_int(p, i64t, "p2i").unwrap()
                }
                other => other.into_int_value(),
            };
            self.builder
                .build_int_compare(int_pred, to_int(lhs), to_int(rhs), "pcmp")
                .unwrap()
                .into()
        } else {
            self.builder
                .build_int_compare(int_pred, lhs.into_int_value(), rhs.into_int_value(), "icmp")
                .unwrap()
                .into()
        }
    }

    /// Coerce an integer value to a target integer type by zero-extension or
    /// truncation (no-op for equal widths or non-integer operands). Used to
    /// reconcile the default-width int constants used for enum ordinals,
    /// CHAR (i16), and subranges with their declared narrower/wider types.
    fn coerce_int(
        &self,
        v: BasicValueEnum<'ctx>,
        target: BasicTypeEnum<'ctx>,
    ) -> BasicValueEnum<'ctx> {
        if let (BasicValueEnum::IntValue(iv), BasicTypeEnum::IntType(it)) = (v, target) {
            let sw = iv.get_type().get_bit_width();
            let dw = it.get_bit_width();
            if sw == dw {
                v
            } else if sw < dw {
                self.builder.build_int_z_extend(iv, it, "zext").unwrap().into()
            } else {
                self.builder.build_int_truncate(iv, it, "trunc").unwrap().into()
            }
        } else {
            v
        }
    }

    /// Reconcile a float value to a target float type's width: a REAL (f64)
    /// constant or value stored into a REAL32/REAL16 slot narrows (FPTrunc); the
    /// reverse widens (FPExt). Same width / non-float pairs pass through. This is
    /// how a width-polymorphic real literal (`r32 := 3.14`) lands at the slot's
    /// precision, and how same-precision REAL32 arithmetic stays f32.
    fn coerce_float(
        &self,
        v: BasicValueEnum<'ctx>,
        target: BasicTypeEnum<'ctx>,
    ) -> BasicValueEnum<'ctx> {
        if let (BasicValueEnum::FloatValue(fv), BasicTypeEnum::FloatType(ft)) = (v, target) {
            let sw = fv.get_type().get_bit_width();
            let dw = ft.get_bit_width();
            if sw == dw {
                v
            } else if sw > dw {
                self.builder.build_float_trunc(fv, ft, "fptrunc").unwrap().into()
            } else {
                self.builder.build_float_ext(fv, ft, "fpext").unwrap().into()
            }
        } else {
            v
        }
    }

    /// Widen the narrower of two integer operands to the other's width so
    /// arithmetic and comparisons operate on matching types.
    fn coerce_int_pair(
        &self,
        lhs: BasicValueEnum<'ctx>,
        rhs: BasicValueEnum<'ctx>,
    ) -> (BasicValueEnum<'ctx>, BasicValueEnum<'ctx>) {
        if let (BasicValueEnum::IntValue(l), BasicValueEnum::IntValue(r)) = (lhs, rhs) {
            let lw = l.get_type().get_bit_width();
            let rw = r.get_type().get_bit_width();
            if lw < rw {
                (self.builder.build_int_z_extend(l, r.get_type(), "zext").unwrap().into(), rhs)
            } else if rw < lw {
                (lhs, self.builder.build_int_z_extend(r, l.get_type(), "zext").unwrap().into())
            } else {
                (lhs, rhs)
            }
        } else {
            (lhs, rhs)
        }
    }

    /// A `SYSTEM.ADDRESS` operand is an LLVM pointer; arithmetic on it is
    /// pointer arithmetic, performed on its pointer-sized integer value.
    fn ptr_operand_to_int(&self, v: BasicValueEnum<'ctx>) -> BasicValueEnum<'ctx> {
        match v {
            BasicValueEnum::PointerValue(p) => self
                .builder
                .build_ptr_to_int(p, self.ctx.i64_type(), "p2i")
                .unwrap()
                .into(),
            other => other,
        }
    }

    fn emit_binary(
        &self,
        op: BinOp,
        lhs: BasicValueEnum<'ctx>,
        rhs: BasicValueEnum<'ctx>,
    ) -> BasicValueEnum<'ctx> {
        use BinOp::*;
        // ADDRESS operands take part in arithmetic as pointer-sized integers;
        // an arithmetic result then carries the ADDRESS (pointer) type back so
        // it matches its IR type when stored or compared.
        let addr_operand = lhs.is_pointer_value() || rhs.is_pointer_value();
        let lhs = self.ptr_operand_to_int(lhs);
        let rhs = self.ptr_operand_to_int(rhs);
        // Reconcile mismatched integer operand widths (enum/CHAR/subrange).
        let (lhs, rhs) = self.coerce_int_pair(lhs, rhs);
        let result = match op {
            Add => self
                .builder
                .build_int_add(lhs.into_int_value(), rhs.into_int_value(), "add")
                .unwrap()
                .into(),
            Sub => self
                .builder
                .build_int_sub(lhs.into_int_value(), rhs.into_int_value(), "sub")
                .unwrap()
                .into(),
            Mul => self
                .builder
                .build_int_mul(lhs.into_int_value(), rhs.into_int_value(), "mul")
                .unwrap()
                .into(),
            Div => self
                .emit_floored_div(lhs.into_int_value(), rhs.into_int_value())
                .into(),
            Mod => self
                .emit_floored_mod(lhs.into_int_value(), rhs.into_int_value())
                .into(),
            Quot => self
                .builder
                .build_int_unsigned_div(
                    lhs.into_int_value(),
                    rhs.into_int_value(),
                    "quot",
                )
                .unwrap()
                .into(),
            Rem => self
                .builder
                .build_int_unsigned_rem(
                    lhs.into_int_value(),
                    rhs.into_int_value(),
                    "rem",
                )
                .unwrap()
                .into(),
            SRem => self
                .builder
                .build_int_signed_rem(
                    lhs.into_int_value(),
                    rhs.into_int_value(),
                    "srem",
                )
                .unwrap()
                .into(),
            BitAnd => self
                .builder
                .build_and(lhs.into_int_value(), rhs.into_int_value(), "band")
                .unwrap()
                .into(),
            BitOr => self
                .builder
                .build_or(lhs.into_int_value(), rhs.into_int_value(), "bor")
                .unwrap()
                .into(),
            BitXor => self
                .builder
                .build_xor(lhs.into_int_value(), rhs.into_int_value(), "bxor")
                .unwrap()
                .into(),
            Shl => self
                .builder
                .build_left_shift(lhs.into_int_value(), rhs.into_int_value(), "shl")
                .unwrap()
                .into(),
            Shr => self
                .builder
                .build_right_shift(
                    lhs.into_int_value(),
                    rhs.into_int_value(),
                    false,
                    "shr",
                )
                .unwrap()
                .into(),
            Eq => self.emit_compare(lhs, rhs, IntPredicate::EQ, FloatPredicate::OEQ),
            // `#` must be UNORDERED not-equal: for a NaN operand it is TRUE (and
            // is the exact negation of `=`/OEQ). The ordered ONE would make
            // `NaN # NaN` FALSE — i.e. NaN spuriously "equal" to NaN. The ORDER
            // comparisons below stay ordered (FALSE on NaN), per IEEE-754.
            Ne => self.emit_compare(lhs, rhs, IntPredicate::NE, FloatPredicate::UNE),
            Lt => self.emit_compare(lhs, rhs, IntPredicate::SLT, FloatPredicate::OLT),
            Le => self.emit_compare(lhs, rhs, IntPredicate::SLE, FloatPredicate::OLE),
            Gt => self.emit_compare(lhs, rhs, IntPredicate::SGT, FloatPredicate::OGT),
            Ge => self.emit_compare(lhs, rhs, IntPredicate::SGE, FloatPredicate::OGE),
            ULt => self.emit_compare(lhs, rhs, IntPredicate::ULT, FloatPredicate::OLT),
            ULe => self.emit_compare(lhs, rhs, IntPredicate::ULE, FloatPredicate::OLE),
            UGt => self.emit_compare(lhs, rhs, IntPredicate::UGT, FloatPredicate::OGT),
            UGe => self.emit_compare(lhs, rhs, IntPredicate::UGE, FloatPredicate::OGE),
            And => self
                .builder
                .build_and(lhs.into_int_value(), rhs.into_int_value(), "and")
                .unwrap()
                .into(),
            Or => self
                .builder
                .build_or(lhs.into_int_value(), rhs.into_int_value(), "or")
                .unwrap()
                .into(),
            // Float arithmetic is vector-aware: a SIMD lane vector is a
            // FloatVectorValue, so `+` on REAL32X4 lowers to a single
            // `fadd <4 x float>`.
            FAdd | FSub | FMul | FDiv => self.emit_float_arith(op, lhs, rhs),
        };
        // ADDRESS arithmetic yields an ADDRESS: convert the integer result back
        // to a pointer so it matches its IR type. Comparisons (which return a
        // BOOLEAN i1) and logical ops go through `emit_compare`/`build_and`,
        // are not arithmetic, and are left untouched.
        let is_arith = matches!(
            op,
            Add | Sub | Mul | Div | Mod | Quot | Rem | SRem | BitAnd | BitOr | Shl | Shr
        );
        if addr_operand && is_arith && let BasicValueEnum::IntValue(iv) = result {
            return self
                .builder
                .build_int_to_ptr(iv, self.ctx.ptr_type(inkwell::AddressSpace::default()), "i2p")
                .unwrap()
                .into();
        }
        result
    }

    /// `FAdd/FSub/FMul/FDiv` on either a scalar float or a SIMD lane vector.
    /// `build_float_*` is generic over `FloatMathValue`, which both `FloatValue`
    /// and `VectorValue` implement, so the vector path emits a packed op.
    fn emit_float_arith(
        &self,
        op: BinOp,
        lhs: BasicValueEnum<'ctx>,
        rhs: BasicValueEnum<'ctx>,
    ) -> BasicValueEnum<'ctx> {
        use BinOp::*;
        if lhs.is_vector_value() {
            let (l, r) = (lhs.into_vector_value(), rhs.into_vector_value());
            match op {
                FAdd => self.builder.build_float_add(l, r, "fadd").unwrap().into(),
                FSub => self.builder.build_float_sub(l, r, "fsub").unwrap().into(),
                FMul => self.builder.build_float_mul(l, r, "fmul").unwrap().into(),
                FDiv => self.builder.build_float_div(l, r, "fdiv").unwrap().into(),
                _ => unreachable!("emit_float_arith: non-float op {op:?}"),
            }
        } else {
            // Reconcile mismatched float widths (a REAL32 lane combined with a
            // REAL/f64 literal): widen the narrower operand so the op is
            // well-typed. The result carries the wider precision.
            let (mut l, mut r) = (lhs.into_float_value(), rhs.into_float_value());
            let lw = l.get_type().get_bit_width();
            let rw = r.get_type().get_bit_width();
            if lw < rw {
                l = self.builder.build_float_ext(l, r.get_type(), "fpext").unwrap();
            } else if rw < lw {
                r = self.builder.build_float_ext(r, l.get_type(), "fpext").unwrap();
            }
            match op {
                FAdd => self.builder.build_float_add(l, r, "fadd").unwrap().into(),
                FSub => self.builder.build_float_sub(l, r, "fsub").unwrap().into(),
                FMul => self.builder.build_float_mul(l, r, "fmul").unwrap().into(),
                FDiv => self.builder.build_float_div(l, r, "fdiv").unwrap().into(),
                _ => unreachable!("emit_float_arith: non-float op {op:?}"),
            }
        }
    }

    fn emit_floored_div(
        &self,
        a: inkwell::values::IntValue<'ctx>,
        b: inkwell::values::IntValue<'ctx>,
    ) -> inkwell::values::IntValue<'ctx> {
        let q = self.builder.build_int_signed_div(a, b, "q").unwrap();
        let qb = self.builder.build_int_mul(q, b, "qb").unwrap();
        let r = self.builder.build_int_sub(a, qb, "r").unwrap();
        let zero = a.get_type().const_zero();
        let r_nz = self
            .builder
            .build_int_compare(IntPredicate::NE, r, zero, "r_nz")
            .unwrap();
        let a_neg = self
            .builder
            .build_int_compare(IntPredicate::SLT, a, zero, "a_neg")
            .unwrap();
        let b_neg = self
            .builder
            .build_int_compare(IntPredicate::SLT, b, zero, "b_neg")
            .unwrap();
        let signs_diff = self.builder.build_xor(a_neg, b_neg, "signs_diff").unwrap();
        let need_adj = self
            .builder
            .build_and(r_nz, signs_diff, "need_adj")
            .unwrap();
        let one = a.get_type().const_int(1, false);
        let adj = self
            .builder
            .build_select(need_adj, one, zero, "adj")
            .unwrap()
            .into_int_value();
        self.builder.build_int_sub(q, adj, "floor_div").unwrap()
    }

    fn emit_floored_mod(
        &self,
        a: inkwell::values::IntValue<'ctx>,
        b: inkwell::values::IntValue<'ctx>,
    ) -> inkwell::values::IntValue<'ctx> {
        let fd = self.emit_floored_div(a, b);
        let fdb = self.builder.build_int_mul(fd, b, "fdb").unwrap();
        self.builder.build_int_sub(a, fdb, "floor_mod").unwrap()
    }

    fn emit_cast(
        &self,
        kind: CastKind,
        v: BasicValueEnum<'ctx>,
        target: BasicTypeEnum<'ctx>,
    ) -> BasicValueEnum<'ctx> {
        match kind {
            CastKind::IntTrunc => self
                .builder
                .build_int_truncate(v.into_int_value(), target.into_int_type(), "trunc")
                .unwrap()
                .into(),
            CastKind::IntZeroExt => self
                .builder
                .build_int_z_extend(v.into_int_value(), target.into_int_type(), "zext")
                .unwrap()
                .into(),
            CastKind::IntSignExt => self
                .builder
                .build_int_s_extend(v.into_int_value(), target.into_int_type(), "sext")
                .unwrap()
                .into(),
            CastKind::IntToFloat => self
                .builder
                .build_signed_int_to_float(
                    v.into_int_value(),
                    target.into_float_type(),
                    "itof",
                )
                .unwrap()
                .into(),
            CastKind::FloatToInt => self
                .builder
                .build_float_to_signed_int(
                    v.into_float_value(),
                    target.into_int_type(),
                    "ftoi",
                )
                .unwrap()
                .into(),
            CastKind::FloatExt => self
                .builder
                .build_float_ext(v.into_float_value(), target.into_float_type(), "fext")
                .unwrap()
                .into(),
            CastKind::FloatTrunc => self
                .builder
                .build_float_trunc(
                    v.into_float_value(),
                    target.into_float_type(),
                    "ftrunc",
                )
                .unwrap()
                .into(),
            CastKind::PtrToInt => {
                let it = target.into_int_type();
                match v {
                    BasicValueEnum::PointerValue(p) => {
                        self.builder.build_ptr_to_int(p, it, "ptr2int").unwrap().into()
                    }
                    // Already an integer (e.g. an address-sized value the IR
                    // produced directly): resize to the target width.
                    BasicValueEnum::IntValue(iv) => {
                        let (sw, dw) = (iv.get_type().get_bit_width(), it.get_bit_width());
                        if sw == dw {
                            iv.into()
                        } else if sw < dw {
                            self.builder.build_int_z_extend(iv, it, "ptr2int").unwrap().into()
                        } else {
                            self.builder.build_int_truncate(iv, it, "ptr2int").unwrap().into()
                        }
                    }
                    // A descriptor `{ptr, len}` (open array / DynamicString):
                    // take the integer value of its data pointer.
                    BasicValueEnum::StructValue(sv) => {
                        let p = self
                            .builder
                            .build_extract_value(sv, 0, "desc.ptr")
                            .unwrap()
                            .into_pointer_value();
                        self.builder.build_ptr_to_int(p, it, "ptr2int").unwrap().into()
                    }
                    _ => self
                        .builder
                        .build_ptr_to_int(v.into_pointer_value(), it, "ptr2int")
                        .unwrap()
                        .into(),
                }
            }
            CastKind::IntToPtr => {
                let pt = target.into_pointer_type();
                match v {
                    BasicValueEnum::IntValue(iv) => {
                        self.builder.build_int_to_ptr(iv, pt, "int2ptr").unwrap().into()
                    }
                    // Already a pointer (e.g. NIL / `ADDRESS(0)` folded to
                    // `ptr null`): a pointer-to-pointer cast is the identity
                    // under opaque pointers.
                    BasicValueEnum::PointerValue(_) => v,
                    _ => self
                        .builder
                        .build_int_to_ptr(v.into_int_value(), pt, "int2ptr")
                        .unwrap()
                        .into(),
                }
            }
            CastKind::BitCast | CastKind::OrdToChar | CastKind::CharToOrd => {
                match (v, target) {
                    (BasicValueEnum::IntValue(iv), BasicTypeEnum::IntType(it)) => {
                        let sw = iv.get_type().get_bit_width();
                        let dw = it.get_bit_width();
                        if sw == dw {
                            iv.into()
                        } else if sw < dw {
                            self.builder
                                .build_int_z_extend(iv, it, "cast_zext")
                                .unwrap()
                                .into()
                        } else {
                            self.builder
                                .build_int_truncate(iv, it, "cast_trunc")
                                .unwrap()
                                .into()
                        }
                    }
                    // True bit reinterpretation between REAL and a same-width
                    // ordinal (SYSTEM.CAST type-punning, e.g. LowReal/LowLong).
                    (BasicValueEnum::FloatValue(fv), BasicTypeEnum::IntType(it)) => {
                        self.builder.build_bit_cast(fv, it, "f2i_bits").unwrap()
                    }
                    (BasicValueEnum::IntValue(iv), BasicTypeEnum::FloatType(ft)) => {
                        self.builder.build_bit_cast(iv, ft, "i2f_bits").unwrap()
                    }
                    // Pointer ↔ pointer (opaque) and same-type: identity.
                    _ => v,
                }
            }
            CastKind::MemReinterpret => {
                // One operand is an aggregate (RECORD / closed ARRAY): reinterpret
                // the bits through a stack slot sized to the LARGER of source/target
                // (so the store is always in-bounds), then load the target type.
                let src_ty = v.get_type();
                let s_sz = src_ty.size_of().and_then(|c| c.get_zero_extended_constant()).unwrap_or(0);
                let d_sz = target.size_of().and_then(|c| c.get_zero_extended_constant()).unwrap_or(0);
                let slot_ty = if d_sz >= s_sz { target } else { src_ty };
                let slot = self.builder.build_alloca(slot_ty, "reinterp.slot").unwrap();
                self.builder.build_store(slot, v).unwrap();
                self.builder.build_load(target, slot, "reinterp").unwrap()
            }
        }
    }
}
