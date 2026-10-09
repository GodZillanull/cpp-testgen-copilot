# common.ps1 - shared helpers for the C++ test generation workflow.
# Dot-source this file:  . "$PSScriptRoot/common.ps1"
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Repository root / platform
# ---------------------------------------------------------------------------
function Find-TgRepoRoot {
    param([string]$Start)
    $d = $Start
    while ($d) {
        if ((Split-Path -Leaf $d) -ne '.github' -and (Test-Path -LiteralPath (Join-Path $d '.github/testgen/config.json'))) {
            return $d
        }
        $parent = Split-Path -Parent $d
        if ($parent -eq $d) { break }
        $d = $parent
    }
    throw "Could not find repository root (a folder containing .github/testgen/config.json) above $Start"
}

$script:TgRoot = Find-TgRepoRoot -Start $PSScriptRoot
$script:TgIsWindows = ($env:OS -eq 'Windows_NT')

function Get-TgRoot { return $script:TgRoot }

# ---------------------------------------------------------------------------
# JSON / file helpers
# ---------------------------------------------------------------------------
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-TgJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    return ($txt | ConvertFrom-Json)
}

function Write-TgJson {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, $script:Utf8NoBom)
}

function Write-TgText {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Get-TgProp {
    # Safe property access on PSCustomObject (StrictMode friendly)
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function ConvertTo-TgArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
function Resolve-TgPath {
    # Relative (to repo root) or absolute -> absolute full path
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $script:TgRoot $Path))
}

function Get-TgRelPath {
    # Absolute -> repo-relative with forward slashes. Returns $null if outside repo.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($script:TgRoot).TrimEnd('\', '/')
    $cmp = [System.StringComparison]::Ordinal
    if ($script:TgIsWindows) { $cmp = [System.StringComparison]::OrdinalIgnoreCase }
    if ($full.Equals($root, $cmp)) { return '' }
    if ($full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, $cmp) -or $full.StartsWith($root + '/', $cmp)) {
        return $full.Substring($root.Length + 1).Replace('\', '/')
    }
    return $null
}

