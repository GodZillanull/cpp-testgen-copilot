# gate.ps1 - TestGen-LLM style acceptance gate for newly added tests.
#
#  A batch of new tests is accepted only if ALL of these hold:
#   1. Build succeeds.
#   2. No test that existed in the baseline was removed or renamed.
#   3. Production code is unchanged since the baseline (unless a human created .github/testgen/seam-approved).
#   4. All tests pass N times in a row with --gtest_shuffle (flaky / failing tests are rejected).
#   5. Every new (enabled) test adds line/branch coverage over the baseline on its own,
#      OR catches a mutant that no baseline test catches (mutants/results.json, produced with the current tests).
#      In mutation-only mode (no coverage tool) only the second criterion applies.
#   6. Every new DISABLED_ test is referenced in <reports>/bug_suspects.md.
#
#  On PASS the baseline is advanced (unless -NoBaselineUpdate), so the next batch must improve on this one.
#  Writes <reports>/gate/gate-report.md and <reports>/gate/last-gate.json. Exit code 0 = PASS, 1 = FAIL.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/gate.ps1 [-NoBaselineUpdate]
param([switch]$NoBaselineUpdate)
. "$PSScriptRoot/common.ps1"

$cfg = Get-TgConfig
$reports = Get-TgReportsDir $cfg
$gateDir = Join-Path $reports 'gate'
$work = Join-Path $gateDir 'work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$baselinePath = Join-Path $reports 'baseline/baseline.json'
$baseline = Read-TgJson $baselinePath
if ($null -eq $baseline) { Write-Host 'NO BASELINE. Run baseline.ps1 first.'; exit 1 }

$repeat = [int](Get-TgProp (Get-TgProp $cfg 'tests') 'repeat' 5)
$gateCfg = Get-TgProp $cfg 'gate'
$requireGain = [bool](Get-TgProp $gateCfg 'requireCoverageGainPerTest' $true)
$maxPerTest = [int](Get-TgProp $gateCfg 'maxPerTestCoverageRuns' 40)

$reasons = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList
$testsHashAtStart = Get-TgTestsHash $cfg
$result = [ordered]@{ verdict = 'FAIL'; createdAt = (Get-Date).ToString('s'); testsHash = $testsHashAtStart }

function Finish([string]$Verdict) {
    $result.verdict = $Verdict
    $result.reasons = @($reasons)
    $result.notes = @($notes)
    Write-TgJson (Join-Path $gateDir 'last-gate.json') $result
    $md = "# Gate report`n`n- Verdict: **$Verdict**`n- Time: $($result.createdAt)`n"
    if ($reasons.Count -gt 0) { $md += "`n## Rejection reasons`n"; foreach ($r in $reasons) { $md += "- $r`n" } }
    if ($result.Contains('newTests')) {
        $md += "`n## New tests`n`n| Test | Unique new lines | New branches | New mutants caught | Status |`n|---|---:|---:|---|---|`n"
        foreach ($t in $result.newTests) { $md += "| $($t.name) | $($t.newLines) | $($t.newBranches) | $($t.killer) | $($t.status) |`n" }
    }
    if ($result.Contains('coverage')) {
        $c = $result.coverage
        $md += "`n## Coverage`n`n- Baseline: $($c.baselineLinePct)% -> Now: $($c.currentLinePct)%`n- Newly covered lines vs baseline: $($c.newlyCoveredLines)`n- Lines no longer covered: $($c.lostLines)`n"
    }
    if ($notes.Count -gt 0) { $md += "`n## Notes`n"; foreach ($n in $notes) { $md += "- $n`n" } }
    Write-TgText (Join-Path $gateDir 'gate-report.md') $md
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host ''
    Write-Host "GATE: $Verdict"
    foreach ($r in $reasons) { Write-Host " - $r" }
    Write-Host "REPORT: $(Get-TgRelPath (Join-Path $gateDir 'gate-report.md'))"
    if ($Verdict -eq 'PASS') { exit 0 } else { exit 1 }
}

# 3. production code unchanged ---------------------------------------------
Write-Host '[1/6] Checking production code is unchanged...'
$prodNow = Get-TgFileHashes -Dirs (Get-TgProductionDirs $cfg)
$prodBase = Get-TgProp $baseline 'productionHashes'
$changed = @()
$baseNames = @{}
if ($prodBase) { foreach ($p in $prodBase.PSObject.Properties) { $baseNames[$p.Name] = $p.Value } }
foreach ($k in $prodNow.Keys) { if (-not $baseNames.ContainsKey($k)) { $changed += "$k (added)" } elseif ($baseNames[$k] -ne $prodNow[$k]) { $changed += "$k (modified)" } }
foreach ($k in $baseNames.Keys) { if (-not $prodNow.Contains($k)) { $changed += "$k (deleted)" } }
$result.productionChanges = $changed
if ($changed.Count -gt 0) {
    if (Test-TgSeamApproved) {
        [void]$notes.Add("Production changes accepted because .github/testgen/seam-approved exists: $($changed -join ', ')")
    } else {
        [void]$reasons.Add("Production code changed without approval: $($changed -join ', '). Revert it, or ask a human to approve the seam (they create .github/testgen/seam-approved).")
    }
}

