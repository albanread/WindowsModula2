MODULE t80070;
IMPORT RealIO, StdChans, IOChan, TextIO;
VAR out : IOChan.ChanId;
    z1, z2, z3 : COMPLEX;

PROCEDURE Emit(z : COMPLEX);
BEGIN
  RealIO.WriteFixed(out, RE(z), 1, 0);
  TextIO.WriteString(out, " ");
  RealIO.WriteFixed(out, IM(z), 1, 0);
  TextIO.WriteLn(out)
END Emit;

BEGIN
  out := StdChans.OutChan();
  z1 := CMPLX(3.0, 4.0);
  z2 := CMPLX(1.0, 2.0);
  z3 := z1 + z2; Emit(z3);     (* 4 + 6i *)
  z3 := z1 - z2; Emit(z3);     (* 2 + 2i *)
  z3 := z1 * z2; Emit(z3);     (* -5 + 10i *)
  z3 := z1 / z2; Emit(z3)      (* 2.2 - 0.4i *)
END t80070.
