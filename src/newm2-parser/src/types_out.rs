use crate::ast::*;
use newm2_lexer::{Env, preprocess};

#[derive(Debug, Clone)]
pub struct TypesOutResult {
    pub text: String,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Default)]
struct TypesOutMetrics {
    emitted_consts: usize,
    emitted_types: usize,
    emitted_procedures: usize,
    skipped_consts: usize,
    skipped_vars: usize,
    skipped_classes: usize,
    skipped_local_modules: usize,
    skipped_exports: usize,
    skipped_pragmas: usize,
}

pub fn format_types_module(module: &Module) -> TypesOutResult {
    let mut warnings = Vec::new();
    let mut out = String::new();
    let mut metrics = TypesOutMetrics::default();

    if module.kind != ModuleKind::Definition {
        warnings.push(format!(
            "types-out: module {} is not a DEFINITION MODULE; emitting a DEFINITION MODULE wrapper",
            module.name
        ));
    }

    out.push_str(&format!("DEFINITION MODULE {};\n", module.name));
    for pragma in &module.pragmas {
        out.push_str(&format_pragma(pragma, 0));
        out.push('\n');
    }
    if !module.pragmas.is_empty() {
        out.push('\n');
    }

    for import in &module.imports {
        out.push_str(&format_import(import));
        out.push('\n');
    }
    if !module.imports.is_empty() {
        out.push('\n');
    }

    let mut const_chunks = Vec::new();
    let mut type_chunks = Vec::new();
    let mut procedure_chunks = Vec::new();
    let mut interface_chunks = Vec::new();
    let mut pending_pragmas: Vec<&Pragma> = Vec::new();
    let mut active_const_conditional = false;
    let mut active_type_conditional = false;
    let mut active_procedure_conditional = false;
    for decl in &module.decls {
        match decl {
            Decl::Pragma(pragma) => pending_pragmas.push(pragma),
            Decl::Const(item) => {
                for pragma in pending_pragmas.drain(..) {
                    match classify_top_level_pragma(pragma) {
                        TopLevelPragma::If
                        | TopLevelPragma::Elsif
                        | TopLevelPragma::Else => {
                            active_const_conditional = true;
                            const_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
                        }
                        TopLevelPragma::End => {
                            if active_const_conditional {
                                active_const_conditional = false;
                                const_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
                            } else {
                                metrics.skipped_pragmas += 1;
                                warnings.push(format!(
                                    "types-out: skipped top-level pragma {:?} at line {}",
                                    pragma.body, pragma.span.start.line
                                ));
                            }
                        }
                        TopLevelPragma::Other => {
                            const_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
                        }
                    }
                }
                metrics.emitted_consts += 1;
                const_chunks.push(format_const_decl(item));
            }
            Decl::Type(ty) => {
                for pragma in pending_pragmas.drain(..) {
                    match classify_top_level_pragma(pragma) {
                        TopLevelPragma::If
                        | TopLevelPragma::Elsif
                        | TopLevelPragma::Else => {
                            active_type_conditional = true;
                            type_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
                        }
                        TopLevelPragma::End => {
                            if active_type_conditional {
                                active_type_conditional = false;
                                type_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
                            } else {
                                metrics.skipped_pragmas += 1;
                                warnings.push(format!(
                                    "types-out: skipped top-level pragma {:?} at line {}",
                                    pragma.body, pragma.span.start.line
                                ));
                            }
                        }
                        TopLevelPragma::Other => {
                            type_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
                        }
                    }
                }
                metrics.emitted_types += 1;
                type_chunks.push(format_type_decl(ty));
            }
            Decl::Procedure(proc_decl) => {
                for pragma in pending_pragmas.drain(..) {
                    match classify_top_level_pragma(pragma) {
                        TopLevelPragma::If
                        | TopLevelPragma::Elsif
                        | TopLevelPragma::Else => {
                            active_procedure_conditional = true;
                            procedure_chunks.push(format!("{}\n", format_pragma(pragma, 0)));
                        }
                        TopLevelPragma::End => {
                            if active_procedure_conditional {
                                active_procedure_conditional = false;
                                procedure_chunks.push(format!("{}\n", format_pragma(pragma, 0)));
                            } else {
                                metrics.skipped_pragmas += 1;
                                warnings.push(format!(
                                    "types-out: skipped top-level pragma {:?} at line {}",
                                    pragma.body, pragma.span.start.line
                                ));
                            }
                        }
                        TopLevelPragma::Other => {
                            procedure_chunks.push(format!("{}\n", format_pragma(pragma, 0)));
                        }
                    }
                }
                metrics.emitted_procedures += 1;
                procedure_chunks.push(format_proc_decl(proc_decl));
            }
            Decl::Class(c) if c.kind == ClassKind::Interface => {
                // Any pending top-level pragmas are not part of an INTERFACE; let
                // the standard skip path record them so nothing is silently lost.
                for pragma in pending_pragmas.drain(..) {
                    metrics.skipped_pragmas += 1;
                    warnings.push(format!(
                        "types-out: skipped top-level pragma {:?} at line {}",
                        pragma.body, pragma.span.start.line
                    ));
                }
                metrics.emitted_types += 1;
                interface_chunks.push(format_interface_decl(c));
            }
            other => {
                for pragma in pending_pragmas.drain(..) {
                    if matches!(classify_top_level_pragma(pragma), TopLevelPragma::End)
                        && active_const_conditional
                    {
                        active_const_conditional = false;
                        const_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
                    } else if matches!(classify_top_level_pragma(pragma), TopLevelPragma::End)
                        && active_type_conditional
                    {
                        active_type_conditional = false;
                        type_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
                    } else if matches!(classify_top_level_pragma(pragma), TopLevelPragma::End)
                        && active_procedure_conditional
                    {
                        active_procedure_conditional = false;
                        procedure_chunks.push(format!("{}\n", format_pragma(pragma, 0)));
                    } else {
                        metrics.skipped_pragmas += 1;
                        warnings.push(format!(
                            "types-out: skipped top-level pragma {:?} at line {}",
                            pragma.body, pragma.span.start.line
                        ));
                    }
                }
                note_skipped_decl(other, &mut metrics);
                warnings.push(format_skipped_decl(other));
            }
        }
    }
    for pragma in pending_pragmas.drain(..) {
        if matches!(classify_top_level_pragma(pragma), TopLevelPragma::End) && active_const_conditional {
            active_const_conditional = false;
            const_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
        } else if matches!(classify_top_level_pragma(pragma), TopLevelPragma::End)
            && active_type_conditional
        {
            active_type_conditional = false;
            type_chunks.push(format!("    {}\n", format_pragma(pragma, 0)));
        } else if matches!(classify_top_level_pragma(pragma), TopLevelPragma::End)
            && active_procedure_conditional
        {
            active_procedure_conditional = false;
            procedure_chunks.push(format!("{}\n", format_pragma(pragma, 0)));
        } else {
            metrics.skipped_pragmas += 1;
            warnings.push(format!(
                "types-out: skipped trailing top-level pragma {:?} at line {}",
                pragma.body, pragma.span.start.line
            ));
        }
    }

    if !type_chunks.is_empty() {
        if !const_chunks.is_empty() {
            out.push_str("CONST\n");
            for chunk in const_chunks {
                out.push_str(&chunk);
            }
            out.push('\n');
        }
        out.push_str("TYPE\n");
        for chunk in type_chunks {
            out.push_str(&chunk);
        }
        out.push('\n');
    } else if !const_chunks.is_empty() {
        out.push_str("CONST\n");
        for chunk in const_chunks {
            out.push_str(&chunk);
        }
        out.push('\n');
    } else if interface_chunks.is_empty() {
        warnings.push(format!(
            "types-out: module {} contains no type declarations",
            module.name
        ));
    }

    // INTERFACE declarations are top-level constructs (not under a TYPE header),
    // emitted after the TYPE section so any struct types they reference precede
    // them. Order within is the generator's (name order).
    if !interface_chunks.is_empty() {
        for chunk in interface_chunks {
            out.push_str(&chunk);
            out.push('\n');
        }
    }

    if !procedure_chunks.is_empty() {
        for chunk in procedure_chunks {
            out.push_str(&chunk);
        }
        out.push('\n');
    }

    out.push_str(&format_types_out_summary_comment(&metrics));
    out.push_str(&format!("END {}.\n", module.name));

    TypesOutResult { text: out, warnings }
}

