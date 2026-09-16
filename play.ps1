#requires -Version 7.0
[CmdletBinding()]
param([switch]$Check, [switch]$DiagnoseJoin, [switch]$Isolated)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
$gamePath = Join-Path $root 'client-image\GunBound.gme'
$tools = Join-Path $root 'lab-tools.exe'
$sessionDir = Join-Path $root 'session'
$statePath = Join-Path $sessionDir 'lab-session.json'
$stopPath = Join-Path $sessionDir 'stop.request'
$vmConfigPath = Join-Path $root 'vm\config.json'
$vmConfig = if (Test-Path -LiteralPath $vmConfigPath) { Get-Content -LiteralPath $vmConfigPath -Raw | ConvertFrom-Json } else { $null }
$useVm = $Isolated -or ($vmConfig -and $vmConfig.enabled)
$guestServer = $useVm -and $vmConfig.serverLocation -eq 'guest'
if ($useVm -or $Check) { . "$root\vm\shared-io.ps1" }
if ($vmConfig -and $vmConfig.PSObject.Properties.Name -contains 'roomFill' -and $vmConfig.roomFill -isnot [bool]) {
    throw 'Room filling must be an explicit boolean in vm\config.json.'
}
$roomFill = $useVm -and $vmConfig.PSObject.Properties.Name -contains 'roomFill' -and $vmConfig.roomFill -eq $true
$playerSetup = if ($useVm -and $vmConfig.PSObject.Properties.Name -contains 'playerSetup') {
    [string]$vmConfig.playerSetup
} elseif ($useVm) { 'manual' } else { 'automatic' }
if ($playerSetup -notin @('manual','automatic')) { throw 'Unsupported Player setup mode in vm\config.json.' }
$manualPlayer = $useVm -and $playerSetup -eq 'manual'
if ($roomFill -and (!$manualPlayer -or !$guestServer)) { throw 'Room filling requires manual Player setup and the isolated guest server.' }
if ($useVm -and (!$vmConfig -or $vmConfig.phase -notin @('provisioned','ready'))) { throw 'The independent bot VM has not completed provisioning.' }
if ($useVm -and $DiagnoseJoin) { throw 'DiagnoseJoin is only supported by the two-local-client mode.' }
if (!$Check -and !$useVm -and (Test-Path -LiteralPath "$root\network.json") -and
    (Get-Content -LiteralPath "$root\network.json" -Raw | ConvertFrom-Json).mode -eq 'private') {
    throw 'The private VM profile is staged but not enabled. Use -Isolated for controlled validation, or restore the documented loopback profile before a two-local-client session.'
}

