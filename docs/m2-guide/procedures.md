# Procedures

A procedure is the fundamental unit of abstraction in Modula-2: named, typed, callable,
and lexically scoped. This page covers declaring them, their parameters, nesting, and
using them as values.

## Proper procedures and function procedures

A **proper procedure** returns no value. It is called as a statement and its header ends
after the parameter list:

```modula2
PROCEDURE WriteValue(n : INTEGER);
BEGIN
  SWholeIO.WriteInt(n, 0);
  STextIO.WriteLn;
END WriteValue;
```

This is taken verbatim from `Mod/tests/T30020Helper.mod`. The closing `END` repeats the
procedure name — the parser enforces this match (`src/newm2-parser/src/parser.rs`,
procedure name-mismatch check).

A **function procedure** adds a result type after a colon. The body must execute a
`RETURN` statement that produces a value of that type:

```modula2
PROCEDURE BumpInt(n : INTEGER) : INTEGER;
BEGIN
  RETURN n + 4
END BumpInt;
```

From `Mod/tests/T30030ScalarHelper.mod`, which also shows `PROCEDURE … : CHAR` and
`PROCEDURE … : BOOLEAN`. The AST node is `ProcDecl` (`src/newm2-parser/src/ast.rs`,
line 145): `return_ty: Option<TypeExpr>` — `None` for a proper procedure, `Some(…)` for
a function procedure.

`RETURN` without an expression is valid in a proper procedure to exit early. In a function
procedure, every path through the body must reach a `RETURN expr`.

## Value and VAR parameters

Parameters are grouped between `(` and `)`. Parameters of the same type share a name
list separated by commas:

```modula2
PROCEDURE WriteRecordValues(leftIn : INTEGER; rightIn : CARDINAL; markIn : CHAR);
```

From `Mod/tests/T40020RecordHelper.mod`. Groups are separated by `;`.

| Mode | Syntax | Semantics |
|------|--------|-----------|
| Value | `name : T` | The argument is **copied**; the procedure gets its own copy |
| VAR | `VAR name : T` | The procedure receives a **reference** to the caller's variable; writes to the parameter are visible in the caller |

```modula2
PROCEDURE Swap(VAR a, b : INTEGER);
VAR tmp : INTEGER;
BEGIN
  tmp := a;
  a   := b;
  b   := tmp;
END Swap;
```

A `VAR` parameter is declared with the `VAR` keyword before the name list; multiple names
may share a single `VAR` prefix. The AST uses `ParamMode::Value` and `ParamMode::Var`
(`src/newm2-parser/src/ast.rs`, lines 184–188). A `VAR` parameter test is exercised in
the parser unit tests (`src/newm2-parser/src/lib.rs`, `procedure_with_var_param`).

**Value semantics for structured types.** Arrays and records passed by value are
**copied** entirely — the callee cannot affect the caller's copy. For large arrays or
records this copy is expensive; `VAR` is the standard way to pass them cheaply while
signalling that modification is permitted. To pass read-only by reference, some Modula-2
dialects use a convention of `VAR` with a note that the procedure will not write; NewM2
also provides a `CONST` mode but that is an extension beyond what the standard tests.

## Open array parameters

An **open array** formal accepts any concrete array of the right element type, regardless
of length. The syntax is `ARRAY OF T` with no index bounds:

```modula2
PROCEDURE Sum(a : ARRAY OF INTEGER) : INTEGER;
VAR i, s : INTEGER;
BEGIN
  s := 0;
  FOR i := 0 TO HIGH(a) DO
    s := s + a[i];
  END;
  RETURN s;
END Sum;
```

Inside the procedure, `HIGH(a)` returns the top index (length minus 1). The pervasive
procedure `HIGH` is described in [The standard environment](standard-environment.md). The
AST node for the formal's type is `TypeExpr::OpenArray(base, span)`
(`src/newm2-parser/src/ast.rs`, line 209). Sema enforces that open-array types appear
only in parameter position, not in `VAR` declarations or record fields.

The real library uses open arrays pervasively for string buffers:

```modula2
PROCEDURE GetStringResource(idNum : CARDINAL; VAR str : ARRAY OF CHAR);
```

From `library/win32def/StringCache.def`. The `EnumCallBack` callback type in
`library/advapidef/ConfigSettings.def` is also `PROCEDURE(ARRAY OF CHAR)`, meaning any
procedure that takes an open char array fits this type.

An open array may itself be a `VAR` parameter (the `VAR` goes before `ARRAY OF T`):

```modula2
PROCEDURE OpenConfig(companyName, appName : ARRAY OF CHAR;
                     user : BOOLEAN) : CfgOpenStatus;
```

From `library/advapidef/ConfigSettings.def`. Both `companyName` and `appName` are open
char arrays passed by value; `user` is an ordinary value parameter of type `BOOLEAN`.

## Nested procedures

