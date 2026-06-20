MODULE T90267DChannel;
(*
 * Group 90 — PaneShell S7 (P3) slice 4a: the per-pane channel (§7 data plane).
 * A lock-guarded FIFO ring per Pane (CRITICAL_SECTION-bounded — amendment C, NOT
 * "lock-free"), drained INLINE for now (D2). Submit enqueues, ChannelNext
 * dequeues FIFO, ChannelDepth reports occupancy. SetThreaded is the dark seam:
 * callable, but does NOT change behaviour (drain stays inline) until P8. Per-pane
 * heap state, so robust under the parallel harness.
 *
 * EXPECTED:
 * depth: 3
 * pop1: Y
 * pop2: Y
 * pop3: Y
 * depth0: 0
 * empty: Y
 * threaded-submit: Y
 * threaded-pop: Y
 *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, LeafPane, Submit, ChannelDepth, ChannelNext, SetThreaded;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR p: Pane; b1, b2, b3, got: ADDRESS; ok: BOOLEAN;

PROCEDURE YN (c: BOOLEAN);
BEGIN IF c THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

BEGIN
  p := LeafPane("p", NewRaster(10, 10));
  b1 := CAST(ADDRESS, 101); b2 := CAST(ADDRESS, 102); b3 := CAST(ADDRESS, 103);

  ok := Submit(p, b1); ok := Submit(p, b2); ok := Submit(p, b3);
  WriteString("depth: "); WriteCard(ChannelDepth(p), 1); WriteLn;

  ok := ChannelNext(p, got); WriteString("pop1: "); YN(ok AND (got = b1));
  ok := ChannelNext(p, got); WriteString("pop2: "); YN(ok AND (got = b2));
  ok := ChannelNext(p, got); WriteString("pop3: "); YN(ok AND (got = b3));
  WriteString("depth0: "); WriteCard(ChannelDepth(p), 1); WriteLn;
  ok := ChannelNext(p, got); WriteString("empty: "); YN(NOT ok);

  (* dark seam: SetThreaded is callable and does not change the inline behaviour *)
  SetThreaded(p, TRUE);
  ok := Submit(p, b1);        WriteString("threaded-submit: "); YN(ok);
  ok := ChannelNext(p, got);  WriteString("threaded-pop: ");    YN(ok AND (got = b1))
END T90267DChannel.
