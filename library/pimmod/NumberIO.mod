IMPLEMENTATION MODULE NumberIO;

IMPORT SWholeIO, WholeStr;

PROCEDURE WriteCard (card: CARDINAL; width: CARDINAL);
BEGIN
  SWholeIO.WriteCard(card, width)
END WriteCard;

PROCEDURE WriteInt (int: INTEGER; width: CARDINAL);
BEGIN
  SWholeIO.WriteInt(int, width)
END WriteInt;

(* PIM CardToStr is right-justified in `width`; the ISO conversion produces the
   minimal form, which matches the corpus's width-0 uses. *)
PROCEDURE CardToStr (card: CARDINAL; width: CARDINAL; VAR str: ARRAY OF CHAR);
BEGIN
  WholeStr.CardToStr(card, str)
END CardToStr;

END NumberIO.