function Test-TgUnderPrefix {
    # Is repo-relative path $Rel under one of the repo-relative prefixes?
    param([string]$Rel, [string[]]$Prefixes)
    if ($null -eq $Rel) { return $false }
    $r = $Rel.Replace('\', '/').TrimStart('/')
    foreach ($p in $Prefixes) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $q = $p.Replace('\', '/').TrimEnd('/')
        while ($q.StartsWith('./')) { $q = $q.Substring(2) }
        $q = $q.TrimStart('/')
        if ($script:TgIsWindows) {
            if ($r.Equals($q, [System.StringComparison]::OrdinalIgnoreCase) -or $r.StartsWith($q + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        } else {
            if ($r -ceq $q -or $r.StartsWith($q + '/', [System.StringComparison]::Ordinal)) { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
function Get-TgConfig {
    $path = Join-Path $script:TgRoot '.github/testgen/config.json'
    $cfg = Read-TgJson $path
    if ($null -eq $cfg) { throw "Config not found or empty: $path" }
    return $cfg
}

function Get-TgReportsDir {
    param($Cfg)
    $r = Get-TgProp (Get-TgProp $Cfg 'paths') 'reports' 'test-reports'
    $abs = Resolve-TgPath $r
    if (-not (Test-Path -LiteralPath $abs)) { New-Item -ItemType Directory -Path $abs -Force | Out-Null }
    return $abs
}

function Get-TgCppExtensions { return @('.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.hxx', '.inl', '.ipp') }

# ---------------------------------------------------------------------------
# Process execution (with timeout, captured output)
# ---------------------------------------------------------------------------
function Join-TgArgs {
    param([string[]]$Arguments)
    $parts = @()
    foreach ($a in $Arguments) {
        if ($null -eq $a) { continue }
        if ($a -eq '') { $parts += '""'; continue }
        if ($a -match '[\s"]') {
            $esc = [regex]::Replace($a, '(\\*)"', '$1$1\"')
            $esc = [regex]::Replace($esc, '(\\+)$', '$1$1')
            $parts += '"' + $esc + '"'
        } else {
            $parts += $a
        }
    }
    return ($parts -join ' ')
}

function Invoke-TgProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $script:TgRoot,
        [int]$TimeoutSec = 600
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-TgArgs $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $p.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
        $timedOut = $true
        try { $p.Kill() } catch { }
        try { [void]$p.WaitForExit(10000) } catch { }
    } else {
        $p.WaitForExit()
    }
    $sw.Stop()
    $out = ''; $err = ''
    try { if ($outTask.Wait(10000)) { $out = $outTask.Result } } catch { }
    try { if ($errTask.Wait(10000)) { $err = $errTask.Result } } catch { }
    $code = -1
    if (-not $timedOut) { $code = $p.ExitCode }
    return [pscustomobject]@{
        ExitCode = $code
        TimedOut = $timedOut
        Output   = ($out + $(if ($err) { "`n" + $err } else { '' }))
        Seconds  = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Invoke-TgShell {
    # Runs a command line through cmd.exe (Windows) or /bin/sh (others)
    param([string]$CommandLine, [string]$WorkingDirectory = $script:TgRoot, [int]$TimeoutSec = 600)
    if ($script:TgIsWindows) {
        return Invoke-TgProcessRaw -FilePath $env:ComSpec -RawArguments ('/d /s /c "' + $CommandLine + '"') -WorkingDirectory $WorkingDirectory -TimeoutSec $TimeoutSec
    } else {
        return Invoke-TgProcess -FilePath '/bin/sh' -Arguments @('-c', $CommandLine) -WorkingDirectory $WorkingDirectory -TimeoutSec $TimeoutSec
    }
}

function Invoke-TgProcessRaw {
    param([string]$FilePath, [string]$RawArguments, [string]$WorkingDirectory, [int]$TimeoutSec)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $RawArguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $p.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
        $timedOut = $true
        try { $p.Kill() } catch { }
    } else { $p.WaitForExit() }
    $out = ''; $err = ''
    try { if ($outTask.Wait(10000)) { $out = $outTask.Result } } catch { }
    try { if ($errTask.Wait(10000)) { $err = $errTask.Result } } catch { }
    $code = -1
    if (-not $timedOut) { $code = $p.ExitCode }
    return [pscustomobject]@{ ExitCode = $code; TimedOut = $timedOut; Output = ($out + "`n" + $err); Seconds = 0 }
}

function Get-TgTail {
    param([string]$Text, [int]$Lines = 40)
    if (-not $Text) { return '' }
    $arr = $Text -split "`r?`n"
    if ($arr.Count -le $Lines) { return ($arr -join "`n") }
    return (($arr[($arr.Count - $Lines)..($arr.Count - 1)]) -join "`n")
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
function Find-TgMsBuild {
    param($Cfg)
    $b = Get-TgProp $Cfg 'build'
    $m = Get-TgProp $b 'msbuild' 'auto'
    if ($m -and $m -ne 'auto') { return $m }
    $cmd = Get-Command 'msbuild' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($pf86) {
        $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
            if ($found) { return $found }
        }
    }
    return $null
}

function Invoke-TgBuild {
    param($Cfg)
    $b = Get-TgProp $Cfg 'build'
    $timeout = [int](Get-TgProp $b 'timeoutSec' 1800)
    $custom = Get-TgProp $b 'command' ''
    if (-not [string]::IsNullOrWhiteSpace($custom)) {
        return Invoke-TgShell -CommandLine $custom -TimeoutSec $timeout
    }
    $msbuild = Find-TgMsBuild $Cfg
    if (-not $msbuild) { throw 'MSBuild.exe not found. Set build.msbuild in .github/testgen/config.json or run from a Developer PowerShell.' }
    $projects = ConvertTo-TgArray (Get-TgProp $b 'project')
    if ($projects.Count -eq 0) { throw 'build.project is empty in config.json' }
    $last = $null
    foreach ($proj in $projects) {
        $argv = @((Resolve-TgPath $proj),
            ('/p:Configuration=' + (Get-TgProp $b 'configuration' 'Debug')),
            ('/p:Platform=' + (Get-TgProp $b 'platform' 'x64')))
        $argv += (ConvertTo-TgArray (Get-TgProp $b 'extraArgs' @('/m', '/nologo', '/v:minimal')))
        $last = Invoke-TgProcess -FilePath $msbuild -Arguments $argv -TimeoutSec $timeout
        if ($last.TimedOut -or $last.ExitCode -ne 0) { return $last }
    }
    return $last
}

# ---------------------------------------------------------------------------
# Google Test helpers
# ---------------------------------------------------------------------------
function Get-TgTestExecutables {
    param($Cfg)
    $t = Get-TgProp $Cfg 'tests'
    $list = @()
    foreach ($e in (ConvertTo-TgArray (Get-TgProp $t 'executables'))) { $list += (Resolve-TgPath $e) }
    if ($list.Count -eq 0) { throw 'tests.executables is empty in config.json' }
    return $list
}

function Get-TgTestWorkDir {
    param($Cfg, [string]$Exe)
    $wd = Get-TgProp (Get-TgProp $Cfg 'tests') 'workingDirectory' ''
    if ([string]::IsNullOrWhiteSpace($wd)) { return (Split-Path -Parent $Exe) }
    return (Resolve-TgPath $wd)
}

function Get-TgTestList {
    # Returns array of @{ Name = 'Suite.Test'; Exe = path }
    param($Cfg)
    $result = @()
    foreach ($exe in (Get-TgTestExecutables $Cfg)) {
        if (-not (Test-Path -LiteralPath $exe)) { throw "Test executable not found: $exe (build first / check tests.executables)" }
        $r = Invoke-TgProcess -FilePath $exe -Arguments @('--gtest_list_tests') -WorkingDirectory (Get-TgTestWorkDir $Cfg $exe) -TimeoutSec 120
        if ($r.TimedOut -or $r.ExitCode -ne 0) { throw "--gtest_list_tests failed for $exe`n$(Get-TgTail $r.Output 20)" }
        $suite = $null
        foreach ($line in ($r.Output -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $body = $line
            $hash = $body.IndexOf('#')
            if ($hash -ge 0) { $body = $body.Substring(0, $hash) }
            if ($line -match '^\S') {
                $s = $body.Trim()
                if ($s.EndsWith('.')) { $suite = $s.Substring(0, $s.Length - 1) } else { $suite = $null }
            } elseif ($suite) {
                $n = $body.Trim()
                if ($n) { $result += [pscustomobject]@{ Name = ($suite + '.' + $n); Exe = $exe } }
            }
        }
    }
    return $result
}

function Get-TgFailedTests {
    # Parses gtest console output. Returns hashtable name -> failure count (one per iteration).
    param([string]$Output)
    $h = @{}
    foreach ($line in ($Output -split "`r?`n")) {
        $m = [regex]::Match($line, '^\[\s+FAILED\s+\]\s+(\S+?)(,| \(\d+ ms\))')
        if ($m.Success -and $m.Groups[2].Value -like ' (*') {
            $n = $m.Groups[1].Value
            if ($n -notmatch '\.') { continue }
            if ($h.ContainsKey($n)) { $h[$n]++ } else { $h[$n] = 1 }
        }
    }
    return $h
}

function Invoke-TgTests {
    # Runs all test executables. Returns summary object.
    param($Cfg, [int]$Repeat = 1, [switch]$Shuffle, [string]$Filter = '', [int]$TimeoutSec = 0)
    $t = Get-TgProp $Cfg 'tests'
    if ($TimeoutSec -le 0) { $TimeoutSec = [int](Get-TgProp $t 'timeoutSec' 600) }
    $extra = ConvertTo-TgArray (Get-TgProp $t 'extraArgs' @())
    $runs = @()
    $allFailed = @{}
    $ok = $true
    foreach ($exe in (Get-TgTestExecutables $Cfg)) {
        $argv = @()
        if ($Repeat -gt 1) { $argv += "--gtest_repeat=$Repeat" }
        if ($Shuffle) { $argv += '--gtest_shuffle'; $argv += '--gtest_random_seed=0' }
        if ($Filter) { $argv += "--gtest_filter=$Filter" }
        $argv += $extra
        $r = Invoke-TgProcess -FilePath $exe -Arguments $argv -WorkingDirectory (Get-TgTestWorkDir $Cfg $exe) -TimeoutSec $TimeoutSec
        $failed = Get-TgFailedTests $r.Output
        foreach ($k in $failed.Keys) { $allFailed[$k] = $failed[$k] }
        $status = 'PASSED'
        if ($r.TimedOut) { $status = 'TIMEOUT' }
        elseif ($r.ExitCode -ne 0 -and $failed.Count -gt 0) { $status = 'FAILED' }
        elseif ($r.ExitCode -ne 0) { $status = 'CRASHED' }
        if ($status -ne 'PASSED') { $ok = $false }
        $runs += [pscustomobject]@{ Exe = (Get-TgRelPath $exe); Status = $status; ExitCode = $r.ExitCode; Seconds = $r.Seconds; Tail = (Get-TgTail $r.Output 30) }
    }
    return [pscustomobject]@{ Ok = $ok; Runs = $runs; Failed = $allFailed; Repeat = $Repeat }
}

# ---------------------------------------------------------------------------
# Coverage (OpenCppCoverage or custom command) -> Cobertura -> normalized model
# Model: hashtable relPath -> @{ Lines = Dictionary[int,int] hits; Branches = Dictionary[int, int[2]] }
# ---------------------------------------------------------------------------
function Find-TgOpenCppCoverage {
    param($Cfg)
    $c = Get-TgProp $Cfg 'coverage'
    $p = Get-TgProp $c 'openCppCoverageExe' 'auto'
    if ($p -and $p -ne 'auto') { return $p }
    $cmd = Get-Command 'OpenCppCoverage' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($cand in @("$env:ProgramFiles\OpenCppCoverage\OpenCppCoverage.exe", "${env:ProgramFiles(x86)}\OpenCppCoverage\OpenCppCoverage.exe")) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { return $cand }
    }
    return $null
}

function Invoke-TgCoverageRun {
    # Runs one executable under coverage, writes Cobertura XML to $OutXml. Returns process result.
    param($Cfg, [string]$Exe, [string]$OutXml, [string]$Filter = '')
    $c = Get-TgProp $Cfg 'coverage'
    $tool = Get-TgProp $c 'tool' 'OpenCppCoverage'
    $timeout = [int](Get-TgProp $c 'timeoutSec' 1800)
    if (Test-Path -LiteralPath $OutXml) { Remove-Item -LiteralPath $OutXml -Force }
    $dir = Split-Path -Parent $OutXml
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $testArgs = @()
    if ($Filter) { $testArgs += "--gtest_filter=$Filter" }
    $testArgs += (ConvertTo-TgArray (Get-TgProp (Get-TgProp $Cfg 'tests') 'extraArgs' @()))

    if ($tool -eq 'custom') {
        $tpl = Get-TgProp $c 'customCommand' ''
        if ([string]::IsNullOrWhiteSpace($tpl)) { throw 'coverage.tool is "custom" but coverage.customCommand is empty' }
        $cmdline = $tpl.Replace('{exe}', $Exe).Replace('{args}', (Join-TgArgs $testArgs)).Replace('{output}', $OutXml).Replace('{root}', $script:TgRoot)
        return Invoke-TgShell -CommandLine $cmdline -TimeoutSec $timeout
    }

    $occ = Find-TgOpenCppCoverage $Cfg
    if (-not $occ) { throw 'OpenCppCoverage.exe not found. Install it (https://github.com/OpenCppCoverage/OpenCppCoverage/releases) or set coverage.openCppCoverageExe.' }
    $argv = @('--quiet')
    foreach ($s in (ConvertTo-TgArray (Get-TgProp $c 'sources' @()))) { $argv += '--sources'; $argv += (Resolve-TgPath $s) }
    foreach ($s in (ConvertTo-TgArray (Get-TgProp $c 'excludedSources' @()))) { $argv += '--excluded_sources'; $argv += (Resolve-TgPath $s) }
    foreach ($m in (ConvertTo-TgArray (Get-TgProp $c 'modules' @()))) { $argv += '--modules'; $argv += $m }
    if (Get-TgProp $c 'optimizedBuild' $false) { $argv += '--optimized_build' }
    $argv += '--export_type'; $argv += ('cobertura:' + $OutXml)
    $argv += '--working_dir'; $argv += (Get-TgTestWorkDir $Cfg $Exe)
    $argv += '--'; $argv += $Exe; $argv += $testArgs
    return Invoke-TgProcess -FilePath $occ -Arguments $argv -TimeoutSec $timeout
}

function Read-TgCobertura {
    # Merges a Cobertura XML into $Model (hashtable). Only files inside the repo are kept.
    param([string]$XmlPath, [hashtable]$Model)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($XmlPath, $settings)
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($reader)
    } finally { $reader.Close() }
    $sources = @()
    foreach ($s in $doc.SelectNodes('//sources/source')) { $sources += $s.InnerText.Trim() }
    foreach ($cls in $doc.SelectNodes('//class')) {
        $fn = $cls.GetAttribute('filename')
        if (-not $fn) { continue }
        $abs = $null
        if ([System.IO.Path]::IsPathRooted($fn) -and -not ($fn.StartsWith('\') -and $script:TgIsWindows)) {
            $abs = $fn
        } else {
            foreach ($src in $sources) {
                $cand = $src.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar + $fn.TrimStart('\', '/')
                if (Test-Path -LiteralPath $cand) { $abs = $cand; break }
            }
            if (-not $abs) {
                $cand = Join-Path $script:TgRoot $fn
                if (Test-Path -LiteralPath $cand) { $abs = $cand }
            }
        }
        if (-not $abs) { continue }
        $rel = Get-TgRelPath $abs
        if ($null -eq $rel -or $rel -eq '') { continue }
        $key = $rel
        if ($script:TgIsWindows) { $key = $rel.ToLowerInvariant() }
        if (-not $Model.ContainsKey($key)) {
            $Model[$key] = @{ Path = $rel; Lines = (New-Object 'System.Collections.Generic.Dictionary[int,int]'); Branches = (New-Object 'System.Collections.Generic.Dictionary[int,int[]]') }
        }
        $entry = $Model[$key]
        foreach ($ln in $cls.SelectNodes('lines/line')) {
            $num = [int]$ln.GetAttribute('number')
            $hits = 0
            [void][int]::TryParse($ln.GetAttribute('hits'), [ref]$hits)
            if ($entry.Lines.ContainsKey($num)) { $entry.Lines[$num] = [Math]::Max($entry.Lines[$num], $hits) } else { $entry.Lines[$num] = $hits }
            $cc = $ln.GetAttribute('condition-coverage')
            if ($cc) {
                $m = [regex]::Match($cc, '\((\d+)/(\d+)\)')
                if ($m.Success) {
                    $cov = [int]$m.Groups[1].Value; $tot = [int]$m.Groups[2].Value
                    if ($entry.Branches.ContainsKey($num)) {
                        $old = $entry.Branches[$num]
                        $entry.Branches[$num] = [int[]]@([Math]::Max($old[0], $cov), [Math]::Max($old[1], $tot))
                    } else { $entry.Branches[$num] = [int[]]@($cov, $tot) }
                }
            }
        }
    }
}

function Get-TgCoverage {
    # Runs coverage for all executables (optionally a gtest filter for one exe). Returns model hashtable.
    param($Cfg, [string]$WorkDir, [string]$OnlyExe = '', [string]$Filter = '')
    $model = @{}
    $i = 0
    foreach ($exe in (Get-TgTestExecutables $Cfg)) {
        if ($OnlyExe -and ($exe -ne $OnlyExe)) { continue }
        $i++
        $xml = Join-Path $WorkDir ("cov_" + $i + ".xml")
        $r = Invoke-TgCoverageRun -Cfg $Cfg -Exe $exe -OutXml $xml -Filter $Filter
        if (-not (Test-Path -LiteralPath $xml)) {
            throw "Coverage run produced no Cobertura file for $exe (exit $($r.ExitCode)).`n$(Get-TgTail $r.Output 25)"
        }
        Read-TgCobertura -XmlPath $xml -Model $model
    }
    return $model
}

function ConvertTo-TgCoverageJson {
    # Model -> serializable object
    param([hashtable]$Model)
    $files = [ordered]@{}
    foreach ($k in ($Model.Keys | Sort-Object)) {
        $e = $Model[$k]
        $cov = @(); $unc = @(); $br = @()
        foreach ($n in ($e.Lines.Keys | Sort-Object)) { if ($e.Lines[$n] -gt 0) { $cov += $n } else { $unc += $n } }
        foreach ($n in ($e.Branches.Keys | Sort-Object)) { $b = $e.Branches[$n]; $br += , @($n, $b[0], $b[1]) }
        $files[$e.Path] = [ordered]@{ covered = $cov; uncovered = $unc; branches = $br }
    }
    return $files
}

function Get-TgCoverageTotals {
    param($FilesObj)
    $lt = 0; $lc = 0; $bt = 0; $bc = 0
    foreach ($p in $FilesObj.PSObject.Properties) {
        $f = $p.Value
        $c = @(ConvertTo-TgArray $f.covered).Count; $u = @(ConvertTo-TgArray $f.uncovered).Count
        $lc += $c; $lt += ($c + $u)
        foreach ($b in (ConvertTo-TgArray $f.branches)) { $bc += [int]$b[1]; $bt += [int]$b[2] }
    }
    $lp = 0; if ($lt -gt 0) { $lp = [Math]::Round(100.0 * $lc / $lt, 1) }
    $bp = $null; if ($bt -gt 0) { $bp = [Math]::Round(100.0 * $bc / $bt, 1) }
    return [pscustomobject]@{ LinesCovered = $lc; LinesTotal = $lt; LinePct = $lp; BranchesCovered = $bc; BranchesTotal = $bt; BranchPct = $bp }
}

function ConvertTo-TgObject {
    # Round-trip an ordered dictionary through JSON so it behaves like data read from disk
    param($Obj)
    return (($Obj | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
}

function Get-TgCoveredSet {
    # FilesObj -> HashSet of "path:line" keys for covered lines
    param($FilesObj)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($null -eq $FilesObj) { return , $set }
    foreach ($p in $FilesObj.PSObject.Properties) {
        $k = $p.Name; if ($script:TgIsWindows) { $k = $k.ToLowerInvariant() }
        foreach ($n in (ConvertTo-TgArray $p.Value.covered)) { [void]$set.Add($k + ':' + $n) }
    }
    return , $set
}

function Get-TgBranchSet {
    # FilesObj -> hashtable "path:line" -> covered branch count
    param($FilesObj)
    $h = @{}
    if ($null -eq $FilesObj) { return $h }
    foreach ($p in $FilesObj.PSObject.Properties) {
        $k = $p.Name; if ($script:TgIsWindows) { $k = $k.ToLowerInvariant() }
        foreach ($b in (ConvertTo-TgArray $p.Value.branches)) { $h[$k + ':' + $b[0]] = [int]$b[1] }
    }
    return $h
}

# ---------------------------------------------------------------------------
# Hashing (production / test files)
# ---------------------------------------------------------------------------
function Get-TgFileHashes {
    # Returns ordered hashtable relPath -> sha256 for C++ files under the given repo-relative dirs
    param([string[]]$Dirs, [string[]]$ExtraFiles = @())
    $exts = Get-TgCppExtensions
    $h = [ordered]@{}
    $files = @()
    foreach ($d in $Dirs) {
        $abs = Resolve-TgPath $d
        if (-not $abs -or -not (Test-Path -LiteralPath $abs)) { continue }
        if (Test-Path -LiteralPath $abs -PathType Leaf) { $files += (Get-Item -LiteralPath $abs); continue }
        $files += @(Get-ChildItem -LiteralPath $abs -Recurse -File | Where-Object { $exts -contains $_.Extension.ToLowerInvariant() })
    }
    foreach ($f in $ExtraFiles) {
        $abs = Resolve-TgPath $f
        if ($abs -and (Test-Path -LiteralPath $abs -PathType Leaf)) { $files += (Get-Item -LiteralPath $abs) }
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    foreach ($f in ($files | Sort-Object FullName -Unique)) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
        $h[(Get-TgRelPath $f.FullName)] = $hash
    }
    return $h
}

function Get-TgCombinedHash {
    param($Hashes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $Hashes.Keys) { [void]$sb.Append($k).Append('=').Append($Hashes[$k]).Append("`n") }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))).Replace('-', '')
}

function Get-TgProductionDirs { param($Cfg) return (ConvertTo-TgArray (Get-TgProp (Get-TgProp $Cfg 'paths') 'production' @('src'))) }
function Get-TgTestDirs { param($Cfg) return (ConvertTo-TgArray (Get-TgProp (Get-TgProp $Cfg 'paths') 'tests' @('tests'))) }

function Get-TgTestsHash {
    param($Cfg)
    return (Get-TgCombinedHash (Get-TgFileHashes -Dirs (Get-TgTestDirs $Cfg)))
}

function Test-TgSeamApproved {
    return (Test-Path -LiteralPath (Join-Path $script:TgRoot '.github/testgen/seam-approved'))
}

# ---------------------------------------------------------------------------
# Source text with encoding preservation (UTF-8 w/ or w/o BOM, UTF-16, or ANSI e.g. Shift_JIS)
# ---------------------------------------------------------------------------
function Get-TgAnsiEncoding {
    try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
    try { return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch { }
    return [System.Text.Encoding]::Default
}

function Read-TgSource {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $enc = $null; $bom = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = New-Object System.Text.UTF8Encoding($true); $bom = 3 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [System.Text.Encoding]::Unicode; $bom = 2 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = [System.Text.Encoding]::BigEndianUnicode; $bom = 2 }
    else {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        try { [void]$strict.GetString($bytes); $enc = New-Object System.Text.UTF8Encoding($false) } catch { $enc = Get-TgAnsiEncoding }
    }
    $text = $enc.GetString($bytes, $bom, $bytes.Length - $bom)
    return [pscustomobject]@{ Text = $text; Encoding = $enc; Bom = $bom; Bytes = $bytes }
}

function Write-TgSource {
    param([string]$Path, $Src, [string]$NewText)
    $body = $Src.Encoding.GetBytes($NewText)
    $out = New-Object byte[] ($Src.Bom + $body.Length)
    if ($Src.Bom -gt 0) { [Array]::Copy($Src.Bytes, 0, $out, 0, $Src.Bom) }
    [Array]::Copy($body, 0, $out, $Src.Bom, $body.Length)
    [System.IO.File]::WriteAllBytes($Path, $out)
}

function Get-TgSourceLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $s = Read-TgSource $Path
    return ($s.Text -split "`r?`n")
}
