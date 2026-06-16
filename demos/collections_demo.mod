MODULE CollectionsDemo;
(*
 * Exercises Vector, StrMap and Hashing.
 *   build: newm2 build demos/collections_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
IMPORT Vector, StrMap, Hashing;

VAR pass, fail: CARDINAL;

PROCEDURE Check (label: ARRAY OF CHAR; got, want: CARDINAL);
BEGIN
  WriteString(label); WriteString(" = "); WriteCard(got, 1);
  IF got = want THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteCard(want, 1); INC(fail) END;
  WriteLn
END Check;

PROCEDURE CheckB (label: ARRAY OF CHAR; got, want: BOOLEAN);
BEGIN
  WriteString(label); WriteString(" = ");
  IF got THEN WriteString("TRUE") ELSE WriteString("FALSE") END;
  IF got = want THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL]"); INC(fail) END;
  WriteLn
END CheckB;

PROCEDURE KName (n: CARDINAL; VAR s: ARRAY OF CHAR);
  VAR buf: ARRAY [0..19] OF CHAR; i, j: CARDINAL;
BEGIN
  s[0] := 'k';
  IF n = 0 THEN s[1] := '0'; s[2] := 0C; RETURN END;
  i := 0; WHILE n > 0 DO buf[i] := CHR(ORD('0') + n MOD 10); n := n DIV 10; INC(i) END;
  j := 1; WHILE i > 0 DO DEC(i); s[j] := buf[i]; INC(j) END;
  s[j] := 0C
END KName;

VAR
  v: Vector.Vector;
  m: StrMap.StrMap;
  it: StrMap.Iterator;
  key: ARRAY [0..63] OF CHAR;
  small: ARRAY [0..3] OF CHAR;
  val, i, sum, cnt: CARDINAL;
  h1, h2, h3: CARDINAL;
  ok: BOOLEAN;

BEGIN
  pass := 0; fail := 0;
  WriteString("=== Vector ==="); WriteLn;
  v := Vector.Create();
  Vector.Push(v, 10); Vector.Push(v, 20); Vector.Push(v, 30);
  Check("len            ", Vector.Length(v), 3);
  Check("get(0)         ", Vector.Get(v, 0), 10);
  Check("get(2)         ", Vector.Get(v, 2), 30);
  Check("last           ", Vector.Last(v), 30);
  Check("pop            ", Vector.Pop(v), 30);
  Check("len after pop  ", Vector.Length(v), 2);
  Vector.Set(v, 0, 99);
  Check("set/get(0)     ", Vector.Get(v, 0), 99);
  Vector.Insert(v, 1, 55);                       (* [99,55,20] *)
  Check("insert get(1)  ", Vector.Get(v, 1), 55);
  Check("insert get(2)  ", Vector.Get(v, 2), 20);
  Check("removed        ", Vector.Remove(v, 0), 99);   (* [55,20] *)
  Check("after remove(0)", Vector.Get(v, 0), 55);
  Vector.Swap(v, 0, 1);                           (* [20,55] *)
  Check("swap get(0)    ", Vector.Get(v, 0), 20);
  Check("oob get        ", Vector.Get(v, 999), 0);
  (* grow stress: push 1000 values *)
  Vector.Clear(v);
  i := 0; WHILE i < 1000 DO Vector.Push(v, i * 3); INC(i) END;
  Check("len 1000       ", Vector.Length(v), 1000);
  Check("get(500)       ", Vector.Get(v, 500), 1500);
  CheckB("cap >= 1000    ", Vector.Capacity(v) >= 1000, TRUE);
  Vector.Dispose(v);

  WriteString("=== StrMap ==="); WriteLn;
  m := StrMap.Create();
  StrMap.Put(m, "a", 1); StrMap.Put(m, "b", 2); StrMap.Put(m, "c", 3);
  Check("count          ", StrMap.Count(m), 3);
  CheckB("get b          ", StrMap.Get(m, "b", val), TRUE);
  Check("  b value      ", val, 2);
  CheckB("has c          ", StrMap.Has(m, "c"), TRUE);
  CheckB("has z          ", StrMap.Has(m, "z"), FALSE);
  StrMap.Put(m, "b", 20);                          (* update *)
  CheckB("get b again    ", StrMap.Get(m, "b", val), TRUE);
  Check("  b updated    ", val, 20);
  Check("count unchanged", StrMap.Count(m), 3);
  CheckB("remove a       ", StrMap.Remove(m, "a"), TRUE);
  CheckB("has a gone     ", StrMap.Has(m, "a"), FALSE);
  CheckB("remove a again ", StrMap.Remove(m, "a"), FALSE);
  Check("count after rm ", StrMap.Count(m), 2);
  (* rehash stress: 100 keys k0..k99 = i*i; remaining: b=20, c=3 *)
  i := 0; WHILE i < 100 DO KName(i, key); StrMap.Put(m, key, i * i); INC(i) END;
  Check("count 102      ", StrMap.Count(m), 102);
  KName(50, key);
  CheckB("get k50        ", StrMap.Get(m, key, val), TRUE);
  Check("  k50 = 2500   ", val, 2500);
  (* full iteration: sum values, count entries *)
  it := StrMap.Iterate(m); sum := 0; cnt := 0;
  WHILE StrMap.Next(m, it, key, val) DO sum := sum + val; INC(cnt) END;
  Check("iterate count  ", cnt, 102);
  Check("iterate sum    ", sum, 328373);           (* 20 + 3 + sum(i*i,0..99)=328350 *)
  StrMap.Dispose(m);

  WriteString("=== Hashing ==="); WriteLn;
  h1 := Hashing.FNV1a("hello"); h2 := Hashing.FNV1a("hello"); h3 := Hashing.FNV1a("world");
  CheckB("FNV1a stable   ", h1 = h2, TRUE);
  CheckB("FNV1a differs  ", h1 # h3, TRUE);

  WriteString("=== StrMap.Next truncation ==="); WriteLn;
  m := StrMap.Create();
  StrMap.Put(m, "hello", 7);                  (* 5-char key into a 4-cell buffer *)
  it := StrMap.Iterate(m);
  ok := StrMap.Next(m, it, small, val);
  CheckB("returned        ", ok, TRUE);
  Check("  value 7      ", val, 7);
  CheckB("trunc terminated", small[3] = 0C, TRUE);   (* must be NUL-terminated, not overrun *)
  StrMap.Dispose(m);

  WriteLn;
  WriteString("PASS="); WriteCard(pass, 1);
  WriteString("  FAIL="); WriteCard(fail, 1); WriteLn
END CollectionsDemo.