# 1. build -------------------------------------------------------------------
Write-Host '[2/6] Building...'
$b = Invoke-TgBuild $cfg
if ($b.TimedOut -or $b.ExitCode -ne 0) {
    [void]$reasons.Add('Build failed.')
    $result.buildTail = Get-TgTail $b.Output 60
    Write-Host (Get-TgTail $b.Output 60)
    Finish 'FAIL'
}

# 2. tests removed / new -----------------------------------------------------
Write-Host '[3/6] Comparing test list with baseline...'
$list = @(Get-TgTestList $cfg)
$nowNames = @{}
foreach ($t in $list) { $nowNames[$t.Name] = $t.Exe }
$baseTests = @(ConvertTo-TgArray (Get-TgProp $baseline 'tests'))
$baseLookup = @{}
foreach ($n in $baseTests) { $baseLookup[$n] = $true }
$removed = @($baseTests | Where-Object { -not $nowNames.ContainsKey($_) })
if ($removed.Count -gt 0) { [void]$reasons.Add("Existing tests were removed or renamed (not allowed): $($removed -join ', ')") }
$newTests = @($list | Where-Object { -not $baseLookup.ContainsKey($_.Name) })
Write-Host "      baseline=$($baseTests.Count) now=$($list.Count) new=$($newTests.Count)"
if ($newTests.Count -eq 0) { [void]$notes.Add('No new tests found compared to the baseline.') }

# 6. disabled tests need a bug_suspects entry --------------------------------
$bugFile = Join-Path $reports 'bug_suspects.md'
$bugText = ''
if (Test-Path -LiteralPath $bugFile) { $bugText = [System.IO.File]::ReadAllText($bugFile) }
function Test-Disabled([string]$n) { return ($n -match '(^|[./])DISABLED_') }

# 4. repeated shuffled runs ---------------------------------------------------
Write-Host "[4/6] Running all tests $repeat times with shuffle..."
$run = Invoke-TgTests -Cfg $cfg -Repeat $repeat -Shuffle
$result.testRuns = $run.Runs
if (-not $run.Ok) {
    foreach ($k in $run.Failed.Keys) {
        $cnt = $run.Failed[$k]
        if ($cnt -lt $repeat) { [void]$reasons.Add("FLAKY: $k failed $cnt/$repeat runs. Remove nondeterminism (time, order, shared state, uninitialized memory) or delete the test.") }
        else { [void]$reasons.Add("FAILING: $k failed in every run. If the code is wrong per spec, record it in bug_suspects.md and mark the test DISABLED_; otherwise fix the test. Never weaken an assertion to match suspicious behaviour.") }
    }
    foreach ($r in $run.Runs) { if ($r.Status -eq 'CRASHED' -or $r.Status -eq 'TIMEOUT') { [void]$reasons.Add("$($r.Exe) $($r.Status) (exit $($r.ExitCode)). Tail:`n$($r.Tail)") } }
    Finish 'FAIL'
}

# 5. coverage gain / unique mutant kills ------------------------------------------
$mode = Get-TgCoverageMode $cfg
$baseMode = [string](Get-TgProp $baseline 'mode' 'OpenCppCoverage')
$result.mode = $mode
if ($mode -ne $baseMode) {
    [void]$reasons.Add("Coverage mode changed (baseline: $baseMode, now: $mode). A human must re-run baseline.ps1.")
    Finish 'FAIL'
}

$nowFiles = $baseline.coverage
$nowTotals = $baseline.totals
$baseSet = $null; $baseBr = @{}
if ($mode -ne 'none') {
    Write-Host '[5/6] Measuring total coverage...'
    $model = Get-TgCoverage -Cfg $cfg -WorkDir (Join-Path $work 'all')
    $nowFiles = ConvertTo-TgObject (ConvertTo-TgCoverageJson $model)
    $nowTotals = Get-TgCoverageTotals $nowFiles
    $baseSet = Get-TgCoveredSet $baseline.coverage
    $nowSet = Get-TgCoveredSet $nowFiles
    $baseBr = Get-TgBranchSet $baseline.coverage
    $gained = 0; foreach ($k in $nowSet) { if (-not $baseSet.Contains($k)) { $gained++ } }
    $lost = @(); foreach ($k in $baseSet) { if (-not $nowSet.Contains($k)) { $lost += $k } }
    $result.coverage = [ordered]@{ baselineLinePct = $baseline.totals.LinePct; currentLinePct = $nowTotals.LinePct; newlyCoveredLines = $gained; lostLines = $lost.Count }
    if ($lost.Count -gt 0) { [void]$notes.Add("Lines covered in baseline but not now (check for nondeterminism): $(($lost | Select-Object -First 15) -join ', ')") }
} else {
    Write-Host '[5/6] Mutation-only mode: coverage is not measured.'
}

