//! NewM2 LLVM backend: IR -> LLVM IR + MCJIT execution.
//!
//! inkwell-based emission with the `llvm22-1` feature, matching the
//! pinned major from NCL. SEH unwind registration via a custom MCJIT
//! memory manager (`jit_mm`) copied from NCL so that Rust panics inside
//! runtime helpers unwind cleanly through JIT'd Modula-2 frames on
//! Windows.
//!
//! Under GC mode, stack maps are emitted via `gc.statepoint` /
//! `gc.relocate`. Under `--no-gc`, those are omitted entirely.
//!
//! ## Entry points
//!
//! - [`emit_llvm_ir`] - emit LLVM IR text for `dump-llvm`.
//! - [`emit_asm`] - emit machine assembly text for `dump-asm`.
//! - [`run_module`] - JIT-compile and execute `ModuleBody` / main.

pub mod codegen;
pub mod jit_mm;

use std::ffi::CStr;

use inkwell::context::Context;
use inkwell::module::Module;
use inkwell::passes::PassBuilderOptions;
use inkwell::targets::{CodeModel, FileType, RelocMode, Target, TargetMachine};
use inkwell::values::AsValueRef;
use inkwell::OptimizationLevel;

use newm2_ir::{Global, IrModule};
use newm2_sema::SemaResult;

pub use codegen::{CodegenOptions, emit_module};

/// Return the LLVM IR text for `ir` (used by `dump-llvm`).
pub fn emit_llvm_ir(ir: &IrModule, sema: &SemaResult, opts: CodegenOptions) -> String {
    let ctx = Context::create();
    let module = codegen::emit_module(&ctx, ir, sema, opts);
    module.print_to_string().to_string()
}

/// Return the machine-code assembly text (AT&T syntax) for `ir`
/// (used by `dump-asm`).
pub fn emit_asm(ir: &IrModule, sema: &SemaResult, opts: CodegenOptions) -> Result<String, String> {
    codegen::init_llvm();
    let ctx = Context::create();
    let module = codegen::emit_module(&ctx, ir, sema, opts);
    module
        .verify()
        .map_err(|e| format!("LLVM verify: {e}"))?;

    let triple = TargetMachine::get_default_triple();
    let target = Target::from_triple(&triple)
        .map_err(|e| format!("Target::from_triple: {e}"))?;
    let tm = target
        .create_target_machine(
            &triple,
            "generic",
            "",
            opt_level(opts.opt_level),
            RelocMode::Default,
            CodeModel::Default,
        )
        .ok_or("create_target_machine failed")?;

    optimize_module(&module, &tm, opts.opt_level)?;
    let buf = tm
        .write_to_memory_buffer(&module, FileType::Assembly)
        .map_err(|e| format!("write_to_memory_buffer: {e}"))?;
    let bytes = buf.as_slice();
    Ok(String::from_utf8_lossy(bytes).into_owned())
}

/// Emit a native **object file** for ahead-of-time (`.exe`) compilation.
///
/// All `irs` (in dependency / topological order — imports first, the program
/// module last) are lowered with AOT codegen (constant vtables), then a small
/// driver is synthesised: a constant `nm2_aot_table` of `{body, final}`
/// function pointers and a C `main` that calls `nm2_aot_run` (in the runtime)
/// with it. The orchestrator reproduces the JIT's init/finalize/HALT semantics.
/// The object is written to `out_path`; the caller links it against the runtime
/// static library and the system libraries to produce the executable.
pub fn emit_aot_object(
    irs: &[&IrModule],
    sema: &SemaResult,
    opts: CodegenOptions,
    out_path: &std::path::Path,
) -> Result<(), String> {
    emit_object_inner(irs, sema, opts, out_path, true)
}

/// Emit the modules in `irs` as a standalone LIBRARY object: their procedures,
/// statics, module bodies/finalizers, and the runtime forwarders, but NO `main`
/// and NO `nm2_aot_table`. A program linked against this provides its own driver
/// over the full init order (the library's `{Module}.body`/`.final` symbols are
/// referenced externally). This is what `build-stdlib` archives into `stdlib.lib`.
pub fn emit_library_object(
    irs: &[&IrModule],
    sema: &SemaResult,
    opts: CodegenOptions,
    out_path: &std::path::Path,
) -> Result<(), String> {
    emit_object_inner(irs, sema, opts, out_path, false)
}

fn emit_object_inner(
    irs: &[&IrModule],
    sema: &SemaResult,
    opts: CodegenOptions,
    out_path: &std::path::Path,
    with_driver: bool,
) -> Result<(), String> {
    codegen::init_llvm();
    let ctx = Context::create();
    let aot_opts = CodegenOptions { aot: true, ..opts };
    let module = emit_linked_module(&ctx, irs, sema, aot_opts)?;

    emit_runtime_forwarders(&ctx, &module);
    if with_driver {
        emit_aot_driver(&ctx, &module, irs, opts.protect_heap);
    }
    finish_object(&module, opts, out_path)
}

/// Emit a PROGRAM object that links against a prebuilt standard library: lower
/// only `irs` (the program's own modules) and synthesise the AOT driver over the
/// FULL `init_order` (every module, program + stdlib, in initialisation order).
/// Stdlib `{Mod}.body`/`.final` entries are referenced as external symbols
/// resolved from `stdlib.lib` at link time. `init_order` is `(name, has_final)`.
pub fn emit_aot_object_with_init_order(
    irs: &[&IrModule],
    init_order: &[(String, bool, bool)],
    sema: &SemaResult,
    opts: CodegenOptions,
    out_path: &std::path::Path,
) -> Result<(), String> {
    codegen::init_llvm();
    let ctx = Context::create();
    let aot_opts = CodegenOptions { aot: true, ..opts };
    let module = emit_linked_module(&ctx, irs, sema, aot_opts)?;
    emit_runtime_forwarders(&ctx, &module);
    emit_aot_driver_with_order(&ctx, &module, init_order, opts.protect_heap);
    finish_object(&module, opts, out_path)
}

fn finish_object(module: &Module<'_>, opts: CodegenOptions, out_path: &std::path::Path) -> Result<(), String> {
    module
        .verify()
        .map_err(|e| format!("LLVM verify (AOT): {e}"))?;

    let triple = TargetMachine::get_default_triple();
    let target = Target::from_triple(&triple)
        .map_err(|e| format!("Target::from_triple: {e}"))?;
    let tm = target
        .create_target_machine(
            &triple,
            "generic",
            "",
            opt_level(opts.opt_level),
            // PIC so the static linker is free to place the image; the default
            // on Windows is fine either way, but Default keeps parity with JIT.
            RelocMode::Default,
            CodeModel::Default,
        )
        .ok_or("create_target_machine failed")?;

    optimize_module(module, &tm, opts.opt_level)?;
    tm.write_to_file(module, FileType::Object, out_path)
        .map_err(|e| format!("write object {}: {e}", out_path.display()))
}

