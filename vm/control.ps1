#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('On','Off','Status','Start','Stop','Renew','GuestStatus','Check')]
    [string]$Action = 'Status',
    [string]$SessionId,
    [switch]$PlayerOnline,
    [switch]$RoomReady,
    [Nullable[int]]$RoomId,
    [ValidateSet(0,2,4,6,8)][int]$RoomCapacity = 0,
    [switch]$Force,
    [switch]$Maintenance
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\host-io.ps1"
$root = Split-Path $PSScriptRoot
$private = Join-Path $root 'private\vm'
$expectedFile = "$root\runtime\vm\GunBound-BotOne\GunBound-BotOne.vbox"
$config = if ($Action -eq 'Check') {
    [pscustomobject]@{machineId='11111111-2222-3333-4444-555555555555';machineFile=$expectedFile;roomFill=$true}
} else { Read-VmConfig $root }
function VBox([string[]]$Arguments) {
    Invoke-VBox $config.virtualBox $Arguments -TimeoutSeconds 240 -PrivateLog "$private\control-vbox.log"
}
function Parse-Info([string[]]$Lines) {
    Convert-VBoxInfo @($Lines | Where-Object { $_ -match '^(UUID|CfgFile|VMState|memory|cpus)=' })
}
function Info {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $notified = $false
    do {
        try {
            $lines = VBox @('showvminfo',$config.machineId,'--machinereadable')
            break
        } catch [InvalidOperationException] {
            if ($_.Exception.Message -notmatch '(?s)Failed to get a console object from the direct session.*VBOX_E_INVALID_OBJECT_STATE' -or
                $watch.Elapsed.TotalSeconds -ge 5) { throw }
            if (!$notified) {
                Write-Warning 'VirtualBox is changing the guest console state; waiting for its verified power-state response.'
                $notified = $true
            }
            Start-Sleep -Milliseconds 200
        }
    } while ($true)
    $info = Parse-Info $lines
    if ($info.UUID -ne $config.machineId -or $info.CfgFile -ne $expectedFile) {
        throw 'Registered VM identity/path changed; no power or guest action was taken.'
    }
    $info
}
function Guest([string]$Script, [int]$TimeoutMs = 45000, [switch]$HardwareOnly) {
    $helpers = ''
    foreach ($name in @('Open-SharedReader','Utc-Ticks','Convert-PlayerLease','Assert-UnstartedGuestServer')) {
        $helpers += "function $name {`n" + (Get-Item "Function:\$name").ScriptBlock.ToString() + "`n}`n"
    }
    (Invoke-VmGuest $root $config ($helpers + $Script) -HardwareOnly:$HardwareOnly `
        -TimeoutSeconds ([int][Math]::Ceiling($TimeoutMs / 1000)) -LogName 'control-guest.log') -join [Environment]::NewLine
}
function Assert-Maintenance {
    if (!$Maintenance) { return }
    if ($PlayerOnline -or $RoomReady -or $Force) { throw 'Provisioning maintenance cannot grant Player input or request forced power-off.' }
    Assert-VmPrivateFile "$private\provision-session.json"
    $session = Get-Content -LiteralPath "$private\provision-session.json" -Raw | ConvertFrom-Json
    if ($session.schemaVersion -ne 1 -or $session.ownerId -ine $config.machineId -or $session.root -ine $root -or
        $session.sessionId -ine $SessionId -or $session.status -notin @('active','failed') -or
        ($Action -ne 'Stop' -and ($session.status -ne 'active' -or !(Test-VmProcess $session.process) -or
            (Get-VmUtcTicks $session.deadlineUtc) -le [DateTime]::UtcNow.Ticks))) {
        throw 'The protected bounded provisioning session no longer authorizes this maintenance action.'
    }
    if (Test-VmPlayerOwner $root) { throw 'Maintenance yielded to the new Player session owner.' }
}
function Read-GuestStatus {
    $json = Guest @'
$ErrorActionPreference = 'Stop'
$file = 'C:\GunBoundAI\session\guest-status.json'
if (Test-Path -LiteralPath $file) {
    $reader = Open-SharedReader $file
    try {
        $buffer = New-Object char[] 65537
        $count = $reader.ReadBlock($buffer,0,$buffer.Length)
        $text = [string]::new($buffer,0,$count)
    } finally { $reader.Dispose() }
    if ($text.Length -gt 65536) { throw 'Oversized guest status.' }
    Write-Output $text
} else { Write-Output 'null' }
'@
    $json | ConvertFrom-Json
}
function New-Lease([string]$Identifier, [bool]$Online, [bool]$Room,
    [Nullable[int]]$RoomIdentifier = $null, [int]$Capacity = 0, [bool]$MultiRoom = $false) {
    $session = [Guid]::Empty
    if (![Guid]::TryParse($Identifier,[ref]$session) -or $session -eq [Guid]::Empty) {
        throw [ArgumentException]::new('A nonempty managed Player session ID is required.')
    }
    $now = [DateTime]::UtcNow
    $lease = [ordered]@{schemaVersion=$(if ($MultiRoom) { 2 } else { 1 });sessionId=$session.ToString('D');issuedUtc=$now.ToString('o')
        expiresUtc=$now.AddSeconds(120).ToString('o');playerOnline=$Online;roomReady=$Room}
    if ($MultiRoom) { $lease.roomId = $RoomIdentifier; $lease.roomCapacity = $Capacity }
    Convert-PlayerLease $lease $now | Out-Null
    $lease
}
function Deliver-Lease($Lease) {
    Assert-Maintenance
    $previousId = [Guid]::Empty
    if ($Maintenance) {
        $record = Get-Content -LiteralPath "$private\provision-session.json" -Raw | ConvertFrom-Json
        if ($record.previousSessionId -and ![Guid]::TryParseExact([string]$record.previousSessionId, 'D', [ref]$previousId)) {
            throw 'Invalid protected interrupted-maintenance handoff.'
        }
    }
    $json = $Lease | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $script = @'
$ErrorActionPreference = 'Stop'
$marker = Get-Content -LiteralPath 'C:\GunBoundAI\vm\guest.json' -Raw | ConvertFrom-Json
if ($marker.root -ne 'C:\GunBoundAI' -or $marker.computerName -ne $env:COMPUTERNAME) { throw 'Guest identity mismatch.' }
$text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__'))
$file = 'C:\ProgramData\GunBoundAIControl\lease.json'
$watch = [Diagnostics.Stopwatch]::StartNew()
do {
    try { $leaseLock = [IO.File]::Open($file + '.lock','OpenOrCreate','ReadWrite','None'); break }
    catch [IO.IOException] {
        if ($watch.Elapsed.TotalSeconds -ge 5) { throw }
        Start-Sleep -Milliseconds 50
    }
} while ($true)
try {
if ('__MAINTENANCE__' -eq 'yes' -and (Test-Path -LiteralPath $file)) {
    $reader = Open-SharedReader $file
    try { $previous = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($previous.Length -gt 4096) { throw 'Oversized existing lease; maintenance cannot infer ownership.' }
    $old = Convert-PlayerLease ($previous | ConvertFrom-Json) ([DateTime]::UtcNow)
    $next = Convert-PlayerLease ($text | ConvertFrom-Json) ([DateTime]::UtcNow)
    if ($old.sessionId -ine $next.sessionId -and $old.expiresUtcTicks -gt [DateTime]::UtcNow.Ticks -and
        ($old.playerOnline -or $old.sessionId -ine '__PREVIOUS__')) {
        throw 'MAINTENANCE_YIELD'
    }
}
[IO.File]::WriteAllText($file + '.new',$text)
if (Test-Path -LiteralPath $file) { [IO.File]::Replace($file + '.new',$file,[NullString]::Value) }
else { [IO.File]::Move($file + '.new',$file) }
$status = 'C:\GunBoundAI\session\guest-status.json'
if (Test-Path -LiteralPath $status) {
    $reader = Open-SharedReader $status
    try {
        $buffer = New-Object char[] 65537
        $count = $reader.ReadBlock($buffer,0,$buffer.Length)
        $result = [string]::new($buffer,0,$count)
    } finally { $reader.Dispose() }
    if ($result.Length -gt 65536) { throw 'Oversized guest status.' }
    Write-Output $result
} else { Write-Output 'null' }
} finally { $leaseLock.Dispose() }
'@
    $result = Guest ($script.Replace('__PAYLOAD__',$payload).Replace('__MAINTENANCE__',$(if ($Maintenance) {'yes'} else {'no'})).
        Replace('__PREVIOUS__',$previousId.ToString('D')))
    [IO.File]::WriteAllText("$private\lease.json",$json)
    $result | ConvertFrom-Json
}
function Stop-Guest([switch]$Hard) {
    Assert-Maintenance
    $info = Info
    if ($info.VMState -eq 'poweroff') { Write-Output 'Bot VM is already off.'; return }
    if ($Hard) {
        VBox @('controlvm',$config.machineId,'poweroff') | Out-Null
    } else {
        if ($info.VMState -ne 'running') { throw "The VM is $($info.VMState). Use explicit -Force only for emergency power-off." }
        $additions = (VBox @('guestproperty','get',$config.machineId,'/VirtualBox/GuestAdd/Version')) -join ''
        if ($additions -match '^Value:') {
            try {
            if ($config.phase -in @('app-provisioned','migrating','provisioned','ready')) {
                $stopSession = if ($Maintenance) { $SessionId } else { [Guid]::NewGuid().ToString('D') }
                Deliver-Lease (New-Lease $stopSession $false $false $null 0 ([bool]$config.roomFill)) | Out-Null
            }
            Assert-Maintenance
            $shutdown = @'
$ErrorActionPreference = 'Stop'
$marker = $null
if (Test-Path -LiteralPath 'C:\GunBoundAI') {
    Assert-GuestIdentity -OwnerId '__OWNER__'
    $marker = Get-Content -LiteralPath 'C:\GunBoundAI\vm\guest.json' -Raw | ConvertFrom-Json
}
if ($marker -and $marker.serverRoot -eq 'C:\GunBoundServer') {
    Assert-GuestIdentity -OwnerId '__OWNER__' -Server
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive `
        -File 'C:\GunBoundAI\vm\guest-server.ps1' -Action Stop
    if ($LASTEXITCODE) { throw 'The protected guest database/server did not stop gracefully; Windows shutdown was not requested.' }
} else {
    Assert-UnstartedGuestServer -OwnerId '__OWNER__'
}
& "$env:SystemRoot\System32\shutdown.exe" /s /t 10 /c 'GunBound AI Lab: bot turned off.'
if ($LASTEXITCODE) { throw 'Guest shutdown request failed.' }
'@
            Guest -TimeoutMs 210000 -HardwareOnly -Script ($shutdown.Replace('__OWNER__',$config.machineId)) | Out-Null
            } catch [InvalidOperationException] {
                if ($Maintenance -or $config.phase -in @('migrating','provisioned','ready')) {
                    throw [InvalidOperationException]::new("Guest database shutdown was not verified; the VM remains on to protect data. $($_.Exception.Message)")
                }
                Write-Warning "Guest shutdown RPC failed; requesting the owned VM's ACPI shutdown: $($_.Exception.Message)"
                VBox @('controlvm',$config.machineId,'acpipowerbutton') | Out-Null
            }
        } else {
            if ($config.phase -in @('migrating','provisioned','ready')) { throw 'Guest management is unavailable; database shutdown cannot be verified, so no power-off was requested.' }
            VBox @('controlvm',$config.machineId,'acpipowerbutton') | Out-Null
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ((Info).VMState -ne 'poweroff') {
            if ($watch.Elapsed.TotalSeconds -ge 120) { throw 'Bot VM has not shut down. It was not forcibly powered off; inspect Status or use explicit -Force.' }
            Start-Sleep -Seconds 1
        }
    }
    if ((Info).VMState -ne 'poweroff') { throw 'VM power-off was not confirmed.' }
    Write-Output 'Owned VM power-off confirmed; the preserved host database was not modified.'
}
if ($Action -eq 'Check') {
    $parsed = Parse-Info @('UUID="11111111-2222-3333-4444-555555555555"','CfgFile="C:\\lab\\vm.vbox"','VMState="poweroff"','GuestProperty="metadata" @123')
    if ($parsed.CfgFile -ne 'C:\lab\vm.vbox' -or $parsed.VMState -ne 'poweroff') { throw 'VM identity decoding changed.' }
    $savedVBox = ${function:VBox}
    try {
        $script:checkInfoCalls = 0
        $script:checkInfoFailure = 'transition'
        function VBox([string[]]$Arguments) {
            $script:checkInfoCalls++
            if ($script:checkInfoFailure -eq 'other') { throw [InvalidOperationException]::new('Unrelated VM operation failure.') }
            if (($script:checkInfoFailure -eq 'transition' -and $script:checkInfoCalls -eq 1) -or
                $script:checkInfoFailure -eq 'persistent-transition') {
                throw [InvalidOperationException]::new('Failed to get a console object from the direct session (VBOX_E_INVALID_OBJECT_STATE)')
            }
            @(
                'UUID="' + $config.machineId + '"'
                'CfgFile=' + ($expectedFile | ConvertTo-Json -Compress)
                'VMState="poweroff"'
            )
        }
        $recovered = Info
        if ($script:checkInfoCalls -ne 2 -or $recovered.VMState -ne 'poweroff') { throw 'The known console-transition race did not recover with a verified state.' }
        $script:checkInfoCalls = 0
        $script:checkInfoFailure = 'other'
        $rejected = $false
        try { Info | Out-Null } catch [InvalidOperationException] { $rejected = $_.Exception.Message -eq 'Unrelated VM operation failure.' }
        if (!$rejected -or $script:checkInfoCalls -ne 1) { throw 'An unrelated VM failure was retried or hidden.' }
        $script:checkInfoCalls = 0
        $script:checkInfoFailure = 'persistent-transition'
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $rejected = $false
        try { Info | Out-Null } catch [InvalidOperationException] {
            $rejected = $_.Exception.Message -match 'VBOX_E_INVALID_OBJECT_STATE'
        }
        if (!$rejected -or $script:checkInfoCalls -lt 2 -or
            $deadline.Elapsed.TotalSeconds -lt 5 -or $deadline.Elapsed.TotalSeconds -gt 10) {
            throw 'A persistent console-transition failure did not stop at its bounded deadline.'
        }
    } finally { Set-Item -Path Function:\VBox -Value $savedVBox }
    $sample = New-Lease ([Guid]::NewGuid().ToString('N')) $true $false
    if (([DateTime]$sample.expiresUtc - [DateTime]$sample.issuedUtc).TotalSeconds -ne 120 -or $sample.roomReady) { throw 'Lease boundaries changed.' }
    $rejected = $false
    try { New-Lease 'not-a-session' $true $true | Out-Null } catch [ArgumentException] { $rejected = $true }
    if (!$rejected) { throw 'An invalid session was accepted.' }
    $samplePath = Join-Path $root ('shared-reader-' + [Guid]::NewGuid().ToString('N'))
    $reader = $null
    try {
        [IO.File]::WriteAllText($samplePath, 'old')
        $reader = Open-SharedReader $samplePath
        [IO.File]::WriteAllText($samplePath + '.new', 'new')
        [IO.File]::Replace($samplePath + '.new', $samplePath, [NullString]::Value)
        if ($reader.ReadToEnd() -cne 'old' -or [IO.File]::ReadAllText($samplePath) -cne 'new') {
            throw 'An open status reader did not preserve atomic old/new file versions.'
        }
        $reader.Dispose(); $reader = $null
        $exclusive = [IO.File]::Open($samplePath,'Open','ReadWrite','None')
        try {
            $retryWatch = [Diagnostics.Stopwatch]::StartNew()
            $rejected = $false
            try { (Open-SharedReader $samplePath).Dispose() }
            catch [IO.IOException] { $rejected = $true }
            if (!$rejected -or $retryWatch.ElapsedMilliseconds -lt 900 -or $retryWatch.ElapsedMilliseconds -gt 2500) {
                throw 'Sharing contention was not retried within its bounded one-second deadline.'
            }
        } finally { $exclusive.Dispose() }
        [IO.File]::Delete($samplePath)
        $retryWatch = [Diagnostics.Stopwatch]::StartNew()
        $rejected = $false
        try { (Open-SharedReader $samplePath).Dispose() }
        catch [IO.FileNotFoundException] { $rejected = $true }
        if (!$rejected -or $retryWatch.ElapsedMilliseconds -ge 900) { throw 'Default missing-status reads acquired an unintended publication wait.' }
        $retryWatch = [Diagnostics.Stopwatch]::StartNew()
        $rejected = $false
        try { (Open-SharedReader $samplePath -WaitForPublication).Dispose() }
        catch [IO.FileNotFoundException] { $rejected = $true }
        if (!$rejected -or $retryWatch.ElapsedMilliseconds -lt 900 -or $retryWatch.ElapsedMilliseconds -gt 2500) {
            throw 'A missing lease publication did not stop at its bounded one-second deadline.'
        }
        $rejected = $false
        try { (Open-SharedReader (Split-Path -Parent $samplePath) -WaitForPublication).Dispose() }
        catch [IO.InvalidDataException] { $rejected = $true }
        if (!$rejected) { throw 'A directory was accepted as a lease publication.' }
        $started = [Threading.ManualResetEventSlim]::new($false)
        $publisher = [PowerShell]::Create()
        try {
            $null = $publisher.AddScript('param($Path,$Started) $Started.Set(); Start-Sleep -Milliseconds 150; [IO.File]::WriteAllText($Path+".new","published"); [IO.File]::Move($Path+".new",$Path)').AddArgument($samplePath).AddArgument($started)
            $pending = $publisher.BeginInvoke()
            if (!$started.Wait(5000)) { throw 'The delayed publication check did not start.' }
            $reader = Open-SharedReader $samplePath -WaitForPublication
            if ($reader.ReadToEnd() -cne 'published') { throw 'A briefly missing lease publication was not recovered.' }
            $reader.Dispose(); $reader = $null
            $publisher.EndInvoke($pending) | Out-Null
            if ($publisher.HadErrors) { throw 'The delayed publication check failed.' }
        } finally {
            $publisher.Stop()
            $publisher.Dispose()
            $started.Dispose()
        }
        $originalAccess = Get-Acl -LiteralPath $samplePath
        $deniedAccess = Get-Acl -LiteralPath $samplePath
        $deniedAccess.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.AccessControlType]::Deny))
        try {
            Set-Acl -LiteralPath $samplePath -AclObject $deniedAccess
            $retryWatch = [Diagnostics.Stopwatch]::StartNew()
            $rejected = $false
            try { (Open-SharedReader $samplePath -WaitForPublication).Dispose() }
            catch [UnauthorizedAccessException] { $rejected = $true }
            if (!$rejected -or $retryWatch.ElapsedMilliseconds -lt 900 -or $retryWatch.ElapsedMilliseconds -gt 2500) {
                throw 'Persistent lease access denial was bypassed or retried without a deadline.'
            }
        } finally { Set-Acl -LiteralPath $samplePath -AclObject $originalAccess }
    } finally {
        if ($reader) { $reader.Dispose() }
        [IO.File]::Delete($samplePath + '.new')
        [IO.File]::Delete($samplePath)
    }
    Write-Output 'PASS: VM identity decoding, bounded console-transition recovery, bounded Player leases, atomic readers, and missing-publication recovery without invented authority. No VM action performed.'
    return
}

