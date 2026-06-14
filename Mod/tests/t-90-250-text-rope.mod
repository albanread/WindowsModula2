MODULE T90250TextRope;
(*
 * Group 90 — the rope text buffer (library/utilmod/TextRope): a balanced tree of
 * text fragments used as an editor document buffer. Exercises NEW/DISPOSE of tree
 * nodes, recursion (split/concat/balance), and string fragment handling. Build a
 * string, insert/append/delete by index, then stress the structure with many
 * front-inserts and rebalance — content is preserved, depth shrinks.
 *
 * EXPECTED:
 * hello, world
 * hello, world!
 * hello world!
 * len=201 balanced=yes
 * ABCDEFGHIJ
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
FROM TextRope IMPORT Rope, FromString, Length, Sub, ToString,
  Insert, Append, DeleteRange, Balance, Free, Depth;

VAR r: Rope; buf: ARRAY [0..255] OF CHAR; i, d0, d1: CARDINAL;

PROCEDURE Put (r: Rope);
BEGIN ToString(r, buf); WriteString(buf); WriteLn END Put;

BEGIN
  r := FromString("hello world");
  r := Insert(r, 5, ",");          Put(r);            (* hello, world *)
  r := Append(r, "!");             Put(r);            (* hello, world! *)
  r := DeleteRange(r, 5, 1);       Put(r);            (* hello world! *)
  Free(r);

  r := FromString("x");
  FOR i := 1 TO 20 DO r := Insert(r, 0, "ABCDEFGHIJ") END;   (* 201 chars *)
  d0 := Depth(r);
  Balance(r);
  d1 := Depth(r);
  WriteString("len="); WriteInt(Length(r), 0);
  WriteString(" balanced=");
  IF d1 < d0 THEN WriteString("yes") ELSE WriteString("no") END;
  WriteLn;
  Sub(r, 0, 10, buf); WriteString(buf); WriteLn;      (* ABCDEFGHIJ *)
  Free(r)
END T90250TextRope.
