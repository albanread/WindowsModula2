(*
Name:     QueryInterface Table
Creation: 01-02-99
LastEdit: 06-05-99
Author:   Egbert J. van der Haring
System:   StonyBrook Modula-2
Remarks:
*)

UNSAFEGUARDED IMPLEMENTATION MODULE QITable;

FROM Storage IMPORT ALLOCATE, DEALLOCATE;
IMPORT WIN32;
IMPORT Ole2;
%IF CHECKING %THEN
  IMPORT SYSTEM;
  IMPORT WINUSER;
%END

TYPE T=         POINTER TO TABLE;
     INTERFACE= RECORD
                  iid:       WIN32.GUID;
                  pIUnknown: Ole2.PIUnknown;
                END; (* record *)
     TABLE=     RECORD
                  iUnknown:    Ole2.IUnknown;
                  cInterfaces: CARDINAL;
                  interface:   ARRAY [0..0] OF INTERFACE;
                END; (* record *)


(* creates table *)
PROCEDURE Create(iUnknown:    Ole2.IUnknown;
                 cInterfaces: CARDINAL): T;

VAR table: T;

BEGIN
  ALLOCATE(table,SIZE(TABLE)+cInterfaces*SIZE(INTERFACE));
  table^.cInterfaces:=cInterfaces;
  table^.iUnknown:=iUnknown;
  RETURN table;
END Create;


(* disposes of table *)
PROCEDURE Dispose(VAR INOUT table: T);

VAR cInterface: CARDINAL;

BEGIN
  cInterface:=0;
  WHILE (cInterface<table^.cInterfaces) DO
    IF (table^.interface[cInterface].pIUnknown^<>EMPTY) THEN
      DESTROY(table^.interface[cInterface].pIUnknown^);
    END; (* if *)
    INC(cInterface);
  END; (* while *)
  DEALLOCATE(table,SIZE(TABLE)+table^.cInterfaces*SIZE(INTERFACE));
  table:=NIL;
END Dispose;


(* adds interface to table *)
PROCEDURE Add(table:      T;
              cInterface: CARDINAL;
              iid:        WIN32.GUID;
              pIUnknown:  Ole2.PIUnknown);
BEGIN
  %IF CHECKING %THEN
    IF (cInterface>=table^.cInterfaces) THEN
      SYSTEM.FUNC WINUSER.MessageBox(NIL,"QITable overflow!!!","QITable",WINUSER.MB_OK+WINUSER.MB_ICONEXCLAMATION);
    END; (* if *)
  %END
  <*/PUSH/NOCHECK:I*>
  table^.interface[cInterface].iid:=iid;
  table^.interface[cInterface].pIUnknown:=pIUnknown;
  <*/POP*>
END Add;


(* finds interface *)
PROCEDURE Find(    table:      T;
                   iid:        WIN32.GUID;
               VAR cInterface: CARDINAL;
               VAR iUnknown:   Ole2.IUnknown): BOOLEAN;

VAR bFound: BOOLEAN;

BEGIN
  IF Ole2.IsEqualGUID(iid,Ole2.IID_IUnknown) THEN
    iUnknown:=table^.iUnknown;
    bFound:=TRUE;
  ELSE
    bFound:=FALSE;
    iUnknown:=EMPTY;
    cInterface:=0;
    REPEAT
      <*/PUSH/NOCHECK:I*>
      IF Ole2.IsEqualGUID(iid,table^.interface[cInterface].iid) THEN
        iUnknown:=table^.interface[cInterface].pIUnknown^;
        bFound:=TRUE;
      ELSE
        INC(cInterface);
      END; (* if *)
      <*/POP*>
    UNTIL bFound OR (cInterface>=table^.cInterfaces);
  END; (* if *)
  RETURN bFound;
END Find;



END QITable.
