MODULE T90206SimdReductions;
(*
 * Group 90 — SIMD reductions & fused multiply-add.
 *   SUM(v)        horizontal lane add (llvm.vector.reduce.fadd).
 *   DOT(a,b)      = SUM(a*b).
 *   FMA(a,b,c)    fused lane-wise a*b + c (llvm.fma).
 *   ABS(v)        lane-wise absolute value (llvm.fabs).
 *   See docs/design/simd-laned-vectors.md.
 *
 * EXPECTED:
 * 10
 * 100
 * 44
 * 14
 * 25
 *)
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteLn;

VAR
  a, b, c : REAL32X4;
  p       : REAL64X2;
BEGIN
  a := REAL32X4{1.0, 2.0, 3.0, 4.0};
  b := REAL32X4{10.0, 10.0, 10.0, 10.0};
  WriteCard(TRUNC(SUM(a)), 1); WriteLn;        (* 1+2+3+4 = 10 *)
  WriteCard(TRUNC(DOT(a, b)), 1); WriteLn;     (* 10*10 = 100 *)
  c := FMA(a, b, a);                           (* a*10 + a = {11,22,33,44} *)
  WriteCard(TRUNC(c[3]), 1); WriteLn;
  a := REAL32X4{-5.0, 2.0, -3.0, 4.0};
  c := ABS(a);                                 (* {5,2,3,4} *)
  WriteCard(TRUNC(SUM(c)), 1); WriteLn;        (* 5+2+3+4 = 14 *)
  p := REAL64X2{3.0, 4.0};
  WriteCard(TRUNC(DOT(p, p)), 1); WriteLn      (* 9+16 = 25 *)
END T90206SimdReductions.
