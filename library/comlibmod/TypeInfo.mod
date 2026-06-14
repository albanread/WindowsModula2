(*
Name:     TypeInfo
Creation: 23-10-1998
LastEdit: 07-09-2001
Author:   Egbert J. van der Haring
System:   StonyBrook Modula-2
Remarks:  Support for COM type info.
*)

UNSAFEGUARDED IMPLEMENTATION MODULE TypeInfo;

IMPORT SYSTEM;
IMPORT WINX;
IMPORT WIN32;
IMPORT WINERROR;
IMPORT Ole2;
IMPORT FileFunc;
%IF CHECKING %THEN
  IMPORT OleException;
%END
%IF %NOT UNICODE %THEN
  IMPORT WINNLS;
%END


(* loads and registers type library *)
PROCEDURE LoadAndRegister(VAR hresult: WIN32.HRESULT): BOOLEAN;

VAR iTypeLib:  Ole2.ITypeLib;
    szFile:    FileFunc.FileSpecString;
    szHelp:    FileFunc.FileSpecString;
    parts:     FileFunc.FileNameParts;
    %IF %NOT UNICODE %THEN
      szuFile:   ARRAY [0..260] OF Ole2.OLECHAR;
      szuHelp:   ARRAY [0..260] OF Ole2.OLECHAR;
    %END
    bValid:    BOOLEAN;

BEGIN
  bValid:=FALSE;
  IF (WIN32.GetModuleFileName(WINX.Instance,szFile,HIGH(szFile))>0) THEN
    FileFunc.ParseFileName(szFile,parts);
    parts.extension:='';
    parts.name:='';
    FileFunc.AssembleParts(parts,szHelp);
  %IF UNICODE %THEN
    hresult:=Ole2.LoadTypeLib(szFile,iTypeLib);
    IF WINERROR.SUCCEEDED(hresult) THEN
      hresult:=Ole2.RegisterTypeLib(iTypeLib,szFile,szHelp);
  %ELSE
    SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szFile,-1,szuFile,HIGH(szuFile));
    SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szHelp,-1,szuHelp,HIGH(szuHelp));
    hresult:=Ole2.LoadTypeLib(szuFile,iTypeLib);
    IF WINERROR.SUCCEEDED(hresult) THEN
      hresult:=Ole2.RegisterTypeLib(iTypeLib,szuFile,szuHelp);
  %END
      bValid:=(hresult=WINERROR.S_OK);
    END; (* if *)
  END; (* if *)
  RETURN bValid;
END LoadAndRegister;


(* loads type library with version cMajor.cMinor *)
(* and returns type info for interface *)
PROCEDURE Load(    cMajor:       CARDINAL;
                   cMinor:       CARDINAL;
                   guidTypeLib:  WIN32.GUID;
                   iidInterface: WIN32.IID;
               VAR iTypeInfo:    Ole2.ITypeInfo);

VAR hresult:  WIN32.HRESULT;
    iTypeLib: Ole2.ITypeLib;

BEGIN
  hresult:=Ole2.LoadRegTypeLib(guidTypeLib,cMajor,cMinor,0,iTypeLib);
  IF (hresult=WINERROR.S_OK) THEN
    hresult:=iTypeLib.GetTypeInfoOfGuid(iidInterface,iTypeInfo);
    SYSTEM.FUNC iTypeLib.Release;
%IF CHECKING %THEN
    IF (hresult<>WINERROR.S_OK) THEN
      OleException.ShowResult(hresult);
    END; (* if *)
  ELSE
    OleException.ShowResult(hresult);
%END
  END; (* if *)
  IF (hresult<>WINERROR.S_OK) THEN
    iTypeInfo:=EMPTY;
  END; (* if *)
END Load;


(* loads type info from <application>.exe *)
PROCEDURE LoadFromMe(    iidInterface: WIN32.IID;
                     VAR iTypeInfo:    Ole2.ITypeInfo): BOOLEAN;

VAR hresult:  WIN32.HRESULT;
    iTypeLib: Ole2.ITypeLib;
    szFile:   FileFunc.FileSpecString;
    %IF %NOT UNICODE %THEN
      szuFile:   ARRAY [0..260] OF Ole2.OLECHAR;
    %END
    bValid:   BOOLEAN;

BEGIN
  bValid:=FALSE;
  IF (WIN32.GetModuleFileName(WINX.Instance,szFile,HIGH(szFile))>0) THEN
    %IF UNICODE %THEN
      hresult:=Ole2.LoadTypeLib(szFile,iTypeLib);
    %ELSE
      SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szFile,-1,szuFile,HIGH(szuFile));
      hresult:=Ole2.LoadTypeLib(szuFile,iTypeLib);
    %END
    IF WINERROR.SUCCEEDED(hresult) THEN
      hresult:=iTypeLib.GetTypeInfoOfGuid(iidInterface,iTypeInfo);
      bValid:=WINERROR.SUCCEEDED(hresult);
      SYSTEM.FUNC iTypeLib.Release;
    END; (* if *)
  END; (* if *)
  IF NOT bValid THEN
    iTypeInfo:=EMPTY;
  END; (* if *)
  RETURN bValid;
END LoadFromMe;


(* releases type info *)
PROCEDURE Release(iTypeInfo: Ole2.ITypeInfo);
BEGIN
  IF (iTypeInfo<>EMPTY) THEN
    SYSTEM.FUNC iTypeInfo.Release();
  END; (* if *)
END Release;


(* default implementation for IDispatch.AddRef *)
PROCEDURE AddRef(cType:       CARDINAL;
                 tiRequested: Ole2.ITypeInfo;
                 tiInterface: Ole2.ITypeInfo);
BEGIN
  IF  (cType=0)
  AND (tiRequested<>EMPTY)
  AND (tiRequested=tiInterface) THEN
    SYSTEM.FUNC tiInterface.AddRef();
  END; (* if *)
END AddRef;



END TypeInfo.