/// The dotted M2 intrinsic names the ISO library calls (e.g. `NM2RT.Raise`,
/// `NM2.IO.WriteText`) paired with the runtime export they forward to (e.g.
/// `nm2_raise`). The JIT resolves these by address mapping (`bind_runtime_helpers`);
/// AOT instead emits a forwarder body for each so the static linker resolves
/// the `nm2_*` symbol from the runtime library.
///
/// MUST stay in sync with `bind_runtime_helpers`. A missing pair fails loudly
/// as an "unresolved external symbol" at link time — never a silent miscompile.
/// Plain `nm2_*`-named references (HALT, run_protected, alloc, …) resolve from
/// the runtime library directly and need no forwarder.
fn runtime_forwarder_pairs() -> Vec<(String, &'static str)> {
    let mut v: Vec<(String, &'static str)> = vec![
        ("STextIO.WriteString", "nm2_io_write_ustr"),
        ("STextIO.WriteLn", "nm2_io_write_ln"),
        ("STextIO.WriteChar", "nm2_io_write_uchar"),
        ("NM2.IO.WriteText", "nm2_io_write_text"),
        ("NM2.IO.WriteErrText", "nm2_io_write_err_text"),
        ("NM2.IO.WriteBytes", "nm2_io_write_bytes"),
        ("NM2.IO.Flush", "nm2_io_flush"),
        ("NM2.IO.FlushErr", "nm2_io_flush_err"),
        ("NM2.IO.PeekChar", "nm2_io_peek_char"),
        ("NM2.IO.ConsumeChar", "nm2_io_consume_char"),
        ("NM2.IO.ReadText", "nm2_io_read_text"),
        ("SWholeIO.WriteInt", "nm2_io_write_int"),
        ("SWholeIO.WriteCard", "nm2_io_write_card"),
        ("InOut.WriteString", "nm2_io_write_ustr"),
        ("InOut.WriteLn", "nm2_io_write_ln"),
        ("InOut.Write", "nm2_io_write_uchar"),
        ("InOut.WriteInt", "nm2_io_write_int"),
        ("InOut.WriteCard", "nm2_io_write_card"),
        ("NM2.IO.WriteUChar", "nm2_io_write_uchar"),
        ("NM2.IO.WriteUInt", "nm2_io_write_uint"),
        ("NM2.IO.WriteUCard", "nm2_io_write_ucard"),
        ("NM2.IO.WriteUString", "nm2_io_write_ustr"),
        ("SYSTEM.COLLECT", "nm2_collect"),
        ("SYSTEM.GCREPORT", "nm2_gcreport"),
        ("NM2Str.Copy", "nm2_copy_string"),
        ("NM2Str.WCopy", "nm2_copy_wstring"),
        ("NM2Str.WNCopy", "nm2_copy_wstring_narrow"),
        ("NM2Str.Length", "nm2_string_length"),
        ("NM2Str.WLength", "nm2_wstr_length"),
        ("NM2Math.Frexp", "nm2_math_frexp"),
        ("NM2Math.Ldexp", "nm2_math_ldexp"),
        ("NM2Math.Modf", "nm2_math_modf"),
        ("NM2Store.Allocate", "nm2_storage_allocate"),
        ("NM2Store.Deallocate", "nm2_storage_deallocate"),
        ("NM2Clock.Now", "nm2_sysclock_now"),
        ("NM2Args.Count", "nm2_program_args_count"),
        ("NM2Args.Copy", "nm2_program_args_copy"),
        ("NM2.File.Open", "nm2_file_open"),
        ("NM2.File.Close", "nm2_file_close"),
        ("NM2.File.Read", "nm2_file_read"),
        ("NM2.File.Write", "nm2_file_write"),
        ("NM2.File.Seek", "nm2_file_seek"),
        ("NM2.File.Tell", "nm2_file_tell"),
        ("NM2.File.Size", "nm2_file_size"),
        ("NM2.File.Flush", "nm2_file_flush"),
        ("NM2.File.WriteText", "nm2_file_write_text"),
        ("NM2.File.ReadText", "nm2_file_read_text"),
        ("NM2.Storage.Allocate", "nm2_storage_allocate"),
        ("NM2.Storage.Deallocate", "nm2_storage_deallocate"),
        ("NM2.SysClock.Now", "nm2_sysclock_now"),
        ("NM2RT.ComInit", "nm2_com_init"),
        ("NM2RT.ComUninit", "nm2_com_uninit"),
        ("NM2RT.ComGetMalloc", "nm2_com_get_malloc"),
        ("NM2RT.ComDrive", "nm2_com_drive"),
        ("NM2RT.SortInts", "nm2_sort_i64"),
        ("NM2RT.GuidEq", "nm2_guid_eq"),
        ("NM2RT.HasHalted", "nm2_term_has_halted"),
        ("NM2RT.IsTerminating", "nm2_term_is_terminating"),
        ("NM2.Math.Frexp", "nm2_math_frexp"),
        ("NM2.Math.Ldexp", "nm2_math_ldexp"),
        ("NM2.Math.Modf", "nm2_math_modf"),
        ("NM2.ProgramArgs.Count", "nm2_program_args_count"),
        ("NM2.ProgramArgs.Copy", "nm2_program_args_copy"),
        ("NM2RT.AllocateExceptionSource", "nm2_alloc_exception_source"),
        ("NM2RT.Raise", "nm2_raise"),
        ("NM2RT.Reraise", "nm2_reraise"),
        ("NM2RT.CurrentExceptionNumber", "nm2_current_number"),
        ("NM2RT.CurrentExceptionSource", "nm2_current_source"),
        ("NM2RT.M2Source", "nm2_m2_source"),
        ("NM2RT.IsCurrentExceptionSource", "nm2_is_current_source"),
        ("NM2RT.IsExceptionalExecution", "nm2_is_exceptional_execution"),
        ("NM2RT.ExceptionHandled", "nm2_exception_handled"),
        ("NM2RT.GetExceptionMessage", "nm2_current_message"),
        // Simulated libc (clean-room printf/exit equivalents).
        ("libc.printf", "nm2_libc_printf"),
        ("libc.exit", "nm2_libc_exit"),
    ]
    .into_iter()
    .map(|(a, b)| (a.to_string(), b))
    .collect();

    // Transcendental surface: NM2Math.<f> and NM2Math.L<f> (LONGREAL) share one
    // f64 backing, matching the generated binds in bind_runtime_helpers.
    let math: &[(&str, &'static str)] = &[
        ("sin", "nm2_math_sin"), ("cos", "nm2_math_cos"), ("tan", "nm2_math_tan"),
        ("arcsin", "nm2_math_arcsin"), ("arccos", "nm2_math_arccos"),
        ("arctan", "nm2_math_arctan"), ("arctan2", "nm2_math_arctan2"),
        ("sqrt", "nm2_math_sqrt"), ("exp", "nm2_math_exp"), ("ln", "nm2_math_ln"),
        ("lg", "nm2_math_lg"), ("pow", "nm2_math_pow"), ("sinh", "nm2_math_sinh"),
        ("cosh", "nm2_math_cosh"), ("tanh", "nm2_math_tanh"),
        ("arcsinh", "nm2_math_arcsinh"), ("arccosh", "nm2_math_arccosh"),
        ("arctanh", "nm2_math_arctanh"), ("floor", "nm2_math_floor"),
        ("truncToInt", "nm2_math_trunc_to_int"), ("truncToCard", "nm2_math_trunc_to_card"),
        // extended surface
        ("ceil", "nm2_math_ceil"), ("round", "nm2_math_round"), ("trunc", "nm2_math_trunc"),
        ("log10", "nm2_math_log10"), ("exp2", "nm2_math_exp2"), ("cbrt", "nm2_math_cbrt"),
        ("expm1", "nm2_math_expm1"), ("log1p", "nm2_math_log1p"),
        ("degrees", "nm2_math_degrees"), ("radians", "nm2_math_radians"), ("sign", "nm2_math_sign"),
        ("hypot", "nm2_math_hypot"), ("copysign", "nm2_math_copysign"),
        ("min", "nm2_math_min"), ("max", "nm2_math_max"),
        ("log", "nm2_math_log"), ("fmod", "nm2_math_fmod"),
    ];
    for (n, sym) in math {
        v.push((format!("NM2Math.{n}"), sym));
        v.push((format!("NM2Math.L{n}"), sym));
    }
    v
}

/// Emit a forwarder body for every referenced (undefined) M2 intrinsic name,
/// calling the corresponding runtime export. The forwarder copies its LLVM
/// signature from the existing declaration, so signatures stay correct without
/// re-deriving them here.
fn emit_runtime_forwarders<'ctx>(ctx: &'ctx Context, module: &Module<'ctx>) {
    use inkwell::module::Linkage;

    let builder = ctx.create_builder();
    for (m2_name, rust_sym) in runtime_forwarder_pairs() {
        let Some(decl) = module.get_function(&m2_name) else { continue };
        // Only undefined declarations need a body.
        if decl.count_basic_blocks() > 0 {
            continue;
        }
        let fty = decl.get_type();
        let target = module
            .get_function(rust_sym)
            .unwrap_or_else(|| module.add_function(rust_sym, fty, Some(Linkage::External)));

        // linkonce_odr: both the prebuilt stdlib object and a program object may
        // define the same forwarder; the linker keeps one and discards the rest.
        decl.set_linkage(Linkage::LinkOnceODR);
        let bb = ctx.append_basic_block(decl, "entry");
        builder.position_at_end(bb);
        let args: Vec<_> = decl.get_params().iter().map(|p| (*p).into()).collect();
        let call = builder
            .build_call(target, &args, "")
            .expect("build_call forwarder");
        match fty.get_return_type() {
            Some(_) => {
                let r = call
                    .try_as_basic_value()
                    .basic()
                    .expect("forwarder target returns a value");
                builder.build_return(Some(&r)).expect("build_return forwarder");
            }
            None => {
                builder.build_return(None).expect("build_return void forwarder");
            }
        }
    }
}

/// Synthesise the AOT entry driver into `module`: a constant `nm2_aot_table`
/// of `{body, final}` function pointers (one record per module, in `irs`
/// order) and `int main()` that tail-calls `nm2_aot_run(table, N)`.
/// Emit `call void @nm2_heap_guard_force_on()` at the current builder position —
/// the `--protect-heap` self-enable hook injected at program entry.
fn emit_force_guard<'ctx>(ctx: &'ctx Context, module: &Module<'ctx>, builder: &inkwell::builder::Builder<'ctx>) {
    use inkwell::module::Linkage;
    let void_ty = ctx.void_type().fn_type(&[], false);
    let force = module
        .get_function("nm2_heap_guard_force_on")
        .unwrap_or_else(|| module.add_function("nm2_heap_guard_force_on", void_ty, Some(Linkage::External)));
    builder.build_call(force, &[], "").expect("build_call nm2_heap_guard_force_on");
}

