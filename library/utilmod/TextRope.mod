IMPLEMENTATION MODULE TextRope;

(* A rope node is either a LEAF holding up to LeafMax characters, or a BRANCH
   holding two child ropes. `len` is the total character count of the whole
   subtree, so Length is O(1) and CharAt can descend by comparing the index
   against the left child's length. A single tagged record type is used (rather
   than a variant record) so child pointers are uniformly `Rope`. *)

CONST
  LeafMax   = 64;       (* characters per leaf fragment *)
  MaxLeaves = 8192;     (* Balance gathers at most this many leaves in place *)

TYPE
  Rope = POINTER TO Node;
  Node = RECORD
    isLeaf : BOOLEAN;
    len    : CARDINAL;                        (* chars in this whole subtree *)
    data   : ARRAY [0..LeafMax-1] OF CHAR;    (* leaf only *)
    left   : Rope;                            (* branch only *)
    right  : Rope;                            (* branch only *)
  END;

(* ---- internal builders ------------------------------------------------- *)

PROCEDURE NewLeaf (VAR src: ARRAY OF CHAR; from, count: CARDINAL): Rope;
  VAR n: Rope; k: CARDINAL;
BEGIN
  NEW(n);
  n^.isLeaf := TRUE; n^.left := NIL; n^.right := NIL; n^.len := count;
  k := 0;
  WHILE k < count DO n^.data[k] := src[from + k]; INC(k) END;
  RETURN n
END NewLeaf;

(* Join two ropes into a branch (or pass through when one side is empty). Takes
   ownership of both children. *)
PROCEDURE MakeBranch (a, b: Rope): Rope;
  VAR n: Rope;
BEGIN
  IF a = NIL THEN RETURN b END;
  IF b = NIL THEN RETURN a END;
  NEW(n);
  n^.isLeaf := FALSE; n^.left := a; n^.right := b; n^.len := a^.len + b^.len;
  RETURN n
END MakeBranch;

