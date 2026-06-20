MODULE T90268RectSolver;
(*
 * Group 90 — PaneShell S8 (P4 part 1/2): the PaneLayout reactive rect solver.
 * Split + Stack are PaneShell.Layout strategies; Retile delegates to them. A
 * Split(Horizontal, 0.70, minFirst=240, minSecond=160) over a 1000x600 host
 * gives a 70/30 split; its right pane is a vertical Stack of 3 (each 1/3 tall).
 * SetWeight + Retile re-solves with the min-size clamps applied (D1: mutate the
 * held tree, then Retile — no diff). SetHidden makes the Stack redistribute.
 *
 * EXPECTED:
 * a: 0,0,700,600
 * stk: 700,0,300,600
 * c: 700,0,300,200
 * d: 700,200,300,200
 * e: 700,400,300,200
 * a-min: 0,0,240,600
 * a-max: 0,0,840,600
 * stk-max: 840,0,160,600
 * d-hidden: 700,0,300,300
 *)
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, LeafPane, SetRect, RectOf,
  Init, OpenWindow, CloseWindow, Retile;
FROM PaneLayout IMPORT Orientation, Split, NewStack, AddChild, SetWeight, SetHidden;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR ws: Workspace; win: PaneWindow; root, a, stk, c, d, e: Pane;

PROCEDURE On (VAR ev: Event): BOOLEAN; BEGIN RETURN FALSE END On;

PROCEDURE PrintRect (label: ARRAY OF CHAR; p: Pane);
  VAR x, y, w, h: CARDINAL;
BEGIN
  RectOf(p, x, y, w, h);
  WriteString(label);
  WriteCard(x, 1); WriteString(","); WriteCard(y, 1); WriteString(",");
  WriteCard(w, 1); WriteString(","); WriteCard(h, 1); WriteLn
END PrintRect;

BEGIN
  a := LeafPane("a", NewRaster(10, 10));
  c := LeafPane("c", NewRaster(10, 10));
  d := LeafPane("d", NewRaster(10, 10));
  e := LeafPane("e", NewRaster(10, 10));
  stk := NewStack(Vertical, 0); AddChild(stk, c); AddChild(stk, d); AddChild(stk, e);
  root := Split(Horizontal, 0.70, 240, 160, a, stk);
  SetRect(root, 0, 0, 1000, 600);
  win := OpenWindow(ws, "S8", 1000, 600, root, On);

  Retile(win);
  PrintRect("a: ", a);  PrintRect("stk: ", stk);
  PrintRect("c: ", c);  PrintRect("d: ", d);  PrintRect("e: ", e);

  (* min-first clamp: weight 0.05 -> first wants 50, clamped up to minFirst 240 *)
  SetWeight(root, 0.05); Retile(win);
  PrintRect("a-min: ", a);

  (* min-second clamp: weight 0.95 -> second wants 50, clamped up to minSecond 160 *)
  SetWeight(root, 0.95); Retile(win);
  PrintRect("a-max: ", a);  PrintRect("stk-max: ", stk);

  (* hidden: reset weight, hide c -> the Stack divides among d,e (each half) *)
  SetWeight(root, 0.70); SetHidden(c, TRUE); Retile(win);
  PrintRect("d-hidden: ", d);

  CloseWindow(win)
END T90268RectSolver.
