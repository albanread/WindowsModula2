MODULE T90213WinrtSortLib;
(*
 * Group 90 — M2WINRT: SortLib. All five abstract callback-driven sorts
 * (Quick/Heap/Shell/BinaryInsert/Merge) over a shared array via compare/swap/
 * assign-by-index procedure parameters. Heavily exercises PROCEDURE-typed
 * parameters, indirect calls (incl. a BOOLEAN-returning comparator with a
 * BOOLEAN flag arg), and nested procedures closing over those params.
 *
 * EXPECTED:
 * Q 1 2 2 3 5 8 8 9
 * H 1 2 2 3 5 8 8 9
 * S 1 2 2 3 5 8 8 9
 * B 1 2 2 3 5 8 8 9
 * M 1 2 2 3 5 8 8 9
 *)
FROM SortLib IMPORT QuickSort, HeapSort, ShellSort, BinaryInsertSort, MergeSort,
  LessEqProc, SwapProc, AssignProc;
FROM NumberIO IMPORT WriteInt;
FROM StrIO IMPORT WriteString, WriteLn;

CONST N = 8;
VAR a: ARRAY [0 .. 2 * N] OF INTEGER;   (* 0=temp, 1..8=data, 9..16=merge scratch *)

PROCEDURE Less (l, r: CARDINAL; eqAlso: BOOLEAN): BOOLEAN;
BEGIN IF eqAlso THEN RETURN a[l] <= a[r] ELSE RETURN a[l] < a[r] END END Less;
PROCEDURE Swap (l, r: CARDINAL);
  VAR t: INTEGER;
BEGIN t := a[l]; a[l] := a[r]; a[r] := t END Swap;
PROCEDURE Assign (l, r: CARDINAL);
BEGIN a[l] := a[r] END Assign;

PROCEDURE Seed;
  VAR i: CARDINAL;
BEGIN
  a[1] := 5; a[2] := 2; a[3] := 8; a[4] := 2; a[5] := 9; a[6] := 3; a[7] := 8; a[8] := 1;
  FOR i := 9 TO 2 * N DO a[i] := 0 END
END Seed;
PROCEDURE Show (tag: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  WriteString(tag);
  FOR i := 1 TO N DO WriteInt(a[i], 1); IF i < N THEN WriteString(" ") END END;
  WriteLn
END Show;

BEGIN
  Seed; QuickSort(N, Less, Swap);          Show("Q ");
  Seed; HeapSort(N, Less, Swap);           Show("H ");
  Seed; ShellSort(N, Less, Assign);        Show("S ");
  Seed; BinaryInsertSort(N, Less, Assign); Show("B ");
  Seed; MergeSort(N, Less, Assign);        Show("M ")
END T90213WinrtSortLib.
