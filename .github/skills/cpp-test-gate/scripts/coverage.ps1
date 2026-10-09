# coverage.ps1 - measure current coverage and list uncovered lines (with source) for the target files.
# Output: <reports>/coverage/uncovered.md (read this to decide which tests to write next)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/coverage.ps1 -Target src/foo.cpp,src/bar [-NoBuild] [-MaxLinesPerFile 150]
param([string[]]$Target = @(), [switch]$NoBuild, [int]$MaxLinesPerFile = 150)
. "$PSScriptRoot/common.ps1"

$cfg = Get-TgConfig
if ((Get-TgCoverageMode $cfg) -eq 'none') {
    Write-Host 'COVERAGE DISABLED: no coverage tool (coverage.tool is none, or auto without OpenCppCoverage).'
    Write-Host 'Mutation-only mode: find weak spots with the cpp-mutation skill (mutate.ps1 -> survivors.md) instead of uncovered.md.'
    exit 4
}
$reports = Get-TgReportsDir $cfg
$work = Join-Path $reports 'coverage/work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

# Accept comma-separated values passed as a single string
$targets = @()
foreach ($t in $Target) { foreach ($x in ($t -split ',')) { if ($x.Trim()) { $targets += $x.Trim().Replace('\', '/') } } }

if (-not $NoBuild) {
    $b = Invoke-TgBuild $cfg
    if ($b.TimedOut -or $b.ExitCode -ne 0) { Write-Host 'BUILD FAILED'; Write-Host (Get-TgTail $b.Output 60); exit 2 }
}

$model = Get-TgCoverage -Cfg $cfg -WorkDir $work
$files = ConvertTo-TgObject (ConvertTo-TgCoverageJson $model)
Write-TgJson (Join-Path $reports 'coverage/current.json') ([ordered]@{ createdAt = (Get-Date).ToString('s'); coverage = $files })
Remove-Item -LiteralPath $work -Recurse -Force

$baseline = Read-TgJson (Join-Path $reports 'baseline/baseline.json')
$baseSet = $null
if ($baseline) { $baseSet = Get-TgCoveredSet $baseline.coverage }

function Format-Ranges([int[]]$nums) {
    $out = @(); if ($nums.Count -eq 0) { return '' }
    $s = $nums[0]; $p = $nums[0]
    for ($i = 1; $i -lt $nums.Count; $i++) {
        if ($nums[$i] -eq $p + 1) { $p = $nums[$i]; continue }
        if ($s -eq $p) { $out += "$s" } else { $out += "$s-$p" }
        $s = $nums[$i]; $p = $nums[$i]
    }
    if ($s -eq $p) { $out += "$s" } else { $out += "$s-$p" }
    return ($out -join ', ')
}

$totals = Get-TgCoverageTotals $files
$md = "# Uncovered code report`n`n- Generated: $((Get-Date).ToString('s'))`n- Overall line coverage: $($totals.LinePct)% ($($totals.LinesCovered)/$($totals.LinesTotal))`n"
if ($null -ne $totals.BranchPct) { $md += "- Overall branch coverage: $($totals.BranchPct)%`n" }
if ($baseline) { $md += "- Baseline line coverage: $($baseline.totals.LinePct)%`n" }
if ($targets.Count -gt 0) { $md += "- Targets: $($targets -join ', ')`n" }
$md += "`n" + 'Lines marked >> are not executed by any test. Lines marked ~~ have partially covered branches.' + "`n"
$md += 'Note: closing braces and else lines may show as uncovered because of compiler-generated code; ignore those.' + "`n"

$shown = 0
foreach ($p in $files.PSObject.Properties) {
    $rel = $p.Name
    if ($targets.Count -gt 0 -and -not (Test-TgUnderPrefix $rel $targets)) { continue }
    $unc = @(ConvertTo-TgArray $p.Value.uncovered | ForEach-Object { [int]$_ } | Sort-Object)
    $cov = @(ConvertTo-TgArray $p.Value.covered).Count
    $partial = @()
    foreach ($b in (ConvertTo-TgArray $p.Value.branches)) { if ([int]$b[1] -lt [int]$b[2]) { $partial += [int]$b[0] } }
    $total = $cov + $unc.Count
    $pct = 0; if ($total -gt 0) { $pct = [Math]::Round(100.0 * $cov / $total, 1) }
    $shown++
    $md += "`n## $rel  ($pct% lines, $cov/$total)`n"
    if ($unc.Count -eq 0 -and $partial.Count -eq 0) { $md += "`nFully covered.`n"; continue }
    if ($unc.Count -gt 0) { $md += "`nUncovered lines: $(Format-Ranges $unc)`n" }
    if ($partial.Count -gt 0) { $md += "Partial branches at lines: $(Format-Ranges ([int[]]$partial))`n" }
    $src = Get-TgSourceLines (Resolve-TgPath $rel)
    if ($src.Count -eq 0) { continue }
    $mark = @{}
    foreach ($n in $unc) { $mark[$n] = '>>' }
    foreach ($n in $partial) { if (-not $mark.ContainsKey($n)) { $mark[$n] = '~~' } }
    # print each uncovered region with 2 lines of context
    $want = New-Object 'System.Collections.Generic.SortedSet[int]'
    foreach ($n in $mark.Keys) { for ($k = $n - 2; $k -le $n + 2; $k++) { if ($k -ge 1 -and $k -le $src.Count) { [void]$want.Add($k) } } }
    $md += "`n``````cpp`n"
    $prev = -1; $printed = 0
    foreach ($k in $want) {
        if ($printed -ge $MaxLinesPerFile) { $md += "... (truncated, raise -MaxLinesPerFile)`n"; break }
        if ($prev -ne -1 -and $k -ne $prev + 1) { $md += "...`n" }
        $m = '  '; if ($mark.ContainsKey($k)) { $m = $mark[$k] }
        $md += ('{0} {1,5}: {2}' -f $m, $k, $src[$k - 1]) + "`n"
        $prev = $k; $printed++
    }
    $md += "``````"
    $md += "`n"
}
if ($shown -eq 0) {
    $md += "`nNo measured file matched the targets. Check coverage.sources in config.json and the -Target paths (repo-relative).`n"
}
$outMd = Join-Path $reports 'coverage/uncovered.md'
Write-TgText $outMd $md
Write-Host "COVERAGE: line=$($totals.LinePct)% ($($totals.LinesCovered)/$($totals.LinesTotal)); files reported=$shown"
Write-Host "REPORT: $(Get-TgRelPath $outMd)"
exit 0