pub fn format_types_module_with_env(module: &Module, env: &Env) -> TypesOutResult {
    let mut result = format_types_module(module);
    match evaluate_pragma_conditionals(&result.text, env) {
        Ok(text) => result.text = text,
        Err(err) => result
            .warnings
            .push(format!("types-out: pragma evaluation failed: {err}")),
    }
    result
}

fn evaluate_pragma_conditionals(text: &str, env: &Env) -> Result<String, String> {
    let rewritten = rewrite_pragma_conditionals_as_directives(text);
    let preprocessed = preprocess(&rewritten, env).map_err(|err| err.to_string())?;
    Ok(compact_blank_lines(&preprocessed))
}

fn rewrite_pragma_conditionals_as_directives(text: &str) -> String {
    let mut out = String::new();
    for segment in text.split_inclusive('\n') {
        let (line, newline) = match segment.strip_suffix('\n') {
            Some(line) => (line, "\n"),
            None => (segment, ""),
        };
        out.push_str(&rewrite_pragma_conditional_line(line));
        out.push_str(newline);
    }
    out
}

fn rewrite_pragma_conditional_line(line: &str) -> String {
    let trimmed = line.trim();
    let Some(body) = trimmed
        .strip_prefix("<*")
        .and_then(|rest| rest.strip_suffix("*>"))
        .map(str::trim)
    else {
        return line.to_string();
    };
    let indent_len = line.len().saturating_sub(line.trim_start().len());
    let indent = &line[..indent_len];
    if let Some(expr) = body.strip_prefix("IF ").and_then(|rest| rest.strip_suffix(" THEN")) {
        return format!("{indent}%IF {} %THEN", expr.trim());
    }
    if let Some(expr) = body.strip_prefix("ELSIF ").and_then(|rest| rest.strip_suffix(" THEN")) {
        return format!("{indent}%ELSIF {} %THEN", expr.trim());
    }
    if body == "ELSE" {
        return format!("{indent}%ELSE");
    }
    if body == "END" {
        return format!("{indent}%END");
    }
    line.to_string()
}

