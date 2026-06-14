(*
Name:     ClassFactory
Creation: 01-02-1999
LastEdit: 08-03-2000
Author:   Egbert J. van der Haring
System:   StonyBrook Modula-2
Remarks:  Implements a basic class factory.
*)

UNSAFEGUARDED IMPLEMENTATION MODULE ClassFactory;

FROM Storage IMPORT DEALLOCATE;
IMPORT SYSTEM;
IMPORT WIN32;
IMPORT WINERROR;
IMPORT Ole2;
IMPORT OleC;

<*/PUSH*>
<*/NOPACK*>
<*/ALIGN:8*>
<*/NOHIGH*>
<*/CALLS:WIN32SYSTEM*>
CLASS C;

  OVERRIDE PROCEDURE QueryInterface(    iid:       WIN32.IID;
                                    VAR interface: Ole2.IUnknown): WIN32.HRESULT;

  VAR hresult: WIN32.HRESULT;

  BEGIN
    IF Ole2.IsEqualGUID(iid,Ole2.IID_IUnknown)
    OR Ole2.IsEqualGUID(iid,Ole2.IID_IClassFactory) THEN
      interface:=SELF;
      SYSTEM.FUNC interface.AddRef();
      hresult:=WINERROR.S_OK;
    ELSE
      hresult:=SYSTEM.CAST(WIN32.HRESULT,WINERROR.E_NOINTERFACE);
      interface:=EMPTY;
    END; (* if *)
    RETURN hresult;
  END QueryInterface;

  OVERRIDE PROCEDURE AddRef(): WIN32.ULONG;
  BEGIN
    IF (nRef=0) THEN
      Lock;
    END; (* if *)
    RETURN WIN32.InterlockedIncrement(nRef);
  END AddRef;


  OVERRIDE PROCEDURE Release(): WIN32.ULONG;

  VAR nLocal: INTEGER;
      this:   Ole2.IClassFactory;

  BEGIN
    nLocal:=WIN32.InterlockedDecrement(nRef);
    IF (nRef=0) THEN
      UnLock;
      this:=SELF;
      DESTROY(this);
    END; (* if *)
    RETURN nLocal;
  END Release;


  OVERRIDE PROCEDURE LockServer(bLock: WIN32.BOOL): WIN32.HRESULT;
  BEGIN
    IF bLock THEN
      Lock;
    ELSE
      UnLock;
    END; (* if *)
    RETURN WINERROR.S_OK;
  END LockServer;

  VAR nRef: INTEGER;

BEGIN
  nRef:=0;
END C;


CLASS C2;

  OVERRIDE PROCEDURE QueryInterface(    iid:       WIN32.IID;
                                    VAR interface: Ole2.IUnknown): WIN32.HRESULT;

  VAR hresult: WIN32.HRESULT;

  BEGIN
    IF Ole2.IsEqualGUID(iid,Ole2.IID_IUnknown)
    OR Ole2.IsEqualGUID(iid,Ole2.IID_IClassFactory)
    OR Ole2.IsEqualGUID(iid,OleC.IID_IClassFactory2) THEN
      interface:=SELF;
      SYSTEM.FUNC interface.AddRef();
      hresult:=WINERROR.S_OK;
    ELSE
      hresult:=SYSTEM.CAST(WIN32.HRESULT,WINERROR.E_NOINTERFACE);
      interface:=EMPTY;
    END; (* if *)
    RETURN hresult;
  END QueryInterface;


  OVERRIDE PROCEDURE AddRef(): WIN32.ULONG;
  BEGIN
    IF (nRef=0) THEN
      Lock;
    END; (* if *)
    RETURN WIN32.InterlockedIncrement(nRef);
  END AddRef;


  OVERRIDE PROCEDURE Release(): WIN32.ULONG;

  VAR nLocal: INTEGER;
      this:   Ole2.IClassFactory;

  BEGIN
    nLocal:=WIN32.InterlockedDecrement(nRef);
    IF (nRef=0) THEN
      UnLock;
      this:=SELF;
      DESTROY(this);
    END; (* if *)
    RETURN nLocal;
  END Release;


  OVERRIDE PROCEDURE LockServer(bLock: WIN32.BOOL): WIN32.HRESULT;
  BEGIN
    IF bLock THEN
      Lock;
    ELSE
      UnLock;
    END; (* if *)
    RETURN WINERROR.S_OK;
  END LockServer;

  VAR nRef: INTEGER;

BEGIN
  nRef:=0;
END C2;
<*/POP*>


VAR nObjects: INTEGER;

(* locks server *)
PROCEDURE Lock;
BEGIN
  SYSTEM.FUNC WIN32.InterlockedIncrement(nObjects);
END Lock;


(* unlocks server *)
PROCEDURE UnLock;
BEGIN
  SYSTEM.FUNC WIN32.InterlockedDecrement(nObjects);
END UnLock;


(* returns S_OK, when server can be unloaded *)
PROCEDURE CanUnload(): WIN32.HRESULT;

VAR hresult: WIN32.HRESULT;

BEGIN
  IF (nObjects=0) THEN
    hresult:=WINERROR.S_OK;
  ELSE
    hresult:=WINERROR.S_FALSE;
  END; (* if *)
  RETURN hresult;
END CanUnload;



BEGIN
  nObjects:=0;
END ClassFactory.
