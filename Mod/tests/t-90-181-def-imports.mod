MODULE T90181DefImports;
(*
 * Group 90 — loader / separate compilation
 * Test: a module's imports declared only in its DEFINITION are followed by the
 *       loader. T90Mid.def imports T90Leaf (the MOD does not re-import it); this
 *       main module imports T90Mid. The loader must collect imports from both
 *       {impl, def}, so T90Leaf is loaded. Helper modules: T90Leaf.def/.mod,
 *       T90Mid.def/.mod.
 *
 * EXPECTED:
 * 8
 *)
IMPORT T90Mid;
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteLn;

BEGIN
  WriteCard(T90Mid.eight(), 0); WriteLn   (* 7 + 1 = 8 *)
END T90181DefImports.
