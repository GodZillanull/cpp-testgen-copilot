# run_tests.ps1 - quick inner loop: build and run the tests (optionally filtered / repeated).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/run_tests.ps1 [-Filter "CalcTest.*"] [-Repeat 1] [-NoBuild]
param([string]$Filter = '', [int]$Repeat = 1, [switch]$NoBuild)
. "$PSScriptRoot/common.ps1"

$cfg = Get-TgConfig
if (-not $NoBuild) {
    $b = Invoke-TgBuild $cfg
    if ($b.TimedOut -or $b.ExitCode -ne 0) {
        Write-Host 'BUILD FAILED'
        Write-Host (Get-TgTail $b.Output 60)
        exit 2
    }
    Write-Host 'BUILD OK'
}
$res = Invoke-TgTests -Cfg $cfg -Repeat $Repeat -Shuffle:($Repeat -gt 1) -Filter $Filter
foreach ($r in $res.Runs) {
    Write-Host "$($r.Exe): $($r.Status) (exit $($r.ExitCode), $($r.Seconds)s)"
    if ($r.Status -ne 'PASSED') { Write-Host $r.Tail }
}
if ($res.Failed.Count -gt 0) {
    Write-Host 'Failed tests:'
    foreach ($k in $res.Failed.Keys) { Write-Host "  $k  (failed $($res.Failed[$k])/$Repeat)" }
}
if ($res.Ok) { Write-Host 'TESTS PASSED'; exit 0 } else { Write-Host 'TESTS FAILED'; exit 1 }
