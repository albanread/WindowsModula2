MODULE T90212WinrtMemUtils;
(*
 * Group 90 — M2WINRT: MemUtils. Portable block-memory ops over SYSTEM byte
 * access: fill (BYTE/WORD/QWORD), zero, scan (eq/ne), compare, overlap-safe
 * move (the critical backward-copy case), plus the hardening primitives
 * SecureZeroMem and EqualCT. Exercises CAST(ADDRESS<->CARDINAL), the giant
 * POINTER TO ARRAY OF BYTE type, 64-bit shifts, and zero-count loop safety.
 *
 * EXPECTED:
 * 170 0
 * 52 18 52 18 52 18
 * 239 205 171 137 103 69 35 1
 * 2 0 5 1
 * 1 2 1 2 3 4 5 6
 * 3 4 5 6 7 8 7 8
 * 2
 * 16
 * Y
 * N
 * Y
 *)
FROM SYSTEM IMPORT ADR;
FROM MemUtils IMPORT FillMemBYTE, FillMemWORD, FillMemQWORD, ZeroMem,
  ScanMemBYTE, ScanMemNeBYTE, CompMem, MoveMem, SecureZeroMem, EqualCT;
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;
PROCEDURE Dump (VAR buf: ARRAY OF BYTE; n: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO n - 1 DO WriteCard(ORD(buf[i]), 1); IF i < n - 1 THEN WriteString(" ") END END;
  WriteLn
END Dump;

VAR buf, b2: ARRAY [0..15] OF BYTE; i: CARDINAL;
BEGIN
  FillMemBYTE(ADR(buf), 16, VAL(BYTE, 0)); FillMemBYTE(ADR(buf), 5, VAL(BYTE, 0AAH));
  FillMemBYTE(ADR(buf), 0, VAL(BYTE, 0FFH));            (* count=0 no-op *)
  WriteCard(ORD(buf[0]), 1); WriteString(" "); WriteCard(ORD(buf[5]), 1); WriteLn;

  ZeroMem(ADR(buf), 16); FillMemWORD(ADR(buf), 3, 01234H); Dump(buf, 6);
  ZeroMem(ADR(buf), 16); FillMemQWORD(ADR(buf), 1, 0123456789ABCDEFH); Dump(buf, 8);

  buf[0] := VAL(BYTE, 10); buf[1] := VAL(BYTE, 20); buf[2] := VAL(BYTE, 30);
  buf[3] := VAL(BYTE, 40); buf[4] := VAL(BYTE, 50);
  WriteCard(ScanMemBYTE(ADR(buf), 5, VAL(BYTE, 30)), 1); WriteString(" ");
  WriteCard(ScanMemBYTE(ADR(buf), 5, VAL(BYTE, 10)), 1); WriteString(" ");
  WriteCard(ScanMemBYTE(ADR(buf), 5, VAL(BYTE, 99)), 1); WriteString(" ");
  WriteCard(ScanMemNeBYTE(ADR(buf), 5, VAL(BYTE, 10)), 1); WriteLn;

  FOR i := 0 TO 7 DO buf[i] := VAL(BYTE, i + 1) END;
  MoveMem(ADR(buf[2]), ADR(buf[0]), 6); Dump(buf, 8);      (* overlap -> backward *)
  FOR i := 0 TO 7 DO buf[i] := VAL(BYTE, i + 1) END;
  MoveMem(ADR(buf[0]), ADR(buf[2]), 6); Dump(buf, 8);      (* overlap -> forward *)

  FOR i := 0 TO 3 DO buf[i] := VAL(BYTE, i + 1); b2[i] := VAL(BYTE, i + 1) END;
  b2[2] := VAL(BYTE, 9);
  WriteCard(CompMem(ADR(buf), ADR(b2), 4), 1); WriteLn;

  FillMemBYTE(ADR(buf), 16, VAL(BYTE, 0FFH)); SecureZeroMem(ADR(buf), 16);
  WriteCard(ScanMemNeBYTE(ADR(buf), 16, VAL(BYTE, 0)), 1); WriteLn;

  FOR i := 0 TO 3 DO buf[i] := VAL(BYTE, i); b2[i] := VAL(BYTE, i) END;
  YN(EqualCT(ADR(buf), ADR(b2), 4));
  b2[3] := VAL(BYTE, 99); YN(EqualCT(ADR(buf), ADR(b2), 4));
  YN(EqualCT(ADR(buf), ADR(b2), 0))
END T90212WinrtMemUtils.