fn emit_aot_driver<'ctx>(ctx: &'ctx Context, module: &Module<'ctx>, irs: &[&IrModule], protect_heap: bool) {
    use inkwell::module::Linkage;
    use inkwell::values::BasicValue;

    let ptr_ty = ctx.ptr_type(inkwell::AddressSpace::default());
    let i32_ty = ctx.i32_type();
    let i64_ty = ctx.i64_type();
    // AotEntry == { ptr body, ptr finalizer } (matches newm2_runtime::AotEntry).
    let entry_ty = ctx.struct_type(&[ptr_ty.into(), ptr_ty.into()], false);

    let fn_ptr = |name: &str| -> inkwell::values::PointerValue<'ctx> {
        match module.get_function(name) {
            Some(f) => f.as_global_value().as_pointer_value(),
            None => ptr_ty.const_null(),
        }
    };

    let mut records = Vec::with_capacity(irs.len());
    for ir in irs {
        let body = fn_ptr(&format!("{}.body", ir.name));
        let fin = fn_ptr(&format!("{}.final", ir.name));
        records.push(entry_ty.const_named_struct(&[body.into(), fin.into()]));
    }
    let table_ty = entry_ty.array_type(records.len() as u32);
    let table_init = entry_ty.const_array(&records);
    let table_gv = module.add_global(table_ty, None, "nm2_aot_table");
    table_gv.set_initializer(&table_init);
    table_gv.set_constant(true);
    table_gv.set_linkage(Linkage::Private);

    // declare i32 @nm2_aot_run(ptr, i64)
    let run_ty = i32_ty.fn_type(&[ptr_ty.into(), i64_ty.into()], false);
    let run_fn = match module.get_function("nm2_aot_run") {
        Some(f) => f,
        None => module.add_function("nm2_aot_run", run_ty, Some(Linkage::External)),
    };

    // define i32 @main() { ret i32 (call nm2_aot_run(table, N)) }
    let main_ty = i32_ty.fn_type(&[], false);
    let main_fn = module.add_function("main", main_ty, None);
    let builder = ctx.create_builder();
    let bb = ctx.append_basic_block(main_fn, "entry");
    builder.position_at_end(bb);
    if protect_heap {
        emit_force_guard(ctx, module, &builder);
    }
    let n = i64_ty.const_int(irs.len() as u64, false);
    let table_ptr = table_gv.as_pointer_value();
    let rc = builder
        .build_call(run_fn, &[table_ptr.into(), n.into()], "rc")
        .expect("build_call nm2_aot_run")
        .try_as_basic_value()
        .basic()
        .expect("nm2_aot_run returns i32");
    builder
        .build_return(Some(&rc.as_basic_value_enum()))
        .expect("build_return main");
}

/// Like [`emit_aot_driver`] but driven by an explicit full init order of
/// `(module name, has_finalizer)` — used when linking against a prebuilt stdlib,
/// where the stdlib modules' bodies/finalizers are external symbols.
fn emit_aot_driver_with_order<'ctx>(
    ctx: &'ctx Context,
    module: &Module<'ctx>,
    init_order: &[(String, bool, bool)],
    protect_heap: bool,
) {
    use inkwell::module::Linkage;
    use inkwell::values::BasicValue;

    let ptr_ty = ctx.ptr_type(inkwell::AddressSpace::default());
    let i32_ty = ctx.i32_type();
    let i64_ty = ctx.i64_type();
    let entry_ty = ctx.struct_type(&[ptr_ty.into(), ptr_ty.into()], false);
    let void_fn_ty = ctx.void_type().fn_type(&[], false);

    // Resolve a `{name}.body`/`.final` table slot: use the local definition if
    // present (a program module's own function); else, IF the module actually
    // has that function (a program module computed it, or the manifest recorded
    // it for a stdlib module), declare it external for the linker to resolve from
    // stdlib.lib; otherwise leave the slot null. Many modules have no body and/or
    // no finalizer — referencing a non-existent one would be an unresolved
    // external, so the `exists` flag is essential.
    let slot = |name: &str, exists: bool| -> inkwell::values::PointerValue<'ctx> {
        if let Some(f) = module.get_function(name) {
            f.as_global_value().as_pointer_value()
        } else if exists {
            module
                .add_function(name, void_fn_ty, Some(Linkage::External))
                .as_global_value()
                .as_pointer_value()
        } else {
            ptr_ty.const_null()
        }
    };

    let mut records = Vec::with_capacity(init_order.len());
    for (name, has_body, has_final) in init_order {
        let body = slot(&format!("{name}.body"), *has_body);
        let fin = slot(&format!("{name}.final"), *has_final);
        records.push(entry_ty.const_named_struct(&[body.into(), fin.into()]));
    }
    let table_ty = entry_ty.array_type(records.len() as u32);
    let table_init = entry_ty.const_array(&records);
    let table_gv = module.add_global(table_ty, None, "nm2_aot_table");
    table_gv.set_initializer(&table_init);
    table_gv.set_constant(true);
    table_gv.set_linkage(Linkage::Private);

    let run_ty = i32_ty.fn_type(&[ptr_ty.into(), i64_ty.into()], false);
    let run_fn = module
        .get_function("nm2_aot_run")
        .unwrap_or_else(|| module.add_function("nm2_aot_run", run_ty, Some(Linkage::External)));

    let main_ty = i32_ty.fn_type(&[], false);
    let main_fn = module.add_function("main", main_ty, None);
    let builder = ctx.create_builder();
    let bb = ctx.append_basic_block(main_fn, "entry");
    builder.position_at_end(bb);
    if protect_heap {
        emit_force_guard(ctx, module, &builder);
    }
    let n = i64_ty.const_int(init_order.len() as u64, false);
    let table_ptr = table_gv.as_pointer_value();
    let rc = builder
        .build_call(run_fn, &[table_ptr.into(), n.into()], "rc")
        .expect("build_call nm2_aot_run")
        .try_as_basic_value()
        .basic()
        .expect("nm2_aot_run returns i32");
    builder
        .build_return(Some(&rc.as_basic_value_enum()))
        .expect("build_return main");
}

/// ORC object-linking-layer backed by our SEH-registering memory manager
/// ([`jit_mm`]). The default ORC layers (JITLink and the stock RTDyld/Section
/// memory manager) do NOT register Windows SEH unwind tables for every JIT'd
/// frame, so unwinding through a minimal frame (e.g. `HALT`, or an exception
/// raised inside a procedure) crashes. Routing the layer through `jit_mm`'s
/// `RtlAddFunctionTable` registration — exactly what MCJIT used — fixes that.
///
/// The llvm-sys binding for `…WithMCJITMemoryManagerLikeCallbacks` is wrong (it
/// omits `CreateContextCtx` and types `CreateContext` as returning `()` instead
/// of `void*`), so we declare the function ourselves with the correct ABI.
mod orc_seh {
    use crate::jit_mm;
    use llvm_sys::execution_engine::{
        LLVMMemoryManagerAllocateCodeSectionCallback, LLVMMemoryManagerAllocateDataSectionCallback,
        LLVMMemoryManagerDestroyCallback, LLVMMemoryManagerFinalizeMemoryCallback,
    };
    use llvm_sys::orc2::{LLVMOrcExecutionSessionRef, LLVMOrcObjectLayerRef};
    use std::ffi::{c_char, c_void};

    unsafe extern "C" {
        fn LLVMOrcCreateRTDyldObjectLinkingLayerWithMCJITMemoryManagerLikeCallbacks(
            ES: LLVMOrcExecutionSessionRef,
            CreateContextCtx: *mut c_void,
            CreateContext: extern "C" fn(*mut c_void) -> *mut c_void,
            NotifyTerminating: extern "C" fn(*mut c_void),
            AllocateCodeSection: LLVMMemoryManagerAllocateCodeSectionCallback,
            AllocateDataSection: LLVMMemoryManagerAllocateDataSectionCallback,
            FinalizeMemory: LLVMMemoryManagerFinalizeMemoryCallback,
            Destroy: LLVMMemoryManagerDestroyCallback,
        ) -> LLVMOrcObjectLayerRef;
    }

    /// LLJIT object-layer factory. `ctx` is the shared `JitMm` we threaded
    /// through `SetObjectLinkingLayerCreator`, reused as the `CreateContextCtx`.
    pub(crate) extern "C" fn obj_layer_creator(
        ctx: *mut c_void,
        es: LLVMOrcExecutionSessionRef,
        _triple: *const c_char,
    ) -> LLVMOrcObjectLayerRef {
        unsafe {
            LLVMOrcCreateRTDyldObjectLinkingLayerWithMCJITMemoryManagerLikeCallbacks(
                es,
                ctx,
                jit_mm::create_context,
                jit_mm::notify_terminating,
                jit_mm::allocate_code_section,
                jit_mm::allocate_data_section,
                jit_mm::finalize_memory,
                Some(jit_mm::orc_destroy),
            )
        }
    }
}

