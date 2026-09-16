#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('Database','Core','Buddy','All')][string]$Part = 'All')
$ErrorActionPreference = 'Stop'
$lab = Split-Path $PSScriptRoot
. "$PSScriptRoot\network-config.ps1"
$network = Get-LabNetwork
$private = "$lab\private\backend"
$dbBin = "$lab\runtime\mariadb\mariadb-11.4.13-winx64\bin"
$env:TEMP = "$lab\runtime\mariadb\work"
$env:TMP = $env:TEMP
$firewall = New-Object -ComObject HNetCfg.FwPolicy2
foreach ($profile in @(1,2,4)) {
    if (!$firewall.FirewallEnabled($profile) -or $firewall.DefaultInboundAction($profile) -ne 0) {
        throw 'Enabled, default-inbound-block firewall profiles are required. No firewall settings were changed.'
    }
}
$parts = if ($Part -eq 'All') { @('Database','Core') } else { @($Part) }
if ('Core' -in $parts) { Assert-LabNetworkPrepared $network }
$owned = [Collections.Generic.List[object]]::new()
$states = @()
try {
    foreach ($group in $parts) {
        $statePath = "$PSScriptRoot\$($group.ToLowerInvariant())-processes.json"
        if (Test-Path -LiteralPath $statePath) {
            $old = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            foreach ($entry in $old) {
                $running = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
                if ($running -and $running.StartTime.ToUniversalTime().Ticks -eq $entry.startedUtcTicks) {
                    throw "$group already has an owned running process. Stop it before starting again."
                }
            }
        }
        $request = "$PSScriptRoot\$($group.ToLowerInvariant()).stop"
        Remove-Item -LiteralPath $request -ErrorAction SilentlyContinue
        $states += [pscustomobject]@{ path=$statePath; request=$request }
        $specs = switch ($group) {
            Database { @(@{ name='mariadb'; path="$dbBin\mariadbd.exe"; cwd=$lab; args=@("--defaults-file=$private\my.ini",'--console'); port=3307 }) }
            Core {
                @(
                    @{ name='db-compat'; path=(Get-Command pwsh -CommandType Application).Source; cwd=$lab; args=@('-NoProfile','-File',"$PSScriptRoot\mysql-compat.ps1"); port=3308; extraPorts=@(3306); script="$PSScriptRoot\mysql-compat.ps1" }
                    @{ name='world'; path="$PSScriptRoot\native\Server8360\Gunboundserv3.exe"; cwd="$PSScriptRoot\native\Server8360"; args=@('-debug'); port=8360 }
                    @{ name='broker'; path="$PSScriptRoot\native\Central\GunBoundBroker3.exe"; cwd="$PSScriptRoot\native\Central"; args=@('-debug'); port=8372 }
                )
            }
            Buddy {
                @(
                    @{ name='buddy-center'; path="$PSScriptRoot\native\BuddyCenter\BuddyCenter2.exe"; cwd="$PSScriptRoot\native\BuddyCenter"; args=@('-debug'); port=8339 }
                    @{ name='buddy'; path="$PSScriptRoot\native\BuddyServ\BuddyServ2.exe"; cwd="$PSScriptRoot\native\BuddyServ"; args=@('-debug'); port=8352 }
                )
            }
        }
        $entries = @()
        foreach ($spec in $specs) {
            $ports = @($spec.port) + @($spec.extraPorts | Where-Object { $_ })
            if (Get-NetTCPConnection -State Listen -LocalPort $ports -ErrorAction SilentlyContinue) {
                throw "A required port ($($ports -join ', ')) is already in use; no existing process was stopped."
            }
            $quoted = ($spec.args | ForEach-Object { '"' + $_ + '"' }) -join ' '
            if ($spec.path.StartsWith("$PSScriptRoot\native\", [StringComparison]::OrdinalIgnoreCase)) {
                New-Item -ItemType Directory -Path "$($spec.cwd)\log" -Force | Out-Null
            }
            $process = Start-Process -FilePath $spec.path -ArgumentList $quoted -WorkingDirectory $spec.cwd -NoNewWindow -PassThru `
                -RedirectStandardOutput "$lab\logs\backend-$($spec.name)-stdout.log" -RedirectStandardError "$lab\logs\backend-$($spec.name)-stderr.log"
            $entry = [pscustomobject]@{
                name=$spec.name; pid=$process.Id; path=$spec.path; port=$spec.port
                startedUtcTicks=$process.StartTime.ToUniversalTime().Ticks; group=$group; script=$spec.script; extraPorts=$spec.extraPorts
                supervisorPid=$PID; supervisorPath=(Get-Process -Id $PID).Path
                supervisorStartedUtcTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
                bindAddress=if ($spec.name -in @('world','broker')) { $network.ServerAddress } else { '127.0.0.1' }
            }
            $owned.Add($entry)
            $entries += $entry
            $stage = $statePath + '.' + [Guid]::NewGuid().ToString('N') + '.stage'
            $stream = [IO.File]::Open($stage, 'CreateNew', 'Write', 'None')
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $entries))
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            } finally { $stream.Dispose() }
            [IO.File]::Move($stage, $statePath, $true)
            $watch = [Diagnostics.Stopwatch]::StartNew()
            do {
                if ($process.HasExited) { throw "$($spec.name) exited ($($process.ExitCode)); inspect its backend logs." }
                $listening = @(Assert-LabServiceEndpoints $entry $network -AllowStarting)
                if ($listening.Count -ne $ports.Count) { Start-Sleep -Milliseconds 250 }
            } until ($listening.Count -eq $ports.Count -or $watch.Elapsed.TotalSeconds -gt 30)
            if ($listening.Count -ne $ports.Count) { throw "$($spec.name) did not finish TCP/UDP startup within 30 seconds. A lingering TCP listener alone is not readiness; inspect backend logs and Windows Application Error events." }
            Write-Output "$($spec.name) PID=$($entry.pid) TCP=$($listening | ForEach-Object { $_.LocalAddress + ':' + $_.LocalPort } | Join-String -Separator ',')"
        }
    }
    $stability = [Diagnostics.Stopwatch]::StartNew()
    $announced = $false
    $nextWorldProbe = 0
    while ($true) {
        if (@($states | Where-Object { Test-Path -LiteralPath $_.request }).Count) { break }
        if ('Core' -in $parts) {
            Assert-LabNetworkUnchanged $network 'network.json changed while Core was running. Stop Core before switching profiles.'
        }
        foreach ($entry in $owned) {
            $p = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
            if (!$p -or $p.Path -ne $entry.path -or $p.StartTime.ToUniversalTime().Ticks -ne $entry.startedUtcTicks) {
                throw "$($entry.name) PID $($entry.pid) stopped unexpectedly; inspect backend logs."
            }
            Assert-LabServiceEndpoints $entry $network | Out-Null
        }
        if ('world' -in $owned.name -and $stability.Elapsed.TotalSeconds -ge $nextWorldProbe) {
            Test-LabWorldResponse $network
            $nextWorldProbe = $stability.Elapsed.TotalSeconds + 5
        }
        if (!$announced -and ($Part -eq 'Database' -or $stability.Elapsed.TotalSeconds -ge 15)) {
            if ($Part -ne 'Database') { & "$PSScriptRoot\health.ps1" }
            Write-Output "Backend $Part is supervised in this foreground session. Use backend\stop.ps1 to stop it."
            $announced = $true
        }
        Start-Sleep -Seconds 1
    }
}
catch {
    $_ | Out-String | Add-Content -LiteralPath "$lab\logs\backend-supervisor-errors.log"
    throw
}
finally {
    $shutdownFailure = $null
    foreach ($entry in @($owned | Sort-Object { if ($_.name -eq 'mariadb') { 2 } elseif ($_.name -eq 'db-compat') { 1 } else { 0 } })) {
        $p = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
        if (!$p -or $p.StartTime.ToUniversalTime().Ticks -ne $entry.startedUtcTicks -or $p.Path -ne $entry.path) { continue }
        if ($entry.name -eq 'mariadb') {
            & "$dbBin\mariadb-admin.exe" "--defaults-file=$private\admin.ini" shutdown 2>> "$lab\logs\backend-shutdown-errors.log"
            if ($LASTEXITCODE -ne 0 -or !$p.WaitForExit(20000)) {
                $shutdownFailure = 'Graceful database shutdown failed or remains pending. Ownership state was retained; repair private admin configuration and run backend\stop.ps1 -Part Database. No database was forcibly killed.'
                continue
            }
        } elseif (!$p.HasExited) {
            Stop-Process -Id $entry.pid -ErrorAction SilentlyContinue
        }
        Write-Output "Stopped owned $($entry.name) PID=$($entry.pid)"
    }
    foreach ($state in $states) {
        $running = @($owned | Where-Object { $_.group.ToLowerInvariant() + '-processes.json' -eq (Split-Path $state.path -Leaf) } | Where-Object {
            $p = Get-Process -Id $_.pid -ErrorAction SilentlyContinue
            $p -and $p.Path -eq $_.path -and $p.StartTime.ToUniversalTime().Ticks -eq $_.startedUtcTicks
        })
        if ($running.Count) { continue }
        [IO.File]::Delete($state.path)
        [IO.File]::Delete($state.request)
    }
    if ($shutdownFailure) { throw $shutdownFailure }
}
