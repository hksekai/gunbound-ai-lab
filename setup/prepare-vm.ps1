#requires -Version 7.4
<#
.SYNOPSIS
Installs only this workspace's newly owned VirtualBox guest; never opens Player.
.DESCRIPTION
Run after the root client build and canonical backend seed have completed and stopped.
Requires an existing Oracle VirtualBox 7.2.x installation and Microsoft English x64
Windows Server 2022 Desktop Experience ISO. The standard image is preferred when present.
Guest-only layout is fixed: GUNBOUND-BOT, C:\GunBoundAI, C:\GunBoundServer; LabBot is
non-administrator. Host paths, VM UUID, private MAC, adapter GUID and passwords are generated.
.NOTES
-Check without inputs uses only synthetic data. With inputs it also validates files, but
never mounts media or invokes VBoxManage. Normal installation requires one-time elevation
as the same Windows user; play.ps1 is non-admin. A one-hour Windows readiness window and
two-hour watchdog bound each attempt. -Resume accepts only protected unfinished intents.
An unresponsive initial OS installation may be powered off; server-bearing guests are
never forced off after a failed database stop. Inspect protected cleanup logs in that case.
Success means code/guest/backend health and a powered-off enabled VM, NOT verified gameplay.
#>
[CmdletBinding()]
param(
    [string]$WindowsIso,
    [string]$ServerSourceDirectory,
    [string]$VirtualBoxPath,
    [ValidateRange(4096,65536)][int]$MemoryMiB = 6144,
    [ValidateRange(2,32)][int]$Cpus = 4,
    [switch]$Check,
    [switch]$Resume
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$vm = Join-Path $root 'vm'
. "$vm\host-io.ps1"
if ($Check) {
    & "$vm\check-provision.ps1"
    if ($WindowsIso -or $ServerSourceDirectory -or $VirtualBoxPath) {
        $null = Assert-VmSourceInputs $root $ServerSourceDirectory
        & "$vm\install-platform.ps1" -WindowsIso $WindowsIso -VirtualBoxPath $VirtualBoxPath -Check
    }
    Write-Output 'VM source/synthetic checks passed. No VM, adapter, ISO mount, service, registry, credential, or Player action was performed. This is not installation/gameplay verification.'
    return
}
$source = Assert-VmSourceInputs $root $ServerSourceDirectory
$existing = if (Test-Path -LiteralPath "$vm\config.json") { Read-VmConfig $root } else { $null }
Assert-VmResume $existing ([bool]$Resume) @('preparing','installing','deploying','app-provisioned','migrating','provisioned')
if (Test-VmPlayerOwner $root) { throw 'A live Player session owns this workspace; VM provisioning did not take over.' }
$private = Join-Path $root 'private\vm'
Protect-VmDirectory $private
$lock = [IO.File]::Open((Join-Path $private 'provision.lock'),'OpenOrCreate','ReadWrite','None')
$watcher = $null
$session = $null
$finished = $false
function Watch-Ready {
    if (!$watcher -or $watcher.HasExited -or !(Test-Path -LiteralPath $watchPath)) {
        throw 'The independent bounded provisioning watchdog is not running; no additional VM action is authorized.'
    }
    $state = Get-Content -LiteralPath $watchPath -Raw | ConvertFrom-Json
    if ($state.sessionId -ine $session.sessionId -or $state.status -cne 'watching' -or !(Test-VmProcess $state.process) -or
        $state.process.pid -ne $watcher.Id -or $state.process.path -ine "$PSHOME\pwsh.exe" -or
        $state.process.startedUtcTicks -ne $watcher.StartTime.ToUniversalTime().Ticks -or
        [DateTime]::UtcNow.Ticks - (Get-VmUtcTicks $state.updatedUtc) -gt 150 * [TimeSpan]::TicksPerSecond -or
        [DateTime]::UtcNow.Ticks -ge (Get-VmUtcTicks $session.deadlineUtc)) {
        throw 'Provisioning lost its bounded watchdog/ownership or reached its two-hour deadline.'
    }
    if (Test-VmPlayerOwner $root) { throw 'Maintenance yielded to the new Player session owner.' }
}
function Snapshot-Server($Config) {
    Assert-VmBackendStopped $root
    $path = Join-Path $vm 'server-snapshot.json'
    $data = Join-Path $root 'runtime\mariadb\data'
    $accountsHash = (Get-FileHash -LiteralPath "$root\private\backend\accounts.json" -Algorithm SHA256).Hash
    if (Test-Path -LiteralPath $path) {
        if (!$Resume) { throw 'An existing offline snapshot requires explicit interrupted-installation recovery.' }
        $snapshot = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $null = Assert-VmPath $snapshot.snapshot "$private\server-snapshots"
        if ($snapshot.ownerId -ine $Config.machineId -or $snapshot.sourceData -ine $data -or
            $snapshot.sourceBundle -ine $source -or $snapshot.accountsSha256 -cne $accountsHash -or
            $snapshot.status -notin @('copying','verified')) { throw 'The protected snapshot provenance belongs to another seed/VM.' }
        Assert-VmTreeManifest $data $snapshot.files
    } else {
        if ($Config.phase -ne 'installing') { throw 'The first offline snapshot is missing; it cannot be reconstructed after deployment.' }
        $id = [Guid]::NewGuid().ToString('N')
        $directory = Join-Path $private "server-snapshots\$id"
        Protect-VmDirectory $directory
        $snapshot = [pscustomobject][ordered]@{
            schemaVersion=1;ownerId=$Config.machineId;snapshotId=$id;status='copying';originalPreserved=$false
            snapshot=(Join-Path $directory 'data');sourceData=$data;sourceBundle=$source;accountsSha256=$accountsHash
            backendManifestSha256=(Get-FileHash -LiteralPath "$root\backend\manifest.json" -Algorithm SHA256).Hash
            schemaSha256=(Get-FileHash -LiteralPath "$root\backend\schema-static.sql" -Algorithm SHA256).Hash
            createdUtc=[DateTime]::UtcNow.ToString('o');files=@(Get-VmTreeManifest $data)
        }
        if (!$snapshot.files.Count) { throw 'The prepared canonical host datadir is empty.' }
        Write-VmJson $path $snapshot
    }
    New-Item -ItemType Directory -Path $snapshot.snapshot -Force | Out-Null
    foreach ($file in $snapshot.files) {
        $target = Assert-VmPath (Join-Path $snapshot.snapshot $file.path) $snapshot.snapshot
        if (Test-Path -LiteralPath $target) {
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne $file.sha256) {
                throw 'An existing snapshot file changed; it was not overwritten.'
            }
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        $copy = Join-Path (Split-Path $snapshot.snapshot) ('copy-' + [Guid]::NewGuid().ToString('N'))
        try {
            Copy-Item -LiteralPath (Join-Path $data $file.path) -Destination $copy
            if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -cne $file.sha256) { throw 'Host seed data changed while being snapshotted.' }
            [IO.File]::Move($copy, $target)
        } finally { if ([IO.File]::Exists($copy)) { [IO.File]::Delete($copy) } }
    }
    Assert-VmBackendStopped $root
    Assert-VmTreeManifest $data $snapshot.files
    Assert-VmTreeManifest $snapshot.snapshot $snapshot.files
    $snapshot.status = 'verified'
    $snapshot.originalPreserved = $true
    Write-VmJson $path $snapshot
}
function Wait-Windows($Config) {
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        Watch-Ready
        $info = Get-OwnedVmInfo $root $Config
        if ($info.VMState -ne 'running') { throw "The owned Windows installation stopped ($($info.VMState)); it was not reset." }
        try {
            $probe = Invoke-VmGuest $root $Config -HardwareOnly -TimeoutSeconds 20 -LogName 'windows-readiness.log' -Script @'
$os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10
$setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup'
$image = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
if ($os.BuildNumber -ne '20348' -or $os.ProductType -ne 3 -or !(Test-Path -LiteralPath 'C:\Windows\explorer.exe')) {
    throw 'The installed image is not the inspected Server 2022 Desktop Experience.'
}
if ($setup.SystemSetupInProgress -eq 0 -and $image.ImageState -eq 'IMAGE_STATE_COMPLETE' -and
    (Get-Service -Name VBoxService).Status -eq 'Running' -and
    !(Get-Process -Name 'VBoxWindowsAdditions','VBoxWindowsAdditions-amd64' -ErrorAction SilentlyContinue)) {
    Write-Output 'GUNBOUND_WINDOWS_READY'
}
'@
            if (($probe -join '').Trim() -ceq 'GUNBOUND_WINDOWS_READY') { return }
        } catch [InvalidOperationException] {}
        if ($wait.Elapsed.TotalSeconds -ge 3600) { throw 'Windows did not complete unattended setup/Guest Additions within one hour; the owned installation will be stopped without reinstalling it.' }
        Start-Sleep -Seconds 10
    } while ($true)
}
try {
    $config = & "$vm\prepare.ps1" -WindowsIso $WindowsIso -VirtualBoxPath $VirtualBoxPath -MemoryMiB $MemoryMiB -Cpus $Cpus -Resume:$Resume
    $sessionPath = Join-Path $private 'provision-session.json'
    $takeover = [IO.File]::Open((Join-Path $private 'control.lock'),'OpenOrCreate','ReadWrite','None')
    try {
        $prior = $null
        if (Test-Path -LiteralPath $sessionPath) {
            $prior = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
            if ($prior.ownerId -ine $config.machineId -or $prior.root -ine $root -or (Test-VmProcess $prior.process)) {
                throw 'Another live provisioning owner exists; its lease/VM was not taken over.'
            }
        }
        $self = Get-Process -Id $PID
        try { $identity = [ordered]@{pid=$PID;path=$self.Path;startedUtcTicks=$self.StartTime.ToUniversalTime().Ticks} }
        finally { $self.Dispose() }
        $now = [DateTime]::UtcNow
        $session = [pscustomobject][ordered]@{
            schemaVersion=1;ownerId=$config.machineId;root=$root;sessionId=[Guid]::NewGuid().ToString('D')
            previousSessionId=$(if ($prior) { $prior.sessionId } else { $null })
            process=$identity;status='active';startedUtc=$now.ToString('o');deadlineUtc=$now.AddHours(2).ToString('o')
        }
        Write-VmJson $sessionPath $session
    } finally { $takeover.Dispose() }
    $watchPath = Join-Path $private "watch-$($session.sessionId).json"
    $watcher = Start-Process -FilePath "$PSHOME\pwsh.exe" -ArgumentList @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',"`"$vm\provision-watch.ps1`"",'-SessionId',$session.sessionId
    ) -WorkingDirectory $root -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$private\watch.out.log" -RedirectStandardError "$private\watch.err.log"
    $wait = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path -LiteralPath $watchPath)) {
        if ($watcher.HasExited -or $wait.Elapsed.TotalSeconds -ge 10) { throw 'The independent provisioning watchdog did not become responsive within ten seconds; no VM was started.' }
        Start-Sleep -Milliseconds 100
    }
    Watch-Ready
    $networkPath = Join-Path $root 'network.json'
    $network = [ordered]@{schemaVersion=2;mode='private';serverAddress='192.168.56.10';humanAddress='192.168.56.1'
        botAddress='192.168.56.10';botAddresses=@('192.168.56.10','192.168.56.11','192.168.56.12')}
    if (Test-Path -LiteralPath $networkPath) {
        $old = Get-Content -LiteralPath $networkPath -Raw | ConvertFrom-Json
        $same = $old.schemaVersion -eq 2 -and $old.mode -ceq 'private' -and $old.serverAddress -ceq '192.168.56.10' -and
            $old.humanAddress -ceq '192.168.56.1' -and $old.botAddress -ceq '192.168.56.10' -and
            ($old.botAddresses -join ',') -ceq ($network.botAddresses -join ',') -and @($old.PSObject.Properties).Count -eq 6
        $loopback = $old.schemaVersion -eq 1 -and $old.mode -ceq 'loopback' -and $old.serverAddress -ceq '127.0.0.1' -and
            $old.humanAddress -ceq '127.0.0.1' -and $old.botAddress -ceq '127.0.0.2' -and @($old.PSObject.Properties).Count -eq 5
        if (!$same -and (!$loopback -or $config.phase -ne 'installing' -or (Test-Path -LiteralPath "$vm\package.json"))) {
            throw 'An existing network profile is not the fresh loopback seed or this exact private topology; no unrelated network was changed.'
        }
    } elseif ($config.phase -ne 'installing') { throw 'The recorded private network profile is missing.' }
    Write-VmJson $networkPath $network
    Assert-VmBackendStopped $root
    & "$root\backend\network-config.ps1" -Prepare -SourceDirectory (Join-Path $source 'Server Binaries\GunBoundXP') | Out-Null
    & "$root\backend\network-config.ps1" -Check | Out-Null
    Snapshot-Server $config
    & "$vm\package.ps1" -Resume:$Resume | Out-Null
    & "$vm\server-package.ps1" -Resume:$Resume | Out-Null

    Watch-Ready
    Assert-VmHostAdapter $root $config
    $info = Get-OwnedVmInfo $root $config
    if ($info.VMState -eq 'poweroff') { Invoke-VBox $config.virtualBox @('startvm',$config.machineId,'--type=headless') | Out-Null }
    elseif ($info.VMState -ne 'running') { throw 'Resume requires the owned VM powered off or running, never saved/paused/aborted state adoption.' }
    Wait-Windows $config
    if ($config.phase -in @('installing','deploying')) {
        Watch-Ready
        & "$vm\deploy.ps1" -Resume:($config.phase -eq 'deploying')
        $config = Read-VmConfig $root
    }
    Watch-Ready
    & "$vm\control.ps1" -Action Renew -SessionId $session.sessionId -Maintenance | Out-Null
    if ($config.phase -in @('app-provisioned','migrating')) {
        & "$vm\migrate-server.ps1" -Resume:($config.phase -eq 'migrating')
        $config = Read-VmConfig $root
    }
    if ($config.phase -ne 'provisioned' -or $config.serverLocation -ne 'guest') { throw 'The application/server first-deployment phase did not complete.' }
    Watch-Ready
    $checks = @'
