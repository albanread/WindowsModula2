(* Thin NewM2 implementation of ISO 10514-1 Strings, written over the
   open-array CHAR primitives (HIGH, indexing) rather than ported verbatim.
   CHAR is the Windows-wide (UTF-16) code unit internally; the string
   terminator is 0C and capacities are HIGH(a)+1 code units. *)
IMPLEMENTATION MODULE Strings;

PROCEDURE Length (stringVal: ARRAY OF CHAR): CARDINAL;
VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(stringVal)) AND (stringVal[i] <> 0C) DO
    INC(i);
  END;
  RETURN i;
END Length;

PROCEDURE Assign (source: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR i, n: CARDINAL;
BEGIN
  n := Length(source);
  i := 0;
  WHILE (i < n) AND (i <= HIGH(destination)) DO
    destination[i] := source[i];
    INC(i);
  END;
  IF i <= HIGH(destination) THEN
    destination[i] := 0C;
  END;
END Assign;

PROCEDURE Extract (source: ARRAY OF CHAR; startIndex, numberToExtract: CARDINAL;
                   VAR destination: ARRAY OF CHAR);
VAR i, srcLen: CARDINAL;
BEGIN
  srcLen := Length(source);
  i := 0;
  WHILE (i < numberToExtract) AND (startIndex + i < srcLen) AND (i <= HIGH(destination)) DO
    destination[i] := source[startIndex + i];
    INC(i);
  END;
  IF i <= HIGH(destination) THEN
    destination[i] := 0C;
  END;
END Extract;

PROCEDURE Delete (VAR stringVar: ARRAY OF CHAR; startIndex, numberToDelete: CARDINAL);
VAR len, i: CARDINAL;
BEGIN
  len := Length(stringVar);
  IF startIndex >= len THEN
    RETURN;
  END;
  i := startIndex;
  WHILE (i + numberToDelete < len) DO
    stringVar[i] := stringVar[i + numberToDelete];
    INC(i);
  END;
  IF i <= HIGH(stringVar) THEN
    stringVar[i] := 0C;
  END;
END Delete;

PROCEDURE Insert (source: ARRAY OF CHAR; startIndex: CARDINAL;
                  VAR destination: ARRAY OF CHAR);
VAR dlen, slen, cap, k, tail, src: CARDINAL;
BEGIN
  dlen := Length(destination);
  slen := Length(source);
  cap := HIGH(destination) + 1;
  IF startIndex > dlen THEN
    startIndex := dlen;
  END;
  (* Shift the tail right by slen (high-to-low to avoid overwrite). *)
  tail := dlen - startIndex;
  k := 0;
  WHILE k < tail DO
    src := dlen - 1 - k;
    IF src + slen < cap THEN
      destination[src + slen] := destination[src];
    END;
    INC(k);
  END;
  (* Copy source into the gap. *)
  k := 0;
  WHILE (k < slen) AND (startIndex + k < cap) DO
    destination[startIndex + k] := source[k];
    INC(k);
  END;
  IF dlen + slen < cap THEN
    destination[dlen + slen] := 0C;
  END;
END Insert;

PROCEDURE Replace (source: ARRAY OF CHAR; startIndex: CARDINAL;
                   VAR destination: ARRAY OF CHAR);
VAR dlen, slen, k: CARDINAL;
BEGIN
  dlen := Length(destination);
  slen := Length(source);
  k := 0;
  WHILE (k < slen) AND (startIndex + k < dlen) DO
    destination[startIndex + k] := source[k];
    INC(k);
  END;
END Replace;

PROCEDURE Append (source: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
VAR dlen, slen, cap, k: CARDINAL;
BEGIN
  dlen := Length(destination);
  slen := Length(source);
  cap := HIGH(destination) + 1;
  k := 0;
  WHILE (k < slen) AND (dlen + k < cap) DO
    destination[dlen + k] := source[k];
    INC(k);
  END;
  IF dlen + k < cap THEN
    destination[dlen + k] := 0C;
  END;
END Append;

PROCEDURE Concat (source1, source2: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
BEGIN
  Assign(source1, destination);
  Append(source2, destination);
END Concat;

PROCEDURE CanAssignAll (sourceLength: CARDINAL; VAR destination: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN sourceLength <= HIGH(destination) + 1;
END CanAssignAll;

PROCEDURE CanExtractAll (sourceLength, startIndex, numberToExtract: CARDINAL;
                         VAR destination: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (startIndex + numberToExtract <= sourceLength)
       AND (numberToExtract <= HIGH(destination) + 1);
END CanExtractAll;

PROCEDURE CanDeleteAll (stringLength, startIndex, numberToDelete: CARDINAL): BOOLEAN;
BEGIN
  RETURN startIndex + numberToDelete <= stringLength;
END CanDeleteAll;

PROCEDURE CanInsertAll (sourceLength, startIndex: CARDINAL;
                        VAR destination: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (startIndex <= Length(destination))
       AND (Length(destination) + sourceLength <= HIGH(destination) + 1);
END CanInsertAll;

PROCEDURE CanReplaceAll (sourceLength, startIndex: CARDINAL;
                         VAR destination: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN startIndex + sourceLength <= Length(destination);
END CanReplaceAll;

PROCEDURE CanAppendAll (sourceLength: CARDINAL; VAR destination: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Length(destination) + sourceLength <= HIGH(destination) + 1;
END CanAppendAll;

PROCEDURE CanConcatAll (source1Length, source2Length: CARDINAL;
                        VAR destination: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN source1Length + source2Length <= HIGH(destination) + 1;
END CanConcatAll;

PROCEDURE Compare (stringVal1, stringVal2: ARRAY OF CHAR): CompareResults;
VAR l1, l2, i: CARDINAL;
BEGIN
  l1 := Length(stringVal1);
  l2 := Length(stringVal2);
  i := 0;
  WHILE (i < l1) AND (i < l2) DO
    IF stringVal1[i] < stringVal2[i] THEN
      RETURN less;
    ELSIF stringVal1[i] > stringVal2[i] THEN
      RETURN greater;
    END;
    INC(i);
  END;
  IF l1 < l2 THEN
    RETURN less;
  ELSIF l1 > l2 THEN
    RETURN greater;
  END;
  RETURN equal;
END Compare;

PROCEDURE Equal (stringVal1, stringVal2: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Compare(stringVal1, stringVal2) = equal;
END Equal;

PROCEDURE FindNext (pattern, stringToSearch: ARRAY OF CHAR; startIndex: CARDINAL;
                    VAR patternFound: BOOLEAN; VAR posOfPattern: CARDINAL);
VAR slen, plen, i, j: CARDINAL;
BEGIN
  slen := Length(stringToSearch);
  plen := Length(pattern);
  patternFound := FALSE;
  posOfPattern := startIndex;
  IF plen = 0 THEN
    patternFound := TRUE;
    RETURN;
  END;
  IF startIndex >= slen THEN
    RETURN;
  END;
  i := startIndex;
  WHILE i + plen <= slen DO
    j := 0;
    WHILE (j < plen) AND (stringToSearch[i + j] = pattern[j]) DO
      INC(j);
    END;
    IF j = plen THEN
      patternFound := TRUE;
      posOfPattern := i;
      RETURN;
    END;
    INC(i);
  END;
END FindNext;

PROCEDURE FindPrev (pattern, stringToSearch: ARRAY OF CHAR; startIndex: CARDINAL;
                    VAR patternFound: BOOLEAN; VAR posOfPattern: CARDINAL);
VAR slen, plen, i, j: CARDINAL;
BEGIN
  slen := Length(stringToSearch);
  plen := Length(pattern);
  patternFound := FALSE;
  posOfPattern := startIndex;
  IF plen = 0 THEN
    patternFound := TRUE;
    RETURN;
  END;
  IF plen > slen THEN
    RETURN;
  END;
  (* Scan forward, keeping the last match at or before startIndex. *)
  i := 0;
  WHILE (i + plen <= slen) AND (i <= startIndex) DO
    j := 0;
    WHILE (j < plen) AND (stringToSearch[i + j] = pattern[j]) DO
      INC(j);
    END;
    IF j = plen THEN
      patternFound := TRUE;
      posOfPattern := i;
    END;
    INC(i);
  END;
END FindPrev;

PROCEDURE FindDiff (stringVal1, stringVal2: ARRAY OF CHAR;
                    VAR differenceFound: BOOLEAN; VAR posOfDifference: CARDINAL);
VAR l1, l2, i, m: CARDINAL;
BEGIN
  l1 := Length(stringVal1);
  l2 := Length(stringVal2);
  differenceFound := FALSE;
  posOfDifference := 0;
  IF l1 < l2 THEN
    m := l1;
  ELSE
    m := l2;
  END;
  i := 0;
  WHILE i < m DO
    IF stringVal1[i] <> stringVal2[i] THEN
      differenceFound := TRUE;
      posOfDifference := i;
      RETURN;
    END;
    INC(i);
  END;
  IF l1 <> l2 THEN
    differenceFound := TRUE;
    posOfDifference := m;
  END;
END FindDiff;

PROCEDURE Capitalize (VAR stringVar: ARRAY OF CHAR);
VAR i, len: CARDINAL;
    c: CHAR;
BEGIN
  len := Length(stringVar);
  i := 0;
  WHILE i < len DO
    c := stringVar[i];
    IF (c >= 'a') AND (c <= 'z') THEN
      stringVar[i] := CHR(ORD(c) - ORD('a') + ORD('A'));
    END;
    INC(i);
  END;
END Capitalize;

END Strings.
