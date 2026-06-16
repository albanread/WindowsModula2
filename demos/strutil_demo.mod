MODULE StrUtilDemo;
(*
 * Exercises StrBuf (growable string builder) and StrUtil (trim/search/replace/split).
 *   build: newm2 build demos/strutil_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard, WriteInt;
IMPORT StrBuf, StrUtil;

VAR pass, fail: CARDINAL;

PROCEDURE StrEq (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  LOOP
    IF (i > HIGH(a)) OR (a[i] = 0C) THEN RETURN (i > HIGH(b)) OR (b[i] = 0C) END;
    IF (i > HIGH(b)) OR (a[i] # b[i]) THEN RETURN FALSE END;
    INC(i)
  END
END StrEq;

PROCEDURE CheckStr (label: ARRAY OF CHAR; VAR got: ARRAY OF CHAR; want: ARRAY OF CHAR);
BEGIN
  WriteString(label); WriteString(" = '"); WriteString(got); WriteString("'");
  IF StrEq(got, want) THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want '"); WriteString(want); WriteString("'"); INC(fail) END;
  WriteLn
END CheckStr;

PROCEDURE Check (label: ARRAY OF CHAR; got, want: CARDINAL);
BEGIN
  WriteString(label); WriteString(" = "); WriteCard(got, 1);
  IF got = want THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteCard(want, 1); INC(fail) END;
  WriteLn
END Check;

PROCEDURE CheckI (label: ARRAY OF CHAR; got, want: INTEGER);
BEGIN
  WriteString(label); WriteString(" = "); WriteInt(got, 1);
  IF got = want THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteInt(want, 1); INC(fail) END;
  WriteLn
END CheckI;

PROCEDURE CheckB (label: ARRAY OF CHAR; got, want: BOOLEAN);
BEGIN
  WriteString(label); WriteString(" = ");
  IF got THEN WriteString("TRUE") ELSE WriteString("FALSE") END;
  IF got = want THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL]"); INC(fail) END;
  WriteLn
END CheckB;

VAR
  b: StrBuf.StrBuf;
  s: ARRAY [0..127] OF CHAR;
  i: CARDINAL;
  ok: BOOLEAN;

BEGIN
  pass := 0; fail := 0;

  WriteString("=== StrBuf ==="); WriteLn;
  b := StrBuf.Create();
  StrBuf.Append(b, "Hello"); StrBuf.AppendCh(b, ' '); StrBuf.Append(b, "world");
  Check("length      ", StrBuf.Length(b), 11);
  ok := StrBuf.ToStr(b, s); CheckStr("build       ", s, "Hello world");
  StrBuf.Clear(b);
  StrBuf.Append(b, "x="); StrBuf.AppendCard(b, 42); StrBuf.AppendCh(b, ','); StrBuf.AppendInt(b, -7);
  ok := StrBuf.ToStr(b, s); CheckStr("nums        ", s, "x=42,-7");
  (* join "a,b,c" via the builder *)
  StrBuf.Clear(b);
  i := 0; WHILE i < 3 DO
    IF i > 0 THEN StrBuf.AppendCh(b, ',') END;
    StrBuf.AppendCh(b, CHR(ORD('a') + i)); INC(i)
  END;
  ok := StrBuf.ToStr(b, s); CheckStr("join        ", s, "a,b,c");
  (* grow stress: 1000 chars *)
  StrBuf.Clear(b);
  i := 0; WHILE i < 1000 DO StrBuf.AppendCh(b, 'x'); INC(i) END;
  Check("grow len    ", StrBuf.Length(b), 1000);
  StrBuf.Dispose(b);

  WriteString("=== StrUtil: trim ==="); WriteLn;
  StrUtil.Trim("  hi there  ", s);      CheckStr("trim        ", s, "hi there");
  StrUtil.TrimLeft("  hi  ", s);        CheckStr("trimLeft    ", s, "hi  ");
  StrUtil.TrimRight("  hi  ", s);       CheckStr("trimRight   ", s, "  hi");
  StrUtil.Trim("nopad", s);            CheckStr("trim nopad  ", s, "nopad");

  WriteString("=== StrUtil: search ==="); WriteLn;
  CheckI("indexOf hit ", StrUtil.IndexOf("hello world", "world", 0), 6);
  CheckI("indexOf miss", StrUtil.IndexOf("hello world", "xyz", 0), -1);
  CheckB("contains    ", StrUtil.Contains("hello", "ell"), TRUE);
  CheckB("not contains", StrUtil.Contains("hello", "z"), FALSE);
  CheckB("startsWith  ", StrUtil.StartsWith("hello", "he"), TRUE);
  CheckB("not starts  ", StrUtil.StartsWith("hello", "lo"), FALSE);
  CheckB("endsWith    ", StrUtil.EndsWith("hello", "lo"), TRUE);
  CheckB("not ends    ", StrUtil.EndsWith("hello", "he"), FALSE);
  Check("count       ", StrUtil.Count("ababab", "ab"), 3);
  Check("count nonov ", StrUtil.Count("aaa", "aa"), 1);

  WriteString("=== StrUtil: replace-all ==="); WriteLn;
  ok := StrUtil.ReplaceAll("a.b.c", ".", "-", s);     CheckStr("dots        ", s, "a-b-c");
  ok := StrUtil.ReplaceAll("aaa", "a", "bb", s);       CheckStr("grow repl   ", s, "bbbbbb");
  ok := StrUtil.ReplaceAll("foofoo", "foo", "X", s);   CheckStr("shrink repl ", s, "XX");
  ok := StrUtil.ReplaceAll("none here", "zzz", "!", s);CheckStr("no match    ", s, "none here");

  WriteString("=== StrUtil: split ==="); WriteLn;
  Check("splitCount 3", StrUtil.SplitCount("a,b,c", ","), 3);
  Check("splitCount 1", StrUtil.SplitCount("abc", ","), 1);
  ok := StrUtil.SplitPart("a,b,c", ",", 0, s); CheckStr("part0       ", s, "a");
  ok := StrUtil.SplitPart("a,b,c", ",", 1, s); CheckStr("part1       ", s, "b");
  ok := StrUtil.SplitPart("a,b,c", ",", 2, s); CheckStr("part2       ", s, "c");
  CheckB("part oob    ", StrUtil.SplitPart("a,b,c", ",", 3, s), FALSE);
  ok := StrUtil.SplitPart("a,,c", ",", 1, s);  CheckStr("empty part  ", s, "");
  Check("multi sep ct", StrUtil.SplitCount("a::b::c", "::"), 3);
  ok := StrUtil.SplitPart("a::b::c", "::", 1, s); CheckStr("multi part1 ", s, "b");

  WriteLn;
  WriteString("PASS="); WriteCard(pass, 1);
  WriteString("  FAIL="); WriteCard(fail, 1); WriteLn
END StrUtilDemo.
