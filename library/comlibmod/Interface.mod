(*
Name:     Interface
Creation: 19-02-1999
LastEdit: 22-02-2000
Author:   Egbert J. van der Haring
System:   StonyBrook Modula-2
Remarks:
*)

IMPLEMENTATION MODULE Interface;

IMPORT SYSTEM;
IMPORT WINX;
IMPORT WIN32;
IMPORT WINREG;
IMPORT WINERROR;
IMPORT Ole2;
IMPORT Strings;
%IF %NOT UNICODE %THEN
  IMPORT WINNLS;
%END


(* converts iid to text *)
PROCEDURE ToText(    iid:   WIN32.IID;
                 VAR szIID: ARRAY OF CHAR);

VAR pszuIID: Ole2.LPOLESTR;

BEGIN
  IF WINERROR.SUCCEEDED(Ole2.StringFromIID(iid,pszuIID)) THEN
    %IF UNICODE %THEN
      Strings.Assign(pszuIID^,szIID);
    %ELSE
      SYSTEM.FUNC WINNLS.WideCharToMultiByte(WINNLS.CP_ACP,WINNLS.WC_COMPOSITECHECK,pszuIID^,-1,szIID,HIGH(szIID),WINX.NIL_STR,WINX.NIL_BOOL);
    %END
    Ole2.CoTaskMemFree(pszuIID);
  END; (* if *)
END ToText;


(* finds interface in Registry and returns its name *)
PROCEDURE Find(    iid:    WIN32.IID;
               VAR szName: ARRAY OF CHAR): BOOLEAN;

VAR hkey:   WINREG.HKEY;
    szIID:  ARRAY [0..40] OF CHAR;
    szKey:  ARRAY [0..80] OF CHAR;
    cCount: CARDINAL;
    cType:  CARDINAL;
    bValid: BOOLEAN;

BEGIN
  bValid:=FALSE;
  ToText(iid,szIID);
  Strings.Concat('Interface\',szIID,szKey);
  IF (WINREG.RegOpenKey(WINREG.HKEY_CLASSES_ROOT,szKey,hkey)=WINERROR.ERROR_SUCCESS) THEN
    cCount:=HIGH(szName)+1;
    bValid:=(WINREG.RegQueryValueEx(hkey,'',WINX.NIL_DWORD,cType,szName,cCount)=WINERROR.ERROR_SUCCESS);
    SYSTEM.FUNC WINREG.RegCloseKey(hkey);
  END; (* if *)
  RETURN bValid;
END Find;



END Interface.
