#requires -Version 7.0
[CmdletBinding()]
param([switch]$WorkingTree, [switch]$Check)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Forbidden-ExportPath([string]$Path) {
    $path = $Path.Replace('\','/')
    $path -match '(^|/)(private|runtime|session|logs|client-image|assets|downloads|node_modules|\.copilot|\.vs)/' -or
        $path -match '(?i)\.(exe|dll|sys|gme|xfs|iso|vdi|vmdk|vhdx?|vbox(?:-prev)?|ova|ovf|zip|7z|rar|msi|cab|pdb|obj|bin|log|jsonl|pfx|p12|pem|key|lnk)$' -or
        $path -match '(^|/)\.env(?:\.|$)' -or
        $path -match '^backend/(native/|schema-static\.sql$|manifest\.json$|loopback-patches\.json$|status\.json$|.*-processes\.json$|.*\.pid$)' -or
        $path -match '^client-build/(human/|bot/|work/|startup/|manifest\.json$|verification\.json$|backend-allowance\.json$)' -or
        $path -match '^vm/(config|media|platform-install|windows-media-record|package|server-package|server-snapshot|maintenance|verification)\.json$' -or
        $path -in @('network.json','bot-process.json','bot.stop','client-processes.jsonl')
}

function Find-ExportTextIssues([string]$Text) {
    $patterns = [ordered]@{
        'personal Windows home path' = '(?i)\b[A-Z]:\\+Users\\+'
        'personal Unix home path' = '(?i)/(?:home|Users)/[A-Za-z0-9_.-]+/'
        'GitHub token' = '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'
        'AWS access-key identifier' = '\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'
        'Slack token' = '\bxox[baprs]-[A-Za-z0-9-]{16,}\b'
        'private-key material' = '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
        'credential-bearing URL' = '(?i)https?://[^/\s:@]+:[^/\s@]+@'
        'signed/tokenized download URL' = '(?i)https?://[^\s"''<>]+[?&](?:sig|token|access_token|client_secret)=[^\s"''<>]+'
    }
    foreach ($entry in $patterns.GetEnumerator()) {
        foreach ($match in [regex]::Matches($Text,$entry.Value)) {
            [pscustomobject]@{Category=$entry.Key;Line=1 + [regex]::Matches($Text.Substring(0,$match.Index),"`n").Count}
        }
    }
}

if ($Check) {
    foreach ($path in @('private/accounts.json','runtime/vm/system.vdi','vm/config.json',
        'backend/schema-static.sql','client-image/GunBound.gme','logs/test.jsonl','image.iso','.env.local')) {
        if (!(Forbidden-ExportPath $path)) { throw 'A private/runtime artifact escaped the export path check.' }
    }
    foreach ($path in @('bot.cs','aim.cs','setup.ps1','backend/login-date-compat.sql',
        'profiles/difficulty.json','client-build/wrapper-config/dxwnd.ini','docs/OVERVIEW.md')) {
        if (Forbidden-ExportPath $path) { throw 'A legitimate source/template path was rejected.' }
    }
    $samples = @(
        ('C:' + '\' + 'Users' + '\' + 'example' + '\project'),
        ('ghp' + '_' + ('a' * 36)),
        ('github' + '_pat_' + ('b' * 40)),
        ('-----BEGIN ' + 'PRIVATE KEY-----'),
        ('https://example.invalid/file?' + 'sig=example'),
        ('https://name' + ':value@example.invalid/')
    )
    foreach ($sample in $samples) {
        if (@(Find-ExportTextIssues $sample).Count -eq 0) { throw 'A sensitive test fixture escaped export text checks.' }
    }
    if (@(Find-ExportTextIssues 'Use $PSScriptRoot and the fixed guest root C:\GunBoundAI.').Count) {
        throw 'A generic runtime path was treated as a personal installation path.'
    }
    Write-Output 'PASS: source-only export paths, token patterns and personal-path checks. No credentials were read.'
    return
}

$arguments = @('-C',$root,'ls-files','-z','--cached')
if ($WorkingTree) { $arguments += @('--others','--exclude-standard') }
$raw = (@(& git @arguments) -join "`n")
if ($LASTEXITCODE) { throw 'Git file inventory failed.' }
$files = @($raw -split [string][char]0 | Where-Object { $_ } | Sort-Object -Unique)
if (!$files.Count) { throw 'No source files were selected. Use -WorkingTree before staging, or stage the intended files first.' }
$issues = [Collections.Generic.List[string]]::new()
foreach ($relative in $files) {
    if (Forbidden-ExportPath $relative) {
        $issues.Add("$relative : excluded private/runtime/binary artifact")
        continue
    }
    if ($WorkingTree) {
        $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (!$path.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)) {
            $issues.Add("$relative : path escapes the repository")
            continue
        }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $issues.Add("$relative : redirected source path")
            continue
        }
        $text = [IO.File]::ReadAllText($path)
    } else {
        $mode = (@(& git -C $root ls-files -s -- $relative) -join '')
        if ($LASTEXITCODE -or $mode -notmatch '^100(?:644|755) ') {
            $issues.Add("$relative : unsupported Git entry type")
            continue
        }
        $text = (@(& git -C $root cat-file blob (':' + $relative)) -join "`n")
        if ($LASTEXITCODE) { throw "Could not read the staged source blob for $relative." }
    }
    foreach ($finding in @(Find-ExportTextIssues $text)) {
        $issues.Add(('{0}:{1}: {2}' -f $relative,$finding.Line,$finding.Category))
    }
}
if ($issues.Count) {
    foreach ($issue in $issues) { Write-Output $issue }
    throw 'Export audit failed. Matching sensitive values were deliberately not printed.'
}
Write-Output ("PASS: {0} source/template files checked; no excluded artifacts or recognized tokens/personal paths found. This is a guardrail, not a guarantee that arbitrary future code is secret-free." -f $files.Count)
