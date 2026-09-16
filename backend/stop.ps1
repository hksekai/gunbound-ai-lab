#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('Database','Core','Buddy','All')][string]$Part = 'All')
$ErrorActionPreference = 'Stop'
$lab = Split-Path $PSScriptRoot
$parts = if ($Part -eq 'All') { @('Core','Buddy','Database') } else { @($Part) }
foreach ($group in $parts) {
    $statePath = "$PSScriptRoot\$($group.ToLowerInvariant())-processes.json"
    if (!(Test-Path -LiteralPath $statePath)) { continue }
    $entries = @(Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
    [IO.File]::WriteAllText("$PSScriptRoot\$($group.ToLowerInvariant()).stop", 'stop')
    foreach ($entry in @($entries | Sort-Object { if ($_.name -eq 'db-compat') { 1 } else { 0 } })) {
        $p = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
        if (!$p -or $p.Path -ne $entry.path -or $p.StartTime.ToUniversalTime().Ticks -ne $entry.startedUtcTicks) { continue }
        $expectedPath = switch -CaseSensitive ($entry.name) {
            'mariadb' { "$lab\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe" }
            'world' { "$PSScriptRoot\native\Server8360\Gunboundserv3.exe" }
            'broker' { "$PSScriptRoot\native\Central\GunBoundBroker3.exe" }
            'buddy-center' { "$PSScriptRoot\native\BuddyCenter\BuddyCenter2.exe" }
            'buddy' { "$PSScriptRoot\native\BuddyServ\BuddyServ2.exe" }
            default { '' }
        }
        $ownedPath = $expectedPath -and $entry.path -ieq $expectedPath -and $entry.group -ceq $group
        if ($entry.name -eq 'db-compat' -and $entry.script -eq "$PSScriptRoot\mysql-compat.ps1") {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($entry.pid)" -ErrorAction SilentlyContinue).CommandLine
            if (!$commandLine) {
                $p.Refresh()
                if ($p.HasExited) {
                    Write-Output "Owned $($entry.name) PID=$($entry.pid) already stopped during cleanup."
                    continue
                }
            }
            $ownedPath = $entry.group -ceq 'Core' -and $commandLine -and $commandLine.Contains($entry.script)
        }
        if ($entry.pid -eq $PID -or !$ownedPath) {
            throw 'Refusing to stop an unowned/protected process.'
        }
        if (!$p.WaitForExit(8000)) {
            if ($entry.name -eq 'mariadb') {
                & "$lab\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadb-admin.exe" "--defaults-file=$lab\private\backend\admin.ini" shutdown
                if ($LASTEXITCODE) { throw 'Graceful database shutdown failed; the database was not forcibly killed.' }
                if (!$p.WaitForExit(15000)) { throw 'Database shutdown is still pending.' }
            } else {
                Stop-Process -Id $entry.pid
            }
        }
        Write-Output "Stopped owned $($entry.name) PID=$($entry.pid)"
    }
    if ($entries.Count -and $entries[0].supervisorPid -and $entries[0].supervisorPid -ne $PID) {
        $supervisor = Get-Process -Id $entries[0].supervisorPid -ErrorAction SilentlyContinue
        if ($supervisor -and $supervisor.Path -eq $entries[0].supervisorPath -and
            $supervisor.StartTime.ToUniversalTime().Ticks -eq $entries[0].supervisorStartedUtcTicks -and
            !$supervisor.WaitForExit(15000)) {
            throw 'The owned backend supervisor is still finishing cleanup; a replacement was not started.'
        }
    }
    [IO.File]::Delete($statePath)
    [IO.File]::Delete("$PSScriptRoot\$($group.ToLowerInvariant()).stop")
}
