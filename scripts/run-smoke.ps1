# NewM2 smoke harness — Windows equivalent of NewCP's tools/basic-smoke.sh.
#
# Phase 0 stub. Will eventually:
#   - Compile every .mod in mod-tests/Tests/ under both memory modes
#     (NEWM2_MODE=gc and NEWM2_MODE=nogc).
#   - Compile every .mod in mod-tests/Tests/Negative/ and expect failure
#     with diagnostic substring matching the sibling .expected file.
#   - Print PASS=N FAIL=N MODE=gc/nogc summary per lane.
#
# Usage: powershell -ExecutionPolicy Bypass -File scripts\run-smoke.ps1

$ErrorActionPreference = 'Stop'

Write-Host "newm2 smoke harness — Phase 0 stub"
Write-Host "TODO: compile mod-tests/Tests/ in both modes; run; tally."
exit 0
