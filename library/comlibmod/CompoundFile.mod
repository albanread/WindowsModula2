(*
Name:     CompoundFile
Creation: 21-01-1999
LastEdit: 24-11-2000
Author:   Egbert J. van der Haring
System:   StonyBrook Modula-2
Remarks:  An interface to structured storage compound files.
*)

UNSAFEGUARDED IMPLEMENTATION MODULE CompoundFile;

IMPORT SYSTEM;
IMPORT WIN32;
IMPORT WINERROR;
IMPORT FileFunc;
IMPORT Ole2;
IMPORT Storage;
IMPORT Strings;
%IF %NOT UNICODE %THEN
  IMPORT WINX;
  IMPORT WINNLS;
%END

TYPE STORAGE= POINTER TO Ole2.IStorage;
     STREAM=  POINTER TO STREAMINFO;
     STREAMINFO= RECORD
                   iStream: Ole2.IStream;
                   bEOS:    BOOLEAN;
                 END; (* record *)
     %IF %NOT UNICODE %THEN
       szuNAME= ARRAY [0..255] OF UCHAR;
     %END


(* creates compound file *)
PROCEDURE Create(    szName:  ARRAY OF CHAR;
                 VAR storage: STORAGE): BOOLEAN;

VAR cMode:   CARDINAL;
    bValid:  BOOLEAN;
    %IF %NOT UNICODE %THEN
      szuName: szuNAME;
    %END

BEGIN
  bValid:=FALSE;
  cMode:=Ole2.STGM_WRITE+Ole2.STGM_SHARE_EXCLUSIVE;
  IF FileFunc.FileExists(szName) THEN
    INC(cMode,Ole2.STGM_CREATE);
  END; (* if *)
  Storage.ALLOCATE(storage,SIZE(Ole2.IStorage));
%IF UNICODE %THEN
  IF WINERROR.SUCCEEDED(Ole2.StgCreateDocfile(szName,cMode,0,storage^)) THEN
%ELSE
  SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szName,-1,szuName,HIGH(szuName));
  IF WINERROR.SUCCEEDED(Ole2.StgCreateDocfile(szuName,cMode,0,storage^)) THEN
%END
    bValid:=TRUE;
  ELSE
    Storage.DEALLOCATE(storage,SIZE(Ole2.IStorage));
    storage:=NIL;
  END; (* if *)
  RETURN bValid;
END Create;


(* uses an already available iStorage *)
PROCEDURE Create2(    iStorage: Ole2.IStorage;
                  VAR storage:  STORAGE);
BEGIN
  Storage.ALLOCATE(storage,SIZE(Ole2.IStorage));
  storage^:=iStorage;
END Create2;


(* opens a compound file *)
PROCEDURE Open(    cMode:   CARDINAL;
                   szName:  ARRAY OF CHAR;
               VAR storage: STORAGE): BOOLEAN;

VAR bValid:  BOOLEAN;
    %IF %NOT UNICODE %THEN
      szuName: szuNAME;
    %END

BEGIN
  bValid:=FALSE;
  TranslateMode(cMode);
  Storage.ALLOCATE(storage,SIZE(Ole2.IStorage));
%IF UNICODE %THEN
  IF WINERROR.SUCCEEDED(Ole2.StgOpenStorage(szName,EMPTY,cMode,NIL,0,storage^)) THEN
%ELSE
  SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szName,-1,szuName,HIGH(szuName));
  IF WINERROR.SUCCEEDED(Ole2.StgOpenStorage(szuName,EMPTY,cMode,NIL,0,storage^)) THEN
%END
    bValid:=TRUE;
  ELSE
    Storage.DEALLOCATE(storage,SIZE(Ole2.IStorage));
    storage:=NIL;
  END; (* if *)
  RETURN bValid;
END Open;


(* closes compound file *)
PROCEDURE Close(VAR INOUT storage: STORAGE);
BEGIN
  IF (storage<>NIL) THEN
    SYSTEM.FUNC storage^.Release();
    Storage.DEALLOCATE(storage,SIZE(Ole2.IStorage));
    storage:=NIL;
  END; (* if *)
