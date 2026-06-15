MODULE AsmDemo;
(*
 * Inline assembler — a Modula-2 procedure whose body is `ASM <intel> END name;`.
 * The body is plain Intel-syntax x86-64, emitted as module-level inline asm and
 * called like any other procedure. Win64 ABI: integer args arrive in rcx, rdx,
 * r8, r9 (then the stack); the integer result goes back in rax. (Floats use
 * xmm0..xmm3 / xmm0.) No register-substitution magic — you write the real ABI.
 *
 *   build: newm2 build demos/asm_demo.mod   (or: newm2 run demos/asm_demo.mod)
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;

(* a = rcx, b = rdx  ->  rax = a + b *)
PROCEDURE Add (a, b: INTEGER): INTEGER;
ASM
  mov rax, rcx
  add rax, rdx
  ret
END Add;

(* a = rcx, b = rdx  ->  rax = a * b *)
PROCEDURE Mul (a, b: INTEGER): INTEGER;
ASM
  mov rax, rcx
  imul rax, rdx
  ret
END Mul;

(* a = rcx, b = rdx, c = r8, d = r9  ->  rax = a + b + c + d *)
PROCEDURE Sum4 (a, b, c, d: INTEGER): INTEGER;
ASM
  mov rax, rcx
  add rax, rdx
  add rax, r8
  add rax, r9
  ret
END Sum4;

(* n = rcx  ->  rax = n*(n+1)/2  via a loop (shows labels + branches) *)
PROCEDURE TriSum (n: INTEGER): INTEGER;
ASM
  xor rax, rax
  mov rdx, rcx
tri_loop:
  test rdx, rdx
  jle tri_done
  add rax, rdx
  dec rdx
  jmp tri_loop
tri_done:
  ret
END TriSum;

PROCEDURE Show (label: ARRAY OF CHAR; v: INTEGER);
BEGIN WriteString(label); WriteInt(v, 1); WriteLn END Show;

BEGIN
  Show("Add(40, 2)        = ", Add(40, 2));        (* 42 *)
  Show("Mul(6, 7)         = ", Mul(6, 7));         (* 42 *)
  Show("Sum4(10,11,12,9)  = ", Sum4(10, 11, 12, 9)); (* 42 *)
  Show("TriSum(8)         = ", TriSum(8));         (* 36 *)
  WriteString("inline assembler: OK"); WriteLn
END AsmDemo.
