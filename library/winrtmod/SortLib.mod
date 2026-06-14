IMPLEMENTATION MODULE SortLib;

(* ---- QuickSort: middle-element pivot, Lomuto partition, recursive. -------
   Pivot is parked at `hi` and never moved during the scan, so comparing other
   elements against position `hi` stays valid under index-only compare/swap. *)
PROCEDURE QuickSort (numItems: CARDINAL; lessEq: LessEqProc; swap: SwapProc);

  PROCEDURE Sort (lo, hi: CARDINAL);
    VAR i, j, mid, p: CARDINAL;
  BEGIN
    IF lo >= hi THEN RETURN END;
    mid := lo + (hi - lo) DIV 2;
    swap(mid, hi);                       (* middle element becomes the pivot at hi *)
    i := lo;
    j := lo;
    WHILE j < hi DO
      IF lessEq(j, hi, FALSE) THEN       (* elem[j] < pivot *)
        IF i # j THEN swap(i, j) END;
        INC(i)
      END;
      INC(j)
    END;
    IF i # hi THEN swap(i, hi) END;      (* pivot to its final place *)
    p := i;
    IF p > lo THEN Sort(lo, p - 1) END;
    Sort(p + 1, hi)
  END Sort;

BEGIN
  IF numItems > 1 THEN Sort(1, numItems) END
END QuickSort;

(* ---- HeapSort: 1-based binary max-heap. --------------------------------- *)
PROCEDURE HeapSort (numItems: CARDINAL; lessEq: LessEqProc; swap: SwapProc);

  PROCEDURE Restore (idx, last: CARDINAL);
    VAR child: CARDINAL;
  BEGIN
    LOOP
      child := 2 * idx;
      IF child > last THEN EXIT END;
      IF (child < last) AND lessEq(child, child + 1, FALSE) THEN
        INC(child)                       (* pick the larger child *)
      END;
      IF lessEq(idx, child, FALSE) THEN  (* parent < child: sift down *)
        swap(idx, child); idx := child
      ELSE
        EXIT
      END
    END
  END Restore;

  VAR i: CARDINAL;
BEGIN
  IF numItems < 2 THEN RETURN END;
  i := numItems DIV 2;                    (* build the heap *)
  WHILE i >= 1 DO
    Restore(i, numItems);
    DEC(i)                               (* i=1 -> 0 ends the loop; DEC(0) never runs *)
  END;
  i := numItems;                          (* sort phase *)
  WHILE i >= 2 DO
    swap(1, i);
    Restore(1, i - 1);
    DEC(i)
  END
END HeapSort;

(* ---- ShellSort: Knuth 3h+1 gaps, temp at index 0. ---------------------- *)
PROCEDURE ShellSort (numItems: CARDINAL; lessEq: LessEqProc; assign: AssignProc);
  VAR h, i, j: CARDINAL;
BEGIN
  IF numItems < 2 THEN RETURN END;
  h := 1;
  WHILE h < numItems DO h := 3 * h + 1 END;
  REPEAT
    h := h DIV 3;
    i := h + 1;
    WHILE i <= numItems DO
      assign(0, i);                       (* stash elem[i] in temp slot 0 *)
      j := i;
      WHILE (j > h) AND lessEq(0, j - h, FALSE) DO   (* temp < predecessor *)
        assign(j, j - h);
        j := j - h
      END;
      assign(j, 0);
      INC(i)
    END
  UNTIL h <= 1
END ShellSort;

(* ---- BinaryInsertSort: stable, binary-search placement, temp at 0. ------ *)
PROCEDURE BinaryInsertSort (numItems: CARDINAL; lessEq: LessEqProc; assign: AssignProc);
  VAR i, j, left, right, mid: CARDINAL;
BEGIN
  i := 2;
  WHILE i <= numItems DO
    assign(0, i);                         (* stash elem[i] *)
    (* binary search [1, i) for the leftmost slot not <= temp *)
    left := 1; right := i;
    WHILE left < right DO
      mid := (left + right) DIV 2;
      IF lessEq(mid, 0, TRUE) THEN        (* elem[mid] <= temp -> go right (stable) *)
        left := mid + 1
      ELSE
        right := mid
      END
    END;
    j := i;                               (* shift [left, i) up by one *)
    WHILE j > left DO
      assign(j, j - 1);
      DEC(j)
    END;
    assign(left, 0);
    INC(i)
  END
END BinaryInsertSort;

(* ---- MergeSort: bottom-up, stable, ping-pong between two halves. --------
   Element k of the region with base `b` lives at absolute index b+k: region A
   (the caller's data) has base 0, the scratch region B has base numItems. *)
PROCEDURE MergeSort (numItems: CARDINAL; lessEq: LessEqProc; assign: AssignProc);

  VAR srcBase, dstBase, p, i, t: CARDINAL;

  PROCEDURE Merge (sb, db, lo, mid, hi: CARDINAL);
    (* merge src[lo,mid) and src[mid,hi) into dst[lo,hi); stable on ties *)
    VAR a, b, k: CARDINAL;
  BEGIN
    a := lo; b := mid; k := lo;
    WHILE (a < mid) AND (b < hi) DO
      IF lessEq(sb + a, sb + b, TRUE) THEN   (* src[a] <= src[b]: take a (stable) *)
        assign(db + k, sb + a); INC(a)
      ELSE
        assign(db + k, sb + b); INC(b)
      END;
      INC(k)
    END;
    WHILE a < mid DO assign(db + k, sb + a); INC(a); INC(k) END;
    WHILE b < hi  DO assign(db + k, sb + b); INC(b); INC(k) END
  END Merge;

  VAR lo, mid, hi: CARDINAL;
BEGIN
  IF numItems < 2 THEN RETURN END;
  srcBase := 0; dstBase := numItems;
  p := 1;
  WHILE p < numItems DO
    i := 1;
    WHILE i <= numItems DO
      lo := i;
      mid := i + p;       IF mid > numItems + 1 THEN mid := numItems + 1 END;
      hi := i + 2 * p;    IF hi  > numItems + 1 THEN hi  := numItems + 1 END;
      Merge(srcBase, dstBase, lo, mid, hi);
      i := i + 2 * p
    END;
    t := srcBase; srcBase := dstBase; dstBase := t;   (* swap roles *)
    p := p * 2
  END;
  IF srcBase # 0 THEN                     (* result landed in scratch: copy back *)
    i := 1;
    WHILE i <= numItems DO assign(i, srcBase + i); INC(i) END
  END
END MergeSort;

END SortLib.