END Close;


(* disposes of storage, without releasing iStorage *)
PROCEDURE Dispose(VAR INOUT storage: STORAGE);
BEGIN
  IF (storage<>NIL) THEN
    Storage.DEALLOCATE(storage,SIZE(Ole2.IStorage));
    storage:=NIL;
  END; (* if *)
END Dispose;


(* writes class GUID to storage *)
PROCEDURE WriteClass(storage: STORAGE;
                     guid:    WIN32.GUID);
BEGIN
  SYSTEM.FUNC Ole2.WriteClassStg(storage^,guid);
END WriteClass;


(* writes user type format to storage *)
PROCEDURE WriteFormat(storage:  STORAGE;
                      cfFormat: CARDINAL;
                      szFormat: ARRAY OF CHAR);

%IF %NOT UNICODE %THEN
VAR szuFormat: szuNAME;
%END

BEGIN
  %IF UNICODE %THEN
    SYSTEM.FUNC Ole2.WriteFmtUserTypeStg(storage^,cfFormat,szFormat);
  %ELSE
    SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szFormat,-1,szuFormat,HIGH(szuFormat));
    SYSTEM.FUNC Ole2.WriteFmtUserTypeStg(storage^,cfFormat,szuFormat);
  %END
END WriteFormat;


(* creates a stream in the storage *)
PROCEDURE CreateStream(    storage: STORAGE;
                           szName:  ARRAY OF CHAR;
                       VAR stream:  STREAM): BOOLEAN;

VAR bValid:  BOOLEAN;
    %IF %NOT UNICODE %THEN
      szuName: szuNAME;
    %END

BEGIN
  bValid:=FALSE;
  IF (storage<>NIL) THEN
    Storage.ALLOCATE(stream,SIZE(STREAMINFO));
  %IF UNICODE %THEN
    IF WINERROR.SUCCEEDED(storage^.CreateStream(szName,Ole2.STGM_WRITE+Ole2.STGM_SHARE_EXCLUSIVE,0,0,stream^.iStream)) THEN
  %ELSE
    SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szName,-1,szuName,HIGH(szuName));
    IF WINERROR.SUCCEEDED(storage^.CreateStream(szuName,Ole2.STGM_WRITE+Ole2.STGM_SHARE_EXCLUSIVE,0,0,stream^.iStream)) THEN
  %END
      stream^.bEOS:=FALSE;
      bValid:=TRUE;
    ELSE
      Storage.DEALLOCATE(stream,SIZE(STREAMINFO));
      stream:=NIL;
    END; (* if *)
  END; (* if *)
  RETURN bValid;
END CreateStream;


(* opens a stream in the storage *)
PROCEDURE OpenStream(    storage: STORAGE;
                         cMode:   CARDINAL;
                         szName:  ARRAY OF CHAR;
                     VAR stream:  STREAM): BOOLEAN;

VAR bValid:  BOOLEAN;
    %IF %NOT UNICODE %THEN
      szuName: szuNAME;
    %END

BEGIN
  bValid:=FALSE;
  IF (storage<>NIL) THEN
    TranslateMode(cMode);
    Storage.ALLOCATE(stream,SIZE(STREAMINFO));
  %IF UNICODE %THEN
    IF WINERROR.SUCCEEDED(storage^.OpenStream(szName,NIL,cMode,0,stream^.iStream)) THEN
  %ELSE
    SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szName,-1,szuName,HIGH(szuName));
    IF WINERROR.SUCCEEDED(storage^.OpenStream(szuName,NIL,cMode,0,stream^.iStream)) THEN
  %END
      stream^.bEOS:=FALSE;
      bValid:=TRUE;
    ELSE
      Storage.DEALLOCATE(stream,SIZE(STREAMINFO));
      stream:=NIL;
    END; (* if *)
  END; (* if *)
  RETURN bValid;
END OpenStream;