foreach ($file in @('lab-client.exe','lab-tools.exe','bot-controller.exe','stop-bot.ps1','stop-lab.ps1',
    'backend\start.ps1','backend\stop.ps1','backend\health.ps1','private\accounts.json','client-image\GunBound.gme')) {
    if (!(Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) { throw "Required lab file is missing: $file" }
}
function Find-LabClients {
    @(Get-CimInstance Win32_Process -Filter "Name='GunBound.gme' OR Name='GunBound.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) })
}
function Identity($Process, [string]$Name, [string]$ExpectedPath = '') {
    $path = if ($ExpectedPath) { $ExpectedPath } else { $Process.Path }
    if (!$path) { throw "The $Name process has not published an executable identity." }
    [ordered]@{ name=$Name; pid=$Process.Id; path=$path; startedUtcTicks=$Process.StartTime.ToUniversalTime().Ticks }
}
function Owned($Entry) {
    if (!$Entry) { return $null }
    $p = Get-Process -Id $Entry.pid -ErrorAction SilentlyContinue
    if ($p -and $p.Path -eq $Entry.path -and $p.StartTime.ToUniversalTime().Ticks -eq $Entry.startedUtcTicks) { return $p }
    return $null
}
function Decode-Mode([string]$Hex) {
    $Hex = $Hex.Trim()
    if ($Hex -notmatch '^[0-9A-Fa-f]{8}$') { throw 'Invalid mode read from lab-tools.' }
    [BitConverter]::ToUInt32([Convert]::FromHexString($Hex), 0)
}
function Room-Target($Report) {
    if ($Report -and $Report.PSObject.Properties.Name -contains 'Observation') {
        if ($Report.Available -isnot [bool] -or $Report.Retryable -isnot [bool] -or
            $Report.Observation -cnotin @('room','non-room','snapshot-busy','structural-error')) {
            throw [ArgumentException]::new('Malformed native room observation.')
        }
        if ($Report.Observation -ceq 'structural-error') {
            throw [InvalidOperationException]::new("Native room structure could not be trusted: $($Report.Diagnostic)")
        }
        if ($Report.Observation -cne 'room') {
            if ($Report.Available -or !$Report.Retryable) { throw [ArgumentException]::new('A room transition has inconsistent availability flags.') }
            return [pscustomobject]@{
                mode=$Report.Mode;roomId=$null;roomCapacity=0;roomReady=$false
                pending=($Report.Observation -ceq 'snapshot-busy');botNames=@()
                issue=$(if ($Report.Observation -ceq 'snapshot-busy') {
                    'Waiting for a coherent native room snapshot; no new bot-join action is authorized.'
                } else { $null })
            }
        }
        if (!$Report.Available -or $Report.Retryable) { throw [ArgumentException]::new('A published room has inconsistent availability flags.') }
    }
    if (!$Report -or $Report.SelfName -cne 'Player' -or $Report.Mode -notin @(9,11) -or
        ($Report.RoomId -isnot [int] -and $Report.RoomId -isnot [long]) -or $Report.RoomId -lt 0 -or $Report.RoomId -gt 65535 -or
        ($Report.Capacity -isnot [int] -and $Report.Capacity -isnot [long]) -or $Report.Capacity -notin @(2,4,6,8) -or
        ($Report.GameType -isnot [int] -and $Report.GameType -isnot [long]) -or $Report.GameType -lt 0 -or $Report.GameType -gt 3) {
        throw [ArgumentException]::new('The native diagnostic did not identify Player and a valid room capacity.')
    }
    $solo = $Report.GameType -eq 0
    $supported = $solo -and $Report.Capacity -in @(2,4)
    [pscustomobject]@{
        mode=[int]$Report.Mode
        roomId=$(if ($solo) { [int]$Report.RoomId } else { $null })
        roomCapacity=$(if ($solo) { [int]$Report.Capacity } else { 0 })
        roomReady=($Report.Mode -eq 9 -and $supported); pending=$false
        botNames=@(if ($supported) { Get-RoomBotNames $Report.Capacity })
        issue=$(if (!$solo) { 'Only Solo rooms are supported; no bots will join this game type.' }
            elseif (!$supported) { "Room capacity $($Report.Capacity) is unsupported. Choose 2 or 4 players; no bots will join this room." }
            else { $null })
    }
}
function Read-RoomTarget($Client) {
    if (!(Owned $Client)) { throw 'Player is no longer this session''s client.' }
    $hex = (& $tools read ([string]$Client.pid) '0087053C' '4') -join ''
    if ($LASTEXITCODE) { throw 'Player room-presence read failed.' }
    $mode = Decode-Mode $hex
    $empty = [pscustomobject]@{mode=$mode;roomId=$null;roomCapacity=0;roomReady=$false;pending=$false;botNames=@();issue=$null}
    if ($mode -notin @(9,11)) { return $empty }
    $output = @(& "$root\bot-controller.exe" --room-state ([string]$Client.pid) 2>> (Join-Path $state.logDirectory 'room-reader.err.log'))
    $code = $LASTEXITCODE
    if ($code) {
        $hex = (& $tools read ([string]$Client.pid) '0087053C' '4') -join ''
        if ($LASTEXITCODE) { throw 'Player exited or its room transition could not be read.' }
        $empty.mode = Decode-Mode $hex
        if ($empty.mode -notin @(9,11)) { return $empty }
        if ($code -ne 3) { throw 'The native room diagnostic failed; inspect room-reader.err.log.' }
        $empty.pending = $true
        $empty.issue = 'Waiting for a coherent native room snapshot; no new bot-join action is authorized.'
        if ($state.roomTarget) {
            $empty.roomId = $state.roomTarget.roomId
            $empty.roomCapacity = $state.roomTarget.roomCapacity
            $empty.botNames = @($state.roomTarget.botNames)
        }
        return $empty
    }
    $json = $output -join [Environment]::NewLine
    if ($json.Length -gt 65536) { throw 'The native room diagnostic was oversized.' }
    $target = Room-Target ($json | ConvertFrom-Json)
    if ($target.pending -and $state.roomTarget) {
        $target.roomId = $state.roomTarget.roomId
        $target.roomCapacity = $state.roomTarget.roomCapacity
        $target.botNames = @($state.roomTarget.botNames)
    }
    $target
}
function Room-BotsReady($Guest, $Target) {
    if (!$Guest -or !$Target -or $Target.pending -or $Target.roomCapacity -notin @(2,4) -or
        $Guest.schemaVersion -ne 2 -or $Guest.phase -ne 'controller-running' -or
        $Guest.roomId -ne $Target.roomId -or $Guest.roomCapacity -ne $Target.roomCapacity) { return $false }
    $expected = @(Get-RoomBotNames $Target.roomCapacity)
    $configured = @($Guest.instances)
    if ($configured.Count -ne 3 -or
        (($configured.name | Sort-Object) -join ',') -cne 'BotOne,BotThree,BotTwo') { return $false }
    $instances = @($configured | Where-Object { $_.name -cin $expected })
    if ($Guest.desiredCount -ne $expected.Count -or $instances.Count -ne $expected.Count) { return $false }
    foreach ($unused in @($configured | Where-Object { $_.name -cnotin $expected })) {
        if ($unused.phase -ne 'stopped' -or $unused.worker -or $unused.client -or $unused.controller) { return $false }
    }
    foreach ($instance in $instances) {
        if ($instance.phase -ne 'controller-running' -or $instance.roomId -ne $Target.roomId -or
            $instance.roomCapacity -ne $Target.roomCapacity -or $instance.clientMode -notin @(9,11) -or
            ($instance.clientMode -eq 9 -and $instance.nativeReady -ne $true)) { return $false }
    }
    return $true
}
function Check-Stop {
    if (Test-Path -LiteralPath $stopPath) {
        $request = Get-Content -LiteralPath $stopPath -Raw | ConvertFrom-Json
        if ($request.sessionId -eq $state.id) {
            $script:stopRequested = $true
            $script:forceCleanup = [bool]$request.force
            throw 'Session stop requested.'
        }
    }
    Sync-BotVm
}
function Wait-PlayerRoom($Client) {
    Phase 'waiting-player-room'
    Write-Host 'Player is ready for manual setup. Join Local Practice and create a 1v1 Solo room.'
    Write-Host 'No automatic Player mouse or keyboard input will be sent. BotOne joins after your room is open.'
    Write-Host 'The private server list has no idle-disconnect timer. Closing Player still ends the managed server/VM session.'
    while ((Mode $Client) -ne 9) {
        Check-Stop
        Start-Sleep -Milliseconds 500
    }
    Write-Host 'Player room detected. Keep it open while BotOne connects.'
}
if ($Check) {
    if ((Decode-Mode '0B000000') -ne 11 -or (Decode-Mode '09000000') -ne 9) { throw 'Mode byte-order regression.' }
    $report = [pscustomobject]@{Mode=9;RoomId=0;Capacity=2;SelfName='Player';GameType=0}
    $target = Room-Target $report
    if (!$target.roomReady -or $target.roomId -ne 0 -or @($target.botNames).Count -ne 1) { throw 'Two-player room filling changed.' }
    $report.Capacity = 4
    $target = Room-Target $report
    if (@($target.botNames).Count -ne 3) { throw 'Four-player room filling changed.' }
    $ready = [pscustomobject]@{schemaVersion=2;phase='controller-running';roomId=0;roomCapacity=4;desiredCount=3
        instances=@(foreach ($name in @('BotOne','BotTwo','BotThree')) {
            [pscustomobject]@{name=$name;phase='controller-running';roomId=0;roomCapacity=4;clientMode=9;nativeReady=$true}
        })}
    if (!(Room-BotsReady $ready $target)) { throw 'A complete ready 2v2 roster was rejected.' }
    $ready.instances[2].nativeReady = $false
    if (Room-BotsReady $ready $target) { throw 'An unready bot was declared ready.' }
    $report.Capacity = 2
    $target = Room-Target $report
    $ready.roomCapacity = 2; $ready.desiredCount = 1
    $ready.instances[0].roomCapacity = 2
    $ready.instances[1].phase = 'stopped'; $ready.instances[2].phase = 'stopped'
    if (!(Room-BotsReady $ready $target)) { throw 'Stopped spare instances prevented a ready two-slot room.' }
    $ready.instances[1].phase = 'starting-client'
    if (Room-BotsReady $ready $target) { throw 'An unwanted bot was ignored in a two-slot room.' }
    foreach ($capacity in @(6,8)) {
        $report.Capacity = $capacity
        $target = Room-Target $report
        if ($target.roomReady -or @($target.botNames).Count -ne 0 -or !$target.issue) { throw 'An unsupported room was silently capped or accepted.' }
    }
    $report.Capacity = 4; $report.SelfName = 'BotTwo'
    $rejected = $false
    try { Room-Target $report | Out-Null } catch [ArgumentException] { $rejected = $true }
    if (!$rejected) { throw 'A bot diagnostic was accepted as Player room authority.' }
    $report.SelfName = 'Player'; $report.GameType = 1
    $target = Room-Target $report
    if ($target.roomReady -or $null -ne $target.roomId -or $target.roomCapacity -ne 0 -or !$target.issue) { throw 'A non-Solo game authorized a bot group.' }
    $transition = [pscustomobject]@{Available=$false;Observation='snapshot-busy';Retryable=$true;Mode=9;Diagnostic='changing'}
    $target = Room-Target $transition
    if (!$target.pending -or $target.roomReady -or !$target.issue) { throw 'A transient snapshot was not safely paused.' }
    $transition.Observation = 'non-room'; $transition.Mode = 3
    $target = Room-Target $transition
    if ($target.pending -or $target.roomReady -or $target.roomCapacity -ne 0) { throw 'A non-room observation retained a bot target.' }
    $transition.Observation = 'structural-error'; $transition.Retryable = $false
    $rejected = $false
    try { Room-Target $transition | Out-Null } catch [InvalidOperationException] { $rejected = $true }
    if (!$rejected) { throw 'A structural room error was hidden as a transition.' }
    $self = Identity (Get-Process -Id $PID) 'check'
    if (!(Owned $self)) { throw 'Process identity check failed.' }
    $self.startedUtcTicks++
    if (Owned $self) { throw 'A stale process identity was incorrectly accepted.' }
    $dated = '{"StartedUtc":"2026-09-13T03:45:50.2371076Z"}' | ConvertFrom-Json
    if (([DateTime]$dated.StartedUtc).ToUniversalTime().Ticks -ne 639248679502371076L) {
        throw 'Launcher timestamp precision was lost while decoding JSON.'
    }
    $stopPath = Join-Path $sessionDir ([Guid]::NewGuid().ToString('N') + '.check-stop')
    $script:checkRenewed = $false
    function Sync-BotVm { $script:checkRenewed = $true }
    Check-Stop
    if (!$script:checkRenewed) { throw 'Normal supervision did not check the VM lease without a stop request.' }
    $script:checkModes = 0
    $script:checkPhase = ''
    function Phase([string]$Name) { $script:checkPhase = $Name }
    function Mode($Client) { $script:checkModes++; if ($script:checkModes -eq 1) { return 3 }; return 9 }
    function Input { throw 'Manual Player setup must not send input.' }
    Wait-PlayerRoom $null
    if ($script:checkModes -ne 2 -or $script:checkPhase -ne 'waiting-player-room') {
        throw 'Manual Player setup did not wait for observed room mode.'
    }
    Write-Output "PASS: required local interfaces exist; PowerShell is $pwsh"
    Write-Output 'PASS: native 2/4 room targets, unsupported sizes/types, structured transitions, readiness, precise ownership/leases, and input-free manual Player setup.'
    Write-Output "Active lab game clients: $((Find-LabClients).Count). No launch, input, stop, data or configuration action performed."
    return
}

New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$lease = [IO.File]::Open((Join-Path $sessionDir 'play.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$state = $null
$stopRequested = $false
$forceCleanup = $false
$human = $null
$vmRunning = $false
$vmLeaseWatch = [Diagnostics.Stopwatch]::StartNew()

function Save-State {
    $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $json = ConvertTo-Json -InputObject $state -Depth 8
    [IO.File]::WriteAllText($statePath + '.new', $json)
    [IO.File]::Move($statePath + '.new', $statePath, $true)
    [IO.File]::WriteAllText((Join-Path $state.logDirectory 'session.json'), $json)
}
function Phase([string]$Name) { $state.phase = $Name; Save-State; Write-Host $Name }
function Sync-BotVm {
    if (!$useVm -or !$state -or !$state.botVm) { return }
    $requestPath = Join-Path $sessionDir 'bot.request'
    if (Test-Path -LiteralPath $requestPath) {
        $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
        if ($request.sessionId -eq $state.id) {
            if ($request.action -notin @('on','off')) { throw 'Invalid managed bot power request.' }
            Remove-Item -LiteralPath $requestPath
            if ($request.action -eq 'off') {
                if ($guestServer) {
                    $script:stopRequested = $true
                    throw 'The combined server/bot VM was turned off; ending this Player session.'
                }
                $state.botVm.desired = $false; Save-State
                & "$root\vm\control.ps1" -Action Stop
                $script:vmRunning = $false
                $state.phase = 'clients-open-bot-off'; Save-State
            } elseif (!$vmRunning) {
                if (!(Owned $human)) { throw 'Bot On requires this session''s Player client.' }
                & "$root\vm\control.ps1" -Action Start -SessionId $state.id -PlayerOnline
                $script:vmRunning = $true
                $state.botVm.desired = $true
                $state.phase = 'bot-starting'; Save-State
                $vmLeaseWatch.Restart()
            }
        }
    }
    if (!$vmRunning -or !$state.botVm.desired -or $vmLeaseWatch.Elapsed.TotalSeconds -lt 10) { return }
    $online = $null -ne (Owned $human)
    $room = $false
    $target = $null
    $roomArguments = @{}
    if ($online) {
        if ($roomFill) {
            $target = Read-RoomTarget $human
            $room = $target.roomReady
            $roomArguments = @{RoomId=$target.roomId;RoomCapacity=$target.roomCapacity}
            $state.roomTarget = $target
        } else {
            $hex = (& $tools read ([string]$human.pid) '0087053C' '4') -join ''
            if ($LASTEXITCODE) { throw 'Player presence read failed; the VM lease was not extended.' }
            $room = (Decode-Mode $hex) -eq 9
        }
    }
    $guest = & "$root\vm\control.ps1" -Action Renew -SessionId $state.id -PlayerOnline:$online -RoomReady:$room @roomArguments
    $vmLeaseWatch.Restart()
    if ($roomFill) {
        if ($guest -and $guest.sessionId -eq ([Guid]$state.id).ToString('D')) { $state.botVm.guestStatus = $guest }
        $current = $state.botVm.guestStatus
        $issue = if ($target -and $target.issue) { $target.issue }
            elseif ($current -and $current.phase -in @('degraded','failed')) { [string]$current.lastError }
            else { $null }
        if ($issue -and $state.roomIssue -ne $issue) { Write-Warning $issue }
        $state.roomIssue = $issue
        $nextPhase = if ($target -and $target.roomCapacity -in @(6,8)) { 'unsupported-room-size' }
            elseif ($issue) { 'bots-degraded' }
            elseif (Room-BotsReady $current $target) { 'ready' }
            elseif ($target -and $target.roomCapacity -in @(2,4)) { 'filling-bots' }
            else { 'waiting-player-room' }
        if ($state.phase -ne $nextPhase) {
            Phase $nextPhase
            if ($nextPhase -eq 'filling-bots') { Write-Host "Filling native room $($target.roomId): $(@($target.botNames).Count) bot(s) for $($target.roomCapacity) slots." }
            if ($nextPhase -eq 'ready') { Write-Host 'The requested bots are joined and ready. Start stays under Player control.' }
        } else { Save-State }
        return
    }
    if ($guest) {
        if ($guest.sessionId -ne ([Guid]$state.id).ToString('D')) { return }
        $state.botVm.guestStatus = $guest
        Save-State
        if ($guest.phase -in @('failed','stopped') -and $online) {
            $state.botVm.desired = $false; Save-State
            if ($guestServer) {
                throw "Guest bot stopped: $($guest.lastError). Ending the Player session because its server shares the VM."
            }
            & "$root\vm\control.ps1" -Action Stop
            $script:vmRunning = $false
            $state.phase = 'clients-open-bot-stopped'; Save-State
            Write-Warning "Guest bot stopped: $($guest.lastError). Player remains open; inspect VM diagnostics before Bot On."
        }
    }
}
function Start-Owned([string]$Name, [string]$Executable, [string[]]$Arguments) {
    $quoted = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $p = Start-Process -FilePath $Executable -ArgumentList $quoted -WorkingDirectory $root -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $state.logDirectory "$Name.out.log") `
        -RedirectStandardError (Join-Path $state.logDirectory "$Name.err.log")
    $record = Identity $p $Name $Executable
    $state.hosts += $record
    Save-State
    $identityTimer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (Owned $record) { return $record }
        $p.Refresh()
        if ($p.HasExited) { throw "$Name exited during startup; inspect its session error log." }
        Start-Sleep -Milliseconds 50
    } while ($identityTimer.Elapsed.TotalSeconds -lt 10)
    throw "$Name did not publish the expected executable identity."
}
function Tool([string]$Action, $Client, [string[]]$Arguments = @()) {
    Check-Stop
    if (!(Owned $Client)) { throw "$($Client.name) is no longer this session's client." }
    $output = @(& $tools $Action ([string]$Client.pid) @Arguments 2>> (Join-Path $state.logDirectory 'tools.err.log'))
    if ($LASTEXITCODE) { throw "lab-tools $Action failed for $($Client.name); see session diagnostics." }
    return $output
}
function Mode($Client) {
    $hex = ((Tool 'read' $Client @('0087053C','4')) -join '').Trim()
    Decode-Mode $hex
}
function Input([string]$Action, $Client, [string[]]$Arguments) {
    Tool 'focus' $Client | Out-Null
    Tool $Action $Client $Arguments | Out-Null
}
function Wait-Mode($Client, [int[]]$Expected, [int]$Seconds = 30) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $mode = Mode $Client
        if ($mode -in $Expected) { return $mode }
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw "$($Client.name) did not reach mode $($Expected -join '/') within ${Seconds}s; last mode=$mode."
}
function Sync-Backend([string]$Part, $HostRecord) {
    if (!$HostRecord) { return }
    $file = Join-Path $root "backend\$($Part.ToLowerInvariant())-processes.json"
    if (!(Test-Path -LiteralPath $file)) { return }
    try { $rows = @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) }
    catch [ArgumentException] { Write-Warning "Waiting for complete $Part ownership metadata: $($_.Exception.Message)"; return }
    $ownedRows = @($rows | Where-Object {
        $p = Owned $_
        $p -and (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.pid)").ParentProcessId -eq $HostRecord.pid
    })
    if ($ownedRows.Count) { $state.backend[$Part] = $ownedRows; Save-State }
}
function Wait-Backend([string]$Part, $HostRecord) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Check-Stop
        if (!(Owned $HostRecord)) { throw "The $Part supervisor exited; inspect its session log." }
        Sync-Backend $Part $HostRecord
        $healthArgs = @('-NoProfile','-File',(Join-Path $root 'backend\health.ps1'))
        if ($Part -eq 'Database') { $healthArgs += '-DatabaseOnly' }
        & $pwsh @healthArgs *> (Join-Path $state.logDirectory "health-$Part.log")
        $requiredCount = if ($Part -eq 'Core') { 3 } else { 1 }
        if ($LASTEXITCODE -eq 0 -and @($state.backend[$Part] | Where-Object { $_ }).Count -ge $requiredCount) { return }
        Start-Sleep -Seconds 1
    } while ($timer.Elapsed.TotalSeconds -lt 75)
    throw "$Part did not become healthy; inspect session health/startup logs."
}
function Start-Client([string]$Role, [string]$Action) {
    Phase "Starting $Role"
    $launcher = Start-Owned "$Role-launcher" (Join-Path $root 'lab-client.exe') @($Action)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Check-Stop
        $file = Join-Path $state.logDirectory "$Role-launcher.out.log"
        foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
            if (!$line.StartsWith('{')) { continue }
            try { $record = $line | ConvertFrom-Json }
            catch [ArgumentException] { Write-Warning "Waiting for a complete $Role startup record."; continue }
            if ($record.Role -ne $Role -or !$record.ProcessId) { continue }
            $p = Get-Process -Id $record.ProcessId -ErrorAction SilentlyContinue
            if (!$p -or $p.StartTime.ToUniversalTime().Ticks -ne
                ([DateTime]$record.StartedUtc).ToUniversalTime().Ticks) {
                throw 'Launcher output does not identify the expected new lab client.'
            }
            if (!$p.Path) { continue }
            if ($p.Path -ne $gamePath) { throw 'Launcher process path does not match the lab client.' }
            $client = Identity $p $Role
            $state.clients += $client
            Save-State
            $expected = if ($Role -eq 'human' -and $manualPlayer) { @(2,3,4,9,13) } else { @(2,3,4,13) }
            Wait-Mode $client $expected 60 | Out-Null
            if (!($Role -eq 'human' -and $manualPlayer)) { Tool 'focus' $client | Out-Null }
            return $client
        }
        if (!(Owned $launcher)) { throw "$Role launcher exited before its startup record; inspect its error log." }
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt 60)
    throw "$Role launcher did not identify its game process in time."
}
function Lobby($Client) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        switch (Mode $Client) {
            3 { return }
            2 {
                Input 'double-click' $Client @('170','65')
                $selection = [Diagnostics.Stopwatch]::StartNew()
                do {
                    Start-Sleep -Milliseconds 200
                    $nextMode = Mode $Client
                } while ($nextMode -eq 2 -and $selection.Elapsed.TotalSeconds -lt 5)
                if ($nextMode -notin @(2,3,4,13)) { throw "Unexpected world-selection mode $nextMode." }
            }
            4 { Input 'click' $Client @('42','560'); Wait-Mode $Client @(3) 15 | Out-Null }
            13 { Input 'click' $Client @('37','563'); Wait-Mode $Client @(3) 15 | Out-Null }
            default { throw "$($Client.name) entered an unexpected mode during lobby setup." }
        }
    } while ($timer.Elapsed.TotalSeconds -lt 75)
    if ($DiagnoseJoin) {
        Phase "diagnostic-lobby-$($Client.name)"
        Wait-Mode $Client @(3) 300 | Out-Null
        return
    }
    throw "$($Client.name) did not reach the lobby."
}

try {
    if ((Find-LabClients).Count) { throw 'A lab game session is already active. It was not closed or modified.' }
    if (Test-Path -LiteralPath $statePath) {
        $old = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($old.phase -ne 'stopped') { throw 'Previous session metadata needs cleanup. Run stop-lab.ps1, then retry.' }
    }
    $id = [Guid]::NewGuid().ToString('N')
    $logs = Join-Path $sessionDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $id.Substring(0,8))
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $state = [ordered]@{ id=$id; root=$root; phase='starting'; updatedUtc=''; logDirectory=$logs
        supervisor=(Identity (Get-Process -Id $PID) 'play'); supervisorActive=$true; hosts=@(); clients=@(); controller=$null
        backend=@{}; reusedDatabase=$false; controllerStopped=$false; botVm=$null; playerSetup=$playerSetup
        roomFill=$roomFill;roomTarget=$null;roomIssue=$null }
    if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath -ErrorAction Stop }
    Save-State
    if ((Find-LabClients).Count) { throw 'A lab client started during preflight; existing clients/core were not touched.' }
    & (Join-Path $root 'stop-bot.ps1')
    if ($guestServer) {
        foreach ($entryFile in @('backend\database-processes.json','backend\core-processes.json')) {
            $file = Join-Path $root $entryFile
            if (Test-Path -LiteralPath $file) {
                foreach ($entry in @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)) {
                    if (Owned $entry) { throw 'The original host backend is still running; stop it before using the guest database copy.' }
                }
            }
        }
        $state.botVm = [ordered]@{machineId=$vmConfig.machineId;desired=$true;guestStatus=$null;includesServer=$true}
        Phase 'Starting the independent server and BotOne VM'
        & "$root\vm\control.ps1" -Action Start -SessionId $state.id
        $vmRunning = $true
        $vmLeaseWatch.Restart()
    } else {
    # A clean core directory is needed only when no game clients exist; never reset game data.
    & (Join-Path $root 'backend\stop.ps1') -Part Core
    & $pwsh -NoProfile -File (Join-Path $root 'backend\health.ps1') -DatabaseOnly *> (Join-Path $logs 'health-Database.log')
    if ($LASTEXITCODE -eq 0) { $state.reusedDatabase = $true; Save-State }
    else {
        $dbHost = Start-Owned 'database-supervisor' $pwsh @('-NoProfile','-File',(Join-Path $root 'backend\start.ps1'),'-Part','Database')
        Wait-Backend 'Database' $dbHost
    }
    $coreHost = Start-Owned 'core-supervisor' $pwsh @('-NoProfile','-File',(Join-Path $root 'backend\start.ps1'),'-Part','Core')
    Wait-Backend 'Core' $coreHost
    }
    $human = Start-Client 'human' $(if ($manualPlayer) { 'play-large' } else { 'play' })
    if ($roomFill) {
        Phase 'waiting-player-room'
        Write-Host 'Join Local Practice and create a Solo room manually: 2 slots fills one bot; 4 slots fills three.'
        Write-Host 'Rooms with 6 or 8 slots are unsupported for now. The bots balance teams; Player controls Start.'
        Write-Host 'No automatic Player mouse/keyboard input is sent. The private server list has no idle-disconnect timer.'
        while ($true) {
            Check-Stop
            if (!(Owned $human)) { Write-Output 'Player closed; ending its managed bot/server session.'; break }
            Start-Sleep -Milliseconds 500
        }
        return
    }
    if ($manualPlayer) {
        Wait-PlayerRoom $human
    } else {
    Lobby $human
    if (!$useVm) {
    $bot = Start-Client 'bot' 'bot-client'
    Lobby $bot
    $mobile = ((Tool 'read' $bot @('00897368','1')) -join '').Trim()
    if ($mobile -ne '00') {
        Phase 'Selecting Armor for BotOne'
        Input 'click' $bot @('593','13')
        Wait-Mode $bot @(13) 10 | Out-Null
        Input 'click' $bot @('74','123')
        if ((Mode $bot) -eq 13) { Input 'click' $bot @('37','563') }
        Wait-Mode $bot @(3) 10 | Out-Null
        if ((((Tool 'read' $bot @('00897368','1')) -join '').Trim()) -ne '00') { throw 'BotOne did not select Armor.' }
    }
    }
    Phase 'Creating a fresh human-hosted Solo duel'
    if ((Mode $human) -ne 3) { throw 'Human is not in the lobby before room creation.' }
    Input 'click' $human @('669','268')
    Input 'click' $human @('420','199')
    foreach ($key in @(68,85,69,76)) { Input 'key' $human @([string]$key,'70') }
    Input 'click' $human @('290','258')
    Input 'click' $human @('440','258')
    Input 'click' $human @('509','382')
    Wait-Mode $human @(9) 35 | Out-Null
    }
    if ($useVm) {
        if (!$vmRunning) {
            $state.botVm = [ordered]@{machineId=$vmConfig.machineId;desired=$true;guestStatus=$null}
            Phase 'Starting the independent BotOne VM'
            & "$root\vm\control.ps1" -Action Start -SessionId $state.id -PlayerOnline -RoomReady
            $vmRunning = $true
        } else {
            & "$root\vm\control.ps1" -Action Renew -SessionId $state.id -PlayerOnline -RoomReady | Out-Null
        }
        $vmLeaseWatch.Restart()
        $joining = [Diagnostics.Stopwatch]::StartNew()
        do {
            Check-Stop
            if (!$vmRunning) { throw 'The guest bot stopped during room setup.' }
            $guest = & "$root\vm\control.ps1" -Action GuestStatus
            if ($guest -and $guest.sessionId -eq ([Guid]$state.id).ToString('D') -and
                $guest.phase -eq 'controller-running' -and $guest.clientMode -in @(9,11)) { break }
            if ($guest -and $guest.sessionId -eq ([Guid]$state.id).ToString('D') -and
                $guest.phase -eq 'failed') { throw "Guest startup failed: $($guest.lastError)" }
            Start-Sleep -Seconds 2
        } while ($joining.Elapsed.TotalSeconds -lt 150)
        if (!$guest -or $guest.sessionId -ne ([Guid]$state.id).ToString('D') -or
            $guest.phase -ne 'controller-running' -or $guest.clientMode -notin @(9,11)) {
            throw 'BotOne did not reach a supervised guest room within 150 seconds.'
        }
        if (!$manualPlayer) { Tool 'focus' $human | Out-Null }
        $state.botVm.guestStatus = $guest
        $state.setupVerified = [ordered]@{
            timeUtc=[DateTime]::UtcNow.ToString('o');automaticRoomJoin=$true
            humanMode=(Mode $human);botMode=$guest.clientMode;isolated=$true;manualPlayerSetup=$manualPlayer
            controllerRunning=$true;nativeReadyVerified=$false;gameplayVerified=$false
        }
    } else {
    Phase 'Joining BotOne to the new room'
    $joined = $false
    if ($DiagnoseJoin) {
        Phase 'diagnostic-room-join'
        Write-Host 'Diagnostic pause: waiting for controlled room entry.'
        while ((Mode $bot) -ne 9) { Check-Stop; Start-Sleep -Milliseconds 250 }
        $joined = $true
    }
    if (!$joined) {
        if ((Mode $bot) -ne 3) { throw 'BotOne is not in the room directory.' }
        Input 'click' $bot @('422','260')
        Start-Sleep -Milliseconds 1000
    }
    for ($attempt = 0; $attempt -lt 4 -and !$joined; $attempt++) {
        if ((Mode $bot) -ne 3) { throw 'BotOne is not in the room directory.' }
        Input 'click' $bot @('84','64','150')
        $joinTimer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $mode = Mode $bot
            if ($mode -eq 9) { $joined = $true; break }
            if ($mode -ne 3) { throw "Unexpected bot mode $mode while joining." }
            Start-Sleep -Milliseconds 250
        } while ($joinTimer.Elapsed.TotalSeconds -lt 6)
    }
    if (!$joined) { throw 'BotOne did not join the fresh room.' }
    foreach ($client in @($human,$bot)) { Wait-Mode $client @(9) 5 | Out-Null }
    Phase 'Starting BotOne controller'
    Tool 'focus' $human | Out-Null
    if (Test-Path -LiteralPath (Join-Path $root 'bot.stop')) { Remove-Item -LiteralPath (Join-Path $root 'bot.stop') }
    $controllerHost = Start-Owned 'controller' (Join-Path $root 'bot-controller.exe') @([string]$human.pid,[string]$bot.pid)
    $state.controller = $controllerHost; Save-State
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Check-Stop
        if (!(Owned $controllerHost)) { throw 'Bot controller exited during room setup.' }
        $recordPath = Join-Path $root 'bot-process.json'
        $registered = $false
        if (Test-Path -LiteralPath $recordPath) {
            try { $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json }
            catch [ArgumentException] { Write-Warning 'Waiting for complete controller registration.'; $record = $null }
            $registered = $record.ProcessId -eq $controllerHost.pid -and
                $record.StartedUtcTicks -eq $controllerHost.startedUtcTicks -and
                $record.HumanProcessId -eq $human.pid -and $record.BotProcessId -eq $bot.pid
        }
        $output = (Get-Content -LiteralPath (Join-Path $logs 'controller.out.log') -Raw -ErrorAction SilentlyContinue)
        if ($registered -and $output -match 'Waiting for an active match \(client mode 9\)') { break }
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt 12)
    if (!$registered -or $output -notmatch 'Waiting for an active match \(client mode 9\)') { throw 'Controller did not confirm its room-ready cycle; no second Ready click was sent.' }
    foreach ($client in @($human,$bot)) { Wait-Mode $client @(9) 3 | Out-Null }
    Tool 'focus' $human | Out-Null
    $state.setupVerified = [ordered]@{
        timeUtc=[DateTime]::UtcNow.ToString('o')
        automaticRoomJoin=(!$DiagnoseJoin)
        humanMode=(Mode $human)
        botMode=(Mode $bot)
        controllerPid=$controllerHost.pid
        controllerRoomReady=$true
    }
    if ($state.setupVerified.humanMode -ne 9 -or $state.setupVerified.botMode -ne 9) {
        throw 'A client left the room during final handoff; setup was not declared ready.'
    }
    }
    Phase 'ready'
    if ($useVm) {
        Write-Output 'Player and the isolated BotOne are in the room. Click Start in Player. BotOne uses only the guest desktop.'
        Write-Output 'Bot On/Off/Status: vm\control.ps1. A room/controller check is not proof of a completed attack.'
    } else {
        Write-Output "Both clients are in the duel room. Click Start in the LEFT human window. BotOne controls only its own turns."
    }
    Write-Output "Keep this supervisor open. Stop: pwsh -NoProfile -File `"$root\stop-lab.ps1`". Diagnostics: $logs"
    while ($true) {
        Check-Stop
        if (!$guestServer -and !(Owned $coreHost)) { throw 'The owned native backend supervisor exited.' }
        if ($dbHost -and !(Owned $dbHost)) { throw 'The owned database supervisor exited.' }
        if (!(Owned $human) -or (!$useVm -and !(Owned $bot))) { Write-Output 'A game client closed; ending this managed session.'; break }
        if (!$useVm -and !$state.controllerStopped -and !(Owned $controllerHost)) {
            $state.controllerStopped = $true
            $state.phase = 'clients-open-controller-stopped'
            Save-State
            Write-Warning 'Bot controller stopped. Clients remain open; use stop-lab.ps1 to end the session.'
        }
        Start-Sleep -Seconds 1
    }
}
catch {
    if ($state) {
        $_ | Out-String | Add-Content -LiteralPath (Join-Path $state.logDirectory 'supervisor.err.log')
        if (!$stopRequested) {
            foreach ($client in $state.clients) {
                if (Owned $client) { & $tools capture ([string]$client.pid) (Join-Path $state.logDirectory ("failure-" + $client.name + '.png')) 2>> (Join-Path $state.logDirectory 'capture.err.log') | Out-Null }
            }
        }
    }
    if (!$stopRequested) { throw }
}
finally {
    try {
        if ($state) {
            & (Join-Path $root 'stop-lab.ps1') -SessionId $state.id -FromSupervisor -Force:$forceCleanup -Confirm:$false
        }
    }
    finally { $lease.Dispose() }
}
