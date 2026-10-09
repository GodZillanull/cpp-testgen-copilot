# stop-check.ps1 - Stop hook for the test-writer agent.
# Blocks the agent from finishing if test files changed since the last gate.ps1 run,
# so every session ends with a machine verdict instead of the agent's own opinion.
$ErrorActionPreference = 'Stop'
try {
    . "$PSScriptRoot/../../skills/cpp-test-gate/scripts/common.ps1"
    $raw = [Console]::In.ReadToEnd()
    $evt = $null
    if ($raw) { $evt = $raw | ConvertFrom-Json }
    if ($evt -and (Get-TgProp $evt 'stop_hook_active' $false)) { Write-Output '{"continue":true}'; exit 0 }

    $cfg = Get-TgConfig
    $reports = Get-TgReportsDir $cfg
    $baseline = Read-TgJson (Join-Path $reports 'baseline/baseline.json')
    if ($null -eq $baseline) { Write-Output '{"continue":true}'; exit 0 }   # setup phase

    $now = Get-TgTestsHash $cfg
    if ($now -eq [string](Get-TgProp $baseline 'testsHash' '')) { Write-Output '{"continue":true}'; exit 0 }
    $last = Read-TgJson (Join-Path $reports 'gate/last-gate.json')
    if ($last -and ([string](Get-TgProp $last 'testsHash' '') -eq $now)) { Write-Output '{"continue":true}'; exit 0 }

    $reason = 'Test files changed since the last gate run. Run: powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/gate.ps1 ; then fix or delete rejected tests (re-run the gate) and report the final verdict to the user.'
    $o = @{ hookSpecificOutput = @{ hookEventName = 'Stop'; decision = 'block'; reason = $reason } }
    Write-Output ($o | ConvertTo-Json -Compress -Depth 5)
    exit 0
} catch {
    Write-Output '{"continue":true}'
    exit 0
}
