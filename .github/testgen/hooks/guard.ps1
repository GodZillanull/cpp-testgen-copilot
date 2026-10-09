# guard.ps1 - PreToolUse hook for the test-writer agent.
# Enforces with code (not prompts):
#   * no edits to production code (unless a human created .github/testgen/seam-approved)
#   * no edits to the workflow itself (.github/skills, agents, prompts, testgen, hooks, .vscode)
#   * no edits to gate/baseline/mutation result files (they must only be written by the scripts)
#   * terminal commands that write to those locations or reset git state are blocked / need approval
# Everything else under paths.tests, paths.testProjectFiles and the reports folder is allowed;
# edits elsewhere ask the user.
# Fails open (allows) if it cannot parse its input, but prints a warning.
$ErrorActionPreference = 'Stop'
try {
    . "$PSScriptRoot/../../skills/cpp-test-gate/scripts/common.ps1"
    $raw = [Console]::In.ReadToEnd()
    $evt = $raw | ConvertFrom-Json
    $tool = [string](Get-TgProp $evt 'tool_name' '')
    $inp = Get-TgProp $evt 'tool_input'
    $cfg = Get-TgConfig
    $reportsRel = ([string](Get-TgProp (Get-TgProp $cfg 'paths') 'reports' 'test-reports')).Replace('\', '/').TrimEnd('/')

    $alwaysProtected = @('.github/skills', '.github/agents', '.github/prompts', '.github/instructions', '.github/testgen', '.github/hooks',
        '.github/copilot-instructions.md', '.vscode',
        "$reportsRel/baseline", "$reportsRel/gate", "$reportsRel/mutants/results.json", "$reportsRel/mutants/killers.json", "$reportsRel/mutants/.backup")
    $prod = @(Get-TgProductionDirs $cfg)
    $testDirs = @(Get-TgTestDirs $cfg)
    $testProj = @(ConvertTo-TgArray (Get-TgProp (Get-TgProp $cfg 'paths') 'testProjectFiles' @()))
    $seamOk = Test-TgSeamApproved

    function Out-Decision([string]$Decision, [string]$Reason) {
        $o = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = $Decision; permissionDecisionReason = $Reason } }
        Write-Output ($o | ConvertTo-Json -Compress -Depth 5)
        exit 0
    }

    function Get-Strings($obj, [string]$key, [System.Collections.ArrayList]$acc) {
        if ($null -eq $obj) { return }
        if ($obj -is [string]) { [void]$acc.Add(@($key, $obj)); return }
        if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [System.Management.Automation.PSCustomObject])) {
            foreach ($x in $obj) { Get-Strings $x $key $acc }; return
        }
        if ($obj -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $obj.PSObject.Properties) { Get-Strings $p.Value $p.Name $acc }
        }
    }

    function Get-Rel([string]$p) {
        $s = $p.Trim()
        if ($s -match '^file://') { $s = [System.Uri]::UnescapeDataString(([System.Uri]$s).LocalPath) }
        if ($s -match '^/[A-Za-z]:/') { $s = $s.Substring(1) }
        try {
            if ([System.IO.Path]::IsPathRooted($s)) { return (Get-TgRelPath $s) }
            return (Get-TgRelPath (Join-Path (Get-TgRoot) $s))
        } catch { return $null }
    }

    $strings = New-Object System.Collections.ArrayList
    Get-Strings $inp '' $strings

    $isTerminal = $tool -match '(?i)terminal|runInTerminal|run_in_terminal|createAndRunTask|run_task|runTask|execute'
    $isEdit = (-not $isTerminal) -and ($tool -match '(?i)edit|create|write|replace|insert|patch|delete|rename|move|notebook')

    if ($isEdit) {
        $paths = @()
        foreach ($kv in $strings) {
            $k = $kv[0]; $v = $kv[1]
            if ($v.Contains("`n")) {
                foreach ($m in [regex]::Matches($v, '\*\*\* (?:Update|Add|Delete) File:\s*(.+)')) { $paths += $m.Groups[1].Value.Trim() }
                continue
            }
            if ($k -match '(?i)path|file|uri|dir|target|destination|source') { $paths += $v }
        }
        foreach ($p in $paths) {
            $rel = Get-Rel $p
            if ($null -eq $rel) { Out-Decision 'ask' "Edit outside the repository: $p" }
            if (Test-TgUnderPrefix $rel $alwaysProtected) {
                Out-Decision 'deny' "'$rel' is part of the test-generation workflow or a script-generated result. The test writer must not modify it. Report the problem to the user instead."
            }
            if (Test-TgUnderPrefix $rel $prod) {
                if ($seamOk) { continue }
                Out-Decision 'deny' "'$rel' is production code. Tests must not change production code. If a seam is needed, describe it in $reportsRel/<target>/analysis.md and ask a human to approve it (they create .github/testgen/seam-approved)."
            }
            if ((Test-TgUnderPrefix $rel $testDirs) -or (Test-TgUnderPrefix $rel $testProj) -or (Test-TgUnderPrefix $rel @($reportsRel))) { continue }
            Out-Decision 'ask' "'$rel' is outside the test folders. Confirm this edit is intended."
        }
        Write-Output '{"continue":true}'
        exit 0
    }

    if ($isTerminal) {
        $cmd = (($strings | ForEach-Object { $_[1] }) -join ' ')
        $c = $cmd.Replace('\', '/')
        if ($c -match '(?i)seam-approved') { Out-Decision 'deny' 'Only a human may create or delete .github/testgen/seam-approved.' }
        if ($c -match '(?i)\bgit\s+(checkout|restore|reset|clean|stash|rm|commit|push)\b') { Out-Decision 'ask' 'This git command changes repository state. Confirm it is intended.' }
        $writes = $c -match '(?i)(Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item|Rename-Item|Clear-Content|\bdel\b|\berase\b|\brm\b|\bmv\b|\bcp\b|\bcopy\b|\bmove\b|\bren\b|sed\s+-i|WriteAll|(?<![\d-])>>?\s*(?!&)\S)'
        if ($writes) {
            foreach ($p in ($alwaysProtected + $prod)) {
                $q = $p.Replace('\', '/').TrimEnd('/')
                if ($q -and $c.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Out-Decision 'deny' "Terminal command would write to a protected location ($q). Use the file edit tools for test files only; production code, the workflow and result files are off limits."
                }
            }
        }
        Write-Output '{"continue":true}'
        exit 0
    }

    Write-Output '{"continue":true}'
    exit 0
} catch {
    $msg = ('guard.ps1 error (allowing the tool call): ' + $_.Exception.Message) -replace '"', "'"
    Write-Output ('{"continue":true,"systemMessage":"' + ($msg -replace '\\', '/') + '"}')
    exit 0
}
