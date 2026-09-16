#requires -Version 7.0
[CmdletBinding()]
param([switch]$Resume)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\host-io.ps1"
$root = Split-Path $PSScriptRoot
$config = Read-VmConfig $root
$package = Get-Content -LiteralPath "$PSScriptRoot\server-package.json" -Raw | ConvertFrom-Json
$private = Join-Path $root 'private\vm'
$null = Assert-VmPath $package.archive "$private\server-packages"
if ($package.ownerId -ine $config.machineId -or !$package.originalHostDataPreserved -or
    (Get-FileHash -LiteralPath $package.archive -Algorithm SHA256).Hash -cne $package.sha256 -or
    ($Resume -and ($config.phase -cne 'migrating' -or $config.serverPackageSha256 -cne $package.sha256)) -or
    (!$Resume -and $config.phase -cne 'app-provisioned') -or $config.serverLocation -eq 'guest') {
    throw 'This is first server migration only; -Resume requires its matching protected interrupted package intent.'
}
Assert-VmBackendStopped $root
if (Test-VmPlayerOwner $root) { throw 'A Player session owns this workspace; migration did not take over.' }
if ((Get-OwnedVmInfo $root $config).VMState -cne 'running') { throw 'The owned application guest must be running.' }
$prepare = @'
. 'C:\GunBoundAI\vm\shared-io.ps1'
$marker = Get-Content -LiteralPath 'C:\GunBoundAI\vm\guest.json' -Raw | ConvertFrom-Json
$reader = Open-SharedReader 'C:\ProgramData\GunBoundAIControl\lease.json'
try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
if ($text.Length -gt 4096) { throw 'Oversized maintenance lease.' }
$lease = Convert-PlayerLease ($text | ConvertFrom-Json) ([DateTime]::UtcNow)
if ($lease.playerOnline -or $lease.expiresUtcTicks -le [DateTime]::UtcNow.Ticks) { throw 'Migration requires a current offline maintenance lease.' }
if (Get-Process -Name 'GunBound.gme','bot-controller','mariadbd','GunBoundBroker3','Gunboundserv3' -ErrorAction SilentlyContinue) {
    throw 'Migration requires guest clients/database/native core stopped.'
}
foreach ($name in @('GunBoundAI-BotSession','GunBoundAI-IdleShutdown')) {
    $task = Get-ScheduledTask -TaskName $name
    if ($task.Description -cne ('GunBound AI Lab guest ' + $marker.ownerId)) { throw 'Guest task ownership changed.' }
    if ($name -eq 'GunBoundAI-BotSession') {
        Disable-ScheduledTask -TaskName $name | Out-Null
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $name }
    } elseif ($task.State -eq 'Disabled') { throw 'The bounded guest idle shutdown task must remain enabled during provisioning.' }
}
if (Test-Path -LiteralPath 'C:\GunBoundServer') {
    if ('__RESUME__' -cne 'yes') { throw 'An existing server root requires explicit interrupted-first-migration recovery.' }
    $owner = Get-Content -LiteralPath 'C:\GunBoundServer\server-owner.json' -Raw | ConvertFrom-Json
    if ($owner.ownerId -ine '__OWNER__' -or $owner.packageId -cne '__PACKAGE__' -or $owner.root -cne 'C:\GunBoundServer') {
        throw 'Existing server data belongs to another package/VM.'
    }
}
'@
$config.phase = 'migrating'
$config | Add-Member -NotePropertyName serverPackageSha256 -NotePropertyValue $package.sha256 -Force
Write-VmJson "$PSScriptRoot\config.json" $config
Invoke-VmGuest $root $config ($prepare.Replace('__OWNER__',$config.machineId).Replace('__PACKAGE__',$package.packageId).
    Replace('__RESUME__',$(if($Resume){'yes'}else{'no'}))) -LogName 'migrate-prepare.log' | Out-Null
Assert-VmPrivateFile $package.archive
Invoke-VBox -VirtualBoxPath $config.virtualBox -TimeoutSeconds 900 -PrivateLog "$private\migrate-copy.log" -Arguments @(
    'guestcontrol',$config.machineId,'copyto','--quiet','--username=Administrator',
    "--passwordfile=$private\guest-admin.txt",'--target-directory=C:\ProgramData\GunBoundAIProvision\',$package.archive) | Out-Null
$finish = Get-VmGuestPackageScript 'server' $package ([bool]$Resume)
$finish += @'

$owner = Get-Content -LiteralPath 'C:\GunBoundServer\server-owner.json' -Raw | ConvertFrom-Json
if ($owner.ownerId -ine '__OWNER__' -or $owner.packageId -cne '__PACKAGE__') { throw 'Server snapshot/package ownership mismatch.' }
$marker = Get-Content -LiteralPath 'C:\GunBoundAI\vm\guest.json' -Raw | ConvertFrom-Json
$marker | Add-Member -NotePropertyName serverRoot -NotePropertyValue 'C:\GunBoundServer' -Force
$marker | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath 'C:\GunBoundAI\vm\guest.json' -Encoding utf8
Assert-GuestIdentity -OwnerId '__OWNER__' -Server
& 'C:\GunBoundAI\vm\configure-room-bots.ps1'
if (!$?) { throw 'Three-bot guest network/instance preparation failed.' }

$taskName = 'GunBoundAI-Backend'
$old = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($old -and $old.Description -cne ('GunBound AI Lab guest ' + $marker.ownerId)) { throw 'Backend task belongs to another installation.' }
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File C:\GunBoundAI\vm\guest-server.ps1 -Action Start'
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -User SYSTEM -RunLevel Highest -Settings $settings -Description ('GunBound AI Lab guest ' + $marker.ownerId) -Force | Out-Null
Disable-ScheduledTask -TaskName $taskName | Out-Null
@{schemaVersion=1;ownerId=$marker.ownerId;packageId='__PACKAGE__';status='migrated';accounts=4;databaseReinitialized=$false} |
    ConvertTo-Json | Set-Content -LiteralPath 'C:\GunBoundAI\vm\server-receipt.json' -Encoding utf8
Write-Output 'Protected four-account server snapshot migrated without reimporting SQL. Idle shutdown stays enabled; no gameplay claim.'
'@
Invoke-VmGuest $root $config ($finish.Replace('__OWNER__',$config.machineId).Replace('__PACKAGE__',$package.packageId)) `
    -TimeoutSeconds 900 -LogName 'migrate-install.log'
$config | Add-Member -NotePropertyName serverLocation -NotePropertyValue 'guest' -Force
$config | Add-Member -NotePropertyName serverRoot -NotePropertyValue 'C:\GunBoundServer' -Force
$config.phase = 'provisioned'
$config.enabled = $false
Write-VmJson "$PSScriptRoot\config.json" $config
