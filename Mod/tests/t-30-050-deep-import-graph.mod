MODULE T30050DeepImportGraph;
(*
 * Group 30 — Deeper module graphs
 * Test: dependency discovery walks implementation imports across a three-hop
 * helper chain.
 *
 * EXPECTED:
 * 37
 * 41
 *)
IMPORT STextIO, SWholeIO;
FROM T30050Graph IMPORT GraphValue;

BEGIN
  SWholeIO.WriteInt(GraphValue(1), 0);
  STextIO.WriteLn;

  SWholeIO.WriteInt(GraphValue(3), 0);
  STextIO.WriteLn;
END T30050DeepImportGraph.