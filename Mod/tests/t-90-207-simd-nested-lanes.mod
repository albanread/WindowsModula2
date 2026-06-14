MODULE T90207SimdNestedLanes;
(*
 * Group 90 — SIMD lane access through fields and array elements (hardening).
 * A lane has no independent address, so `rec.v[i]` / `grid[k][i]` (read and
 * write) load the whole addressable vector and extract/insert — they must NOT
 * fall through to byte-addressed array indexing (which silently corrupted
 * adjacent lanes). Also exercises unary negate and mixed f32-lane * literal.
 *
 * EXPECTED:
 * 99
 * 3
 * 50
 * 6
 * 5
 *)
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteLn;

TYPE R = RECORD v: REAL32X4 END;
VAR
  r    : R;
  grid : ARRAY [0..3] OF REAL32X4;
  w, z : REAL32X4;
BEGIN
  r.v := REAL32X4{1.0, 2.0, 3.0, 4.0};
  r.v[1] := 99.0;                       (* lane write through a field *)
  WriteCard(TRUNC(r.v[1]), 1); WriteLn; (* 99 *)
  WriteCard(TRUNC(r.v[2]), 1); WriteLn; (* 3 — adjacent lane NOT corrupted *)
  grid[1] := REAL32X4{5.0, 6.0, 7.0, 8.0};
  grid[1][2] := 50.0;                   (* lane write through an array element *)
  WriteCard(TRUNC(grid[1][2]), 1); WriteLn; (* 50 *)
  w := -REAL32X4{3.0, 6.0, 9.0, 12.0};  (* packed fneg *)
  z := ABS(w);
  WriteCard(TRUNC(z[1]), 1); WriteLn;   (* 6 *)
  WriteCard(TRUNC(grid[1][0] * 1.0), 1); WriteLn (* f32 lane * f64 literal = 5 *)
END T90207SimdNestedLanes.