# mutants killed by a new test and by no baseline test, measured against the current test sources
$curTestsHash = Get-TgTestsHash $cfg
$mres = Read-TgJson (Join-Path $reports 'mutants/results.json')
$uk = Get-TgUniqueKills -Results $mres -BaselineTests $baseLookup -CurrentTestsHash $curTestsHash
$killerLookup = @{}
foreach ($k in $uk.Kills.Keys) { $killerLookup[$k] = (@($uk.Kills[$k]) -join ',') }
if ($uk.Stale -gt 0) { [void]$notes.Add("$($uk.Stale) killed mutant result(s) were produced with older test code and were ignored. Run mutate.ps1 -OnlySurvivors after the last test change to refresh them.") }

Write-Host "[6/6] Checking the contribution of $($newTests.Count) new test(s)..."
$rows = @()
$idx = 0
foreach ($t in $newTests) {
    $row = [ordered]@{ name = $t.Name; newLines = 0; newBranches = 0; killer = ''; status = '' }
    if ($killerLookup.ContainsKey($t.Name)) { $row.killer = $killerLookup[$t.Name] }
    if (Test-Disabled $t.Name) {
        $plain = ($t.Name -replace 'DISABLED_', '')
        $suiteTest = $plain.Split('/')[0]
        if ($bugText -and ($bugText.Contains($plain) -or $bugText.Contains($t.Name) -or $bugText.Contains($suiteTest))) { $row.status = 'DISABLED (bug suspect recorded)' }
        else {
            $row.status = 'REJECT: DISABLED without bug_suspects.md entry'
            [void]$reasons.Add("$($t.Name) is DISABLED but not referenced in bug_suspects.md.")
        }
        $rows += [pscustomobject]$row; continue
    }
    if ($mode -eq 'none') {
        $row.newLines = '-'; $row.newBranches = '-'
        if ($row.killer) { $row.status = 'ACCEPT (catches a mutant no existing test catches)' }
        elseif ($requireGain) {
            $row.status = 'REJECT: catches no new mutant'
            [void]$reasons.Add("$($t.Name) catches no mutant that the existing tests miss (mutation-only mode). Write mutants for the behaviour it checks and run mutate.ps1 -OnlySurvivors; if it still kills nothing new, delete it.")
        } else { $row.status = 'ACCEPT (gain not required)' }
        $rows += [pscustomobject]$row; continue
    }
    $idx++
    if ($idx -gt $maxPerTest) {
        $row.status = 'NOT MEASURED (limit gate.maxPerTestCoverageRuns)'
        [void]$notes.Add("Per-test coverage limit reached; $($t.Name) was not measured individually. Submit smaller batches.")
        $rows += [pscustomobject]$row; continue
    }
    $tm = Get-TgCoverage -Cfg $cfg -WorkDir (Join-Path $work ("t" + $idx)) -OnlyExe $t.Exe -Filter $t.Name
    $tf = ConvertTo-TgObject (ConvertTo-TgCoverageJson $tm)
    $ts = Get-TgCoveredSet $tf
    foreach ($k in $ts) { if (-not $baseSet.Contains($k)) { $row.newLines++ } }
    $tb = Get-TgBranchSet $tf
    foreach ($k in $tb.Keys) {
        $bb = 0; if ($baseBr.ContainsKey($k)) { $bb = $baseBr[$k] }
        if ($tb[$k] -gt $bb) { $row.newBranches += ($tb[$k] - $bb) }
    }
    if ($row.newLines -gt 0 -or $row.newBranches -gt 0) { $row.status = 'ACCEPT (coverage gain)' }
    elseif ($row.killer) { $row.status = 'ACCEPT (catches a mutant no existing test catches)' }
    elseif ($requireGain) {
        $row.status = 'REJECT: no coverage gain, catches no new mutant'
        [void]$reasons.Add("$($t.Name) adds no coverage over the baseline and catches no mutant that existing tests miss. Delete it, or strengthen it to target a surviving mutant (mutate.ps1 -OnlySurvivors).")
    } else { $row.status = 'ACCEPT (gain not required)' }
    $rows += [pscustomobject]$row
}
$result.newTests = $rows

if ($reasons.Count -gt 0) { Finish 'FAIL' }

if (-not $NoBaselineUpdate) {
    $bl = [ordered]@{
        createdAt        = (Get-Date).ToString('s')
        previous         = $baseline.createdAt
        mode             = $mode
        tests            = @($list | ForEach-Object { $_.Name })
        coverage         = $nowFiles
        totals           = $nowTotals
        productionHashes = $prodNow
        testsHash        = (Get-TgTestsHash $cfg)
    }
    Write-TgJson $baselinePath $bl
    [void]$notes.Add('Baseline advanced to the current state.')
}
Finish 'PASS'
