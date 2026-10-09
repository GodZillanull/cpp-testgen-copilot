# mutate.ps1 - LLM-proposed mutation testing for MSVC / .vcxproj projects (Meta ACH style).
#
# The agent writes candidate faults to <reports>/mutants/mutants.json:
# {
#   "target": "src/foo.cpp",
#   "mutants": [
#     { "id": "M1", "file": "src/foo.cpp", "line": 42,
#       "original": "if (count > limit)", "mutated": "if (count >= limit)",
#       "fault": "off-by-one at the limit boundary" }
#   ]
# }
# Rules: single-line snippets, "original" must appear exactly once within +-3 lines of "line".
# Mark a surviving mutant as equivalent with  "equivalent": true, "equivalentReason": "..."  (it is then skipped).
#
# For each mutant: apply -> build -> run tests -> restore original bytes (always).
#   KILLED      : a test failed (or crashed / timed out)  -> the test suite detects this fault
#   SURVIVED    : all tests passed                         -> write a test that kills it
#   BUILD_ERROR : the mutant does not compile              -> invalid mutant, ignored
#   INVALID     : snippet not found / not unique / not in production paths
#
# Outputs: <reports>/mutants/results.json, survivors.md, killers.json (test -> killed mutant ids; read by gate.ps1)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-mutation/scripts/mutate.ps1 [-Ids M1,M2] [-OnlySurvivors]
param([string[]]$Ids = @(), [switch]$OnlySurvivors, [string]$MutantsFile = '')
. "$PSScriptRoot/../../cpp-test-gate/scripts/common.ps1"

$cfg = Get-TgConfig
$reports = Get-TgReportsDir $cfg
$mdir = Join-Path $reports 'mutants'
$backupDir = Join-Path $mdir '.backup'
if (-not $MutantsFile) { $MutantsFile = Join-Path $mdir 'mutants.json' } else { $MutantsFile = Resolve-TgPath $MutantsFile }
$mcfg = Get-TgProp $cfg 'mutation'
$maxRun = [int](Get-TgProp $mcfg 'maxMutantsPerRun' 20)
$testTimeout = [int](Get-TgProp $mcfg 'testTimeoutSec' 300)

# ---- crash recovery: restore any leftover backups from an interrupted run ----
if (Test-Path -LiteralPath $backupDir) {
    foreach ($m in @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -File)) {
        $info = Read-TgJson $m.FullName
        $bak = [System.IO.Path]::ChangeExtension($m.FullName, '.bak')
        if ($info -and (Test-Path -LiteralPath $bak)) {
            [System.IO.File]::WriteAllBytes((Resolve-TgPath $info.file), [System.IO.File]::ReadAllBytes($bak))
            Write-Host "RECOVERED: restored $($info.file) from an interrupted run"
        }
        Remove-Item -LiteralPath $m.FullName, $bak -Force -ErrorAction SilentlyContinue
    }
}
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$doc = Read-TgJson $MutantsFile
if ($null -eq $doc) { Write-Host "No mutants file: $(Get-TgRelPath $MutantsFile)"; exit 1 }
$mutants = @(ConvertTo-TgArray (Get-TgProp $doc 'mutants'))
$idFilter = @()
foreach ($i in $Ids) { foreach ($x in ($i -split ',')) { if ($x.Trim()) { $idFilter += $x.Trim() } } }

$prev = Read-TgJson (Join-Path $mdir 'results.json')
$prevStatus = @{}
if ($prev) { foreach ($r in (ConvertTo-TgArray $prev.results)) { $prevStatus[[string]$r.id] = [string]$r.status } }

$selected = @()
foreach ($m in $mutants) {
    $id = [string](Get-TgProp $m 'id' '')
    if ($idFilter.Count -gt 0 -and ($idFilter -notcontains $id)) { continue }
    if ($OnlySurvivors -and $prevStatus.ContainsKey($id) -and $prevStatus[$id] -ne 'SURVIVED') { continue }
    $selected += $m
}
if ($selected.Count -gt $maxRun) {
    Write-Host "NOTE: $($selected.Count) mutants selected, running only the first $maxRun (mutation.maxMutantsPerRun)."
    $selected = $selected[0..($maxRun - 1)]
}