A procedure body may declare local procedures in its declaration section (`ProcBody.decls`
— `src/newm2-parser/src/ast.rs`, line 170–173). A nested procedure has access to all
locals and parameters of every enclosing scope (static chain / upvalue capture):

```modula2
PROCEDURE SortWords(VAR data : ARRAY OF INTEGER);
  VAR n : INTEGER;

  PROCEDURE Less(i, j : INTEGER) : BOOLEAN;
  BEGIN
    RETURN data[i] < data[j];   (* sees the enclosing data parameter *)
  END Less;

BEGIN
  n := HIGH(data);
  (* … call Less … *)
END SortWords;
```

The nested `Less` sees `data` from the enclosing `SortWords` directly. Nesting is
recursive — a nested procedure may itself contain further nested procedures. The AST
represents this naturally: `ProcBody.decls` is a `Vec<Decl>`, and `Decl::Procedure`
inside that vec is a nested procedure parsed identically to a top-level one
(`src/newm2-parser/src/parser.rs`, `parse_top_decls`).

> **Status.** Nested procedure scoping is resolved by sema. Lowering to LLVM IR for
> nested procedures that capture outer locals (closure upvalues) is a work in progress;
> nested procedures that do not capture outer variables lower correctly today.

## FORWARD declarations

A **FORWARD** declaration gives the compiler a procedure's signature before the body
appears. This lets two procedures call each other when one must be declared before the
other:

```modula2
PROCEDURE IsEven(n : INTEGER) : BOOLEAN; FORWARD;

PROCEDURE IsOdd(n : INTEGER) : BOOLEAN;
BEGIN
  IF n = 0 THEN RETURN FALSE END;
  RETURN IsEven(n - 1);
END IsOdd;

PROCEDURE IsEven(n : INTEGER) : BOOLEAN;
BEGIN
  IF n = 0 THEN RETURN TRUE END;
  RETURN IsOdd(n - 1);
END IsEven;
```

The `FORWARD` keyword follows the full header and a `;`; the body comes later in the same
module. The parser sets `ProcDecl.is_forward = true`
(`src/newm2-parser/src/ast.rs`, line 155) and `body = None` for the forward stub, then
parses the full body when the second declaration appears.

**DEFINITION modules as forward declarations.** In practice, a procedure in a
`DEFINITION MODULE` is purely a header — no body, parsed into a `ProcDecl` with
`body: None` (`body: Option<ProcBody>`). The implementation module then supplies the
body. This is the standard Modula-2 forward-declaration mechanism for exported procedures;
explicit `FORWARD` inside a single module is needed only for mutual recursion within one
file. See [Modules & compilation](modules-and-compilation.md) for the definition/
implementation pairing.

## Procedure variables and procedure types

A *procedure type* describes the signature of a callable value. The [Declarations &
types](declarations-and-types.md) page introduced the type form; here is the usage side.

A variable of procedure type holds a reference to any procedure with the matching
signature:

```modula2
TYPE
  Comparator = PROCEDURE(INTEGER, INTEGER) : BOOLEAN;

VAR
  cmp : Comparator;

PROCEDURE LessThan(a, b : INTEGER) : BOOLEAN;
BEGIN
  RETURN a < b;
END LessThan;

BEGIN
  cmp := LessThan;
  IF cmp(3, 7) THEN
    STextIO.WriteString("ordered");
  END;
END …
```

The assignment `cmp := LessThan` stores a procedure reference. The call `cmp(3, 7)` calls
it through the variable — useful for callbacks, dispatch tables, and functional idioms.

The predeclared type `PROC` is short for `PROCEDURE` with no parameters and no result,
convenient for zero-argument callbacks:

```modula2
VAR action : PROC;
BEGIN
  action := MyInit;
  action;          (* call with no arguments *)
END …
```

The `Float.def` library uses procedure-type variables directly in `VAR` declarations:

```modula2
VAR
  SetRoundingBoth : PROCEDURE (RoundingMode) [Pass(BX),Alters(BX)] = SetRounding87;
  InitBoth        : PROCEDURE (            ) [         Alters(  )] = Init87;
```

From `library/advapidef/Float.def`. The `[Pass(BX), Alters(BX)]` are register-passing
attributes on the procedure type — a low-level extension for hand-optimised library code.
The `EnumCallBack = PROCEDURE(ARRAY OF CHAR)` type in `library/advapidef/ConfigSettings.def`
shows a procedure type used as a callback parameter.

The AST represents both sides: a procedure type literal is `TypeExpr::Proc(ProcType)` and
a procedure declaration is `Decl::Procedure(ProcDecl)`, where `ProcDecl.body` is `None`
in a forward or definition-module header and `Some(ProcBody)` in a full declaration
(`src/newm2-parser/src/ast.rs`, lines 144–173).

---
[NewM2 Guide home](index.md) · [Statements & control flow](statements-and-control-flow.md) · [Modules & compilation](modules-and-compilation.md)
