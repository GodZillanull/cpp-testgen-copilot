# baseline.ps1 - build, run existing tests, measure coverage and record the baseline that gate.ps1 compares against.
# Run once before generating tests (and again only when a human decides to reset the baseline).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/baseline.ps1
param([switch]$NoBuild)
. "$PSScriptRoot/common.ps1"

$cfg = Get-TgConfig
$reports = Get-TgReportsDir $cfg
$work = Join-Path $reports 'baseline/work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

if (-not $NoBuild) {
    Write-Host '[1/4] Building...'
    $b = Invoke-TgBuild $cfg
    if ($b.TimedOut -or $b.ExitCode -ne 0) {
        Write-Host 'BUILD FAILED'
        Write-Host (Get-TgTail $b.Output 40)
        exit 2
    }
}

Write-Host '[2/4] Listing tests...'
$tests = @(Get-TgTestList $cfg)
Write-Host "      $($tests.Count) test(s) found"

Write-Host '[3/4] Running existing tests...'
$run = Invoke-TgTests -Cfg $cfg -Repeat 1
if (-not $run.Ok) {
    Write-Host 'EXISTING TESTS ARE NOT GREEN. Fix or exclude them (tests.extraArgs: ["--gtest_filter=-Broken.*"]) before taking a baseline.'
    foreach ($r in $run.Runs) { Write-Host "  $($r.Exe): $($r.Status)"; Write-Host $r.Tail }
    exit 3
}

$mode = Get-TgCoverageMode $cfg
if ($mode -eq 'none') {
    Write-Host '[4/4] Coverage disabled -> mutation-only mode (no coverage measured)'
    $files = ConvertTo-TgObject ([ordered]@{})
    $totals = [pscustomobject]@{ LinesCovered = 0; LinesTotal = 0; LinePct = $null; BranchesCovered = 0; BranchesTotal = 0; BranchPct = $null }
} else {
    Write-Host '[4/4] Measuring coverage...'
    $model = Get-TgCoverage -Cfg $cfg -WorkDir $work
    $files = ConvertTo-TgObject (ConvertTo-TgCoverageJson $model)
    $totals = Get-TgCoverageTotals $files
}

$prodHashes = Get-TgFileHashes -Dirs (Get-TgProductionDirs $cfg)
$baseline = [ordered]@{
    createdAt        = (Get-Date).ToString('s')
    mode             = $mode
    tests            = @($tests | ForEach-Object { $_.Name })
    coverage         = $files
    totals           = $totals
    productionHashes = $prodHashes
    testsHash        = (Get-TgTestsHash $cfg)
}
Write-TgJson (Join-Path $reports 'baseline/baseline.json') $baseline
Remove-Item -LiteralPath $work -Recurse -Force

$lineTxt = "$($totals.LinePct)% ($($totals.LinesCovered)/$($totals.LinesTotal))"
if ($mode -eq 'none') { $lineTxt = 'not measured (mutation-only mode)' }
$branchTxt = 'n/a (tool reports line coverage only)'
if ($null -ne $totals.BranchPct) { $branchTxt = "$($totals.BranchPct)% ($($totals.BranchesCovered)/$($totals.BranchesTotal))" }
$md = @"
# Baseline

- Created: $($baseline.createdAt)
- Tests: $($tests.Count)
- Mode: $mode
- Line coverage: $lineTxt
- Branch coverage: $branchTxt
- Production files hashed: $($prodHashes.Count)

## Coverage by file

| File | Covered | Total | % |
|---|---:|---:|---:|
"@
foreach ($p in $files.PSObject.Properties) {
    $c = @(ConvertTo-TgArray $p.Value.covered).Count; $u = @(ConvertTo-TgArray $p.Value.uncovered).Count
    $pct = 0; if (($c + $u) -gt 0) { $pct = [Math]::Round(100.0 * $c / ($c + $u), 1) }
    $md += "`n| $($p.Name) | $c | $($c + $u) | $pct |"
}
Write-TgText (Join-Path $reports 'baseline/baseline.md') $md
Write-Host ''
Write-Host "BASELINE SAVED: mode=$mode tests=$($tests.Count) line=$lineTxt -> $(Get-TgRelPath (Join-Path $reports 'baseline/baseline.json'))"
exit 0