/// ORC LLJIT execution path (the MCJIT successor): emit the linked module to an
/// in-memory relocatable object, load it via `LLVMOrcLLJITAddObjectFile` (RTDyld
/// relocates already-emitted machine code), define the runtime/extern bindings
/// as absolute symbols, then run each module body in topo order. The object-file
/// entry point is also what lets the JIT load a prebuilt stdlib object later.
pub fn run_modules_orc(
    irs: &[&IrModule],
    entry_module_name: &str,
    sema: &SemaResult,
    opts: CodegenOptions,
) -> Result<i32, String> {
    use llvm_sys::error::{LLVMConsumeError, LLVMErrorRef, LLVMGetErrorMessage};
    use llvm_sys::orc2::lljit::{
        LLVMOrcCreateLLJIT, LLVMOrcCreateLLJITBuilder, LLVMOrcLLJITAddObjectFile,
        LLVMOrcLLJITGetMainJITDylib, LLVMOrcLLJITLookup, LLVMOrcLLJITMangleAndIntern,
        LLVMOrcLLJITRef,
    };
    use llvm_sys::orc2::{
        LLVMJITEvaluatedSymbol, LLVMJITSymbolFlags, LLVMOrcAbsoluteSymbols, LLVMOrcCSymbolMapPair,
        LLVMOrcExecutorAddress, LLVMOrcJITDylibDefine,
    };

    let _ = entry_module_name;
    codegen::init_llvm();
    let ctx = Context::create();
    let module = emit_linked_module(&ctx, irs, sema, opts)?;
    module.verify().map_err(|e| format!("LLVM verify (ORC): {e}"))?;

    // Emit the linked module to an in-memory relocatable object.
    let triple = TargetMachine::get_default_triple();
    let target =
        Target::from_triple(&triple).map_err(|e| format!("Target::from_triple: {e}"))?;
    let tm = target
        .create_target_machine(
            &triple,
            "generic",
            "",
            opt_level(opts.opt_level),
            RelocMode::Default,
            CodeModel::Default,
        )
        .ok_or("create_target_machine failed")?;
    optimize_module(&module, &tm, opts.opt_level)?;
    let obj = tm
        .write_to_memory_buffer(&module, FileType::Object)
        .map_err(|e| format!("ORC emit object: {e}"))?;

    // Create the LLJIT with the SEH-registering RTDyld object layer (jit_mm).
    let mut jit: LLVMOrcLLJITRef = std::ptr::null_mut();
    let builder = unsafe { LLVMOrcCreateLLJITBuilder() };
    let mm_ctx = jit_mm::new_context();
    unsafe {
        llvm_sys::orc2::lljit::LLVMOrcLLJITBuilderSetObjectLinkingLayerCreator(
            builder,
            orc_seh::obj_layer_creator,
            mm_ctx,
        );
    }
    let err = unsafe { LLVMOrcCreateLLJIT(&mut jit, builder) };
    let orc_err = |what: &str, err: LLVMErrorRef| -> String {
        let m = unsafe { LLVMGetErrorMessage(err) };
        let s = unsafe { CStr::from_ptr(m) }.to_string_lossy().into_owned();
        unsafe { llvm_sys::error::LLVMDisposeErrorMessage(m) };
        format!("ORC {what}: {s}")
    };
    if !err.is_null() {
        return Err(orc_err("CreateLLJIT", err));
    }
    let main_jd = unsafe { LLVMOrcLLJITGetMainJITDylib(jit) };

    // Define every runtime-helper / external `(name, address)` binding as an
    // absolute symbol, so the loaded object's external references resolve to the
    // driver process's runtime (one shared runtime instance — same as MCJIT).
    let mut sym_map: Vec<LLVMOrcCSymbolMapPair> = Vec::new();
    {
        let mut collector = |name: &str, addr: *const ()| {
            // Only define symbols the module references but does NOT define
            // (an undefined declaration), so we never duplicate a module symbol.
            match module.get_function(name) {
                Some(f) if f.count_basic_blocks() == 0 => {}
                _ => return,
            }
            let Ok(cname) = std::ffi::CString::new(name) else { return };
            let interned = unsafe { LLVMOrcLLJITMangleAndIntern(jit, cname.as_ptr()) };
            sym_map.push(LLVMOrcCSymbolMapPair {
                Name: interned,
                Sym: LLVMJITEvaluatedSymbol {
                    Address: addr as LLVMOrcExecutorAddress,
                    // Exported (1) | Callable (4).
                    Flags: LLVMJITSymbolFlags { GenericFlags: 1 | 4, TargetFlags: 0 },
                },
            });
        };
        for_each_runtime_binding(&module, opts, &mut collector);
        for_each_external_binding(irs, &mut collector);
    }
    if !sym_map.is_empty() {
        let mu = unsafe { LLVMOrcAbsoluteSymbols(sym_map.as_mut_ptr(), sym_map.len()) };
        let err = unsafe { LLVMOrcJITDylibDefine(main_jd, mu) };
        if !err.is_null() {
            return Err(orc_err("define absolute symbols", err));
        }
    }

    // Hand the object to the JIT (consumes the buffer; RTDyld relocates it).
    let obj_ref = obj.as_mut_ptr();
    std::mem::forget(obj);
    let err = unsafe { LLVMOrcLLJITAddObjectFile(jit, main_jd, obj_ref) };
    if !err.is_null() {
        return Err(orc_err("AddObjectFile", err));
    }

    // Resolve a symbol to its executor address (0 = absent).
    let orc_lookup = |name: &str| -> u64 {
        let Ok(c) = std::ffi::CString::new(name) else { return 0 };
        let mut addr: LLVMOrcExecutorAddress = 0;
        let err = unsafe { LLVMOrcLLJITLookup(jit, &mut addr, c.as_ptr()) };
        if !err.is_null() {
            unsafe { LLVMConsumeError(err) };
            return 0;
        }
        addr
    };

    #[cfg(feature = "gc")]
    if opts.memory_mode == newm2_ir::MemoryMode::Gc {
        use newm2_runtime::nm2_init_gc;
        let stack_sentinel = 0usize;
        unsafe { nm2_init_gc((&stack_sentinel as *const usize).cast::<u8>()) };
    }

    if opts.memory_mode == newm2_ir::MemoryMode::Gc {
        for ir in irs {
            let addr = orc_lookup(&format!("{}.init_roots", ir.name));
            if addr != 0 {
                let f: extern "C" fn() = unsafe { std::mem::transmute(addr) };
                f();
            }
        }
    }

    patch_vtables(irs, &orc_lookup)?;
    register_jit_symbols(irs, &orc_lookup);
    newm2_runtime::nm2_finalize_jit_symbols();
    newm2_runtime::nm2_install_crash_handler();

    // Run each module body in dependency order; finalizers in reverse. (The JIT
    // is intentionally not disposed — the executed/registered code stays mapped,
    // matching the MCJIT path which leaks its engine.)
    let mut initialized = 0usize;
    let mut first_error: Option<String> = None;
    let mut halt_code: Option<i32> = None;
    for ir in irs {
        let addr = orc_lookup(&format!("{}.body", ir.name));
        match run_void_at(addr, &ir.name, "body") {
            RunOutcome::Ran => initialized += 1,
            RunOutcome::Halted(code) => {
                initialized += 1;
                halt_code = Some(code);
                break;
            }
            RunOutcome::Failed(e) => {
                first_error = Some(e);
                break;
            }
        }
    }
    newm2_runtime::begin_termination();
    for ir in irs[..initialized].iter().rev() {
        let addr = orc_lookup(&format!("{}.final", ir.name));
        if let RunOutcome::Failed(e) = run_void_at(addr, &ir.name, "final") {
            if first_error.is_none() {
                first_error = Some(e);
            }
        }
    }

    match first_error {
        Some(e) => Err(e),
        None => Ok(halt_code.unwrap_or(0)),
    }
}

/// JIT-compile and execute one lowered module.
pub fn run_module(
    ir: &IrModule,
    sema: &SemaResult,
    opts: CodegenOptions,
) -> Result<i32, String> {
    run_modules(&[ir], &ir.name, sema, opts)
}

