# Test client for the newm2 compiler daemon (named pipe, 4-byte LE length frames).
param([string]$Pipe = 'newm2test')
$c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut)
$c.Connect(5000)

function Send-Cmd($s) {
  $b = [System.Text.Encoding]::UTF8.GetBytes($s)
  $len = [BitConverter]::GetBytes([int]$b.Length)
  $c.Write($len, 0, 4); $c.Write($b, 0, $b.Length); $c.Flush()
  $lb = New-Object byte[] 4; $r = 0
  while ($r -lt 4) { $n = $c.Read($lb, $r, 4 - $r); if ($n -le 0) { break }; $r += $n }
  $rl = [BitConverter]::ToInt32($lb, 0)
  $buf = New-Object byte[] $rl; $r = 0
  while ($r -lt $rl) { $n = $c.Read($buf, $r, $rl - $r); if ($n -le 0) { break }; $r += $n }
  return [System.Text.Encoding]::UTF8.GetString($buf)
}

$base = 'e:\NewModula2\projects\FastPanesM2'
Write-Output ("ping        -> " + (Send-Cmd 'ping'))
Write-Output ("version     -> " + (Send-Cmd 'version'))
Write-Output ("check OK    -> [" + (Send-Cmd ('check "' + $base + '\sample.mod"')) + "]")
Write-Output ("check ERR   -> " + (Send-Cmd ('check "' + $base + '\broken.mod"')))
$ast = Send-Cmd ('dump ast "' + $base + '\sample.mod"')
Write-Output ("dump ast    -> first line: " + ($ast -split "`n")[0])
Write-Output ("build OK    -> " + (Send-Cmd ('build "' + $base + '\sample.mod" "' + $env:TEMP + '\daemon_build.exe"')))
Write-Output ("build ERR   -> " + (Send-Cmd ('build "' + $base + '\broken.mod"')))
$runout = Send-Cmd ('run "' + $base + '\sample.mod"')
Write-Output ("run OK      -> " + ($runout -replace "`r?`n", " | "))
Write-Output ("shutdown    -> " + (Send-Cmd 'shutdown'))
$c.Dispose()
