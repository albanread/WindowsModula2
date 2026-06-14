MODULE T90241RunProg;
(*
 * Group 90 — Win32 helper library: RunProg (clean-room recreation of the
 * ADW/Stony Brook win32 helper). Launch external programs via direct Win32
 * (CreateProcessW + WaitForSingleObject + GetExitCodeProcess), in pure M2.
 * PerformCommand runs "%COMSPEC% /C <com>" synchronously and returns the
 * interpreter's exit code, which `exit N` makes deterministic.
 *
 * EXPECTED:
 * launched: Y
 * code42: 42
 * code7: 7
 * code0: 0
 *)
FROM RunProg IMPORT PerformCommand, SyncExec;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR status: CARDINAL; ok: BOOLEAN;
BEGIN
  ok := PerformCommand("exit 42", SyncExec, status);
  WriteString("launched: "); YN(ok); WriteLn;
  WriteString("code42: "); WriteCard(status, 1); WriteLn;
  ok := PerformCommand("exit 7", SyncExec, status);
  WriteString("code7: "); WriteCard(status, 1); WriteLn;
  ok := PerformCommand("exit 0", SyncExec, status);
  WriteString("code0: "); WriteCard(status, 1); WriteLn
END T90241RunProg.