fn compact_blank_lines(text: &str) -> String {
    let mut out = String::new();
    let mut previous_blank = false;
    for line in text.lines() {
        let blank = line.trim().is_empty();
        if blank {
            if previous_blank {
                continue;
            }
            previous_blank = true;
            continue;
        }
        previous_blank = false;
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}

fn format_skipped_decl(decl: &Decl) -> String {
    match decl {
        Decl::Const(c) => format!(
            "types-out: skipped CONST {} at line {}",
            c.name, c.span.start.line
        ),
        Decl::Var(v) => format!(
            "types-out: skipped VAR {} at line {}",
            v.names.join(", "),
            v.span.start.line
        ),
        Decl::Procedure(_) => unreachable!(),
        Decl::Pragma(p) => format!(
            "types-out: skipped top-level pragma {:?} at line {}",
            p.body, p.span.start.line
        ),
        Decl::LocalModule(m) => format!(
            "types-out: skipped LOCAL MODULE {} at line {}",
            m.name, m.span.start.line
        ),
        Decl::Export { names, span, .. } => format!(
            "types-out: skipped EXPORT {} at line {}",
            names.join(", "),
            span.start.line
        ),
        Decl::Class(c) => format!(
            "types-out: skipped CLASS {} at line {}",
            c.name, c.span.start.line
        ),
        Decl::Type(_) => unreachable!(),
    }
}

fn note_skipped_decl(decl: &Decl, metrics: &mut TypesOutMetrics) {
    match decl {
        Decl::Const(_) => metrics.skipped_consts += 1,
        Decl::Var(_) => metrics.skipped_vars += 1,
        Decl::Procedure(_) => unreachable!(),
        Decl::Pragma(_) => metrics.skipped_pragmas += 1,
        Decl::LocalModule(_) => metrics.skipped_local_modules += 1,
        Decl::Export { .. } => metrics.skipped_exports += 1,
        Decl::Class(_) => metrics.skipped_classes += 1,
        Decl::Type(_) => {}
    }
}

fn format_types_out_summary_comment(metrics: &TypesOutMetrics) -> String {
    let mut parts = vec![format!("{} type{} emitted", metrics.emitted_types, plural(metrics.emitted_types))];
    if metrics.emitted_consts > 0 {
        parts.push(format!("{} const{} emitted", metrics.emitted_consts, plural(metrics.emitted_consts)));
    }
    if metrics.emitted_procedures > 0 {
        parts.push(format!(
            "{} procedure{} emitted",
            metrics.emitted_procedures,
            plural(metrics.emitted_procedures)
        ));
    }
    if metrics.skipped_consts > 0 {
        parts.push(format!("{} const{} skipped", metrics.skipped_consts, plural(metrics.skipped_consts)));
    }
    if metrics.skipped_vars > 0 {
        parts.push(format!("{} var{} skipped", metrics.skipped_vars, plural(metrics.skipped_vars)));
    }
    if metrics.skipped_classes > 0 {
        parts.push(format!("{} class{} skipped", metrics.skipped_classes, plural(metrics.skipped_classes)));
    }
    if metrics.skipped_local_modules > 0 {
        parts.push(format!("{} local module{} skipped", metrics.skipped_local_modules, plural(metrics.skipped_local_modules)));
    }
    if metrics.skipped_exports > 0 {
        parts.push(format!("{} export{} skipped", metrics.skipped_exports, plural(metrics.skipped_exports)));
    }
    if metrics.skipped_pragmas > 0 {
        parts.push(format!("{} pragma{} skipped", metrics.skipped_pragmas, plural(metrics.skipped_pragmas)));
    }
    format!("(* types-out summary: {} *)\n", parts.join("; "))
}

fn plural(count: usize) -> &'static str {
    if count == 1 { "" } else { "s" }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TopLevelPragma {
    If,
    Elsif,
    Else,
    End,
    Other,
}

fn classify_top_level_pragma(pragma: &Pragma) -> TopLevelPragma {
    let body = pragma.body.trim();
    if body.starts_with("IF ") {
        TopLevelPragma::If
    } else if body.starts_with("ELSIF ") {
        TopLevelPragma::Elsif
    } else if body == "ELSE" {
        TopLevelPragma::Else
    } else if body == "END" {
        TopLevelPragma::End
    } else {
        TopLevelPragma::Other
    }
}

fn format_import(import: &Import) -> String {
    match import {
        Import::From { module, names, .. } => {
            if names.is_empty() {
                format!("FROM {module} IMPORT *;")
            } else {
                format!("FROM {module} IMPORT {};", names.join(", "))
            }
        }
        Import::Plain { names, .. } => {
            let rendered = names.iter().map(format_import_name).collect::<Vec<_>>().join(", ");
            format!("IMPORT {rendered};")
        }
    }
}

fn format_import_name(name: &ImportName) -> String {
    match &name.alias {
        Some(alias) => format!("{} := {alias}", name.name),
        None => name.name.clone(),
    }
}

fn format_const_decl(item: &ConstDecl) -> String {
    let exported = if item.exported { "*" } else { "" };
    format!(
        "    {}{} = {};\n",
        item.name,
        exported,
        format_expr(&item.value)
    )
}

fn format_type_decl(ty: &TypeDecl) -> String {
    let exported = if ty.exported { "*" } else { "" };
    match &ty.def {
        Some(def) => format!(
            "    {}{} = {};\n",
            ty.name,
            exported,
            format_type_expr(def, 4)
        ),
        None => format!("    {}{};\n", ty.name, exported),
    }
}

fn format_proc_decl(proc_decl: &ProcDecl) -> String {
    let mut out = String::from("PROCEDURE ");
    out.push_str(&proc_decl.name);
    if proc_decl.exported {
        out.push('*');
    }
    if let Some(linkage) = &proc_decl.external_linkage {
        out.push_str(&format_proc_external_linkage(linkage));
    }
    out.push('(');
    out.push_str(&proc_decl.params.iter().map(format_param).collect::<Vec<_>>().join("; "));
    out.push(')');
    if let Some(return_ty) = &proc_decl.return_ty {
        out.push_str(" : ");
        out.push_str(&format_type_expr(return_ty, 0));
    }
    if !proc_decl.attrs.is_empty() {
        out.push(' ');
        out.push_str(&format_proc_attrs(&proc_decl.attrs));
    }
    if !proc_decl.pragmas.is_empty() {
        out.push(' ');
        out.push_str(
            &proc_decl
                .pragmas
                .iter()
                .map(|pragma| format_pragma(pragma, 0))
                .collect::<Vec<_>>()
                .join(" "),
        );
    }
    out.push_str(";\n");
    out
}

/// Render a COM `INTERFACE` declaration:
/// ```text
/// INTERFACE Name ["iid"];
///   INHERIT Base;            (* omitted when there is no base *)
///   PROCEDURE M (p : ADDRESS) : HRESULT <* @3 *>;
///   ...
/// END Name;
/// ```
/// Method ordering and the `<* @N *>` ordinal pragmas come straight from the
/// AST (the generator computes the absolute slot); fields are not emitted (an
/// interface is vtable-only).
fn format_interface_decl(class: &ClassDecl) -> String {
    let mut out = String::from("INTERFACE ");
    out.push_str(&class.name);
    if class.exported {
        out.push('*');
    }
    if let Some(iid) = &class.iid {
        out.push_str(&format!(" [\"{iid}\"]"));
    }
    out.push_str(";\n");

    if let Some(base) = &class.inherit {
        out.push_str(&format!("    INHERIT {};\n", base.segments.join(".")));
    }

    for member in &class.members {
        if let ClassMember::Method(method) = member {
            out.push_str("    ");
            out.push_str(&format_interface_method(method));
            out.push('\n');
        }
    }

    out.push_str(&format!("END {};\n", class.name));
    out
}

/// Render one abstract method line of an INTERFACE, mirroring `format_proc_decl`
/// for the `PROCEDURE name (params) : ret` head, then appending its `<* @N *>`
/// ordinal pragma(s) and a trailing `;`.
fn format_interface_method(method: &MethodDecl) -> String {
    let mut out = String::from("PROCEDURE ");
    out.push_str(&method.name);
    out.push('(');
    out.push_str(&method.params.iter().map(format_param).collect::<Vec<_>>().join("; "));
    out.push(')');
    if let Some(return_ty) = &method.return_ty {
        out.push_str(" : ");
        out.push_str(&format_type_expr(return_ty, 0));
    }
    if !method.attrs.is_empty() {
        out.push(' ');
        out.push_str(&format_proc_attrs(&method.attrs));
    }
    if !method.pragmas.is_empty() {
        out.push(' ');
        out.push_str(
            &method
                .pragmas
                .iter()
                .map(|pragma| format_pragma(pragma, 0))
                .collect::<Vec<_>>()
                .join(" "),
        );
    }
    out.push(';');
    out
}

fn format_proc_external_linkage(linkage: &ProcExternalLinkage) -> String {
    let mut out = format!("[{}", format_string_literal(&linkage.link_name));
    if linkage.is_external {
        out.push_str(" EXTERNAL");
    }
    if let Some(dll_name) = &linkage.dll_name {
        out.push_str(" FROM ");
        out.push_str(&format_string_literal(dll_name));
    }
    out.push(']');
    out
}

fn format_param(param: &Param) -> String {
    let mut out = String::new();
    if !param.pragmas.is_empty() {
        out.push_str(
            &param
                .pragmas
                .iter()
                .map(|pragma| format_pragma(pragma, 0))
                .collect::<Vec<_>>()
                .join(" "),
        );
        out.push(' ');
    }
    if matches!(param.mode, ParamMode::Var) {
        out.push_str("VAR ");
    } else if matches!(param.mode, ParamMode::Const) {
        out.push_str("CONST ");
    }
    out.push_str(&param.names.join(", "));
    out.push_str(" : ");
    out.push_str(&format_type_expr(&param.ty, 0));
    out
}

fn format_type_expr(ty: &TypeExpr, indent: usize) -> String {
    match ty {
        TypeExpr::Named(qn) => qn.segments.join("."),
        TypeExpr::Subrange(lo, hi, _) => {
            format!("[{}..{}]", format_expr(lo), format_expr(hi))
        }
        TypeExpr::Enum(names, values, _) => {
            let items: Vec<String> = names
                .iter()
                .zip(values.iter())
                .map(|(name, val)| match val {
                    Some(e) => format!("{} = {}", name, format_expr(e)),
                    None => name.clone(),
                })
                .collect();
            format!("({})", items.join(", "))
        }
        TypeExpr::Array(indices, base, _) => format!(
            "ARRAY {} OF {}",
            indices
                .iter()
                .map(|index| format_type_expr(index, indent))
                .collect::<Vec<_>>()
                .join(", "),
            format_type_expr(base, indent)
        ),
        TypeExpr::OpenArray(base, _) => format!("ARRAY OF {}", format_type_expr(base, indent)),
        TypeExpr::Record(record) => format_record_type(record, indent),
        TypeExpr::Pointer(base, _) => format!("POINTER TO {}", format_type_expr(base, indent)),
        TypeExpr::Proc(proc_ty) => format_proc_type(proc_ty, indent),
        TypeExpr::Set { packed, element, .. } => {
            let head = if *packed { "PACKEDSET OF" } else { "SET OF" };
            format!("{head} {}", format_type_expr(element, indent))
        }
    }
}

fn format_record_type(record: &RecordType, indent: usize) -> String {
    let mut out = String::from("RECORD");
    for field in &record.fields {
        out.push('\n');
        out.push_str(&format_record_field(field, indent + 4));
    }
    if let Some(variant) = &record.variant {
        out.push('\n');
        out.push_str(&format_variant_part(variant, indent + 4));
    }
    out.push('\n');
    out.push_str(&spaces(indent));
    out.push_str("END");
    out
}

fn format_record_field(field: &RecordField, indent: usize) -> String {
    let mut out = String::new();
    for pragma in &field.pragmas {
        out.push_str(&spaces(indent));
        out.push_str(&format_pragma(pragma, 0));
        out.push('\n');
    }
    out.push_str(&spaces(indent));
    out.push_str(&format_field_names(&field.names, field.exported));
    out.push_str(" : ");
    out.push_str(&format_type_expr(&field.ty, indent));
    out.push(';');
    out
}

fn format_variant_part(variant: &VariantPart, indent: usize) -> String {
    let mut out = String::new();
    out.push_str(&spaces(indent));
    out.push_str("CASE");
    if let Some(tag_name) = &variant.tag_name {
        out.push(' ');
        out.push_str(tag_name);
    }
    if let Some(tag_type) = &variant.tag_type {
        out.push_str(" : ");
        out.push_str(&tag_type.segments.join("."));
    }
    out.push_str(" OF");

    for arm in &variant.arms {
        out.push('\n');
        out.push_str(&spaces(indent));
        out.push_str("| ");
        out.push_str(
            &arm
                .labels
                .iter()
                .map(format_case_label)
                .collect::<Vec<_>>()
                .join(", "),
        );
        out.push(':');
        for field in &arm.fields {
            out.push('\n');
            out.push_str(&format_record_field(field, indent + 4));
        }
        if let Some(nested) = &arm.variant {
            out.push('\n');
            out.push_str(&format_variant_part(nested, indent + 4));
        }
    }

    if let Some(else_arm) = &variant.else_arm {
        out.push('\n');
        out.push_str(&spaces(indent));
        out.push_str("ELSE");
        for field in else_arm {
            out.push('\n');
            out.push_str(&format_record_field(field, indent + 4));
        }
    }

    out.push('\n');
    out.push_str(&spaces(indent));
    out.push_str("END");
    out
}

fn format_case_label(label: &CaseLabel) -> String {
    match label {
        CaseLabel::Single(expr) => format_expr(expr),
        CaseLabel::Range(lo, hi) => format!("{}..{}", format_expr(lo), format_expr(hi)),
    }
}

fn format_proc_type(proc_ty: &ProcType, indent: usize) -> String {
    let params = proc_ty
        .params
        .iter()
        .map(format_proc_type_param)
        .collect::<Vec<_>>()
        .join("; ");
    let mut out = format!("PROCEDURE({params})");
    if let Some(return_ty) = &proc_ty.return_ty {
        out.push_str(" : ");
        out.push_str(&format_type_expr(return_ty, indent));
    }
    if !proc_ty.attrs.is_empty() {
        out.push(' ');
        out.push_str(&format_proc_attrs(&proc_ty.attrs));
    }
    out
}

fn format_proc_type_param(param: &ProcTypeParam) -> String {
    let mut out = String::new();
    if !param.pragmas.is_empty() {
        for (index, pragma) in param.pragmas.iter().enumerate() {
            if index > 0 {
                out.push(' ');
            }
            out.push_str(&format_pragma(pragma, 0));
        }
        out.push(' ');
    }
    if matches!(param.mode, ParamMode::Var) {
        out.push_str("VAR ");
    } else if matches!(param.mode, ParamMode::Const) {
        out.push_str("CONST ");
    }
    out.push_str(&format_type_expr(&param.ty, 0));
    out
}

fn format_proc_attrs(attrs: &[ProcAttr]) -> String {
    let inner = attrs.iter().map(format_proc_attr).collect::<Vec<_>>().join(", ");
    format!("[{inner}]")
}

fn format_proc_attr(attr: &ProcAttr) -> String {
    if attr.args.is_empty() {
        attr.name.clone()
    } else {
        format!("{}({})", attr.name, attr.args.join(", "))
    }
}

fn format_string_literal(literal: &newm2_lexer::StringLiteral) -> String {
    format!("\"{}\"{}", literal.value, literal.flavor.suffix())
}

fn format_field_names(names: &[String], exported: bool) -> String {
    if exported {
        format!("{}*", names.join(", "))
    } else {
        names.join(", ")
    }
}

fn format_pragma(pragma: &Pragma, indent: usize) -> String {
    format!("{}<*{}*>", spaces(indent), pragma.body)
}

fn format_expr(expr: &Expr) -> String {
    match expr {
        Expr::Integer(value, _) => value.to_string(),
        Expr::Real(value, _) => format_real_literal(*value),
        Expr::Char(value, _) => format!("'{}'", value.value),
        Expr::String(value, _) => {
            let suffix = value.flavor.suffix();
            // Pick a delimiter the string does not itself contain (M2 has no
            // string escapes). A value with both quote kinds is unrepresentable
            // and is filtered out upstream by the generator.
            let delim = if value.value.contains('"') { '\'' } else { '"' };
            format!("{delim}{}{delim}{suffix}", value.value)
        }
        Expr::Nil(_) => "NIL".to_string(),
        Expr::Designator(designator) => format_designator(designator),
        Expr::Call(target, args, _) => format!(
            "{}({})",
            format_expr(target),
            args.iter().map(format_expr).collect::<Vec<_>>().join(", ")
        ),
        Expr::Binary(op, left, right, _) => format!(
            "({} {} {})",
            format_expr(left),
            format_binary_op(*op),
            format_expr(right)
        ),
        Expr::Unary(op, inner, _) => format!("({}{})", format_unary_op(*op), format_expr(inner)),
        Expr::Set { type_name, elements, .. } => {
            let prefix = type_name
                .as_ref()
                .map(|name| format!("{}", name.segments.join(".")))
                .unwrap_or_default();
            let elems = elements
                .iter()
                .map(format_set_elem)
                .collect::<Vec<_>>()
                .join(", ");
            if prefix.is_empty() {
                format!("{{{elems}}}")
            } else {
                format!("{}{{{elems}}}", prefix)
            }
        }
    }
}

/// Render an f64 as a Modula-2 REAL literal. A bare `f64::to_string()` drops the
/// decimal point for whole values (`100.0` -> "100", `3.4e38` ->
/// "340282...000"), which the lexer then scans as an *integer* and rejects when
/// it overflows. A REAL literal must contain a `.`; large magnitudes use a
/// scientific form with a decimal mantissa.
fn format_real_literal(value: f64) -> String {
    if !value.is_finite() {
        return "0.0".to_string();
    }
    let plain = value.to_string();
    if plain.contains('.') {
        return plain;
    }
    if plain.len() <= 15 {
        return format!("{plain}.0");
    }
    let sci = format!("{value:E}");
    match sci.split_once('E') {
        Some((mantissa, exp)) => {
            let mantissa =
                if mantissa.contains('.') { mantissa.to_string() } else { format!("{mantissa}.0") };
            format!("{mantissa}E{exp}")
        }
        None => format!("{sci}.0"),
    }
}

fn format_set_elem(elem: &SetElem) -> String {
    match elem {
        SetElem::Single(expr) => format_expr(expr),
        SetElem::Range(lo, hi) => format!("{}..{}", format_expr(lo), format_expr(hi)),
    }
}

fn format_designator(designator: &Designator) -> String {
    let mut out = designator.base.segments.join(".");
    for selector in &designator.selectors {
        match selector {
            Selector::Field(name, _) => {
                out.push('.');
                out.push_str(name);
            }
            Selector::Index(indices, _) => {
                out.push('[');
                out.push_str(&indices.iter().map(format_expr).collect::<Vec<_>>().join(", "));
                out.push(']');
            }
            Selector::Deref(_) => out.push('^'),
            Selector::TypeGuard(name, _) => {
                out.push('(');
                out.push_str(&name.segments.join("."));
                out.push(')');
            }
        }
    }
    out
}

fn format_binary_op(op: BinaryOp) -> &'static str {
    match op {
        BinaryOp::Add => "+",
        BinaryOp::Sub => "-",
        BinaryOp::Mul => "*",
        BinaryOp::Div => "/",
        BinaryOp::DivKw => "DIV",
        BinaryOp::Mod => "MOD",
        BinaryOp::Rem => "REM",
        BinaryOp::Eq => "=",
        BinaryOp::Ne => "#",
        BinaryOp::Lt => "<",
        BinaryOp::Le => "<=",
        BinaryOp::Gt => ">",
        BinaryOp::Ge => ">=",
        BinaryOp::And => "AND",
        BinaryOp::Or => "OR",
        BinaryOp::In => "IN",
        BinaryOp::Bor => "BOR",
        BinaryOp::Band => "BAND",
        BinaryOp::Bxor => "BXOR",
        BinaryOp::Shl => "SHL",
        BinaryOp::Shr => "SHR",
    }
}

fn format_unary_op(op: UnaryOp) -> &'static str {
    match op {
        UnaryOp::Pos => "+",
        UnaryOp::Neg => "-",
        UnaryOp::Not => "NOT ",
    }
}

fn spaces(indent: usize) -> String {
    " ".repeat(indent)
}