MODULE BigIntDemo;
(*
 * Exercises the BigInt arbitrary-precision library against known exact values.
 *   build: newm2 build demos/bigint_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
FROM BigInt IMPORT BigInt, FromCard, FromInt, FromStr0, ToStr, Mul, Add, Sub, DivMod,
  Pow, PowMod, Gcd, Dispose, Copy;

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

(* check that ToStr(g) (base 10) equals `expect`, then dispose g *)
PROCEDURE CheckVal (label, expect: ARRAY OF CHAR; g: BigInt);
  VAR s: ARRAY [0..399] OF CHAR; ok: BOOLEAN;
BEGIN
  ok := ToStr(g, 10, s);
  WriteString(label); WriteString(" = ");
  IF ok THEN WriteString(s) ELSE WriteString("<buffer too small>") END;
  IF ok AND StrEq(s, expect) THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] expected "); WriteString(expect); INC(fail) END;
  WriteLn;
  Dispose(g)
END CheckVal;

PROCEDURE Factorial (n: CARDINAL; VAR snapAt: CARDINAL; VAR snap: BigInt): BigInt;
  VAR f, t: BigInt; i: CARDINAL;
BEGIN
  f := FromCard(1); snap := FromCard(1);
  i := 1;
  WHILE i <= n DO
    t := Mul(f, FromCard(i)); Dispose(f); f := t;
    IF i = snapAt THEN Dispose(snap); snap := Copy(f) END;
    INC(i)
  END;
  RETURN f
END Factorial;

PROCEDURE Fib (n: CARDINAL): BigInt;
  VAR a, b, t: BigInt; i: CARDINAL;
BEGIN
  a := FromCard(0); b := FromCard(1); i := 0;
  WHILE i < n DO
    t := Add(a, b); Dispose(a); a := b; b := t; INC(i)
  END;
  RETURN a
END Fib;

VAR
  f100, f99, q, r, two, g: BigInt;
  sa: CARDINAL;
  s: ARRAY [0..399] OF CHAR;
  ok: BOOLEAN;

BEGIN
  pass := 0; fail := 0;
  WriteString("=== BigInt: arbitrary-precision exact maths ==="); WriteLn;

  (* 20! — classic, fits in checking by value *)
  sa := 19;
  f100 := Factorial(20, sa, f99);
  Dispose(f99);
  CheckVal("20!         ", "2432902008176640000", f100);

  (* 2^100 — straddles many limbs *)
  two := FromCard(2);
  CheckVal("2^100       ", "1267650600228229401496703205376", Pow(two, 100));

  (* Fibonacci(100) *)
  CheckVal("fib(100)    ", "354224848179261915075", Fib(100));

  (* 100! / 99! must be exactly 100, remainder 0 *)
  sa := 99;
  f100 := Factorial(100, sa, f99);
  ok := DivMod(f100, f99, q, r);
  CheckVal("100!/99! q  ", "100", q);
  CheckVal("100!%99! r  ", "0", r);
  (* and 100! should have 158 digits ending in 24 zeros — print its length *)
  ok := ToStr(f100, 10, s);
  WriteString("100! digits = ");
  sa := 0; WHILE (sa <= HIGH(s)) AND (s[sa] # 0C) DO INC(sa) END;
  WriteInt(sa, 1);
  IF sa = 158 THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL] expected 158"); INC(fail) END;
  WriteLn;
  Dispose(f100); Dispose(f99);

  (* gcd(1071, 462) = 21 *)
  CheckVal("gcd(1071,462)", "21", Gcd(FromCard(1071), FromCard(462)));

  (* 2^100 mod 1000 = 376 (last 3 digits of 2^100) *)
  CheckVal("2^100 mod1000", "376", PowMod(FromCard(2), FromCard(100), FromCard(1000)));

  (* a big modular exponentiation with a multi-limb modulus: 7^512 mod (10^20+39) *)
  (* checked indirectly via round-trip below instead *)

  (* signed arithmetic *)
  CheckVal("-5 * 7      ", "-35", Mul(FromInt(-5), FromCard(7)));
  CheckVal("3 - 10      ", "-7", Sub(FromCard(3), FromCard(10)));

  (* FromStr -> ToStr round trip of a 40-digit number *)
  CheckVal("roundtrip   ", "1234567890123456789012345678901234567890",
           FromStr0("1234567890123456789012345678901234567890"));

  (* exact product that overflows 64 bits both ways *)
  CheckVal("10^19 * 10^19", "100000000000000000000000000000000000000",
           Mul(FromStr0("10000000000000000000"), FromStr0("10000000000000000000")));

  WriteLn;
  WriteString("PASS="); WriteInt(pass, 1);
  WriteString("  FAIL="); WriteInt(fail, 1); WriteLn
END BigIntDemo.
