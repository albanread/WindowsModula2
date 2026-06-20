# Drive a running FastPanesM2 IDE by sending a ptcl command over its \\.\pipe\fastpanes
# pipe (4-byte LE length + UTF-8 payload framing). Prints the reply.
param([string]$Cmd = "expr {1 + 1}", [string]$Pipe = "fastpanes", [int]$TimeoutMs = 4000)

$c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut)
try { $c.Connect($TimeoutMs) } catch { Write-Output "CONNECT-FAIL: $_"; exit 1 }

$bytes = [System.Text.Encoding]::UTF8.GetBytes($Cmd)
$len = [BitConverter]::GetBytes([int]$bytes.Length)   # x86/x64 are little-endian
$c.Write($len, 0, 4)
$c.Write($bytes, 0, $bytes.Length)
$c.Flush()

$rl = New-Object byte[] 4
$got = 0
while ($got -lt 4) { $r = $c.Read($rl, $got, 4 - $got); if ($r -le 0) { break }; $got += $r }
if ($got -lt 4) { Write-Output "NO-REPLY"; $c.Dispose(); exit 1 }
$rlen = [BitConverter]::ToInt32($rl, 0)
$buf = New-Object byte[] $rlen
$got = 0
while ($got -lt $rlen) { $r = $c.Read($buf, $got, $rlen - $got); if ($r -le 0) { break }; $got += $r }
$reply = [System.Text.Encoding]::UTF8.GetString($buf, 0, $got)
Write-Output "REPLY: [$reply]"
$c.Dispose()
