MODULE T90211WinrtSpecialReals;
(*
 * Group 90 — M2WINRT: SpecialReals. IEEE-754 f64 special values built as CONST
 * via CAST(REAL, <bit pattern>) (exercising the const-fold bit-reinterpret the
 * compiler now performs), and bit-pattern classification predicates. The matrix
 * classifies each special value across all eight predicates.
 * Columns: Fin NaN QNaN SNaN Inf +Inf -Inf -0
 *
 * EXPECTED:
 * Inf  NNNNYYNN
 * -Inf NNNNYNYN
 * QNaN NYYNNNNN
 * SNaN NYNYNNNN
 * -0   YNNNNNNY
 * 3.5  YNNNNNNN
 *)
FROM SpecialReals IMPORT Infinity, MinusInfinity, QNaN, SNaN, MinusZero,
  IsFinite, IsNaN, IsQNaN, IsSNaN, IsInfinity, IsPositiveInfinity,
  IsNegativeInfinity, IsMinusZero;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

PROCEDURE Row (label: ARRAY OF CHAR; r: REAL);
BEGIN
  WriteString(label);
  YN(IsFinite(r)); YN(IsNaN(r)); YN(IsQNaN(r)); YN(IsSNaN(r));
  YN(IsInfinity(r)); YN(IsPositiveInfinity(r)); YN(IsNegativeInfinity(r)); YN(IsMinusZero(r));
  WriteLn
END Row;

VAR z: REAL;
BEGIN
  Row("Inf  ", Infinity);
  Row("-Inf ", MinusInfinity);
  Row("QNaN ", QNaN);
  Row("SNaN ", SNaN);
  Row("-0   ", MinusZero);
  z := 3.5;
  Row("3.5  ", z)
END T90211WinrtSpecialReals.
