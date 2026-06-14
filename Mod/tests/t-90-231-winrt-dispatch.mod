MODULE T90231WinrtDispatch;
(*
 * Group 90 — M2WINRT: Dispatch, late-bound (IDispatch) COM Automation
 * from M2. Creates a real Automation object by ProgID (Scripting.Dictionary),
 * binds its IDispatch, resolves a member name to a DISPID and invokes it — all
 * hidden behind a by-name API. Reads the empty dictionary's Count property
 * (VT_I4 = 0) and confirms a bogus member name is rejected.
 *
 * EXPECTED:
 * create: Y
 * getid Count: Y
 * Count: 0
 * bad-member: N
 *)
FROM SYSTEM IMPORT ADR;
FROM Com IMPORT Initialize, Uninitialize, CreateInstance;
FROM Guid IMPORT FromString, FromProgID;
FROM Dispatch IMPORT GetID, GetIntProp;
FROM NumberIO IMPORT WriteInt;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR clsid, iidDisp: ARRAY [0..15] OF BYTE; obj: ADDRESS; ok: BOOLEAN; id, count: INTEGER;
BEGIN
  ok := Initialize();
  ok := FromProgID("Scripting.Dictionary", clsid);
  ok := FromString("{00020400-0000-0000-C000-000000000046}", iidDisp);   (* IID_IDispatch *)
  ok := CreateInstance(ADR(clsid), ADR(iidDisp), obj);
  WriteString("create: "); YN(ok); WriteLn;
  WriteString("getid Count: "); YN(GetID(obj, "Count", id)); WriteLn;
  WriteString("Count: ");
  IF GetIntProp(obj, "Count", count) THEN WriteInt(count, 1) ELSE WriteString("?") END; WriteLn;
  WriteString("bad-member: "); YN(GetID(obj, "NoSuchMember", id)); WriteLn;
  Uninitialize()
END T90231WinrtDispatch.