if ($Action -in @('On','Off')) {
    $stateFile = "$root\session\lab-session.json"
    $state = if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } else { $null }
    $owner = if ($state -and $state.supervisor) { Get-Process -Id $state.supervisor.pid -ErrorAction SilentlyContinue } else { $null }
    $active = $owner -and $state.supervisorActive -and $state.root -eq $root -and
        $owner.Path -eq $state.supervisor.path -and $owner.StartTime.ToUniversalTime().Ticks -eq $state.supervisor.startedUtcTicks
    if ($active) {
        if (!$state.botVm -or $state.botVm.machineId -ne $config.machineId) { throw 'The existing Player session is not using this VM; it was not replaced.' }
        $request = @{sessionId=$state.id;action=$Action.ToLowerInvariant()} | ConvertTo-Json -Compress
        [IO.File]::WriteAllText("$root\session\bot.request.new",$request)
        [IO.File]::Move("$root\session\bot.request.new","$root\session\bot.request",$true)
        Write-Output "Bot $($Action.ToLowerInvariant()) requested from the active Player session."
        return
    }
    if ($Action -eq 'On') {
        if (!$config.enabled -or $config.phase -ne 'ready') { throw 'The independent bot has not passed provisioning and been enabled yet.' }
        & "$root\play.ps1" -Isolated
        return
    }
    $Action = 'Stop'
}
$info = Info
if ($Action -eq 'Status') {
    [pscustomobject]@{provider='virtualbox';machine=$config.machineName;powerState=$info.VMState
        provisioning=$config.phase;enabled=$config.enabled;memoryMiB=$info.memory
        azureResourcesCreated=$false;azureComputeCharges='none'}
    return
}
if ($Action -eq 'GuestStatus') {
    if ($info.VMState -ne 'running') { throw "Bot VM is $($info.VMState), not running." }
    Read-GuestStatus
    return
}
# Provisioning copies/health checks can outlast a lease. Only the verified offline renewer may run beside them.
$lock = if ($Maintenance -and $Action -eq 'Renew') { $null } else {
    [IO.File]::Open("$private\control.lock",'OpenOrCreate','ReadWrite','None')
}
try {
    Assert-Maintenance
    if ($Action -eq 'Stop') { Stop-Guest -Hard:$Force; return }
    $allowed = if ($Maintenance) { @('deploying','app-provisioned','migrating','provisioned','ready') } else { @('provisioned','ready') }
    if ($config.phase -notin $allowed) { throw 'The guest must be provisioned before delivering Player leases.' }
    $lease = New-Lease $SessionId ([bool]$PlayerOnline) ([bool]$RoomReady) $RoomId $RoomCapacity ([bool]$config.roomFill)
    if ($Action -eq 'Start') {
        Assert-VmHostAdapter $root $config
        if ($info.VMState -eq 'poweroff') {
            Write-Host 'Starting the VM. A cold Windows boot and backend startup can take about 1-2 minutes.'
            VBox @('startvm',$config.machineId,'--type=headless') | Out-Null
        }
        elseif ($info.VMState -ne 'running') { throw "The owned VM cannot start from $($info.VMState); inspect it first." }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $nextNotice = 15
        Write-Host 'Waiting for Windows guest services...'
        do {
            $info = Info
            if ($info.VMState -ne 'running') { throw "The VM stopped during startup: $($info.VMState)." }
            $additions = (VBox @('guestproperty','get',$config.machineId,'/VirtualBox/GuestAdd/Version')) -join ''
            if ($additions -match '^Value:') {
                try {
                    $probe = Guest "Write-Output 'GUNBOUND_GUEST_READY'"
                    if ($probe.Trim() -eq 'GUNBOUND_GUEST_READY') { break }
                    throw [InvalidOperationException]::new('The guest readiness probe returned unexpected output.')
                } catch [InvalidOperationException] {
                    if ($_.Exception.Message -notmatch 'Guest Additions are not installed or not ready|guest execution service is not ready|Error starting guest session.*starting') { throw }
                }
            }
            if ($watch.Elapsed.TotalSeconds -ge $nextNotice) {
                Write-Host ("Windows guest services are still starting ({0:N0}s elapsed)." -f $watch.Elapsed.TotalSeconds)
                $nextNotice += 15
            }
            if ($watch.Elapsed.TotalSeconds -ge 150) { throw 'The guest did not become manageable within 150 seconds.' }
            Start-Sleep -Seconds 2
        } while ($true)
        $lease = New-Lease $SessionId ([bool]$PlayerOnline) ([bool]$RoomReady) $RoomId $RoomCapacity ([bool]$config.roomFill)
        Deliver-Lease $lease | Out-Null
        if ($config.serverLocation -eq 'guest') {
            Write-Host 'Windows guest services are ready. Starting/checking the database and game servers...'
            Guest -TimeoutMs 130000 -Script @'
$marker = Get-Content -LiteralPath 'C:\GunBoundAI\vm\guest.json' -Raw | ConvertFrom-Json
if ($marker.serverRoot -ne 'C:\GunBoundServer' -or $marker.computerName -ne $env:COMPUTERNAME) { throw 'Guest server identity mismatch.' }
Start-ScheduledTask -TaskName 'GunBoundAI-Backend'
$watch = [Diagnostics.Stopwatch]::StartNew()
do {
    $health = Start-Process -FilePath 'C:\GunBoundServer\runtime\pwsh\pwsh.exe' `
        -ArgumentList '-NoProfile -File C:\GunBoundServer\backend\health.ps1' -NoNewWindow -PassThru `
        -RedirectStandardOutput 'C:\GunBoundServer\logs\vm-start-health.log' `
        -RedirectStandardError 'C:\GunBoundServer\logs\vm-start-health.err.log'
    try {
        $null = $health.Handle
        if (!$health.WaitForExit(30000)) { throw 'The guest health probe exceeded 30 seconds; readiness was not inferred.' }
        $healthCode = $health.ExitCode
    } finally { $health.Dispose() }
    if ($healthCode -eq 0) { Write-Output 'Protected guest database and native core are healthy.'; break }
    if ((Get-ScheduledTask -TaskName 'GunBoundAI-Backend').State -ne 'Running' -and $watch.Elapsed.TotalSeconds -gt 5) {
        throw 'The protected guest backend task stopped; inspect server logs.'
    }
    Start-Sleep -Seconds 1
} while ($watch.Elapsed.TotalSeconds -lt 90)
if ($healthCode -ne 0) { throw 'The protected guest backend did not become healthy within 90 seconds.' }
'@ | Out-Null
            Write-Host 'Database and game servers are ready.'
        }
        $lease = New-Lease $SessionId ([bool]$PlayerOnline) ([bool]$RoomReady) $RoomId $RoomCapacity ([bool]$config.roomFill)
        Deliver-Lease $lease | Out-Null
        Guest "Start-ScheduledTask -TaskName 'GunBoundAI-BotSession' -ErrorAction Stop" | Out-Null
        Write-Output 'Bot VM started headlessly and received the bounded Player lease; gameplay is not yet confirmed.'
    } elseif ($Action -eq 'Renew') {
        if ($info.VMState -ne 'running') { throw "Cannot renew a Player lease while the bot VM is $($info.VMState)." }
        Deliver-Lease $lease
    }
} finally {
    if ($lock) { $lock.Dispose() }
}
