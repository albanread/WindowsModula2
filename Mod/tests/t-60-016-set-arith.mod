MODULE t60016;
IMPORT STextIO;
TYPE S = SET OF [0..7];
VAR a, b: S;
PROCEDURE pb(x: BOOLEAN);
BEGIN IF x THEN STextIO.WriteString("1") ELSE STextIO.WriteString("0") END END pb;
BEGIN
  a := S{0,1}; b := S{1,2};
  pb(0 IN (a+b)); pb(1 IN (a+b)); pb(2 IN (a+b)); pb(3 IN (a+b));  (* union 1110 *)
  pb(1 IN (a*b)); pb(0 IN (a*b));                                   (* isect 10 *)
  pb(0 IN (a-b)); pb(1 IN (a-b));                                   (* diff  10 *)
  STextIO.WriteLn;
END t60016.