(* closes stream *)
PROCEDURE CloseStream(VAR INOUT stream: STREAM);
BEGIN
  IF (stream<>NIL) THEN
    SYSTEM.FUNC stream^.iStream.Release();
    Storage.DEALLOCATE(stream,SIZE(STREAMINFO));
    stream:=NIL;
  END; (* if *)
END CloseStream;


(* deletes a stream from the storage *)
PROCEDURE DeleteStream(storage:  STORAGE;
                       szStream: ARRAY OF CHAR): BOOLEAN;

VAR bValid:    BOOLEAN;
    %IF %NOT UNICODE %THEN
      szuStream: szuNAME;
    %END

BEGIN
  bValid:=FALSE;
  IF (storage<>NIL) THEN
    %IF UNICODE %THEN
      bValid:=(storage^.DestroyElement(szStream)=WINERROR.S_OK);
    %ELSE
      SYSTEM.FUNC WINNLS.MultiByteToWideChar(WINNLS.CP_ACP,WINNLS.MB_PRECOMPOSED,szStream,-1,szuStream,HIGH(szuStream));
      bValid:=(storage^.DestroyElement(szuStream)=WINERROR.S_OK);
    %END
  END; (* if *)
  RETURN bValid;
END DeleteStream;


(* returns TRUE if szStream exists in storage *)
PROCEDURE ExistsStream(storage:  STORAGE;
                       szStream: ARRAY OF CHAR): BOOLEAN;

VAR iEnum:     Ole2.IEnumSTATSTG;
    statstg:   Ole2.STATSTG;
    %IF %NOT UNICODE %THEN
      szCheck:   FileFunc.NameString;
    %END
    cFetched:  CARDINAL;
    bFound:    BOOLEAN;

BEGIN
  bFound:=FALSE;
  IF  (storage<>NIL)
  AND (storage^.EnumElements(0,NIL,0,iEnum)=WINERROR.S_OK) THEN
    WHILE (NOT bFound)
    AND   (iEnum.Next(1,statstg,cFetched)=WINERROR.S_OK) DO
      %IF UNICODE %THEN
        bFound:=(Strings.Compare(szStream,statstg.pwcsName^)=Strings.equal);
      %ELSE
        SYSTEM.FUNC WINNLS.WideCharToMultiByte(WINNLS.CP_ACP,WINNLS.WC_COMPOSITECHECK,statstg.pwcsName^,-1,szCheck,HIGH(szCheck),WINX.NIL_STR,WINX.NIL_BOOL);
        bFound:=(Strings.Compare(szStream,szCheck)=Strings.equal);
      %END
    END; (* while *)
    SYSTEM.FUNC iEnum.Release();
  END; (* if *)
  RETURN bFound;
END ExistsStream;


(* enumerates streams in a storage *)
PROCEDURE EnumStreams(storage:  STORAGE;
                      dword:    SYSTEM.DWORD;
                      callback: CALLBACK);

VAR iEnum:     Ole2.IEnumSTATSTG;
    statstg:   Ole2.STATSTG;
    %IF %NOT UNICODE %THEN
      szStream:  FileFunc.NameString;
    %END
    cFetched:  CARDINAL;
    bNext:     BOOLEAN;

BEGIN
  IF  (storage<>NIL)
  AND (storage^.EnumElements(0,NIL,0,iEnum)=WINERROR.S_OK) THEN
    bNext:=TRUE;
    WHILE bNext AND (iEnum.Next(1,statstg,cFetched)=WINERROR.S_OK) DO
      %IF UNICODE %THEN
        bNext:=callback(dword,statstg.pwcsName^);
      %ELSE
        SYSTEM.FUNC WINNLS.WideCharToMultiByte(WINNLS.CP_ACP,WINNLS.WC_COMPOSITECHECK,statstg.pwcsName^,-1,szStream,HIGH(szStream),WINX.NIL_STR,WINX.NIL_BOOL);
        bNext:=callback(dword,szStream);
      %END
    END; (* while *)
    SYSTEM.FUNC iEnum.Release();
  END; (* if *)
END EnumStreams;