# ---- sanity: original code must build and pass ----
Write-Host 'Checking that the unmutated code builds and passes...'
$b0 = Invoke-TgBuild $cfg
if ($b0.TimedOut -or $b0.ExitCode -ne 0) { Write-Host 'BUILD FAILED on unmutated code. Fix the build first.'; Write-Host (Get-TgTail $b0.Output 40); exit 2 }
$t0 = Invoke-TgTests -Cfg $cfg -TimeoutSec $testTimeout
if (-not $t0.Ok) { Write-Host 'TESTS FAIL on unmutated code. Mutation results would be meaningless.'; exit 2 }

$prodDirs = Get-TgProductionDirs $cfg
$results = @()
$n = 0
foreach ($m in $selected) {
    $n++
    $id = [string](Get-TgProp $m 'id' "#$n")
    $rel = ([string](Get-TgProp $m 'file' '')).Replace('\', '/')
    $line = [int](Get-TgProp $m 'line' 0)
    $orig = [string](Get-TgProp $m 'original' '')
    $mut = [string](Get-TgProp $m 'mutated' '')
    $row = [ordered]@{ id = $id; file = $rel; line = $line; original = $orig; mutated = $mut; fault = [string](Get-TgProp $m 'fault' ''); status = ''; killedBy = @(); detail = '' }
    Write-Host ("[{0}/{1}] {2} {3}:{4}" -f $n, $selected.Count, $id, $rel, $line)

    if (Get-TgProp $m 'equivalent' $false) { $row.status = 'EQUIVALENT'; $row.detail = [string](Get-TgProp $m 'equivalentReason' ''); $results += [pscustomobject]$row; continue }
    if (-not (Test-TgUnderPrefix $rel $prodDirs)) { $row.status = 'INVALID'; $row.detail = 'file is not under paths.production'; $results += [pscustomobject]$row; continue }
    $abs = Resolve-TgPath $rel
    if (-not (Test-Path -LiteralPath $abs)) { $row.status = 'INVALID'; $row.detail = 'file not found'; $results += [pscustomobject]$row; continue }
    if (-not $orig -or $orig -eq $mut -or $orig.Contains("`n") -or $mut.Contains("`n")) { $row.status = 'INVALID'; $row.detail = 'original/mutated must be different single-line snippets'; $results += [pscustomobject]$row; continue }

    $src = Read-TgSource $abs
    $text = $src.Text
    # locate the window [line-3, line+3]
    $starts = New-Object System.Collections.Generic.List[int]
    $starts.Add(0)
    for ($i = 0; $i -lt $text.Length; $i++) { if ($text[$i] -eq "`n") { $starts.Add($i + 1) } }
    $from = [Math]::Max(1, $line - 3); $to = [Math]::Min($starts.Count, $line + 3)
    if ($line -lt 1 -or $line -gt $starts.Count) { $row.status = 'INVALID'; $row.detail = "line out of range (file has $($starts.Count) lines)"; $results += [pscustomobject]$row; continue }
    $wStart = $starts[$from - 1]
    $wEnd = $text.Length; if ($to -lt $starts.Count) { $wEnd = $starts[$to] }
    $window = $text.Substring($wStart, $wEnd - $wStart)
    $first = $window.IndexOf($orig, [System.StringComparison]::Ordinal)
    if ($first -lt 0) { $row.status = 'INVALID'; $row.detail = 'original snippet not found within +-3 lines (copy it exactly, including spacing)'; $results += [pscustomobject]$row; continue }
    if ($window.IndexOf($orig, $first + 1, [System.StringComparison]::Ordinal) -ge 0) { $row.status = 'INVALID'; $row.detail = 'original snippet is not unique within +-3 lines; make it longer'; $results += [pscustomobject]$row; continue }
    $pos = $wStart + $first
    $newText = $text.Substring(0, $pos) + $mut + $text.Substring($pos + $orig.Length)

    $bakBase = Join-Path $backupDir ($id -replace '[^A-Za-z0-9_-]', '_')
    [System.IO.File]::WriteAllBytes($bakBase + '.bak', $src.Bytes)
    Write-TgJson ($bakBase + '.json') ([ordered]@{ file = $rel })
    try {
        Write-TgSource -Path $abs -Src $src -NewText $newText
        $b = Invoke-TgBuild $cfg
        if ($b.TimedOut -or $b.ExitCode -ne 0) {
            $row.status = 'BUILD_ERROR'; $row.detail = (Get-TgTail $b.Output 8)
        } else {
            $t = Invoke-TgTests -Cfg $cfg -TimeoutSec $testTimeout
            if ($t.Ok) { $row.status = 'SURVIVED' }
            else {
                $row.status = 'KILLED'
                $row.killedBy = @($t.Failed.Keys | Sort-Object)
                $bad = @($t.Runs | Where-Object { $_.Status -eq 'CRASHED' -or $_.Status -eq 'TIMEOUT' })
                if ($bad.Count -gt 0) { $row.detail = 'killed by ' + (($bad | ForEach-Object { $_.Status }) -join ',') }
            }
        }
    } finally {
        [System.IO.File]::WriteAllBytes($abs, $src.Bytes)
        Remove-Item -LiteralPath ($bakBase + '.bak'), ($bakBase + '.json') -Force -ErrorAction SilentlyContinue
    }
    Write-Host "      -> $($row.status)"
    $results += [pscustomobject]$row
}

# rebuild the original so binaries match the sources again
Write-Host 'Rebuilding unmutated code...'
[void](Invoke-TgBuild $cfg)

# merge with previous results (by id) so partial re-runs keep history
$merged = [ordered]@{}
if ($prev) { foreach ($r in (ConvertTo-TgArray $prev.results)) { $merged[[string]$r.id] = $r } }
foreach ($r in $results) { $merged[[string]$r.id] = $r }
$all = @($merged.Values)

$killed = @($all | Where-Object { $_.status -eq 'KILLED' }).Count
$surv = @($all | Where-Object { $_.status -eq 'SURVIVED' })
$equiv = @($all | Where-Object { $_.status -eq 'EQUIVALENT' }).Count
$valid = $killed + $surv.Count
$score = $null; if ($valid -gt 0) { $score = [Math]::Round(100.0 * $killed / $valid, 1) }
Write-TgJson (Join-Path $mdir 'results.json') ([ordered]@{ updatedAt = (Get-Date).ToString('s'); score = $score; killed = $killed; survived = $surv.Count; equivalent = $equiv; results = $all })

# killers.json: test name -> mutant ids it kills (used by gate.ps1 to accept tests without new coverage)
$k = [ordered]@{}
foreach ($r in $all) {
    if ($r.status -ne 'KILLED') { continue }
    foreach ($tn in (ConvertTo-TgArray $r.killedBy)) {
        if (-not $k.Contains($tn)) { $k[$tn] = @() }
        $k[$tn] = @($k[$tn]) + @([string]$r.id)
    }
}
Write-TgJson (Join-Path $mdir 'killers.json') $k

$md = "# Mutation results`n`n- Mutation score: $score% (killed $killed / valid $valid; equivalent $equiv)`n`n"
$md += "| ID | Location | Status | Fault | Killed by / detail |`n|---|---|---|---|---|`n"
foreach ($r in $all) {
    $d = (@(ConvertTo-TgArray $r.killedBy) -join ' ')
    if (-not $d) { $d = ([string]$r.detail).Replace("`r", ' ').Replace("`n", ' ') }
    if ($d.Length -gt 120) { $d = $d.Substring(0, 120) + '...' }
    $md += "| $($r.id) | $($r.file):$($r.line) | $($r.status) | $($r.fault) | $d |`n"
}
if ($surv.Count -gt 0) {
    $md += "`n## Surviving mutants (write a test that FAILS on the mutated code and PASSES on the original)`n"
    foreach ($r in $surv) { $md += "`n### $($r.id) - $($r.file):$($r.line)`n- Fault: $($r.fault)`n- Original: ``$($r.original)```n- Mutated: ``$($r.mutated)```n" }
}
Write-TgText (Join-Path $mdir 'survivors.md') $md
Write-Host ''
Write-Host "MUTATION SCORE: $score% (killed=$killed survived=$($surv.Count) equivalent=$equiv)"
Write-Host "REPORT: $(Get-TgRelPath (Join-Path $mdir 'survivors.md'))"
exit 0
