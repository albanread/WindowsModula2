MODULE T90233WinrtDispatchArgs;
(*
 * Group 90 — M2WINRT: the complete late-bound COM Automation client.
 * Drives a live Scripting.Dictionary through the general VARIANT API: methods
 * with MULTIPLE mixed-type arguments (Add(string, int)), a property-get
 * (Count), a parameterized property (Item(string) -> int), and boolean results
 * (Exists(string)). Builds args with V*, reads results with As*, releases with
 * Clear. This proves M2 can call arbitrary Automation members with arbitrary
 * arguments and result types.
 *
 * EXPECTED:
 * create: Y
 * count: 2
 * item foo: 42
 * exists foo: Y
 * exists zzz: N
 *)
FROM SYSTEM IMPORT ADDRESS;
FROM Com IMPORT Initialize, Uninitialize, CreateInstance;
FROM Guid IMPORT FromString, FromProgID;
FROM Dispatch IMPORT Variant, VInt, VStr, AsInt, AsBool, Clear, Invoke,
  GetIntProp, DISPATCH_METHOD, DISPATCH_PROPERTYGET;
FROM NumberIO IMPORT WriteInt;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR clsid, iidDisp: ARRAY [0..15] OF BYTE; dict: ADDRESS; ok: BOOLEAN;
    a: ARRAY [0..1] OF Variant; res: Variant; n: INTEGER;
BEGIN
  ok := Initialize();
  ok := FromProgID("Scripting.Dictionary", clsid);
  ok := FromString("{00020400-0000-0000-C000-000000000046}", iidDisp);
  ok := CreateInstance(ADR(clsid), ADR(iidDisp), dict);
  WriteString("create: "); YN(ok); WriteLn;

  a[0] := VStr("foo"); a[1] := VInt(42);
  ok := Invoke(dict, "Add", DISPATCH_METHOD, a, 2, res); Clear(a[0]); Clear(a[1]); Clear(res);
  a[0] := VStr("bar"); a[1] := VInt(99);
  ok := Invoke(dict, "Add", DISPATCH_METHOD, a, 2, res); Clear(a[0]); Clear(a[1]); Clear(res);

  ok := GetIntProp(dict, "Count", n); WriteString("count: "); WriteInt(n, 1); WriteLn;

  a[0] := VStr("foo"); ok := Invoke(dict, "Item", DISPATCH_PROPERTYGET, a, 1, res);
  WriteString("item foo: "); WriteInt(AsInt(res), 1); WriteLn; Clear(a[0]); Clear(res);

  a[0] := VStr("foo"); ok := Invoke(dict, "Exists", DISPATCH_METHOD, a, 1, res);
  WriteString("exists foo: "); YN(AsBool(res)); WriteLn; Clear(a[0]); Clear(res);
  a[0] := VStr("zzz"); ok := Invoke(dict, "Exists", DISPATCH_METHOD, a, 1, res);
  WriteString("exists zzz: "); YN(AsBool(res)); WriteLn; Clear(a[0]); Clear(res);
  Uninitialize()
END T90233WinrtDispatchArgs.
