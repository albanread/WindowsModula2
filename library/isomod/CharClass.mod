(* Copyright (c) xTech 1993,95. All Rights Reserved. *)
(* Ported to NewM2 2026-06-07 from XDS 2.60 lib/src/isomod. Apache-2.0.
   Integration notes:
     - Removed the USE_CLIBS conditional-compilation branches and the
       associated `IMPORT SYSTEM, xPOSIX` plus `<*+ M2EXTENSIONS *>`
       pragma. Kept the portable ASCII-range classification branch.
     - CHAR is the Windows-wide (UTF-16) code unit in NewM2, but the
       ISO classification here is defined over the ASCII range, so the
       plain range tests are retained verbatim.
*)
IMPLEMENTATION MODULE CharClass;

(* Modifications:
   22-Mar-94 Ned: merging implementations (XDS upstream)
   2026-06-07: drop USE_CLIBS/xPOSIX branches; keep ASCII logic (NewM2 port).
*)

CONST TAB = 11C;

PROCEDURE IsNumeric(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch>='0') & (ch<='9');
END IsNumeric;

PROCEDURE IsLetter(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch>='a') & (ch<='z') OR (ch>='A') & (ch<='Z')
END IsLetter;

PROCEDURE IsUpper(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch>='A') & (ch<='Z')
END IsUpper;

PROCEDURE IsLower(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch>='a') & (ch<='z')
END IsLower;

PROCEDURE IsControl(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ORD(ch) MOD 200B)<=37B
END IsControl;

PROCEDURE IsWhiteSpace(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch=' ') OR (ch=TAB);
END IsWhiteSpace;

END CharClass.