/// JIT-compile multiple lowered modules into one engine and execute the
/// specified entry module body.
pub fn run_modules(
    irs: &[&IrModule],
    entry_module_name: &str,
    sema: &SemaResult,
    opts: CodegenOptions,
) -> Result<i32, String> {
    // ORC LLJIT is the default engine. The legacy MCJIT path is kept reachable
    // via NEWM2_MCJIT during the transition, then removed.
    if std::env::var_os("NEWM2_MCJIT").is_none() {
        return run_modules_orc(irs, entry_module_name, sema, opts);
    }

    use llvm_sys::execution_engine::{
        LLVMCreateMCJITCompilerForModule, LLVMExecutionEngineRef,
        LLVMGetFunctionAddress, LLVMInitializeMCJITCompilerOptions,
        LLVMMCJITCompilerOptions,
    };
    use std::mem::size_of;

    codegen::init_llvm();

    let ctx = Context::create();
    let module = emit_linked_module(&ctx, irs, sema, opts)?;
    module.verify().map_err(|e| format!("LLVM verify: {e}"))?;

    let mut jit_opts: LLVMMCJITCompilerOptions = unsafe { std::mem::zeroed() };
    unsafe {
        LLVMInitializeMCJITCompilerOptions(
            &mut jit_opts,
            size_of::<LLVMMCJITCompilerOptions>(),
        );
    }
    jit_opts.OptLevel = opts.opt_level;
    jit_opts.MCJMM = unsafe { jit_mm::make_mm() };

    let mut engine: LLVMExecutionEngineRef = std::ptr::null_mut();
    let mut err_msg: *mut std::ffi::c_char = std::ptr::null_mut();
    let rc = unsafe {
        LLVMCreateMCJITCompilerForModule(
            &mut engine,
            module.as_mut_ptr(),
            &mut jit_opts,
            size_of::<LLVMMCJITCompilerOptions>(),
            &mut err_msg,
        )
    };
    if rc != 0 || engine.is_null() {
        let msg = if err_msg.is_null() {
            "LLVMCreateMCJITCompilerForModule failed".to_string()
        } else {
            let s = unsafe { CStr::from_ptr(err_msg) }
                .to_string_lossy()
                .into_owned();
            unsafe { llvm_sys::core::LLVMDisposeMessage(err_msg) };
            s
        };
        return Err(format!("JIT init: {msg}"));
    }

    bind_runtime_helpers(engine, &module, opts);
    bind_external_functions(engine, &module, irs);

    #[cfg(feature = "gc")]
    if opts.memory_mode == newm2_ir::MemoryMode::Gc {
        use newm2_runtime::nm2_init_gc;
        let stack_sentinel = 0usize;
        unsafe { nm2_init_gc((&stack_sentinel as *const usize).cast::<u8>()) };
    }

    let _ = entry_module_name;

    if opts.memory_mode == newm2_ir::MemoryMode::Gc {
        for ir in irs {
            let init_roots_name = format!("{}.init_roots\0", ir.name);
            let init_roots_addr = unsafe {
                LLVMGetFunctionAddress(engine, init_roots_name.as_ptr() as *const _)
            };
            if init_roots_addr != 0 {
                let init_roots_fn: extern "C" fn() = unsafe { std::mem::transmute(init_roots_addr) };
                init_roots_fn();
            }
        }
    }

    // MCJIT symbol lookup: a function address (forces materialization) or, for
    // a global like `Class.vtable`, its emitted address.
    let mcjit_lookup = |name: &str| -> u64 {
        use llvm_sys::execution_engine::{LLVMGetFunctionAddress, LLVMGetGlobalValueAddress};
        let Ok(c) = std::ffi::CString::new(name) else { return 0 };
        let a = unsafe { LLVMGetFunctionAddress(engine, c.as_ptr()) };
        if a != 0 {
            return a;
        }
        unsafe { LLVMGetGlobalValueAddress(engine, c.as_ptr()) }
    };
    patch_vtables(irs, &mcjit_lookup)?;

    // Register JIT'd procedure addresses for the crash handler's high-level
    // (M2) backtrace, then install the signal-safe handler. Done after all
    // symbols are resolvable and before any user code runs, so the handler
    // reads an immutable, fully-populated table.
    register_jit_symbols(irs, &mcjit_lookup);
    newm2_runtime::nm2_finalize_jit_symbols();
    newm2_runtime::nm2_install_crash_handler();

    let _ = keep_forever(module);

    // Run each module *initializer* in dependency (topological) order: `irs`
    // is built by lowering `graph.topo_order`, so imported modules initialize
    // before the modules that depend on them, and the entry module's body (its
    // `BEGIN … END`) runs last. A body is a `void` function; a Rust panic from
    // a runtime helper unwinds across the C-unwind boundary and is caught here.
    let mut initialized = 0usize;
    let mut first_error: Option<String> = None;
    let mut halt_code: Option<i32> = None;
    for ir in irs {
        match run_jit_void(engine, &ir.name, "body") {
            RunOutcome::Ran => initialized += 1,
            // HALT: the halting module still counts as initialized (so its
            // finalizer runs). Termination is clean (no unwound exception); the
            // process exit status is HALT's argument — bare HALT defaults to 1
            // (abnormal termination), HALT(0) exits cleanly.
            RunOutcome::Halted(code) => {
                initialized += 1;
                halt_code = Some(code);
                break;
            }
            RunOutcome::Failed(e) => {
                first_error = Some(e);
                break;
            }
        }
    }

    // Termination has begun: module finalizers (`<name>.final`, the module-level
    // FINALLY part) run in reverse initialization order — ISO LIFO — for every
    // module that finished initializing, whether termination is normal, via
    // HALT, or via an unhandled exception from a later initializer. From here
    // `TERMINATION.IsTerminating()` is TRUE.
    newm2_runtime::begin_termination();
    for ir in irs[..initialized].iter().rev() {
        if let RunOutcome::Failed(e) = run_jit_void(engine, &ir.name, "final") {
            if first_error.is_none() {
                first_error = Some(e);
            }
        }
    }

    match first_error {
        Some(e) => Err(e),
        None => Ok(halt_code.unwrap_or(0)),
    }
}

/// Outcome of running a JIT'd `void` function body.
enum RunOutcome {
    /// Returned normally (or the symbol was absent).
    Ran,
    /// Unwound via `HALT` — run finalizers, then exit with the carried status.
    Halted(i32),
    /// Unwound via an uncaught exception / panic — abnormal.
    Failed(String),
}

/// Look up `<module>.<suffix>` (a `void` JIT function) and run it under
/// `catch_unwind`, turning an uncaught M2 exception into a named diagnostic.
/// Returns `Ok(())` when the symbol is absent (the module has no such part).
fn run_jit_void(
    engine: llvm_sys::execution_engine::LLVMExecutionEngineRef,
    module: &str,
    suffix: &str,
) -> RunOutcome {
    use llvm_sys::execution_engine::LLVMGetFunctionAddress;
    let sym = format!("{module}.{suffix}\0");
    let addr = unsafe { LLVMGetFunctionAddress(engine, sym.as_ptr() as *const _) };
    run_void_at(addr, module, suffix)
}

/// Run a JIT'd `void` body/finalizer given its already-resolved address (0 =
/// absent → nothing to run). Engine-agnostic: the MCJIT and ORC paths resolve
/// the address their own way and share this unwind/HALT/exception handling.
fn run_void_at(addr: u64, module: &str, suffix: &str) -> RunOutcome {
    if addr == 0 {
        return RunOutcome::Ran;
    }
    let f: extern "C-unwind" fn() = unsafe { std::mem::transmute(addr) };
    match std::panic::catch_unwind(|| f()) {
        Ok(()) => RunOutcome::Ran,
        Err(payload) => {
            // HALT unwinds with a HaltMarker carrying the exit status.
            if let Some(h) = payload.downcast_ref::<newm2_runtime::HaltMarker>() {
                return RunOutcome::Halted(h.code);
            }
            if let Some(exc) = payload.downcast_ref::<newm2_runtime::ExceptionPayload>() {
                let msg = String::from_utf8_lossy(&exc.message);
                let tail = if msg.is_empty() {
                    String::new()
                } else {
                    format!(": {msg}")
                };
                let what = newm2_runtime::describe_exception(exc.source, exc.number);
                let where_ = if suffix == "final" {
                    format!("{module} (finalization)")
                } else {
                    module.to_string()
                };
                RunOutcome::Failed(format!("unhandled exception in {where_}: {what}{tail}"))
            } else {
                RunOutcome::Failed(format!("panic in JIT'd module {suffix} {module}"))
            }
        }
    }
}

/// Register every JIT-compiled procedure's entry address and qualified name
/// with the runtime crash handler, so a fatal fault can annotate native frames
/// with their Modula-2 `Module.Proc` provenance.
fn register_jit_symbols(irs: &[&IrModule], lookup: &dyn Fn(&str) -> u64) {
    for ir in irs {
        for func in &ir.funcs {
            let addr = lookup(&func.name);
            if addr != 0 {
                newm2_runtime::nm2_register_jit_symbol(
                    addr as usize,
                    func.name.as_ptr(),
                    func.name.len(),
                );
            }
        }
    }
}

fn emit_linked_module<'ctx>(
    ctx: &'ctx Context,
    irs: &[&IrModule],
    sema: &SemaResult,
    opts: CodegenOptions,
) -> Result<Module<'ctx>, String> {
    use llvm_sys::linker::LLVMLinkModules2;

    let mut iter = irs.iter();
    let Some(first) = iter.next() else {
        return Err("no modules to emit".to_string());
    };

    let dest = codegen::emit_module(ctx, first, sema, opts);
    for ir in iter {
        let src = codegen::emit_module(ctx, ir, sema, opts);
        let rc = unsafe { LLVMLinkModules2(dest.as_mut_ptr(), src.as_mut_ptr()) };
        std::mem::forget(src);
        if rc != 0 {
            return Err(format!("LLVM link: failed to link module {}", ir.name));
        }
    }
    promote_typeinfo_linkage(&dest);
    Ok(dest)
}

