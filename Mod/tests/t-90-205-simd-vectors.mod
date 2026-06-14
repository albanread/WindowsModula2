MODULE T90205SimdVectors;
(*
 * Group 90 — first-class SIMD lane vectors.
 *   REAL32X4 = <4 x f32>, REAL64X2 = <2 x f64>: register-resident, element-wise
 *   + - * /, scalar broadcast, lane read/write, and arrays of vectors.
 *   See docs/design/simd-laned-vectors.md.
 *
 * EXPECTED:
 * 11
 * 44
 * 4
 * 30
 * 100
 * 400
 * 2
 *)
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteLn;

VAR
  a, b, c : REAL32X4;
  p, q    : REAL64X2;
  grid    : ARRAY [0..3] OF REAL32X4;
  i       : CARDINAL;
BEGIN
  a := REAL32X4{1.0, 2.0, 3.0, 4.0};
  b := REAL32X4{10.0, 20.0, 30.0, 40.0};
  c := a + b;                       (* {11,22,33,44} *)
  WriteCard(TRUNC(c[0]), 1); WriteLn;
  WriteCard(TRUNC(c[3]), 1); WriteLn;
  c := a * REAL32X4{2.0};           (* broadcast {2,2,2,2} -> {2,4,6,8} *)
  WriteCard(TRUNC(c[1]), 1); WriteLn;
  c := a * 10.0;                    (* direct scalar broadcast -> {10,20,30,40} *)
  WriteCard(TRUNC(c[2]), 1); WriteLn;
  c[0] := 100.0;                    (* lane write *)
  WriteCard(TRUNC(c[0]), 1); WriteLn;
  p := REAL64X2{3.0, 4.0};
  q := REAL64X2{10.0, 100.0};
  p := p * q;                       (* {30, 400} *)
  WriteCard(TRUNC(p[1]), 1); WriteLn;
  FOR i := 0 TO 3 DO grid[i] := REAL32X4{1.0, 1.0, 1.0, 1.0} END;
  c := grid[1] + grid[2];           (* array of vectors: {2,2,2,2} *)
  WriteCard(TRUNC(c[3]), 1); WriteLn
END T90205SimdVectors.
