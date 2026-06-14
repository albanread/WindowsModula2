(*
Name:     OleException
Creation: 29-02-2000
LastEdit: 15-05-2000
Author:   Egbert J. van der Haring
System:   StonyBrook Modula-2
Remarks:
*)

IMPLEMENTATION MODULE OleException;

IMPORT SYSTEM;
IMPORT WIN32;
IMPORT WINUSER;
IMPORT ASCII;
IMPORT Conversions;
IMPORT Ole2;
IMPORT Strings;
IMPORT Bstr;


(* shows exception *)
PROCEDURE Show(exinfo: Ole2.EXCEPINFO);

VAR szSource: ARRAY [0..20] OF CHAR;
    szText:   ARRAY [0..320] OF CHAR;
    szHelp:   ARRAY [0..80] OF CHAR;

BEGIN
  IF (exinfo.bstrDescription=NIL) THEN
    IF NOT Conversions.CardBaseToStr(exinfo.wCode,16,szSource) THEN
      szSource:='?';
    END; (* if *)
    Strings.Concat('Object raised an exception, wCode = ',szSource,szText);
    IF NOT Conversions.CardBaseToStr(SYSTEM.CAST(CARDINAL,exinfo.scode),16,szSource) THEN
      szSource:='?';
    END; (* if *)
    Strings.Append(', scode = ',szText);
    Strings.Append(szSource,szText);
  ELSE
    Bstr.ToASCII(exinfo.bstrDescription,szText);
    Bstr.ToASCII(exinfo.bstrHelpFile,szHelp);
    IF (szHelp[0]<>0C) THEN
      Strings.Append(ASCII.cr,szText);
      Strings.Append(ASCII.lf,szText);
      Strings.Append('See ',szText);
      Strings.Append(szHelp,szText);
      Strings.Append(' for more info.',szText);
    END; (* if *)
  END; (* if *)
  Bstr.ToASCII(exinfo.bstrSource,szSource);
  SYSTEM.FUNC WINUSER.MessageBox(NIL,szText,szSource,WINUSER.MB_OK+WINUSER.MB_ICONEXCLAMATION);
END Show;


(* shows hresult, which was not S_OK but although there was no exception *)
PROCEDURE ShowResult(hresult: WIN32.HRESULT);

VAR szText: ARRAY [0..200] OF CHAR;

BEGIN
  GetText(hresult,szText);
  SYSTEM.FUNC WINUSER.MessageBox(NIL,szText,'',WINUSER.MB_OK+WINUSER.MB_ICONEXCLAMATION);
END ShowResult;


(* returns text for exception *)
PROCEDURE GetText(    hresult: WIN32.HRESULT;
                  VAR szText:  ARRAY OF CHAR);

VAR szNumber: ARRAY [0..20] OF CHAR;

BEGIN
  IF (WIN32.FormatMessage(WIN32.FORMAT_MESSAGE_FROM_SYSTEM
                      +WIN32.FORMAT_MESSAGE_IGNORE_INSERTS,NIL,SYSTEM.CAST(CARDINAL,hresult),
                      WIN32.MAKELANGID(WIN32.LANG_NEUTRAL,WIN32.SUBLANG_DEFAULT),
                      szText,HIGH(szText),NIL)=0) THEN
    szText:='Unknown error';
  END; (* if *)
  SYSTEM.FUNC Conversions.CardBaseToStr(SYSTEM.CAST(CARDINAL,hresult),16,szNumber);
  Strings.Append(' (',szText);
  Strings.Append(szNumber,szText);
  Strings.Append(').',szText);
END GetText;



END OleException.
