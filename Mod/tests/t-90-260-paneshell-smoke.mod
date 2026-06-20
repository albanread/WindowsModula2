MODULE T90260PaneShellSmoke;
(*
 * Group 90 — PaneShell Sprint 0 scaffolding smoke test. Proves the new
 * library/uidef + library/uimod (UI) family exists, compiles, is
 * AUTO-DISCOVERED (zero driver/loader/test registration), and LINKS
 * cross-family to the existing winrt stack (WinShell) — all by importing the
 * four new modules plus WinShell by name and making a live reference to each so
 * no import is dead-code eliminated. Declaring a Surface.Backend var forces the
 * abstract CLASS-as-vtable through codegen, not merely name resolution.
 *
 * EXPECTED:
 * paneshell-scaffolding-ok
 *)
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM StrIO IMPORT WriteString, WriteLn;
IMPORT Surface;
IMPORT PaneShell;
IMPORT PaneLayout;
IMPORT MDIContainer;
IMPORT WinShell;

VAR
  b:   Surface.Backend;            (* the abstract Backend (all five methods) -> codegen *)
  k:   Surface.Kind;
  p:   PaneShell.Pane;
  o:   PaneLayout.Orientation;
  st:  MDIContainer.Style;
  win: WinShell.Window;            (* cross-family winrt type *)
  ap:  ADDRESS;

BEGIN
  b   := NIL;                      (* Surface.Backend *)
  k   := Surface.Canvas;           (* a Surface.Kind enum value *)
  ap  := ADR(p);                   (* ADR of a PaneShell.Pane *)
  o   := PaneLayout.Horizontal;    (* a PaneLayout.Orientation value *)
  st  := MDIContainer.Tabbed;      (* an MDIContainer.Style value *)
  win := NIL;                      (* a WinShell.Window value *)
  WriteString("paneshell-scaffolding-ok"); WriteLn
END T90260PaneShellSmoke.
