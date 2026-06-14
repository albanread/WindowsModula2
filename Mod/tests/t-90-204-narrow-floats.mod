MODULE T90204NarrowFloats;
(*
 * Group 90 — true narrow IEEE floats (REAL32/SHORTREAL = f32, REAL16 = f16),
 * distinct types for Win32 FLOAT interop and SIMD/matrix work.
 *   - SHORTREAL (f32): 2.5 * 2.5 = 6.25 -> TRUNC = 6, SIZE = 4.
 *   - REAL16    (f16): 1.5 * 2.0 = 3.0  -> TRUNC = 3, SIZE = 2.
 * Scalar f16 arithmetic lowers through the x86 F16C / soft-float path; this
 * exercises it end to end through the JIT.
 *
 * EXPECTED:
 * 6
 * 3
 * 4
 * 2
 *)
FROM SYSTEM IMPORT REAL16, REAL32, TSIZE;
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteLn;

VAR
  h, two: REAL16;
  f: REAL32;
BEGIN
  f := 2.5; f := f * f;
  WriteCard(TRUNC(f), 1); WriteLn;
  h := 1.5; two := 2.0; h := h * two;
  WriteCard(TRUNC(h), 1); WriteLn;
  WriteCard(TSIZE(REAL32), 1); WriteLn;
  WriteCard(TSIZE(REAL16), 1); WriteLn
END T90204NarrowFloats.