PROCEDURE StrLen (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END;
  RETURN i
END StrLen;

(* Build a balanced tree of leaves covering s[from .. from+count-1]. *)
PROCEDURE BuildSlice (VAR s: ARRAY OF CHAR; from, count: CARDINAL): Rope;
  VAR half: CARDINAL;
BEGIN
  IF count <= LeafMax THEN RETURN NewLeaf(s, from, count) END;
  half := count DIV 2;
  RETURN MakeBranch(BuildSlice(s, from, half), BuildSlice(s, from + half, count - half))
END BuildSlice;

(* ---- construction ------------------------------------------------------ *)

PROCEDURE Empty (): Rope;
BEGIN RETURN NIL END Empty;

PROCEDURE FromString (s: ARRAY OF CHAR): Rope;
  VAR len: CARDINAL;
BEGIN
  len := StrLen(s);
  IF len = 0 THEN RETURN NIL END;
  RETURN BuildSlice(s, 0, len)
END FromString;

(* ---- queries ----------------------------------------------------------- *)

PROCEDURE Length (r: Rope): CARDINAL;
BEGIN
  IF r = NIL THEN RETURN 0 ELSE RETURN r^.len END
END Length;

PROCEDURE CharAt (r: Rope; i: CARDINAL): CHAR;
BEGIN
  IF (r = NIL) OR (i >= r^.len) THEN RETURN 0C END;
  WHILE NOT r^.isLeaf DO
    IF i < r^.left^.len THEN
      r := r^.left
    ELSE
      i := i - r^.left^.len; r := r^.right
    END
  END;
  RETURN r^.data[i]
END CharAt;

PROCEDURE Sub (r: Rope; i, n: CARDINAL; VAR out: ARRAY OF CHAR);
  VAR k, len: CARDINAL;
BEGIN
  len := Length(r);
  k := 0;
  WHILE (k < n) AND (k < HIGH(out)) AND (i + k < len) DO
    out[k] := CharAt(r, i + k); INC(k)
  END;
  out[k] := 0C
END Sub;

PROCEDURE ToString (r: Rope; VAR out: ARRAY OF CHAR);
BEGIN
  Sub(r, 0, Length(r), out)
END ToString;

(* ---- editing (consume arguments) --------------------------------------- *)

PROCEDURE Concat (a, b: Rope): Rope;
  VAR n: Rope; k: CARDINAL;
BEGIN
  IF a = NIL THEN RETURN b END;
  IF b = NIL THEN RETURN a END;
  (* Merge two small leaves into one fragment — keeps the tree from
     fragmenting under many small edits, and exercises DISPOSE. *)
  IF a^.isLeaf AND b^.isLeaf AND (a^.len + b^.len <= LeafMax) THEN
    NEW(n);
    n^.isLeaf := TRUE; n^.left := NIL; n^.right := NIL; n^.len := a^.len + b^.len;
    k := 0;
    WHILE k < a^.len DO n^.data[k] := a^.data[k]; INC(k) END;
    k := 0;
    WHILE k < b^.len DO n^.data[a^.len + k] := b^.data[k]; INC(k) END;
    DISPOSE(a); DISPOSE(b);
    RETURN n
  END;
  RETURN MakeBranch(a, b)
END Concat;

(* Split rope r at index i into l = [0,i) and rr = [i,len). Consumes r. *)
PROCEDURE SplitNode (r: Rope; i: CARDINAL; VAR l, rr: Rope);
  VAR w: CARDINAL; ll, lr, rl, rr2, rl0, rr0: Rope;
BEGIN
  IF r = NIL THEN l := NIL; rr := NIL; RETURN END;
  IF i = 0 THEN l := NIL; rr := r; RETURN END;
  IF i >= r^.len THEN l := r; rr := NIL; RETURN END;
  IF r^.isLeaf THEN
    l  := NewLeaf(r^.data, 0, i);
    rr := NewLeaf(r^.data, i, r^.len - i);
    DISPOSE(r)
  ELSE
    w   := r^.left^.len;
    rl0 := r^.left; rr0 := r^.right;
    IF i = w THEN
      l := rl0; rr := rr0; DISPOSE(r)
    ELSIF i < w THEN
      SplitNode(rl0, i, ll, lr);          (* left child consumed *)
      l  := ll;
      rr := Concat(lr, rr0);              (* reuse right child *)
      DISPOSE(r)
    ELSE
      SplitNode(rr0, i - w, rl, rr2);     (* right child consumed *)
      l  := Concat(rl0, rl);             (* reuse left child *)
      rr := rr2;
      DISPOSE(r)
    END
  END
END SplitNode;

PROCEDURE Insert (r: Rope; i: CARDINAL; s: ARRAY OF CHAR): Rope;
  VAR l, rr, mid: Rope;
BEGIN
  mid := FromString(s);
  IF mid = NIL THEN RETURN r END;
  IF i >= Length(r) THEN RETURN Concat(r, mid) END;
  SplitNode(r, i, l, rr);
  RETURN Concat(Concat(l, mid), rr)
END Insert;

PROCEDURE Append (r: Rope; s: ARRAY OF CHAR): Rope;
BEGIN
  RETURN Concat(r, FromString(s))
END Append;

PROCEDURE DeleteRange (r: Rope; i, n: CARDINAL): Rope;
  VAR l, tmp, mid, rr: Rope; len: CARDINAL;
BEGIN
  len := Length(r);
  IF (i >= len) OR (n = 0) THEN RETURN r END;
  IF i + n > len THEN n := len - i END;
  SplitNode(r, i, l, tmp);              (* l = [0,i), tmp = [i,len) *)
  SplitNode(tmp, n, mid, rr);           (* mid = [i,i+n), rr = [i+n,len) *)
  Free(mid);                            (* drop the deleted text *)
  RETURN Concat(l, rr)
END DeleteRange;

(* ---- maintenance ------------------------------------------------------- *)

PROCEDURE Free (VAR r: Rope);
BEGIN
  IF r = NIL THEN RETURN END;
  IF NOT r^.isLeaf THEN Free(r^.left); Free(r^.right) END;
  DISPOSE(r);
  r := NIL
END Free;

PROCEDURE Gather (r: Rope; VAR arr: ARRAY OF Rope; VAR count: CARDINAL);
BEGIN
  IF r = NIL THEN RETURN END;
  IF r^.isLeaf THEN
    IF count <= HIGH(arr) THEN arr[count] := r; INC(count) END
  ELSE
    Gather(r^.left, arr, count);
    Gather(r^.right, arr, count);
    DISPOSE(r)                          (* free the branch; leaves kept in arr *)
  END
END Gather;

PROCEDURE BuildBalanced (VAR arr: ARRAY OF Rope; lo, hi: CARDINAL): Rope;
  VAR mid: CARDINAL;
BEGIN
  IF lo = hi THEN RETURN arr[lo] END;
  mid := (lo + hi) DIV 2;
  RETURN MakeBranch(BuildBalanced(arr, lo, mid), BuildBalanced(arr, mid + 1, hi))
END BuildBalanced;

PROCEDURE Balance (VAR r: Rope);
  VAR arr: ARRAY [0..MaxLeaves-1] OF Rope; count: CARDINAL;
BEGIN
  IF r = NIL THEN RETURN END;
  IF Leaves(r) > MaxLeaves THEN RETURN END;     (* too large to rebuild in place *)
  count := 0;
  Gather(r, arr, count);
  IF count = 0 THEN r := NIL ELSE r := BuildBalanced(arr, 0, count - 1) END
END Balance;

(* ---- structure inspection ---------------------------------------------- *)

PROCEDURE Depth (r: Rope): CARDINAL;
  VAR dl, dr: CARDINAL;
BEGIN
  IF r = NIL THEN RETURN 0 END;
  IF r^.isLeaf THEN RETURN 1 END;
  dl := Depth(r^.left); dr := Depth(r^.right);
  IF dl > dr THEN RETURN dl + 1 ELSE RETURN dr + 1 END
END Depth;

PROCEDURE Leaves (r: Rope): CARDINAL;
BEGIN
  IF r = NIL THEN RETURN 0 END;
  IF r^.isLeaf THEN RETURN 1 END;
  RETURN Leaves(r^.left) + Leaves(r^.right)
END Leaves;

PROCEDURE Nodes (r: Rope): CARDINAL;
BEGIN
  IF r = NIL THEN RETURN 0 END;
  IF r^.isLeaf THEN RETURN 1 END;
  RETURN 1 + Nodes(r^.left) + Nodes(r^.right)
END Nodes;

END TextRope.
