IMPLEMENTATION MODULE Dispatch;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM System_Com IMPORT DISPPARAMS;
FROM System_Variant IMPORT VariantClear;
FROM Foundation IMPORT SysAllocString, BSTR;

CONST
  NUL     = CHR(0);
  MaxArgs = 16;

TYPE
  PChar = POINTER TO CHAR;
  WPtr  = POINTER TO ARRAY [0 .. MAX(CARDINAL) - 1] OF CHAR;

(* The IDispatch vtable is fixed and standard, so one ABSTRACT CLASS — the three
   IUnknown methods then the four IDispatch methods, in order — consumes any
   Automation object. Only the two methods we call carry real signatures. *)
ABSTRACT CLASS IDispatch;
  ABSTRACT PROCEDURE QueryInterface() : INTEGER;            (* slot 0 *)
  ABSTRACT PROCEDURE AddRef() : INTEGER;                    (* slot 1 *)
  ABSTRACT PROCEDURE Release() : INTEGER;                   (* slot 2 *)
  ABSTRACT PROCEDURE GetTypeInfoCount() : INTEGER;          (* slot 3 *)
  ABSTRACT PROCEDURE GetTypeInfo() : INTEGER;               (* slot 4 *)
  ABSTRACT PROCEDURE GetIDsOfNames(riid, names: ADDRESS;
                                   cNames, lcid: CARDINAL; dispid: ADDRESS) : INTEGER;   (* slot 5 *)
  ABSTRACT PROCEDURE Invoke(dispid: INTEGER; riid: ADDRESS; lcid, flags: CARDINAL;
                            params, result, excep, argErr: ADDRESS) : INTEGER;           (* slot 6 *)
END IDispatch;

VAR iidNull: ARRAY [0 .. 15] OF BYTE;   (* IID_NULL, zeroed once at load *)

PROCEDURE Succeeded (hr: INTEGER): BOOLEAN;
  (* A virtual COM method returns the 32-bit HRESULT in EAX, which zeros the
     upper 32 bits of RAX — so a negative HRESULT read as a 64-bit INTEGER looks
     positive. Test the HRESULT severity bit (31) instead of the 64-bit sign. *)
BEGIN
  RETURN (hr BAND 80000000H) = 0
END Succeeded;

(* ---- VARIANT construction ---- *)

PROCEDURE VEmpty (): Variant;
  VAR v: Variant;
BEGIN v.lo := VT_EMPTY; v.val := 0; v.hi := 0; RETURN v END VEmpty;

PROCEDURE VInt (n: INTEGER): Variant;
  VAR v: Variant;
BEGIN
  v.lo := VT_I4; v.val := CAST(CARDINAL, n) BAND 0FFFFFFFFH; v.hi := 0; RETURN v
END VInt;

PROCEDURE VBool (b: BOOLEAN): Variant;
  VAR v: Variant;
BEGIN
  v.lo := VT_BOOL; IF b THEN v.val := 0FFFFH ELSE v.val := 0 END; v.hi := 0; RETURN v
END VBool;

PROCEDURE VStr (s: ARRAY OF CHAR): Variant;
  VAR v: Variant; b: BSTR;
BEGIN
  b := SysAllocString(ADR(s));
  v.lo := VT_BSTR; v.val := CAST(CARDINAL, b.Value); v.hi := 0; RETURN v
END VStr;

(* ---- VARIANT inspection ---- *)

PROCEDURE VType (VAR v: Variant): CARDINAL;
BEGIN RETURN v.lo BAND 0FFFFH END VType;

PROCEDURE AsInt (VAR v: Variant): INTEGER;
  VAR u: CARDINAL;
BEGIN
  u := v.val BAND 0FFFFFFFFH;
  IF u >= 80000000H THEN RETURN VAL(INTEGER, u) - 4294967296 ELSE RETURN VAL(INTEGER, u) END
END AsInt;

PROCEDURE AsBool (VAR v: Variant): BOOLEAN;
BEGIN RETURN (v.val BAND 0FFFFH) # 0 END AsBool;