/// Promote every coalesced `{Class}.typeinfo` global from weak_odr back to
/// external linkage, now that `LLVMLinkModules2` has merged any duplicate
/// redeclarations (an abstract COM-interface mirror like `IMalloc` is declared
/// independently in several modules — they MUST coalesce, so codegen emits them
/// weak_odr). Post-coalesce there is exactly one definition per name, so
/// external is safe — and necessary: the JIT's RTDyld drops weak data globals
/// even when referenced/anchored, leaving a dangling `&typeinfo`; external
/// forces materialisation. (AOT's real linker handles either linkage; promoting
/// a single definition is harmless there.)
fn promote_typeinfo_linkage(module: &Module<'_>) {
    use inkwell::module::Linkage;
    for gv in module.get_globals() {
        if gv.get_name().to_string_lossy().ends_with(".typeinfo") {
            gv.set_linkage(Linkage::External);
        }
    }
}

fn opt_level(n: u32) -> OptimizationLevel {
    match n {
        0 => OptimizationLevel::None,
        1 => OptimizationLevel::Less,
        2 => OptimizationLevel::Default,
        _ => OptimizationLevel::Aggressive,
    }
}

/// Run the LLVM mid-end IR optimization pipeline (mem2reg, inlining, instcombine,
/// GVN, loop opts, …) before machine-code emission. Gated by the driver's `--opt`
/// level: level 0 (the default) is a no-op, so the lenient/fast default behaviour
/// is unchanged; `--opt 1|2|3` runs `default<O1|O2|O3>`. Both the JIT and AOT
/// paths call this so they optimise identically. Without it, `opt_level` only set
/// the backend `CodeGenOpt` level — the IR pipeline never ran, so allocas were
/// never even promoted to registers.
fn optimize_module(module: &Module<'_>, tm: &TargetMachine, n: u32) -> Result<(), String> {
    // The mid-end passes (SROA, GVN/MemorySSA, InstCombine, vectorizers) size
    // structs and fold typed GEPs into byte offsets using the *module's*
    // datalayout. The backend lays out globals + emits code with the target
    // machine's layout, so the module must carry that same layout or the
    // optimizer strides arrays / offsets fields under a different (default)
    // layout than the storage actually uses. Stamp it before any pass runs.
    module.set_data_layout(&tm.get_target_data().get_data_layout());
    if n == 0 {
        return Ok(());
    }
    let pipeline = match n {
        1 => "default<O1>",
        2 => "default<O2>",
        _ => "default<O3>",
    };
    module
        .run_passes(pipeline, tm, PassBuilderOptions::create())
        .map_err(|e| format!("LLVM optimize ({pipeline}): {e}"))
}

fn keep_forever(module: Module<'_>) -> usize {
    let ptr = module.as_mut_ptr();
    std::mem::forget(module);
    ptr as usize
}

fn bind_runtime_helpers(
    engine: llvm_sys::execution_engine::LLVMExecutionEngineRef,
    module: &Module<'_>,
    opts: CodegenOptions,
) {
    // MCJIT: map each runtime helper's name to its address via the engine.
    let mut binder = |name: &str, addr: *const ()| {
        use llvm_sys::core::LLVMGetNamedFunction;
        use llvm_sys::execution_engine::LLVMAddGlobalMapping;
        let cname = std::ffi::CString::new(name).unwrap();
        let fn_val = unsafe { LLVMGetNamedFunction(module.as_mut_ptr(), cname.as_ptr()) };
        if !fn_val.is_null() {
            unsafe { LLVMAddGlobalMapping(engine, fn_val, addr as *mut std::ffi::c_void) };
        }
    };
    for_each_runtime_binding(module, opts, &mut binder);
}

