#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param([switch]$Force, [string]$SessionId, [switch]$FromSupervisor)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$sessionDir = Join-Path $root 'session'
$statePath = Join-Path $sessionDir 'lab-session.json'
$stopPath = Join-Path $sessionDir 'stop.request'
if (!(Test-Path -LiteralPath $statePath)) { Write-Output 'No managed play session exists. Existing standalone clients/core were not touched.'; return }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
if ($state.root -ne $root -or !$state.id -or ($SessionId -and $state.id -ne $SessionId)) { throw 'Session identity does not match this lab.' }
if ($state.phase -eq 'stopped') { Write-Output 'The managed lab session is already stopped.'; return }

function Owned($Entry) {
    if (!$Entry) { return $null }
    $p = Get-Process -Id $Entry.pid -ErrorAction SilentlyContinue
    if ($p -and $p.Path -eq $Entry.path -and $p.StartTime.ToUniversalTime().Ticks -eq $Entry.startedUtcTicks) { return $p }
    return $null
}
function Save-State {
    $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $json = ConvertTo-Json -InputObject $state -Depth 8
    [IO.File]::WriteAllText($statePath + '.new', $json)
    [IO.File]::Move($statePath + '.new', $statePath, $true)
    if ($state.logDirectory -and $state.logDirectory.StartsWith($sessionDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
        [IO.File]::WriteAllText((Join-Path $state.logDirectory 'session.json'), $json)
    }
}
if ($FromSupervisor -and ($PID -ne $state.supervisor.pid -or !(Owned $state.supervisor))) { throw 'Only the owning play supervisor may request internal cleanup.' }
if (!$PSCmdlet.ShouldProcess("Managed lab session $($state.id)", 'Gracefully stop its controller, clients and owned backend')) { return }
if (!$FromSupervisor -and $state.supervisorActive -and $state.phase -ne 'cleanup-failed' -and (Owned $state.supervisor)) {
    [IO.File]::WriteAllText($stopPath + '.new', (ConvertTo-Json @{sessionId=$state.id;force=[bool]$Force}))
    [IO.File]::Move($stopPath + '.new', $stopPath, $true)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 300
        $current = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($current.id -ne $state.id) { throw 'Session changed while waiting; no new session was touched.' }
        if ($current.phase -eq 'stopped') { Write-Output 'Managed lab session stopped.'; return }
        if ($current.phase -eq 'cleanup-failed') { throw $current.cleanupError }
    } while ((Owned $state.supervisor) -and $timer.Elapsed.TotalSeconds -lt 75)
    if (Owned $state.supervisor) { throw 'The supervisor is still processing cleanup. Check its window/logs; no process was forcibly killed.' }
}

