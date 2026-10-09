# check_env.ps1 - verify that config.json, MSBuild, test executables and the coverage tool are usable.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-test-gate/scripts/check_env.ps1
. "$PSScriptRoot/common.ps1"

$problems = @()
$cfg = Get-TgConfig
Write-Host "Repository root : $(Get-TgRoot)"

# Build
$customBuild = Get-TgProp (Get-TgProp $cfg 'build') 'command' ''
if ($customBuild) {
    Write-Host "Build           : custom command -> $customBuild"
} else {
    $ms = Find-TgMsBuild $cfg
    if ($ms) { Write-Host "MSBuild         : $ms" } else { $problems += 'MSBuild.exe not found (set build.msbuild or use Developer PowerShell for VS 2022).' }
    foreach ($p in (ConvertTo-TgArray (Get-TgProp (Get-TgProp $cfg 'build') 'project'))) {
        $abs = Resolve-TgPath $p
        if (Test-Path -LiteralPath $abs) { Write-Host "Project         : $p" } else { $problems += "build.project not found: $p" }
    }
}

# Coverage tool
$requested = [string](Get-TgProp (Get-TgProp $cfg 'coverage') 'tool' 'auto')
$tool = Get-TgCoverageMode $cfg
if ($tool -eq 'custom') {
    Write-Host "Coverage        : custom command"
} elseif ($tool -eq 'OpenCppCoverage') {
    $occ = Find-TgOpenCppCoverage $cfg
    if ($occ) { Write-Host "OpenCppCoverage : $occ" } else { $problems += 'coverage.tool is OpenCppCoverage but OpenCppCoverage.exe was not found. Install it, or set coverage.tool to "auto" or "none".' }
} else {
    Write-Host "Coverage        : NONE -> mutation-only mode (new tests must catch a mutant that existing tests miss)"
    if ($requested -match '^(?i)auto$') { Write-Host '                  (OpenCppCoverage not found; install it later to enable coverage mode, then re-run baseline.ps1)' }
}
if ($tool -ne 'none') {
    foreach ($s in (ConvertTo-TgArray (Get-TgProp (Get-TgProp $cfg 'coverage') 'sources' @()))) {
        if (-not (Test-Path -LiteralPath (Resolve-TgPath $s))) { $problems += "coverage.sources path not found: $s" }
    }
}

# Paths
foreach ($d in (Get-TgProductionDirs $cfg)) { if (-not (Test-Path -LiteralPath (Resolve-TgPath $d))) { $problems += "paths.production not found: $d" } }
foreach ($d in (Get-TgTestDirs $cfg)) { if (-not (Test-Path -LiteralPath (Resolve-TgPath $d))) { $problems += "paths.tests not found: $d (create it or fix config)" } }

# Executables (may not exist before first build)
foreach ($e in (Get-TgTestExecutables $cfg)) {
    if (Test-Path -LiteralPath $e) {
        Write-Host "Test exe        : $(Get-TgRelPath $e)"
        $pdb = [System.IO.Path]::ChangeExtension($e, '.pdb')
        if ($script:TgIsWindows -and $tool -eq 'OpenCppCoverage' -and -not (Test-Path -LiteralPath $pdb)) {
            Write-Host "  WARNING: $([System.IO.Path]::GetFileName($pdb)) not found next to the exe. OpenCppCoverage needs PDBs (Linker > Debugging > Generate Debug Info)."
        }
    } else {
        Write-Host "Test exe        : $(Get-TgRelPath $e)  (not built yet)"
    }
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) { Write-Host "git             : $($git.Source)" } else { Write-Host 'git             : not found (optional)' }

if (Test-TgSeamApproved) { Write-Host 'Seam approval   : PRESENT (.github/testgen/seam-approved) - production edits are currently allowed' }

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host 'PROBLEMS:'
    foreach ($p in $problems) { Write-Host " - $p" }
    exit 1
}
Write-Host ''
Write-Host 'ENVIRONMENT OK'
exit 0