/// Enumerate every runtime-helper `(M2 name, address)` binding, invoking
/// `binder` for each. Shared by the MCJIT (`AddGlobalMapping`) and ORC
/// (absolute-symbol) engines so the binding list lives in exactly one place.
fn for_each_runtime_binding(
    module: &Module<'_>,
    opts: CodegenOptions,
    binder: &mut dyn FnMut(&str, *const ()),
) {
    let mut bind = |name: &str, addr: *const ()| binder(name, addr);

    // REAL16 (f16) soft-float conversion libcalls. On x86 without F16C, LLVM
    // lowers f16 arithmetic/conversion to __extendhfsf2 / __truncsfhf2 (and the
    // f64 variants); these are implemented in the binary's compiler-builtins but
    // are not exported for the JIT's dlsym-style resolver, so a call to them
    // lands on a null address. Declare them in the module (the lowering reuses an
    // existing same-named declaration) and map each to its real address, taken
    // via an extern reference so the linker keeps the symbol.
    {
        unsafe extern "C" {
            fn __extendhfsf2();
            fn __truncsfhf2();
            fn __extendhfdf2();
            fn __truncdfhf2();
        }
        let cx = module.get_context();
        let h = cx.f16_type();
        let s = cx.f32_type();
        let d = cx.f64_type();
        for (name, fty, addr) in [
            ("__extendhfsf2", s.fn_type(&[h.into()], false), __extendhfsf2 as *const ()),
            ("__truncsfhf2", h.fn_type(&[s.into()], false), __truncsfhf2 as *const ()),
            ("__extendhfdf2", d.fn_type(&[h.into()], false), __extendhfdf2 as *const ()),
            ("__truncdfhf2", h.fn_type(&[d.into()], false), __truncdfhf2 as *const ()),
        ] {
            if module.get_function(name).is_none() {
                module.add_function(name, fty, None);
            }
            bind(name, addr);
        }
    }

    use newm2_runtime::{
        nm2_alloc, nm2_collect, nm2_copy_string, nm2_copy_wstring, nm2_copy_wstring_narrow,
        nm2_file_close, nm2_file_flush,
        nm2_file_open, nm2_file_read, nm2_file_read_text, nm2_file_seek, nm2_file_size,
        nm2_file_tell, nm2_file_write, nm2_file_write_text, nm2_free, nm2_gcreport,
        nm2_io_write_card,
        nm2_io_write_int, nm2_io_write_ln, nm2_io_write_uchar,
        nm2_io_write_ucard, nm2_io_write_uint, nm2_io_write_ustr, nm2_math_frexp,
        nm2_math_ldexp, nm2_math_modf,
        nm2_math_arccos, nm2_math_arccosh, nm2_math_arcsin, nm2_math_arcsinh,
        nm2_math_arctan, nm2_math_arctan2, nm2_math_arctanh, nm2_math_cos,
        nm2_math_cosh, nm2_math_exp, nm2_math_floor, nm2_math_lg, nm2_math_ln,
        nm2_math_pow, nm2_math_sin, nm2_math_sinh, nm2_math_sqrt, nm2_math_tan,
        nm2_math_tanh, nm2_math_trunc_to_card, nm2_math_trunc_to_int,
        nm2_math_ceil, nm2_math_round, nm2_math_trunc, nm2_math_log10, nm2_math_exp2,
        nm2_math_cbrt, nm2_math_expm1, nm2_math_log1p, nm2_math_degrees, nm2_math_radians,
        nm2_math_sign, nm2_math_hypot, nm2_math_copysign, nm2_math_min, nm2_math_max,
        nm2_math_log, nm2_math_fmod,
        nm2_program_args_copy, nm2_program_args_count,
        nm2_storage_allocate, nm2_storage_deallocate, nm2_string_length, nm2_wstr_length,
        nm2_sysclock_now, nm2_shift, nm2_rotate,
        nm2_coroutine_new, nm2_coroutine_transfer, nm2_coroutine_current,
        nm2_com_init, nm2_com_uninit, nm2_com_get_malloc, nm2_com_drive, nm2_guid_eq,
        nm2_sort_i64,
        nm2_halt, nm2_term_has_halted, nm2_term_is_terminating,
        nm2_io_write_text, nm2_io_write_err_text, nm2_io_write_bytes,
        nm2_io_flush, nm2_io_flush_err,
        nm2_io_peek_char, nm2_io_consume_char, nm2_io_read_text,
        nm2_alloc_exception_source, nm2_assert_failed, nm2_current_message,
        nm2_current_number, nm2_current_source, nm2_exception_handled,
        nm2_is_current_source, nm2_is_exceptional_execution, nm2_m2_source,
        nm2_raise, nm2_raise_m2, nm2_reraise, nm2_run_protected,
        nm2_guard_source, nm2_raise_guard, nm2_rtti_isa, nm2_typeinfo_of,
        nm2_com_query_interface, nm2_com_release,
        nm2_libc_printf, nm2_libc_exit,
    };

    // Manual heap allocator — bound in every mode (the default model).
    bind("nm2_alloc", nm2_alloc as *const ());
    bind("nm2_free", nm2_free as *const ());

    // CHAR is Windows-wide (UTF-16) internally; the text writers convert
    // UTF-16 -> UTF-8 at the I/O boundary. (Narrow nm2_io_write_str/_char
    // remain available for explicit ACHAR.)
    bind("STextIO.WriteString", nm2_io_write_ustr as *const ());
    bind("STextIO.WriteLn", nm2_io_write_ln as *const ());
    bind("STextIO.WriteChar", nm2_io_write_uchar as *const ());
    // ISO channel device backing (StdChans console DeviceTable → NM2IO.*).
    bind("libc.printf", nm2_libc_printf as *const ());
    bind("libc.exit", nm2_libc_exit as *const ());
    bind("NM2.IO.WriteText", nm2_io_write_text as *const ());
    bind("NM2.IO.WriteErrText", nm2_io_write_err_text as *const ());
    bind("NM2.IO.WriteBytes", nm2_io_write_bytes as *const ());
    bind("NM2.IO.Flush", nm2_io_flush as *const ());
    bind("NM2.IO.FlushErr", nm2_io_flush_err as *const ());
    bind("NM2.IO.PeekChar", nm2_io_peek_char as *const ());
    bind("NM2.IO.ConsumeChar", nm2_io_consume_char as *const ());
    bind("NM2.IO.ReadText", nm2_io_read_text as *const ());
    bind("SWholeIO.WriteInt", nm2_io_write_int as *const ());
    bind("SWholeIO.WriteCard", nm2_io_write_card as *const ());
    bind("InOut.WriteString", nm2_io_write_ustr as *const ());
    bind("InOut.WriteLn", nm2_io_write_ln as *const ());
    bind("InOut.Write", nm2_io_write_uchar as *const ());
    bind("InOut.WriteInt", nm2_io_write_int as *const ());
    bind("InOut.WriteCard", nm2_io_write_card as *const ());
    bind("NM2.IO.WriteUChar", nm2_io_write_uchar as *const ());
    bind("NM2.IO.WriteUInt", nm2_io_write_uint as *const ());
    bind("NM2.IO.WriteUCard", nm2_io_write_ucard as *const ());
    bind("NM2.IO.WriteUString", nm2_io_write_ustr as *const ());
    bind("SYSTEM.COLLECT", nm2_collect as *const ());
    bind("SYSTEM.GCREPORT", nm2_gcreport as *const ());

    // Bootstrap runtime primitives backing the ISO library. Bound as
    // `Module.Proc` matching the rtdef DEF modules (NM2Str, NM2Math, …);
    // the M2 ISO bodies call them QUALIFIED so the symbol resolves here.
    bind("NM2Str.Copy", nm2_copy_string as *const ());
    bind("NM2Str.WCopy", nm2_copy_wstring as *const ());
    bind("NM2Str.WNCopy", nm2_copy_wstring_narrow as *const ());
    bind("NM2Str.Length", nm2_string_length as *const ());
    bind("NM2Str.WLength", nm2_wstr_length as *const ());
    bind("NM2Math.Frexp", nm2_math_frexp as *const ());
    bind("NM2Math.Ldexp", nm2_math_ldexp as *const ());
    bind("NM2Math.Modf", nm2_math_modf as *const ());
    // Transcendental/power surface. REAL and LONGREAL are both f64, so the
    // plain and `L`-prefixed (LONGREAL) procedures share one backing fn.
    {
        let m: &[(&str, *const ())] = &[
            ("sin", nm2_math_sin as *const ()),
            ("cos", nm2_math_cos as *const ()),
            ("tan", nm2_math_tan as *const ()),
            ("arcsin", nm2_math_arcsin as *const ()),
            ("arccos", nm2_math_arccos as *const ()),
            ("arctan", nm2_math_arctan as *const ()),
            ("arctan2", nm2_math_arctan2 as *const ()),
            ("sqrt", nm2_math_sqrt as *const ()),
            ("exp", nm2_math_exp as *const ()),
            ("ln", nm2_math_ln as *const ()),
            ("lg", nm2_math_lg as *const ()),
            ("pow", nm2_math_pow as *const ()),
            ("sinh", nm2_math_sinh as *const ()),
            ("cosh", nm2_math_cosh as *const ()),
            ("tanh", nm2_math_tanh as *const ()),
            ("arcsinh", nm2_math_arcsinh as *const ()),
            ("arccosh", nm2_math_arccosh as *const ()),
            ("arctanh", nm2_math_arctanh as *const ()),
            ("floor", nm2_math_floor as *const ()),
            ("truncToInt", nm2_math_trunc_to_int as *const ()),
            ("truncToCard", nm2_math_trunc_to_card as *const ()),
            ("ceil", nm2_math_ceil as *const ()),
            ("round", nm2_math_round as *const ()),
            ("trunc", nm2_math_trunc as *const ()),
            ("log10", nm2_math_log10 as *const ()),
            ("exp2", nm2_math_exp2 as *const ()),
            ("cbrt", nm2_math_cbrt as *const ()),
            ("expm1", nm2_math_expm1 as *const ()),
            ("log1p", nm2_math_log1p as *const ()),
            ("degrees", nm2_math_degrees as *const ()),
            ("radians", nm2_math_radians as *const ()),
            ("sign", nm2_math_sign as *const ()),
            ("hypot", nm2_math_hypot as *const ()),
            ("copysign", nm2_math_copysign as *const ()),
            ("min", nm2_math_min as *const ()),
            ("max", nm2_math_max as *const ()),
            ("log", nm2_math_log as *const ()),
            ("fmod", nm2_math_fmod as *const ()),
        ];
        for (name, f) in m {
            bind(&format!("NM2Math.{name}"), *f);
            // LONGREAL variant (Lsin, Lsqrt, …) shares the f64 backing.
            bind(&format!("NM2Math.L{name}"), *f);
        }
    }
    bind("NM2Store.Allocate", nm2_storage_allocate as *const ());
    bind("NM2Store.Deallocate", nm2_storage_deallocate as *const ());
    bind("NM2Clock.Now", nm2_sysclock_now as *const ());
    bind("NM2Args.Count", nm2_program_args_count as *const ());
    bind("NM2Args.Copy", nm2_program_args_copy as *const ());
    bind("NM2.File.Open", nm2_file_open as *const ());
    bind("NM2.File.Close", nm2_file_close as *const ());
    bind("NM2.File.Read", nm2_file_read as *const ());
    bind("NM2.File.Write", nm2_file_write as *const ());
    bind("NM2.File.Seek", nm2_file_seek as *const ());
    bind("NM2.File.Tell", nm2_file_tell as *const ());
    bind("NM2.File.Size", nm2_file_size as *const ());
    bind("NM2.File.Flush", nm2_file_flush as *const ());
    bind("NM2.File.WriteText", nm2_file_write_text as *const ());
    bind("NM2.File.ReadText", nm2_file_read_text as *const ());

    // EXTERNAL link names used by the ported rtdef DEFs (NM2Storage,
    // NM2SysClock, NM2LowMath, NM2ProgramArgs) — `["NM2.X.Y" EXTERNAL]`.
    bind("NM2.Storage.Allocate", nm2_storage_allocate as *const ());
    bind("NM2.Storage.Deallocate", nm2_storage_deallocate as *const ());
    bind("NM2.SysClock.Now", nm2_sysclock_now as *const ());
    bind("nm2_shift", nm2_shift as *const ());
    bind("nm2_rotate", nm2_rotate as *const ());
    bind("nm2_coroutine_new", nm2_coroutine_new as *const ());
    bind("nm2_coroutine_transfer", nm2_coroutine_transfer as *const ());
    bind("nm2_coroutine_current", nm2_coroutine_current as *const ());
    bind("NM2RT.ComInit", nm2_com_init as *const ());
    bind("NM2RT.ComUninit", nm2_com_uninit as *const ());
    bind("NM2RT.ComGetMalloc", nm2_com_get_malloc as *const ());
    bind("NM2RT.ComDrive", nm2_com_drive as *const ());
    bind("NM2RT.SortInts", nm2_sort_i64 as *const ());
    bind("NM2RT.GuidEq", nm2_guid_eq as *const ());
    bind("nm2_halt", nm2_halt as *const ());
    bind("NM2RT.HasHalted", nm2_term_has_halted as *const ());
    bind("NM2RT.IsTerminating", nm2_term_is_terminating as *const ());
    bind("NM2.Math.Frexp", nm2_math_frexp as *const ());
    bind("NM2.Math.Ldexp", nm2_math_ldexp as *const ());
    bind("NM2.Math.Modf", nm2_math_modf as *const ());
    bind("NM2.ProgramArgs.Count", nm2_program_args_count as *const ());
    bind("NM2.ProgramArgs.Copy", nm2_program_args_copy as *const ());

    // ISO EXCEPTIONS runtime (RAISE / protected blocks). The NM2RT.* names
    // are the M2 EXCEPTIONS-module surface; the raw names are emitted directly
    // by codegen for RAISE / EXCEPT-FINALLY lowering (lowering still TODO).
    bind("NM2RT.AllocateExceptionSource", nm2_alloc_exception_source as *const ());
    bind("NM2RT.Raise", nm2_raise as *const ());
    bind("NM2RT.Reraise", nm2_reraise as *const ());
    bind("NM2RT.CurrentExceptionNumber", nm2_current_number as *const ());
    bind("NM2RT.CurrentExceptionSource", nm2_current_source as *const ());
    bind("NM2RT.M2Source", nm2_m2_source as *const ());
    bind("NM2RT.IsCurrentExceptionSource", nm2_is_current_source as *const ());
    bind("NM2RT.IsExceptionalExecution", nm2_is_exceptional_execution as *const ());
    bind("NM2RT.ExceptionHandled", nm2_exception_handled as *const ());
    bind("NM2RT.GetExceptionMessage", nm2_current_message as *const ());
    bind("nm2_raise", nm2_raise as *const ());
    bind("nm2_reraise", nm2_reraise as *const ());
    bind("nm2_run_protected", nm2_run_protected as *const ());
    bind("nm2_is_exceptional_execution", nm2_is_exceptional_execution as *const ());
    bind("nm2_exception_handled", nm2_exception_handled as *const ());
    bind("nm2_assert_failed", nm2_assert_failed as *const ());
    bind("nm2_raise_m2", nm2_raise_m2 as *const ());
    bind("nm2_m2_source", nm2_m2_source as *const ());
    bind("nm2_raise_guard", nm2_raise_guard as *const ());
    bind("nm2_guard_source", nm2_guard_source as *const ());
    bind("nm2_rtti_isa", nm2_rtti_isa as *const ());
    bind("nm2_typeinfo_of", nm2_typeinfo_of as *const ());
    bind("nm2_com_query_interface", nm2_com_query_interface as *const ());
    bind("nm2_com_release", nm2_com_release as *const ());

    // GC-mode runtime helpers are only available (and only emitted by
    // codegen) when the collector is compiled in.
    #[cfg(feature = "gc")]
    if opts.memory_mode == newm2_ir::MemoryMode::Gc {
        use newm2_runtime::{
            nm2_gc_push_root, nm2_new_rec, nm2_pin, nm2_register_module_roots,
            nm2_register_thread, nm2_safepoint, nm2_sys_new, nm2_unpin,
            nm2_unregister_thread,
        };

        bind("nm2_safepoint", nm2_safepoint as *const ());
        bind("nm2_gc_push_root", nm2_gc_push_root as *const ());
        bind("nm2_pin", nm2_pin as *const ());
        bind("nm2_unpin", nm2_unpin as *const ());
        bind("nm2_new_rec", nm2_new_rec as *const ());
        bind("nm2_sys_new", nm2_sys_new as *const ());
        bind("nm2_register_thread", nm2_register_thread as *const ());
        bind("nm2_unregister_thread", nm2_unregister_thread as *const ());
        bind("nm2_register_module_roots", nm2_register_module_roots as *const ());
    }

    #[cfg(not(feature = "gc"))]
    let _ = opts;
}

