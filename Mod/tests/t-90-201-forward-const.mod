MODULE T90201ForwardConst;
(*
 * Group 90 — constant expressions
 * Test: a constant may reference constants declared later in the same scope
 *       (a forward constant reference, which the ISO spec allows). `foo` is built from
 *       `hello`/`space`/`world`, all declared after it.
 *
 * EXPECTED:
 * hello world
 * 11
 *)
FROM StrIO IMPORT WriteString, WriteLn;
FROM StrLib IMPORT StrLen;
FROM NumberIO IMPORT WriteCard;

CONST
  foo   = hello + space + world;
  hello = "hello";
  space = " ";
  world = "world";

BEGIN
  WriteString(foo); WriteLn;
  WriteCard(StrLen(foo), 0); WriteLn
END T90201ForwardConst.
