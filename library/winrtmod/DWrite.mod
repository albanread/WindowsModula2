IMPLEMENTATION MODULE DWrite;

FROM SYSTEM IMPORT ADDRESS, ADR;
FROM Graphics_DirectWrite IMPORT DWriteCreateFactory, IDWriteFactory;
FROM Guid IMPORT FromString;

(* IDWriteFactory is IMPORTed from the winapi-gen-generated
   Graphics_DirectWrite module. Its whole vtable layout — IUnknown at 0/1/2 then
   the methods in IDL order, with CreateTextFormat machine-checked at slot 15 —
   comes from the Windows metadata. The compiler computes each slot and rejects a
   mismatch. *)

VAR gFactory: ADDRESS;

PROCEDURE Startup (): BOOLEAN;
  VAR iid: ARRAY [0..15] OF BYTE; hr: INTEGER32;
BEGIN
  IF gFactory # NIL THEN RETURN TRUE END;   (* idempotent: the shared factory is created once
                                               so instanced text/canvas surfaces don't clobber it
                                               (PaneShell S1/S2 amendment A/N) *)
  IF NOT FromString("{b859ee5a-d838-4b5b-a2e8-1adc7d93db48}", iid) THEN RETURN FALSE END;
  gFactory := NIL;
  hr := DWriteCreateFactory(0, ADR(iid), ADR(gFactory));    (* 0 = SHARED *)
  RETURN SUCCEEDED(hr) AND (gFactory # NIL)
END Startup;

PROCEDURE Ready (): BOOLEAN;
BEGIN RETURN gFactory # NIL END Ready;

PROCEDURE CreateFormat (fontName: ARRAY OF CHAR; size: SHORTREAL): ADDRESS;
  VAR f: IDWriteFactory; fmt: ADDRESS; locale: ARRAY [0..7] OF CHAR; hr: INTEGER;
BEGIN
  IF gFactory = NIL THEN RETURN NIL END;
  f := gFactory;
  fmt := NIL;
  locale := "en-us";
  (* DWRITE_FONT_WEIGHT_NORMAL=400, _STYLE_NORMAL=0, _STRETCH_NORMAL=5; the enum
     args are 32-bit, so pass them as INTEGER32 to match the vtable signature. *)
  hr := f.CreateTextFormat(ADR(fontName), NIL,
                           VAL(INTEGER32, 400), VAL(INTEGER32, 0), VAL(INTEGER32, 5),
                           size, ADR(locale), ADR(fmt));
  IF FAILED(hr) THEN RETURN NIL END;
  RETURN fmt
END CreateFormat;

BEGIN
  gFactory := NIL
END DWrite.