PROCEDURE AsStr (VAR v: Variant; VAR s: ARRAY OF CHAR);
  VAR p: WPtr; i, cap: CARDINAL;
BEGIN
  s[0] := NUL;
  IF v.val = 0 THEN RETURN END;
  p := CAST(WPtr, v.val);
  cap := HIGH(s) + 1; i := 0;
  WHILE (i + 1 < cap) AND (p^[i] # NUL) DO s[i] := p^[i]; INC(i) END;
  s[i] := NUL
END AsStr;

PROCEDURE AsObj (VAR v: Variant): ADDRESS;
BEGIN RETURN CAST(ADDRESS, v.val) END AsObj;

PROCEDURE Clear (VAR v: Variant);
  VAR rc: INTEGER;
BEGIN
  rc := VariantClear(ADR(v))   (* frees a BSTR / releases an object, sets VT_EMPTY *)
END Clear;

(* ---- name resolution + the universal call ---- *)

PROCEDURE GetID (obj: ADDRESS; name: ARRAY OF CHAR; VAR dispid: INTEGER): BOOLEAN;
  VAR disp: IDispatch; names: ARRAY [0 .. 0] OF ADDRESS; hr: INTEGER;
BEGIN
  disp := obj;
  names[0] := ADR(name);
  dispid := 0;
  hr := disp.GetIDsOfNames(ADR(iidNull), ADR(names), 1, 0, ADR(dispid));
  RETURN Succeeded(hr)
END GetID;

PROCEDURE Invoke (obj: ADDRESS; name: ARRAY OF CHAR; flags: CARDINAL;
                  args: ARRAY OF Variant; nargs: CARDINAL; VAR result: Variant): BOOLEAN;
  VAR disp: IDispatch; dp: DISPPARAMS; rev: ARRAY [0 .. MaxArgs - 1] OF Variant;
      dispid, hr: INTEGER; i: CARDINAL;
BEGIN
  result := VEmpty();
  IF nargs > MaxArgs THEN RETURN FALSE END;
  IF NOT GetID(obj, name, dispid) THEN RETURN FALSE END;
  disp := obj;
  (* COM expects the argument VARIANTs in reverse order (last first) *)
  i := 0;
  WHILE i < nargs DO rev[i] := args[nargs - 1 - i]; INC(i) END;
  IF nargs > 0 THEN dp.rgvarg := ADR(rev) ELSE dp.rgvarg := NIL END;
  dp.rgdispidNamedArgs := NIL; dp.cArgs := VAL(DWORD, nargs); dp.cNamedArgs := 0;
  hr := disp.Invoke(dispid, ADR(iidNull), 0, flags, ADR(dp), ADR(result), NIL, NIL);
  RETURN Succeeded(hr)
END Invoke;

(* ---- convenience ---- *)

PROCEDURE GetIntProp (obj: ADDRESS; name: ARRAY OF CHAR; VAR value: INTEGER): BOOLEAN;
  VAR none: ARRAY [0 .. 0] OF Variant; res: Variant; ok: BOOLEAN;
BEGIN
  value := 0;
  IF NOT Invoke(obj, name, DISPATCH_PROPERTYGET, none, 0, res) THEN RETURN FALSE END;
  ok := VType(res) = VT_I4;
  IF ok THEN value := AsInt(res) END;
  Clear(res);
  RETURN ok
END GetIntProp;

PROCEDURE InvokeStr1 (obj: ADDRESS; name, arg: ARRAY OF CHAR; VAR result: ARRAY OF CHAR): BOOLEAN;
  VAR args: ARRAY [0 .. 0] OF Variant; res: Variant; ok: BOOLEAN;
BEGIN
  result[0] := NUL;
  args[0] := VStr(arg);
  ok := Invoke(obj, name, DISPATCH_METHOD, args, 1, res) AND (VType(res) = VT_BSTR);
  IF ok THEN AsStr(res, result) END;
  Clear(args[0]); Clear(res);
  RETURN ok
END InvokeStr1;

VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO 15 DO iidNull[i] := VAL(BYTE, 0) END
END Dispatch.
