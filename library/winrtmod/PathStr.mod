IMPLEMENTATION MODULE PathStr;

(* Pure string work over Windows paths. BaseStart = index just past the last
   separator; DotPos = index of the last '.' in the final component (a leading
   dot, e.g. ".gitignore", is not an extension). All writers truncate-and-always-
   terminate via CopyRange (which reserves the terminator slot). *)

PROCEDURE SLen (s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END; RETURN i END SLen;

PROCEDURE IsSep (c: CHAR): BOOLEAN;
BEGIN RETURN (c = '\') OR (c = '/') END IsSep;

PROCEDURE CopyRange (s: ARRAY OF CHAR; a, b: CARDINAL; VAR out: ARRAY OF CHAR);
  VAR i, k: CARDINAL;
BEGIN
  k := 0; i := a;
  WHILE (i < b) AND (k < HIGH(out)) DO out[k] := s[i]; INC(k); INC(i) END;
  out[k] := 0C
END CopyRange;

PROCEDURE BaseStart (path: ARRAY OF CHAR; len: CARDINAL): CARDINAL;
  VAR i, start: CARDINAL;
BEGIN
  start := 0; i := 0;
  WHILE i < len DO IF IsSep(path[i]) THEN start := i + 1 END; INC(i) END;
  RETURN start
END BaseStart;

PROCEDURE DotPos (path: ARRAY OF CHAR; len, baseStart: CARDINAL): CARDINAL;
  VAR i, dot: CARDINAL;
BEGIN
  dot := len;
  i := baseStart;
  WHILE i < len DO IF path[i] = '.' THEN dot := i END; INC(i) END;
  IF dot = baseStart THEN dot := len END;          (* leading dot = no extension *)
  RETURN dot
END DotPos;

PROCEDURE Join (a, b: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR la, lb, i, k: CARDINAL;
BEGIN
  la := SLen(a); lb := SLen(b); k := 0;
  i := 0; WHILE (i < la) AND (k < HIGH(out)) DO out[k] := a[i]; INC(k); INC(i) END;
  IF (la > 0) AND (lb > 0) AND (NOT IsSep(a[la-1])) AND (k < HIGH(out)) THEN
    out[k] := '\'; INC(k)
  END;
  i := 0; WHILE (i < lb) AND (k < HIGH(out)) DO out[k] := b[i]; INC(k); INC(i) END;
  out[k] := 0C
END Join;

PROCEDURE DirName (path: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR len, bs: CARDINAL;
BEGIN
  len := SLen(path); bs := BaseStart(path, len);
  IF bs = 0 THEN CopyRange(path, 0, 0, out) ELSE CopyRange(path, 0, bs - 1, out) END
END DirName;

PROCEDURE BaseName (path: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR len, bs: CARDINAL;
BEGIN
  len := SLen(path); bs := BaseStart(path, len);
  CopyRange(path, bs, len, out)
END BaseName;

PROCEDURE Ext (path: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR len, bs, dp: CARDINAL;
BEGIN
  len := SLen(path); bs := BaseStart(path, len); dp := DotPos(path, len, bs);
  IF dp < len THEN CopyRange(path, dp, len, out) ELSE CopyRange(path, 0, 0, out) END
END Ext;

PROCEDURE StripExt (path: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR len, bs, dp: CARDINAL;
BEGIN
  len := SLen(path); bs := BaseStart(path, len); dp := DotPos(path, len, bs);
  CopyRange(path, 0, dp, out)
END StripExt;

PROCEDURE ChangeExt (path, newExt: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR len, bs, dp, ne, i, k: CARDINAL;
BEGIN
  len := SLen(path); bs := BaseStart(path, len); dp := DotPos(path, len, bs);
  k := 0;
  i := 0; WHILE (i < dp) AND (k < HIGH(out)) DO out[k] := path[i]; INC(k); INC(i) END;
  ne := SLen(newExt);
  i := 0; WHILE (i < ne) AND (k < HIGH(out)) DO out[k] := newExt[i]; INC(k); INC(i) END;
  out[k] := 0C
END ChangeExt;

PROCEDURE IsAbsolute (path: ARRAY OF CHAR): BOOLEAN;
  VAR len: CARDINAL;
BEGIN
  len := SLen(path);
  IF len = 0 THEN RETURN FALSE END;
  IF IsSep(path[0]) THEN RETURN TRUE END;            (* rooted "\.." or UNC "\\.." *)
  IF (len >= 2) AND (path[1] = ':') THEN RETURN TRUE END;   (* drive "X:.." *)
  RETURN FALSE
END IsAbsolute;

END PathStr.