(* returns TRUE if end of stream is reached during read *)
PROCEDURE EOS(stream: STREAM): BOOLEAN;
BEGIN
  RETURN stream^.bEOS;
END EOS;


(* translates mode to required Ole2 mode *)
PROCEDURE TranslateMode(VAR INOUT cMode: CARDINAL);
BEGIN
  CASE cMode OF
    cREAD:  cMode:=Ole2.STGM_READ+Ole2.STGM_SHARE_EXCLUSIVE;
  | cWRITE: cMode:=Ole2.STGM_WRITE+Ole2.STGM_SHARE_EXCLUSIVE;
  ELSE (* assume cREADWRITE *)
    cMode:=Ole2.STGM_READWRITE+Ole2.STGM_SHARE_EXCLUSIVE;
  END; (* case *)
END TranslateMode;


(* writes array of bytes to stream *)
PROCEDURE Write(stream: STREAM;
                bytes:  ARRAY OF SYSTEM.BYTE);

VAR cLength:  CARDINAL;
    cWritten: CARDINAL;

BEGIN
  stream^.bEOS:=FALSE;
  cLength:=HIGH(bytes)+1;
  SYSTEM.FUNC stream^.iStream.Write(bytes,cLength,cWritten);
END Write;


(* reads array of bytes from stream *)
PROCEDURE Read(    stream: STREAM;
               VAR bytes:  ARRAY OF SYSTEM.BYTE);

VAR cLength: CARDINAL;
    cRead:   CARDINAL;

BEGIN
  cLength:=HIGH(bytes)+1;
  SYSTEM.FUNC stream^.iStream.Read(bytes,cLength,cRead);
  stream^.bEOS:=(cRead<cLength);
END Read;


(* writes text to stream *)
PROCEDURE WriteText(stream: STREAM;
                    szText: ARRAY OF CHAR);

VAR cLength:  CARDINAL;
    cWritten: CARDINAL;

BEGIN
  stream^.bEOS:=FALSE;
  cLength:=LENGTH(szText);
  IF WINERROR.SUCCEEDED(stream^.iStream.Write(cLength,SIZE(cLength),cWritten)) THEN
    SYSTEM.FUNC stream^.iStream.Write(szText,cLength,cWritten);
  END; (* if *)
END WriteText;


(* reads text from stream *)
PROCEDURE ReadText(    stream: STREAM;
                   VAR szText: ARRAY OF CHAR);

VAR cLength: CARDINAL;
    cRead:   CARDINAL;

BEGIN
  IF WINERROR.SUCCEEDED(stream^.iStream.Read(cLength,SIZE(cLength),cRead)) THEN
    IF (cLength>HIGH(szText)) THEN
      cLength:=HIGH(szText);
    END; (* if *)
    SYSTEM.FUNC stream^.iStream.Read(szText,cLength,cRead);
    stream^.bEOS:=(cRead<cLength);
    szText[cRead]:=0C;
  END; (* if *)
END ReadText;


(* writes cCount bytes from array to stream *)
(* returns actual number of bytes written *)
PROCEDURE WriteBytes(stream: STREAM;
                     bytes:  ARRAY OF SYSTEM.BYTE;
                     cCount: CARDINAL): CARDINAL;

VAR cWritten: CARDINAL;

BEGIN
  IF NOT WINERROR.SUCCEEDED(stream^.iStream.Write(bytes,cCount,cWritten)) THEN
    cWritten:=0;
  END; (* if *)
  RETURN cWritten;
END WriteBytes;


(* reads cCount bytes from stream to array *)
(* returns actual number of bytes read *)
PROCEDURE ReadBytes(    stream:  STREAM;
                    VAR bytes:   ARRAY OF SYSTEM.BYTE;
                        cCount:  CARDINAL): CARDINAL;

VAR cRead: CARDINAL;

BEGIN
  IF NOT WINERROR.SUCCEEDED(stream^.iStream.Read(bytes,cCount,cRead)) THEN
    cRead:=0;
  END; (* if *)
  RETURN cRead;
END ReadBytes;



END CompoundFile.