fn bind_external_functions(
    engine: llvm_sys::execution_engine::LLVMExecutionEngineRef,
    module: &Module<'_>,
    irs: &[&IrModule],
) {
    let mut binder =
        |name: &str, addr: *const ()| bind_function_address(engine, module, name, addr);
    for_each_external_binding(irs, &mut binder);
}

/// Enumerate every `EXTERNAL` function `(name, resolved address)` binding (Win32
/// DLL imports, libc shims), invoking `binder` for each. Shared by the MCJIT and
/// ORC engines so address resolution lives in exactly one place.
fn for_each_external_binding(irs: &[&IrModule], binder: &mut dyn FnMut(&str, *const ())) {
    use std::collections::HashSet;

    let defined_funcs: HashSet<&str> = irs
        .iter()
        .flat_map(|ir| ir.funcs.iter().map(|func| func.name.as_str()))
        .collect();

    for ir in irs {
        for global in &ir.globals {
            let Global::ExternFunc { name, dll_name, .. } = global else { continue };
            if defined_funcs.contains(name.as_str()) {
                continue;
            }
            let Some(addr) = resolve_external_function_address(name, dll_name.as_deref()) else {
                continue;
            };
            binder(name, addr);
        }
    }
}

fn bind_function_address(
    engine: llvm_sys::execution_engine::LLVMExecutionEngineRef,
    module: &Module<'_>,
    name: &str,
    addr: *const (),
) {
    use llvm_sys::core::LLVMGetNamedFunction;
    use llvm_sys::execution_engine::LLVMAddGlobalMapping;

    let Ok(cname) = std::ffi::CString::new(name) else {
        return;
    };
    let fn_val = unsafe { LLVMGetNamedFunction(module.as_mut_ptr(), cname.as_ptr()) };
    if fn_val.is_null() {
        return;
    }
    unsafe {
        LLVMAddGlobalMapping(engine, fn_val, addr as *mut std::ffi::c_void);
    }
}

fn resolve_external_function_address(name: &str, dll: Option<&str>) -> Option<*const ()> {
    let mut candidates = vec![name];
    if let Some((_, tail)) = name.rsplit_once('.') {
        candidates.push(tail);
    }
    for candidate in candidates {
        if let Some(addr) = resolve_external_function_address_impl(candidate, dll) {
            return Some(addr);
        }
    }
    None
}

/// LoadLibrary the named DLL and GetProcAddress the symbol.
#[cfg(windows)]
fn proc_in_dll(dll: &str, name: &str) -> Option<*const ()> {
    use std::ffi::{c_char, c_void};

    unsafe extern "system" {
        fn LoadLibraryW(lp_lib_file_name: *const u16) -> *mut c_void;
        fn GetProcAddress(h_module: *mut c_void, lp_proc_name: *const c_char) -> *mut c_void;
    }

    let proc_name = std::ffi::CString::new(name).ok()?;
    let wide: Vec<u16> = dll.encode_utf16().chain(std::iter::once(0)).collect();
    let module = unsafe { LoadLibraryW(wide.as_ptr()) };
    if module.is_null() {
        return None;
    }
    let addr = unsafe { GetProcAddress(module, proc_name.as_ptr()) };
    (!addr.is_null()).then(|| addr as *const ())
}

#[cfg(windows)]
fn resolve_external_function_address_impl(name: &str, dll: Option<&str>) -> Option<*const ()> {
    // Honor the binding's recorded DLL first (so exports outside the common
    // allow-list still resolve), then fall back to probing the common DLLs.
    if let Some(dll) = dll.filter(|d| !d.is_empty()) {
        if let Some(addr) = proc_in_dll(dll, name) {
            return Some(addr);
        }
    }

    const DLLS: &[&str] = &[
        "kernel32.dll",
        "user32.dll",
        "gdi32.dll",
        "advapi32.dll",
        "comdlg32.dll",
        "comctl32.dll",
        "ole32.dll",
        "oleaut32.dll",
        "shell32.dll",
        "shlwapi.dll",
        "ws2_32.dll",
        "winspool.drv",
        "version.dll",
        "imm32.dll",
        "uxtheme.dll",
    ];

    DLLS.iter().find_map(|dll| proc_in_dll(dll, name))
}

#[cfg(not(windows))]
fn resolve_external_function_address_impl(_name: &str, _dll: Option<&str>) -> Option<*const ()> {
    None
}

fn patch_vtables(
    irs: &[&IrModule],
    lookup: &dyn Fn(&str) -> u64,
) -> Result<(), String> {
    use std::collections::HashSet;
    // Methods actually defined in this compile; a vtable slot naming a method not
    // among them (e.g. an abstract slot) is skipped, matching the prior
    // module-membership check.
    let defined: HashSet<&str> = irs
        .iter()
        .flat_map(|ir| ir.funcs.iter().map(|f| f.name.as_str()))
        .collect();

    for ir in irs {
        for g in &ir.globals {
            let Global::ClassDesc { class_name, vtable_slots, has_typeinfo } = g else { continue };
            if vtable_slots.is_empty() {
                continue;
            }

            let vt_addr = lookup(&format!("{class_name}.vtable"));
            if vt_addr == 0 {
                continue;
            }

            // When the vtable carries the {Class}.typeinfo pointer at physical
            // slot 0, methods are written at physical slot 1+ (matching the
            // dispatch +1 in lower.rs and the codegen layout).
            let base = if *has_typeinfo { 1 } else { 0 };
            let vt_ptr = vt_addr as *mut usize;
            for (slot_idx, fn_name) in vtable_slots.iter().enumerate() {
                if fn_name.is_empty() || !defined.contains(fn_name.as_str()) {
                    continue;
                }
                let fn_addr = lookup(fn_name) as usize;
                if fn_addr == 0 {
                    return Err(format!(
                        "vtable patch: method `{fn_name}` (slot {slot_idx} of `{class_name}.vtable`) resolved to null"
                    ));
                }
                unsafe { vt_ptr.add(base + slot_idx).write(fn_addr) };
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use newm2_ir::{IrModule, MemoryMode};
    use newm2_sema::SemaResult;

    #[test]
    fn empty_module_llvm_ir() {
        let ir = IrModule::new("TestMod", MemoryMode::NoGc);
        let sema = fake_sema();
        let opts = CodegenOptions::default();
        let ir_text = emit_llvm_ir(&ir, &sema, opts);
        assert!(ir_text.contains("TestMod"), "expected module name in IR: {ir_text}");
    }

    fn fake_sema() -> SemaResult {
        use newm2_loader::build_module_graph;
        use newm2_loader::SearchPath;

        let tmp = std::env::temp_dir().join("__nm2_test_empty.mod");
        std::fs::write(&tmp, "MODULE __empty; END __empty.\n").unwrap();
        let sp = SearchPath::new();
        let graph = build_module_graph(&tmp, &sp).unwrap();
        let result = newm2_sema::check_module_graph(&graph);
        let _ = std::fs::remove_file(&tmp);
        result
    }
}
