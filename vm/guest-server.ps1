#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Health','Check')][string]$Action = 'Health',
    [switch]$Check
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$serverRoot = 'C:\GunBoundServer'
$pwshDirectory = "$serverRoot\runtime\pwsh"
$pwsh = "$pwshDirectory\pwsh.exe"

function Integer($Value) { $Value -is [int] -or $Value -is [long] }
function Guest-Matches($Marker, [string]$Root, [string]$Computer) {
    if ($Marker -isnot [pscustomobject]) { return $false }
    foreach ($field in @('schemaVersion','root','serverRoot','computerName','provider','ownerId','leaseSeconds')) {
        if (@($Marker.PSObject.Properties.Name) -cnotcontains $field) { return $false }
    }
    $owner = [Guid]::Empty
    (Integer $Marker.schemaVersion) -and $Marker.schemaVersion -eq 1 -and
        $Root -eq 'C:\GunBoundAI' -and $Marker.root -is [string] -and $Marker.root -eq $Root -and
        $Marker.serverRoot -is [string] -and $Marker.serverRoot -eq $serverRoot -and
        $Marker.computerName -is [string] -and $Marker.computerName -eq 'GUNBOUND-BOT' -and $Marker.computerName -eq $Computer -and
        $Marker.provider -is [string] -and $Marker.provider -eq 'virtualbox' -and (Integer $Marker.leaseSeconds) -and $Marker.leaseSeconds -eq 120 -and
        $Marker.ownerId -is [string] -and $Marker.ownerId -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -and
        [Guid]::TryParseExact($Marker.ownerId, 'D', [ref]$owner) -and $owner -ne [Guid]::Empty
}
function Identity-Matches($Expected, $Actual) {
    foreach ($record in @($Expected,$Actual)) {
        if (!$record) { return $false }
        foreach ($field in @('pid','path','startedUtcTicks')) {
            if (@($record.PSObject.Properties.Name) -notcontains $field) { return $false }
        }
        if (!(Integer $record.pid) -or $record.pid -le 0 -or $record.pid -gt [int]::MaxValue -or
            !(Integer $record.startedUtcTicks) -or $record.startedUtcTicks -le 0 -or
            $record.startedUtcTicks -gt [DateTime]::MaxValue.Ticks -or $record.path -isnot [string] -or
            !$record.path.StartsWith($serverRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $Expected.pid -eq $Actual.pid -and $Expected.startedUtcTicks -eq $Actual.startedUtcTicks -and
        [String]::Equals($Expected.path, $Actual.path, [StringComparison]::OrdinalIgnoreCase)
}
function Backend-Arguments([string]$Name) {
    if ($Name -notin @('Start','Stop','Health')) { throw 'Unsupported backend action.' }
    $arguments = @('-NoProfile','-NonInteractive','-File',"$serverRoot\backend\$($Name.ToLowerInvariant()).ps1")
    if ($Name -ne 'Health') { $arguments += @('-Part','All') }
    return $arguments
}
function Verified-ExitCode($Code) {
    if (!(Integer $Code) -or $Code -lt [int]::MinValue -or $Code -gt [int]::MaxValue) {
        throw 'The backend invocation has no trustworthy exit code; success was not inferred.'
    }
    return [int]$Code
}
if ($Check -or $Action -eq 'Check') {
    $marker = [pscustomobject]@{
        schemaVersion=1;root='C:\GunBoundAI';serverRoot=$serverRoot;computerName='GUNBOUND-BOT'
        provider='virtualbox';ownerId='11111111-2222-3333-4444-555555555555';leaseSeconds=120
    }
    if (!(Guest-Matches $marker 'C:\GunBoundAI' 'GUNBOUND-BOT') -or
        (Guest-Matches $marker 'C:\GunBoundAI' 'PARENT-HOST') -or
        (Guest-Matches $marker 'C:\Other' 'GUNBOUND-BOT')) { throw 'Guest identity/root guard changed.' }
    $marker.provider = 'azure'
    if (Guest-Matches $marker 'C:\GunBoundAI' 'GUNBOUND-BOT') { throw 'Azure was accepted for local VM actions.' }
    $marker.provider = 'virtualbox'; $marker.serverRoot = 'C:\GunBoundAI'
    if (Guest-Matches $marker 'C:\GunBoundAI' 'GUNBOUND-BOT') { throw 'Application credentials were accepted as server credentials.' }
    $owned = [pscustomobject]@{pid=200;path=$pwsh;startedUtcTicks=639248679502371076L}
    $actual = $owned | ConvertTo-Json | ConvertFrom-Json
    if (!(Identity-Matches $owned $actual)) { throw 'Exact PID/path/start ticks were rejected.' }
    $actual.startedUtcTicks++
    if (Identity-Matches $owned $actual) { throw 'A reused PID was accepted.' }
    $actual.startedUtcTicks = $owned.startedUtcTicks; $actual.path = 'C:\GunBoundAI\pwsh.exe'
    if (Identity-Matches $owned $actual) { throw 'An executable outside the protected server root was accepted.' }
    $actual.path = $pwsh; $actual.startedUtcTicks = [double]$owned.startedUtcTicks
    if ((Identity-Matches $owned $actual) -or (Identity-Matches $owned $null)) { throw 'Rounded or missing identity data was accepted.' }
    $actual.startedUtcTicks = $owned.startedUtcTicks; $actual.path = $null
    if (Identity-Matches $owned $actual) { throw 'An unpublished image path was accepted as ownership.' }
    foreach ($count in @(1,3)) {
        $json = ConvertTo-Json -InputObject (@($owned) * $count)
        $decoded = 0
        foreach ($entry in ($json | ConvertFrom-Json)) {
            if (!(Identity-Matches $entry $owned)) { throw 'A JSON backend array was not decoded into ownership records.' }
            $decoded++
        }
        if ($decoded -ne $count) { throw 'Backend ownership array cardinality changed.' }
    }
    foreach ($name in @('Start','Stop','Health')) {
        $arguments = @(Backend-Arguments $name)
        $expected = "-NoProfile|-NonInteractive|-File|$serverRoot\backend\$($name.ToLowerInvariant()).ps1"
        if ($name -ne 'Health') { $expected += '|-Part|All' }
        if (($arguments -join '|') -cne $expected) { throw 'Protected full-backend routing changed.' }
    }
    if ((Verified-ExitCode 0) -ne 0 -or (Verified-ExitCode 7) -ne 7) { throw 'Backend exit codes were changed.' }
    foreach ($invalid in @($null,'0',0.0)) {
        $rejected = $false
        try { Verified-ExitCode $invalid | Out-Null } catch { $rejected = $true }
        if (!$rejected) { throw 'Missing or coerced exit information was treated as success.' }
    }
    & "$PSScriptRoot\guest-idle.ps1" -Check
    Write-Output 'PASS: identified local guest, separate protected server root, exact process ownership, portable full-backend commands, and idle shutdown gates. No process/service/network/power action performed.'
    return
}

$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$logs = "$serverRoot\logs"
$marker = $null
function Assert-Guest {
    if ($root -ne 'C:\GunBoundAI') { throw 'Run only the installed C:\GunBoundAI\vm guest wrapper; use -Check on the host.' }
    $candidate = Get-Content -LiteralPath "$PSScriptRoot\guest.json" -Raw | ConvertFrom-Json
    if (!(Guest-Matches $candidate $root ([Environment]::MachineName))) {
        throw 'The guest/root/server-root/owner/provider marker does not identify this local VM. Azure requires explicit deallocation.'
    }
    . "$PSScriptRoot\shared-io.ps1"
    Assert-GuestIdentity -OwnerId $candidate.ownerId -Server
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if ($identity.User.Value -ne 'S-1-5-18' -and
            !$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Protected backend actions require SYSTEM or an elevated Administrator; LabBot must not access server credentials.'
        }
    } finally { $identity.Dispose() }
    $script:marker = $candidate
}
function Event([string]$Name, $Details) {
    [ordered]@{timeUtc=[DateTime]::UtcNow.ToString('o');action=$Action;name=$Name;details=$Details} |
        ConvertTo-Json -Depth 5 -Compress | Add-Content -LiteralPath "$logs\guest-server-$($Action.ToLowerInvariant())-events.jsonl"
}
function Observe([int]$ProcessId) {
    try { $p = [Diagnostics.Process]::GetProcessById($ProcessId) }
    catch [ArgumentException] { return $null }
    try {
        if ($p.HasExited) { return $null }
        [pscustomobject]@{pid=$p.Id;path=$p.MainModule.FileName;startedUtcTicks=$p.StartTime.ToUniversalTime().Ticks}
    } catch {
        if (!$p.HasExited) { throw }
        return $null
    } finally { $p.Dispose() }
}
function Read-Record([string]$Name) {
    $file = "$logs\guest-server-$($Name.ToLowerInvariant()).json"
    if (!(Test-Path -LiteralPath $file)) { return $null }
    $record = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if ($record.schemaVersion -ne 1 -or $record.ownerId -ne $marker.ownerId -or
        $record.action -ne $Name -or $record.path -ne $pwsh -or
        $record.script -ne "$serverRoot\backend\$($Name.ToLowerInvariant()).ps1" -or
        !(Identity-Matches $record $record)) { throw "Invalid protected $Name process record; no PID was adopted." }
    return $record
}
function Save-Record($Record) {
    $file = "$logs\guest-server-$($Record.action.ToLowerInvariant()).json"
    $next = $file + '.new'
    [IO.File]::WriteAllText($next, (ConvertTo-Json -InputObject $Record -Depth 4))
    if ([IO.File]::Exists($file)) { [IO.File]::Replace($next, $file, [NullString]::Value) }
    else { [IO.File]::Move($next, $file) }
}
function Services {
    $native = @(
        "$serverRoot\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe"
        "$serverRoot\backend\native\Server8360\Gunboundserv3.exe"
        "$serverRoot\backend\native\Central\GunBoundBroker3.exe"
        "$serverRoot\backend\native\BuddyCenter\BuddyCenter2.exe"
        "$serverRoot\backend\native\BuddyServ\BuddyServ2.exe"
    )
    $filter = "Name='mariadbd.exe' OR Name='Gunboundserv3.exe' OR Name='GunBoundBroker3.exe' OR Name='BuddyCenter2.exe' OR Name='BuddyServ2.exe' OR Name='pwsh.exe'"
    foreach ($row in @(Get-CimInstance Win32_Process -Filter $filter -OperationTimeoutSec 10)) {
        if (!$row.ExecutablePath) {
            if (Observe $row.ProcessId) { throw 'A possible backend process has unreadable executable identity; shutdown cannot be verified.' }
            continue
        }
        $service = $row.ExecutablePath -in $native
        if ($row.ExecutablePath -eq $pwsh) {
            if (!$row.CommandLine) { throw 'A protected PowerShell process has no readable command identity.' }
            $service = $row.CommandLine.IndexOf("$serverRoot\backend\start.ps1", [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $row.CommandLine.IndexOf("$serverRoot\backend\mysql-compat.ps1", [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        if ($service) {
            $actual = Observe $row.ProcessId
            if ($actual) { $actual }
        }
    }
}
function Stop-Proofs {
    $supervisor = Read-Record 'Start'
    if ($supervisor) { $supervisor }
    foreach ($group in @('database','core','buddy')) {
        $file = "$serverRoot\backend\$group-processes.json"
        if (!(Test-Path -LiteralPath $file)) { continue }
        foreach ($entry in (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)) {
            if (!(Identity-Matches $entry $entry)) { throw 'Backend ownership metadata is invalid or belongs to another root; original records were not changed.' }
            $entry
            $parent = [pscustomobject]@{pid=$entry.supervisorPid;path=$entry.supervisorPath;startedUtcTicks=$entry.supervisorStartedUtcTicks}
            if (!(Identity-Matches $parent $parent) -or $parent.path -ne $pwsh) { throw 'Backend supervisor metadata is not the protected portable PowerShell.' }
            $parent
        }
    }
}
function Run-Backend([string]$Name, [int]$Seconds) {
    Assert-Guest
    $previous = Read-Record $Name
    if ($previous -and (Identity-Matches $previous (Observe $previous.pid))) { throw "An owned $Name invocation is still running; a duplicate was refused." }
    $arguments = @(Backend-Arguments $Name)
    $p = $null
    try {
        $p = Start-Process -FilePath $pwsh -ArgumentList ($arguments -join ' ') -WorkingDirectory $serverRoot -NoNewWindow -PassThru `
            -RedirectStandardOutput "$logs\guest-server-$($Name.ToLowerInvariant()).out.log" `
            -RedirectStandardError "$logs\guest-server-$($Name.ToLowerInvariant()).err.log"
        $null = $p.Handle
        $record = [pscustomobject]@{
            schemaVersion=1;ownerId=$marker.ownerId;action=$Name;pid=$p.Id;path=$pwsh
            startedUtcTicks=$p.StartTime.ToUniversalTime().Ticks;script="$serverRoot\backend\$($Name.ToLowerInvariant()).ps1"
        }
        $published = [Diagnostics.Stopwatch]::StartNew()
        while (!$p.HasExited) {
            $actual = Observe $p.Id
            if (Identity-Matches $record $actual) { break }
            if ($p.HasExited) { break }
            if ($actual -and ($actual.pid -ne $record.pid -or
                $actual.startedUtcTicks -ne $record.startedUtcTicks -or $actual.path)) {
                throw 'The created backend PowerShell identity did not match.'
            }
            if ($published.Elapsed.TotalSeconds -ge 5) { throw 'The backend PowerShell did not publish its image path within five seconds.' }
            Start-Sleep -Milliseconds 25
        }
        Save-Record $record
        Event 'invoked' $record
        if ($Name -eq 'Start') {
            $script:controlLock.Dispose()
            $script:controlLock = $null
            Write-Host 'Backend Start is supervised in this foreground task; use -Action Health to check actual readiness.'
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (!$p.WaitForExit(500)) {
            if ($Seconds -gt 0 -and $timer.Elapsed.TotalSeconds -ge $Seconds) {
                throw "$Name exceeded ${Seconds}s; its owned invocation may still be running. No process was killed and shutdown is not authorized."
            }
        }
        $code = Verified-ExitCode $p.ExitCode
        Event 'completed' @{exitCode=$code;pid=$record.pid;startedUtcTicks=$record.startedUtcTicks}
        return $code
    }
    catch {
        Event 'invocation-failed' @{message=$_.Exception.Message;pid=if ($p) {$p.Id} else {$null}}
        throw
    }
    finally { if ($p) { $p.Dispose() } }
}

Assert-Guest
if (!(Test-Path -LiteralPath $serverRoot -PathType Container)) { throw 'The protected server root has not been provisioned.' }
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$controlLock = $null
$startLock = $null
$oldPath = $env:PATH
$exitCode = 1
try {
    $required = @($pwsh,"$serverRoot\backend\$($Action.ToLowerInvariant()).ps1")
    if ($Action -ne 'Stop') { $required += "$serverRoot\network.json" }
    if ($Action -eq 'Start') { $required += @("$serverRoot\backend\stop.ps1","$serverRoot\backend\health.ps1") }
    foreach ($file in $required) {
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required protected backend file is missing: $file" }
    }
    $env:PATH = $pwshDirectory + ';' + $oldPath
    if ((Get-Command pwsh -CommandType Application).Source -ne $pwsh) { throw 'The protected portable pwsh is not first on the process PATH.' }
    $controlLock = [IO.File]::Open("$logs\guest-server.control.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    if ($Action -eq 'Start') {
        $startLock = [IO.File]::Open("$logs\guest-server.start.lock", 'OpenOrCreate', 'ReadWrite', 'None')
        if (@(Services).Count) { throw 'Backend processes already exist in the server root; a second server was not started.' }
        $exitCode = Run-Backend 'Start' 0
        if (@(Services).Count) { throw 'The foreground supervisor exited but backend processes remain; explicit owned cleanup is required.' }
    }
    elseif ($Action -eq 'Stop') {
        $proofs = @(Stop-Proofs)
        $before = @(Services)
        foreach ($actual in $before) {
            if (!@($proofs | Where-Object { Identity-Matches $_ $actual }).Count) {
                throw "Server PID $($actual.pid) has no matching protected ownership record; no stop or power action was attempted."
            }
        }
        $exitCode = Run-Backend 'Stop' 180
        if ($exitCode -eq 0) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            do {
                $remaining = @(Services)
                if (!$remaining.Count) { break }
                Start-Sleep -Milliseconds 250
            } while ($timer.Elapsed.TotalSeconds -lt 15)
            if ($remaining.Count) { throw 'Backend stop returned but MariaDB/native services or their supervisor remain; shutdown is not authorized.' }
            Event 'graceful-stop-verified' @{remainingProcesses=0}
        }
    }
    else { $exitCode = Run-Backend 'Health' 60 }
    if ($exitCode -ne 0) {
        Event 'backend-error' @{exitCode=$exitCode}
        [Console]::Error.WriteLine("Backend $Action returned $exitCode. Inspect protected $logs\guest-server-$($Action.ToLowerInvariant()).err.log; no success was inferred.")
    }
}
catch {
    $exitCode = 1
    Event 'failed' @{message=$_.Exception.Message}
    [Console]::Error.WriteLine($_.Exception.Message)
}
finally {
    $env:PATH = $oldPath
    if ($controlLock) { $controlLock.Dispose() }
    if ($startLock) { $startLock.Dispose() }
}
exit $exitCode