try {
    $state.phase = 'stopping'; Save-State
    if ($state.botVm) {
        $vm = Get-Content -LiteralPath (Join-Path $root 'vm\config.json') -Raw | ConvertFrom-Json
        if ($vm.machineId -ne $state.botVm.machineId) { throw 'The session VM identity changed; no different VM was stopped.' }
        & (Join-Path $root 'vm\control.ps1') -Action Stop -SessionId $state.id -Force:$Force
        $state.botVm.desired = $false
        Save-State
    }
    if (!$state.controller) { $state.controller = @($state.hosts | Where-Object name -eq 'controller' | Select-Object -First 1)[0] }
    foreach ($hostEntry in @($state.hosts | Where-Object name -like '*-launcher')) {
        if (!(Owned $hostEntry) -or $hostEntry.path -ne (Join-Path $root 'lab-client.exe')) { continue }
        foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($hostEntry.pid)" |
            Where-Object ExecutablePath -eq (Join-Path $root 'client-image\GunBound.gme'))) {
            if ($child.ProcessId -notin $state.clients.pid) {
                $p = Get-Process -Id $child.ProcessId -ErrorAction Stop
                $state.clients += @{name=($hostEntry.name -replace '-launcher$','');pid=$p.Id;path=$p.Path;startedUtcTicks=$p.StartTime.ToUniversalTime().Ticks}
            }
        }
    }
    foreach ($part in @('Core','Database')) {
        $hostName = $part.ToLowerInvariant() + '-supervisor'
        $hostEntry = $state.hosts | Where-Object name -eq $hostName | Select-Object -First 1
        $file = Join-Path $root "backend\$($part.ToLowerInvariant())-processes.json"
        if (!(Owned $hostEntry) -or !(Test-Path -LiteralPath $file)) { continue }
        $rows = @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json | Where-Object {
            (Owned $_) -and (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.pid)").ParentProcessId -eq $hostEntry.pid
        })
        if ($rows.Count) { $state.backend[$part] = $rows }
    }
    Save-State
    if (Owned $state.controller) {
        if ($state.controller.path -ne (Join-Path $root 'bot-controller.exe')) { throw 'Controller path is not the owned lab controller.' }
        $bot = Get-Content -LiteralPath (Join-Path $root 'bot-process.json') -Raw | ConvertFrom-Json
        if ($bot.ProcessId -ne $state.controller.pid -or $bot.StartedUtcTicks -ne $state.controller.startedUtcTicks) {
            throw 'Controller metadata changed; refusing to stop a different controller.'
        }
        & (Join-Path $root 'stop-bot.ps1')
    }
    $remaining = @()
    foreach ($entry in @($state.clients)) {
        $p = Owned $entry
        if (!$p) { continue }
        if ($entry.path -ne (Join-Path $root 'client-image\GunBound.gme')) { throw 'Refusing to close an unexpected client path.' }
        $p.CloseMainWindow() | Out-Null
        if (!$p.WaitForExit(12000)) {
            if ($Force) {
                $same = Owned $entry
                if ($same) { Stop-Process -Id $same.Id -ErrorAction Stop }
            } else { $remaining += $entry.pid }
        }
    }
    if ($remaining.Count) {
        throw "Client(s) $($remaining -join ', ') need an exit confirmation. Close them, then run stop-lab.ps1 again; core/database remain available. -Force is explicit emergency client termination."
    }
    foreach ($part in @('Core','Database')) {
        $expected = @($state.backend[$part] | Where-Object { $_ })
        if (!$expected.Count) { continue }
        $file = Join-Path $root "backend\$($part.ToLowerInvariant())-processes.json"
        if (!(Test-Path -LiteralPath $file)) {
            if (@($expected | Where-Object { Owned $_ }).Count) { throw "$part ownership file is missing while an owned process remains." }
            continue
        }
        $current = @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
        foreach ($entry in $current) {
            if (!(Owned $entry)) { continue }
            if (!@($expected | Where-Object { $_.pid -eq $entry.pid -and $_.path -eq $entry.path -and $_.startedUtcTicks -eq $entry.startedUtcTicks }).Count) {
                throw "$part was replaced outside this session; it was not stopped."
            }
        }
        & (Join-Path $root 'backend\stop.ps1') -Part $part
    }
    foreach ($entry in @($state.hosts)) {
        if ($entry.name -eq 'controller') { continue }
        $p = Owned $entry
        if (!$p) { continue }
        if (!$p.WaitForExit(5000)) {
            if ($entry.name -like '*-launcher' -and $entry.path -eq (Join-Path $root 'lab-client.exe')) {
                $same = Owned $entry
                if ($same) { Stop-Process -Id $same.Id -ErrorAction Stop }
            } else { throw "Owned supervisor $($entry.pid) has not finished; no supervisor/database was forcibly killed." }
        }
    }
    $state.phase = 'stopped'
    $state.supervisorActive = $false
    $state.cleanupError = $null
    Save-State
    if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath -ErrorAction Stop }
    Write-Output 'Owned controller, clients and core stopped. A database reused from before this session was left running.'
}
catch {
    $state.phase = 'cleanup-failed'
    $state.supervisorActive = $false
    $state.cleanupError = $_.Exception.Message
    Save-State
    if ($state.logDirectory -and $state.logDirectory.StartsWith($sessionDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $_ | Out-String | Add-Content -LiteralPath (Join-Path $state.logDirectory 'cleanup.err.log')
    }
    throw
}
