(*
Name:     Moniker
Creation: 18-02-1999
LastEdit: 22-02-2000
Author:   Egbert J. van der Haring
System:   StonyBrook Modula-2
Remarks:  encapsulates monikers, so we can use ARRAY OF CHARs.
*)

UNSAFEGUARDED IMPLEMENTATION MODULE Moniker;

IMPORT SYSTEM;
IMPORT WINERROR;
IMPORT Ole2;
%IF %NOT UNICODE %THEN
  IMPORT WINX;
  IMPORT WINNLS;

  TYPE szuFILE= ARRAY [0..260] OF UCHAR;
%END



(* creates a file moniker *)
PROCEDURE CreateFile(    szFile:   ARRAY OF CHAR;
                     VAR iMoniker: Ole2.IMoniker): BOOLEAN;
%IF UNICODE %THEN
  BEGIN
    RETURN WINERROR.SUCCEEDED(Ole2.CreateFileMoniker(szFile,iMoniker));
  END CreateFile;
%ELSE
  VAR szuFile: szuFILE;

  BEGIN
    SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szFile,-1,szuFile,HIGH(szuFile));
    RETURN WINERROR.SUCCEEDED(Ole2.CreateFileMoniker(szuFile,iMoniker));
  END CreateFile;
%END


(* creates an item moniker *)
PROCEDURE CreateItem(    szItem:   ARRAY OF CHAR;
                     VAR iMoniker: Ole2.IMoniker): BOOLEAN;
%IF UNICODE %THEN
  BEGIN
    RETURN WINERROR.SUCCEEDED(Ole2.CreateItemMoniker('!',szItem,iMoniker));
  END CreateItem;
%ELSE
  VAR szuItem: szuFILE;

  BEGIN
    SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szItem,-1,szuItem,HIGH(szuItem));
    RETURN WINERROR.SUCCEEDED(Ole2.CreateItemMoniker('!',szuItem,iMoniker));
  END CreateItem;
%END


(* returns monikers display name *)
PROCEDURE GetDisplayName(    iMoniker: Ole2.IMoniker;
                         VAR szName:   ARRAY OF CHAR): BOOLEAN;

VAR iBindCtx: Ole2.IBindCtx;
    pszuName: Ole2.LPOLESTR;
    bValid:   BOOLEAN;

BEGIN
  bValid:=FALSE;
  IF WINERROR.SUCCEEDED(Ole2.CreateBindCtx(0,iBindCtx)) THEN
      IF WINERROR.SUCCEEDED(iMoniker.GetDisplayName(iBindCtx,EMPTY,pszuName)) THEN
        %IF UNICODE %THEN
          szName:=pszuName^;
        %ELSE
          SYSTEM.FUNC WINNLS.WideCharToMultiByte(WINNLS.CP_ACP,WINNLS.WC_COMPOSITECHECK,pszuName^,-1,szName,HIGH(szName),WINX.NIL_STR,WINX.NIL_BOOL);
        %END
        Ole2.CoTaskMemFree(pszuName);
        bValid:=TRUE;
      END; (* if *)
    SYSTEM.FUNC iBindCtx.Release();
  END; (* if *)
  RETURN bValid;
END GetDisplayName;


(* creates a moniker for szFile and *)
(* registers the file as running *)
PROCEDURE RegisterAsRunning(    szFile:      ARRAY OF CHAR;
                                iUnknown:    Ole2.IUnknown;
                            VAR iMoniker:    Ole2.IMoniker;
                            VAR cRegistered: CARDINAL): BOOLEAN;

VAR iROT:   Ole2.IRunningObjectTable;
    bValid: BOOLEAN;

BEGIN
  bValid:=FALSE;
  IF CreateFile(szFile,iMoniker) THEN
    IF WINERROR.SUCCEEDED(Ole2.GetRunningObjectTable(0,iROT)) THEN
      bValid:=WINERROR.SUCCEEDED(iROT.Register(0,iUnknown,iMoniker,cRegistered));
      SYSTEM.FUNC iROT.Release();
    ELSE
      SYSTEM.FUNC iMoniker.Release();
      iMoniker:=EMPTY;
    END; (* if *)
  ELSE
    iMoniker:=EMPTY;
  END; (* if *)
  RETURN bValid;
END RegisterAsRunning;


(* revokes registered object and releases moniker *)
(* NB: iMoniker may be EMPTY, in which case nothing happens *)
PROCEDURE Revoke(VAR INOUT iMoniker:    Ole2.IMoniker;
                 VAR INOUT cRegistered: CARDINAL);

VAR iROT:   Ole2.IRunningObjectTable;
    bValid: BOOLEAN;

BEGIN
  IF (iMoniker<>EMPTY) THEN
    IF WINERROR.SUCCEEDED(Ole2.GetRunningObjectTable(0,iROT)) THEN
      bValid:=WINERROR.SUCCEEDED(iROT.Revoke(cRegistered));
      SYSTEM.FUNC iROT.Release();
      cRegistered:=0;
    END; (* if *)
    SYSTEM.FUNC iMoniker.Release();
    iMoniker:=EMPTY;
  END; (* if *)
END Revoke;



END Moniker.
