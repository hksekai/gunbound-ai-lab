#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][Guid]$SessionId)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\host-io.ps1"
$root = Split-Path $PSScriptRoot
$private = Join-Path $root 'private\vm'
$sessionPath = Join-Path $private 'provision-session.json'
$statusPath = Join-Path $private ("watch-$($SessionId.ToString('D')).json")
$self = Get-Process -Id $PID
try { $processIdentity = [ordered]@{pid=$PID;path=$self.Path;startedUtcTicks=$self.StartTime.ToUniversalTime().Ticks} }
finally { $self.Dispose() }
$failures = 0
function Record([string]$Status, [string]$Message = '') {
    Write-VmJson $statusPath ([ordered]@{schemaVersion=1;sessionId=$SessionId.ToString('D');updatedUtc=[DateTime]::UtcNow.ToString('o')
        status=$Status;process=$processIdentity;message=$Message})
}
function Session {
    Assert-VmPrivateFile $sessionPath
    $record = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    if ($record.schemaVersion -ne 1 -or $record.root -ine $root -or $record.sessionId -ine $SessionId.ToString('D')) { return $null }
    $record
}
Record 'watching'
while ($true) {
    $session = Session
    $action = Get-VmWatchAction $session $SessionId.ToString('D') ([DateTime]::UtcNow) `
        (Test-VmProcess $session.process) (Test-VmPlayerOwner $root)
    if ($action -eq 'retire') { Record 'retired'; return }
    if ($action -eq 'yield') { Record 'yielded' 'A new Player session owns the workspace; no maintenance power/lease action was taken.'; return }
    $config = Read-VmConfig $root
    if ($config.machineId -ine $session.ownerId) { Record 'refused' 'VM ownership changed.'; return }
    if ($action -eq 'stop') {
        if ((Get-OwnedVmInfo $root $config).VMState -eq 'poweroff') { Record 'stopped'; return }
        Record 'stopping' 'Provisioning ended, its owner exited, or its two-hour deadline expired.'
        try {
            & "$PSScriptRoot\control.ps1" -Action Stop -SessionId $SessionId.ToString('D') -Maintenance | Out-Null
            Record 'stopped'
            return
        } catch {
            if ($_.Exception.Message -match 'yielded') { Record 'yielded'; return }
            $latest = Session
            if (!$latest -or (Test-VmPlayerOwner $root)) { Record 'yielded'; return }
            $config = Read-VmConfig $root
            if ($config.phase -in @('preparing','installing')) {
                # ponytail: pre-deployment Windows alone may not answer ACPI. Never use this fallback after any app/server deployment.
                $info = Get-OwnedVmInfo $root $config
                if ($info.VMState -ne 'poweroff') { Invoke-VBox $config.virtualBox @('controlvm',$config.machineId,'poweroff') | Out-Null }
                if ((Get-OwnedVmInfo $root $config).VMState -ne 'poweroff') { throw 'Initial-installation power-off was not confirmed.' }
                Record 'stopped' 'Unresponsive initial Windows installation powered off; no server data had been deployed.'
                return
            }
            $failures++
            Record 'stop-failed' 'Graceful protected database shutdown could not be verified. No forced VM power-off; guest idle shutdown remains armed.'
            if ($failures -ge 3) { throw 'Guest/database requires explicit recovery; inspect the protected watchdog and guest-stop logs.' }
            Start-Sleep -Seconds 20
            continue
        }
    }
    try {
        if ($config.phase -in @('deploying','app-provisioned','migrating','provisioned') -and
            (Get-OwnedVmInfo $root $config).VMState -eq 'running') {
            & "$PSScriptRoot\control.ps1" -Action Renew -SessionId $SessionId.ToString('D') -Maintenance | Out-Null
        }
        Record 'watching'
    } catch {
        if ($_.Exception.Message -match 'yielded') { Record 'yielded'; return }
        Record 'watching' 'Guest management is not ready; no Player input was authorized and lease bounds were not extended.'
    }
    Start-Sleep -Seconds 20
}