Assert-GuestIdentity -OwnerId '__OWNER__' -Server
$bot = Get-LocalUser -Name LabBot
if (!$bot.Enabled -or (Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object SID -eq $bot.SID)) { throw 'LabBot must remain enabled and non-administrator.' }
$marker = Get-Content -LiteralPath 'C:\GunBoundAI\vm\guest.json' -Raw | ConvertFrom-Json
if (!$marker.roomFill -or ($marker.botInstances.name -join ',') -cne 'BotOne,BotTwo,BotThree') { throw 'Three-bot provisioning is incomplete.' }
foreach ($path in @('C:\GunBoundAI','C:\GunBoundServer')) {
    $manifestFile = if ($path -eq 'C:\GunBoundAI') { "$path\vm\package-manifest.json" } else { "$path\package-manifest.json" }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.ownerId -ine '__OWNER__') { throw 'Code manifest ownership differs.' }
    foreach ($file in $manifest.files) {
        if (($path -eq 'C:\GunBoundAI' -and $file.path -ceq 'vm\guest.json') -or
            ($path -eq 'C:\GunBoundServer' -and $file.path.StartsWith('runtime\mariadb\data\',[StringComparison]::OrdinalIgnoreCase))) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path $path $file.path))
        if (!$target.StartsWith($path + '\',[StringComparison]::OrdinalIgnoreCase) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $file.sha256) { throw 'Provisioned guest code/credential hash mismatch.' }
    }
}
$canonical = @(Get-Content -LiteralPath 'C:\GunBoundServer\private\accounts.json' -Raw | ConvertFrom-Json)
$bots = @(Get-Content -LiteralPath 'C:\GunBoundAI\private\bot-accounts.json' -Raw | ConvertFrom-Json)
if (($canonical.username -join ',') -cne 'Player,BotOne,BotTwo,BotThree' -or
    ($bots.username -join ',') -cne 'BotOne,BotTwo,BotThree') { throw 'Canonical server/bot-only package selection differs.' }
foreach ($instance in $marker.botInstances) {
    $path = 'C:\GunBoundAI\instances\' + $instance.name
    $receipt = Get-Content -LiteralPath "$path\private\instance.json" -Raw | ConvertFrom-Json
    if ($receipt.ownerId -ine '__OWNER__' -or $receipt.root -cne $path -or $receipt.status -cne 'ready' -or
        $receipt.name -cne $instance.name -or $receipt.address -cne $instance.address) { throw 'A per-instance protected root is not ready.' }
    foreach ($file in @('lab-client.exe','lab-tools.exe','bot-controller.exe')) {
        if ((Get-FileHash -LiteralPath "$path\$file" -Algorithm SHA256).Hash -cne
            (Get-FileHash -LiteralPath "C:\GunBoundAI\$file" -Algorithm SHA256).Hash) { throw 'An isolated bot has different code.' }
    }
    if ((Get-FileHash -LiteralPath "$path\client-image\GunBound.gme" -Algorithm SHA256).Hash -cne
        '683CB237147C8DE28C2A5EA3343E9A6B6082EC5D1851F5D20DFBF8BA81A530A8') { throw 'An instance client fingerprint differs.' }
}
& 'C:\GunBoundAI\lab-client.exe' self-check
if ($LASTEXITCODE) { throw 'Guest client code self-check failed.' }
& 'C:\GunBoundAI\bot-controller.exe' --self-check
if ($LASTEXITCODE) { throw 'Guest controller code self-check failed.' }
& 'C:\GunBoundAI\vm\guest-session.ps1' -Check
if (!$?) { throw 'Guest coordinator/input-arbiter checks failed.' }
& 'C:\GunBoundAI\vm\guest-server.ps1' -Check
if (!$?) { throw 'Guest lifecycle/shutdown checks failed.' }
& 'C:\GunBoundAI\vm\configure-room-bots.ps1' -Check
if (!$?) { throw 'Guest instance/network checks failed.' }
foreach ($name in @('GunBoundAI-Backend','GunBoundAI-BotSession','GunBoundAI-IdleShutdown')) {
    $task = Get-ScheduledTask -TaskName $name
    if ($task.Description -cne ('GunBound AI Lab guest ' + $marker.ownerId)) { throw 'Guest scheduled task ownership differs.' }
    Enable-ScheduledTask -TaskName $name | Out-Null
}
Write-Output 'GUNBOUND_CODE_CHECKS_PASSED'
'@
    $result = Invoke-VmGuest $root $config ($checks.Replace('__OWNER__',$config.machineId)) -TimeoutSeconds 900 -LogName 'provision-code-checks.log'
    if ($result -cnotcontains 'GUNBOUND_CODE_CHECKS_PASSED') { throw 'Guest code checks did not publish their completion proof.' }
    Watch-Ready
    & "$vm\control.ps1" -Action Stop -SessionId $session.sessionId -Maintenance | Out-Null
    Disconnect-VmInstallMedia $root $config
    Invoke-VBox $config.virtualBox @('modifyvm',$config.machineId,'--nic1=none','--boot1=disk','--boot2=none','--boot3=none','--boot4=none') | Out-Null
    Watch-Ready
    & "$vm\control.ps1" -Action Start -SessionId $session.sessionId -Maintenance | Out-Null
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        Watch-Ready
        $status = & "$vm\control.ps1" -Action GuestStatus
        if ($status -and $status.schemaVersion -eq 2 -and $status.phase -eq 'waiting-player' -and
            !$status.inputFault -and !$status.lastError -and $status.desiredCount -eq 0) { break }
        if ($wait.Elapsed.TotalSeconds -ge 120) { throw 'The non-admin LabBot desktop/coordinator did not become idle-ready within 120 seconds.' }
        Start-Sleep -Seconds 5
    } while ($true)
    $health = Invoke-VmGuest $root $config -TimeoutSeconds 90 -LogName 'provision-health.log' -Script @'
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive `
    -File 'C:\GunBoundAI\vm\guest-server.ps1' -Action Health
if ($LASTEXITCODE) { throw 'Protected guest backend health failed.' }
Write-Output 'GUNBOUND_BACKEND_HEALTHY'
'@
    if ($health -cnotcontains 'GUNBOUND_BACKEND_HEALTHY') { throw 'Guest backend health did not publish a trustworthy success result.' }
    Watch-Ready
    & "$vm\control.ps1" -Action Stop -SessionId $session.sessionId -Maintenance | Out-Null
    if ((Get-OwnedVmInfo $root $config).VMState -cne 'poweroff') { throw 'Final VM shutdown was not confirmed; readiness was not enabled.' }
    Assert-VmBackendStopped $root
    $snapshot = Get-Content -LiteralPath "$vm\server-snapshot.json" -Raw | ConvertFrom-Json
    Assert-VmTreeManifest (Join-Path $root 'runtime\mariadb\data') $snapshot.files
    Write-VmJson "$private\ready.json" ([ordered]@{schemaVersion=1;ownerId=$config.machineId;verifiedUtc=[DateTime]::UtcNow.ToString('o')
        codeChecksPassed=$true;backendHealthPassed=$true;nonAdminDesktopReady=$true;roomFill=$true;bots=3
        guestPowerState='poweroff';originalHostDataPreserved=$true;gameplayVerified=$false;playerOpened=$false})
    $config.phase = 'ready'
    $config.enabled = $true
    Write-VmJson "$vm\config.json" $config
    $session.status = 'complete'
    Write-VmJson $sessionPath $session
    $finished = $true
    Write-Output 'Owned VM installed, provisioned and enabled for normal play.ps1; it is OFF. Three bot accounts, code checks, non-admin desktop and backend health passed. Player/gameplay were not opened or verified.'
} finally {
    if ($session -and !$finished -and (Test-Path -LiteralPath "$private\provision-session.json")) {
        $current = Get-Content -LiteralPath "$private\provision-session.json" -Raw | ConvertFrom-Json
        if ($current.sessionId -ieq $session.sessionId) {
            $session.status = 'failed'
            Write-VmJson "$private\provision-session.json" $session
        }
    }
    if ($watcher) {
        if (!$watcher.WaitForExit($(if ($finished) { 150000 } else { 360000 }))) {
            Write-Warning 'The independent watchdog is still performing bounded guest cleanup. Inspect private\vm\watch-*.json; no successful shutdown is being inferred.'
        }
        $watcher.Dispose()
    }
    $lock.Dispose()
}
