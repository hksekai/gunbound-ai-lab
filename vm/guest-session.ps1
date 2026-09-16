#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Check,
    [ValidateSet('BotOne','BotTwo','BotThree')][string]$Instance
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\shared-io.ps1"

function Decode-Mode([string]$Hex) {
    $Hex = $Hex.Trim()
    if ($Hex -notmatch '^[0-9a-fA-F]{8}$') { throw 'Invalid four-byte mode response from lab-tools.' }
    [Convert]::ToUInt32(($Hex.Substring(6,2) + $Hex.Substring(4,2) + $Hex.Substring(2,2) + $Hex.Substring(0,2)), 16)
}
function Integer($Value) { $Value -is [int] -or $Value -is [long] }
function Validate-Lease($Data, [DateTime]$Now) {
    Convert-PlayerLease $Data $Now
}
function Lease-State($Lease, [DateTime]$Now) {
    if (!$Lease) { return 'missing' }
    if ($Lease.expiresUtcTicks -le $Now.ToUniversalTime().Ticks) { return 'expired' }
    if (!$Lease.playerOnline) { return 'offline' }
    return 'online'
}
function Player-RoomReady($Lease, [DateTime]$Now) {
    (Lease-State $Lease $Now) -eq 'online' -and $Lease.roomReady
}
function Property($Record, [string]$Name) {
    if ($Record -is [Collections.IDictionary]) { return $Record[$Name] }
    if ($Record -and $Record.PSObject.Properties[$Name]) { return $Record.$Name }
    return $null
}
function Instance-Root([string]$Name) {
    if ($Name -cnotin @('BotOne','BotTwo','BotThree')) { throw 'Only the three fixed bot instance identities are permitted.' }
    'C:\GunBoundAI\instances\' + $Name
}
function Room-FillEnabled($Marker) {
    $enabled = Property $Marker 'roomFill'
    $instances = Property $Marker 'botInstances'
    if ($null -eq $enabled -and $null -eq $instances) { return $false }
    if ($enabled -isnot [bool]) { throw 'The guest roomFill flag must be a boolean.' }
    if (!$enabled -and $null -eq $instances) { return $false }
    if ((Property $Marker 'serverRoot') -isnot [string] -or (Property $Marker 'serverRoot') -cne 'C:\GunBoundServer' -or
        $instances -isnot [array] -or $instances.Count -ne 3) { throw 'roomFill requires the protected server root and exactly three fixed bot instances.' }
    $names = @('BotOne','BotTwo','BotThree')
    for ($index = 0; $index -lt 3; $index++) {
        $entry = $instances[$index]
        if ($entry -isnot [pscustomobject] -or @($entry.PSObject.Properties.Name).Count -ne 2 -or
            (Property $entry 'name') -isnot [string] -or (Property $entry 'address') -isnot [string] -or
            (Property $entry 'name') -cne $names[$index] -or
            (Property $entry 'address') -cne ('192.168.56.' + (10 + $index))) {
            throw 'botInstances must be exactly BotOne/.10, BotTwo/.11, BotThree/.12 in the private 192.168.56 subnet.'
        }
    }
    return $enabled
}
function Same-Target($First, $Second) {
    if (!$First -or !$Second) { return $false }
    $firstId = Property $First 'roomId'; $secondId = Property $Second 'roomId'
    (Property $First 'sessionId') -is [string] -and (Property $Second 'sessionId') -is [string] -and
        (Property $First 'sessionId') -eq (Property $Second 'sessionId') -and
        ($null -eq $firstId -or (Integer $firstId)) -and ($null -eq $secondId -or (Integer $secondId)) -and
        $firstId -eq $secondId -and (Integer (Property $First 'roomCapacity')) -and
        (Integer (Property $Second 'roomCapacity')) -and $First.roomCapacity -eq $Second.roomCapacity
}
function Room-Phase($Lease, [DateTime]$Now) {
    if ((Lease-State $Lease $Now) -ne 'online') { return 'waiting-player' }
    if ($Lease.schemaVersion -ne 2 -or $null -eq $Lease.roomId) { return 'waiting-room' }
    if ($Lease.roomCapacity -notin @(2,4)) { return 'unsupported-room-size' }
    if (!$Lease.roomReady) { return 'waiting-room' }
    return 'starting-bots'
}
function Lease-Target($Lease, [DateTime]$Now) {
    if ((Lease-State $Lease $Now) -eq 'online' -and $Lease.schemaVersion -eq 2 -and $null -ne $Lease.roomId) {
        [pscustomobject]@{sessionId=$Lease.sessionId;roomId=$Lease.roomId;roomCapacity=$Lease.roomCapacity}
    }
}
function Recent-WorkerPublication($Entry, [DateTime]$Now) {
    if (!$Entry.alive -or !$Entry.status) { return $false }
    $updated = Utc-Ticks $Entry.status.updatedUtc
    $updated -ge $Now.ToUniversalTime().AddSeconds(-2).Ticks -and $updated -le $Now.ToUniversalTime().AddSeconds(30).Ticks
}
function Matches-Identity($Expected, $Actual, [string]$Path) {
    foreach ($record in @($Expected,$Actual)) {
        if (!$record) { return $false }
        foreach ($field in @('pid','path','startedUtcTicks')) {
            if (@($record.PSObject.Properties.Name) -notcontains $field) { return $false }
        }
        if (!(Integer $record.pid) -or $record.pid -le 0 -or $record.pid -gt [int]::MaxValue -or
            !(Integer $record.startedUtcTicks) -or $record.startedUtcTicks -le 0 -or
            $record.startedUtcTicks -gt [DateTime]::MaxValue.Ticks -or $record.path -isnot [string] -or
            ![String]::Equals($record.path, $Path, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $Expected.pid -eq $Actual.pid -and $Expected.startedUtcTicks -eq $Actual.startedUtcTicks
}
function Startup-Identity($Expected, $Actual, [string]$Path) {
    if (!(Matches-Identity $Expected $Expected $Path)) { throw 'Invalid newly created process identity.' }
    if (!$Actual) { return 'pending' }
    if (Matches-Identity $Expected $Actual $Path) { return 'ready' }
    if (!$Actual.path) {
        $unpublished = [pscustomobject]@{pid=$Actual.pid;path=$Path;startedUtcTicks=$Actual.startedUtcTicks}
        if (Matches-Identity $Expected $unpublished $Path) { return 'pending' }
    }
    throw 'Process identity did not match its requested executable.'
}
function Matches-GuestMarker($Marker, [string]$RootPath, [string]$ComputerName) {
    if ($Marker -isnot [pscustomobject]) { return $false }
    foreach ($field in @('schemaVersion','root','computerName','leaseSeconds','provider','ownerId')) {
        if (@($Marker.PSObject.Properties.Name) -cnotcontains $field) { return $false }
    }
    $owner = [Guid]::Empty
    (Integer $Marker.schemaVersion) -and $Marker.schemaVersion -eq 1 -and
        $RootPath -eq 'C:\GunBoundAI' -and $Marker.root -is [string] -and $Marker.root -eq $RootPath -and
        $Marker.computerName -is [string] -and $Marker.computerName -eq 'GUNBOUND-BOT' -and
        $Marker.computerName -eq $ComputerName -and (Integer $Marker.leaseSeconds) -and $Marker.leaseSeconds -eq 120 -and
        $Marker.provider -is [string] -and $Marker.provider -ceq 'virtualbox' -and $Marker.ownerId -is [string] -and
        $Marker.ownerId -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -and
        [Guid]::TryParseExact($Marker.ownerId, 'D', [ref]$owner) -and $owner -ne [Guid]::Empty -and
        ((Property $Marker 'serverRoot') -eq $null -or
            ((Property $Marker 'serverRoot') -is [string] -and (Property $Marker 'serverRoot') -ceq 'C:\GunBoundServer'))
}
function Matches-WorkerRegistration($Registration, $Coordinator, $Worker, $Target, [string]$Name, [string]$ShellPath) {
    $Registration -and (Integer (Property $Registration 'schemaVersion')) -and $Registration.schemaVersion -eq 1 -and
        (Property $Registration 'name') -is [string] -and $Registration.name -ceq $Name -and $Name -cin @('BotOne','BotTwo','BotThree') -and
        (Property $Registration 'script') -is [string] -and
        [String]::Equals($Registration.script, 'C:\GunBoundAI\vm\guest-session.ps1', [StringComparison]::OrdinalIgnoreCase) -and
        (Same-Target $Registration $Target) -and (Integer $Registration.roomId) -and $Registration.roomId -ge 0 -and
        $Registration.roomId -le 65535 -and $Registration.roomCapacity -in @(2,4) -and
        $Name -cin @(Get-RoomBotNames $Registration.roomCapacity) -and
        (Matches-Identity (Property $Registration 'coordinator') $Coordinator $ShellPath) -and
        (Matches-Identity (Property $Registration 'worker') $Worker $ShellPath)
}
function Matches-WorkerStatus($Status, $Registration, [string]$ShellPath) {
    $Status -and (Integer (Property $Status 'schemaVersion')) -and $Status.schemaVersion -eq 2 -and
        (Property $Status 'name') -is [string] -and $Status.name -ceq $Registration.name -and (Same-Target $Status $Registration) -and
        (Matches-Identity (Property $Status 'worker') $Registration.worker $ShellPath) -and
        (Matches-Identity (Property $Status 'coordinator') $Registration.coordinator $ShellPath)
}
function Matches-PeerProcess($Registration, $Status, $Actual, $Coordinator, $Worker, $Target, [string]$ShellPath) {
    $name = Property $Registration 'name'
    if (!(Matches-WorkerRegistration $Registration $Coordinator $Worker $Target $name $ShellPath) -or
        !(Matches-WorkerStatus $Status $Registration $ShellPath)) { return $false }
    $peerRoot = Instance-Root $name
    $paths = @{client="$peerRoot\client-image\GunBound.gme";launcher="$peerRoot\lab-client.exe"
        controller="$peerRoot\bot-controller.exe";probe="$peerRoot\bot-controller.exe";tool="$peerRoot\lab-tools.exe"}
    foreach ($kind in @('client','launcher','controller','probe','tool')) {
        if (Matches-Identity (Property $Status $kind) $Actual $paths[$kind]) { return $true }
    }
    return $false
}
function Matches-StopRequest($Request, $Registration, [DateTime]$Now, [string]$ShellPath) {
    try {
        if (!$Request -or !(Integer (Property $Request 'schemaVersion')) -or $Request.schemaVersion -ne 1 -or
            (Property $Request 'action') -isnot [string] -or $Request.action -cne 'stop' -or
            (Property $Request 'name') -isnot [string] -or $Request.name -cne $Registration.name -or !(Same-Target $Request $Registration) -or
            !(Matches-Identity (Property $Request 'worker') $Registration.worker $ShellPath) -or
            !(Matches-Identity (Property $Request 'coordinator') $Registration.coordinator $ShellPath)) { return $false }
        $issued = Utc-Ticks (Property $Request 'issuedUtc')
        $issued -ge $Registration.worker.startedUtcTicks -and
            $issued -le $Now.ToUniversalTime().AddSeconds(30).Ticks -and $issued -gt $Now.ToUniversalTime().AddSeconds(-120).Ticks
    } catch { return $false }
}
function Native-Observation($Native) {
    if ($Native -isnot [pscustomobject] -or @($Native.PSObject.Properties.Name) -notcontains 'Mode') {
        throw 'Native room probe must include its nullable mode field.'
    }
    $available = Property $Native 'Available'
    $mode = Property $Native 'Mode'
    if ($available -isnot [bool] -or ($null -eq $mode -and $available) -or
        ($null -ne $mode -and (!(Integer $mode) -or $mode -lt 0 -or $mode -gt 65535))) {
        throw 'Native room probe returned an invalid availability/mode shape.'
    }
    $observation = Property $Native 'Observation'
    $retryable = Property $Native 'Retryable'
    if ($null -eq $observation -and $null -eq $retryable) {
        if ($null -eq $mode) { throw 'A legacy native diagnostic must include its integer mode.' }
        if ($available) { return 'room' }
        return 'retryable'
    }
    if ($observation -isnot [string] -or $observation -cnotin @('room','non-room','snapshot-busy','structural-error') -or
        $retryable -isnot [bool] -or $available -ne ($observation -ceq 'room') -or
        ($observation -cin @('non-room','snapshot-busy') -and !$retryable) -or
        ($observation -cin @('room','structural-error') -and $retryable)) {
        throw 'Native room probe returned contradictory observation/retryability fields.'
    }
    if ($observation -ceq 'structural-error') {
        $diagnostic = Property $Native 'Diagnostic'
        if ($diagnostic -isnot [string]) { $diagnostic = 'No bounded diagnostic text was returned.' }
        if ($diagnostic.Length -gt 512) { $diagnostic = $diagnostic.Substring(0,512) }
        throw "Non-retryable native structural error: $diagnostic"
    }
    if ($available) { return 'room' }
    return 'retryable'
}
function Native-RoomSummary($Native, $Target, [string]$Name, [switch]$Joining) {
    if ((Property $Native 'Available') -isnot [bool] -or !$Native.Available) { throw 'The native room snapshot is not available yet.' }
    foreach ($field in @('Mode','RoomId','Capacity','SelfSlot','MasterSlot','Occupied')) {
        if (!(Integer (Property $Native $field))) { throw "Native room $field is not an integer." }
    }
    if ($Native.Mode -notin @(9,11) -or ($Joining -and $Native.Mode -ne 9) -or
        $Native.RoomId -lt 0 -or $Native.RoomId -gt 65535 -or $Native.Capacity -notin @(2,4) -or
        $Native.SelfSlot -lt 0 -or $Native.SelfSlot -gt 7 -or $Native.MasterSlot -lt 0 -or $Native.MasterSlot -gt 7 -or
        $Native.Occupied -lt 2 -or $Native.Occupied -gt $Native.Capacity) { throw 'Unsupported native room mode, capacity, slots, or occupancy.' }
    if ($Target.schemaVersion -eq 2) {
        if ($Native.RoomId -ne $Target.roomId -or $Native.Capacity -ne $Target.roomCapacity) {
            throw "Joined native room $($Native.RoomId)/capacity $($Native.Capacity) differs from protected Player room $($Target.roomId)/capacity $($Target.roomCapacity); no Ready or handoff is allowed."
        }
    } elseif ($Native.Capacity -ne 2) { throw 'Legacy guest sessions support only an actual two-player room.' }
    $gameType = Property $Native 'GameType'
    if ($null -ne $gameType -and (!(Integer $gameType) -or $gameType -ne 0)) { throw 'The native controller supports Solo game type 0 only; no handoff is allowed for Score/Tag/Jewel.' }
    foreach ($field in @('Names','States','Teams')) {
        if ((Property $Native $field) -isnot [array] -or $Native.$field.Count -ne 8) { throw "Invalid native $field array." }
    }
    $expected = @('Player') + @(Get-RoomBotNames $Native.Capacity)
    $seen = @()
    for ($slot = 0; $slot -lt 8; $slot++) {
        if (!(Integer $Native.States[$slot]) -or $Native.States[$slot] -lt 0 -or $Native.States[$slot] -gt 4) { throw 'Unknown native roster state.' }
        if ($Native.States[$slot] -eq 0) { continue }
        if ($Native.Names[$slot] -isnot [string] -or $Native.Names[$slot] -cnotin $expected -or
            $Native.Names[$slot] -cin $seen -or !(Integer $Native.Teams[$slot]) -or
            ($Native.Teams[$slot] -notin @(0,1) -and ($Joining -or $Native.Teams[$slot] -ne 255))) {
            throw 'The native room contains an unapproved, duplicate, or unsettled participant.'
        }
        $seen += $Native.Names[$slot]
    }
    if ($seen.Count -ne $Native.Occupied -or $Native.States[$Native.SelfSlot] -eq 0 -or
        $Native.States[$Native.MasterSlot] -eq 0 -or $Native.Names[$Native.MasterSlot] -cne 'Player' -or
        (Property $Native 'SelfName') -isnot [string] -or $Native.SelfName -cne $Name -or $Native.Names[$Native.SelfSlot] -cne $Name) {
        throw 'The native self identity and human Player master were not verified.'
    }
    [pscustomobject]@{mode=$Native.Mode;roomId=$Native.RoomId;roomCapacity=$Native.Capacity;selfSlot=$Native.SelfSlot
        nativeReady=($Native.Mode -eq 9 -and $Native.States[$Native.SelfSlot] -eq 3)}
}

function Invoke-Checks {
    function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
    $emptyOutput = '' + (& {})
    Assert ($null -ne $emptyOutput -and $emptyOutput.Trim() -ceq '') 'Empty native-helper output must remain a string in PowerShell 5.1.'
    Assert ((Decode-Mode '0B000000') -eq 11 -and (Decode-Mode '09000000') -eq 9 -and
        (Decode-Mode '78563412') -eq 0x12345678 -and (Decode-Mode 'FFFFFFFF') -eq [uint32]::MaxValue) 'LE decoding changed.'
    $rejected = $false
    try { Decode-Mode '090000' | Out-Null } catch { $rejected = $true }
    Assert $rejected 'A short memory response was accepted.'
    Assert ((Utc-Ticks '2026-09-13T03:45:50.2371076Z') -eq 639248679502371076L -and
        (Utc-Ticks '2026-09-13T03:45:50.2371076+00:00') -eq 639248679502371076L) 'Timestamp ticks lost precision.'
    $now = [DateTime]::Parse('2026-09-13T00:00:00Z').ToUniversalTime()
    $data = [pscustomobject]@{
        schemaVersion=1; sessionId='11111111-2222-3333-4444-555555555555'
        issuedUtc=$now.ToString('o'); expiresUtc=$now.AddSeconds(120).ToString('o'); playerOnline=$true; roomReady=$true
    }
    $valid = Validate-Lease $data $now
    Assert ((Lease-State $valid $now) -eq 'online' -and (Lease-State $valid $now.AddSeconds(120)) -eq 'expired' -and
        (Lease-State $null $now) -eq 'missing') 'Lease expiry or missing-state guard changed.'
    Assert (Player-RoomReady $valid $now) 'An online room-ready lease was rejected.'
    $valid.roomReady = $false
    Assert (!(Player-RoomReady $valid $now)) 'Bot client startup was allowed before Player created a room.'
    $valid.roomReady = $true
    $valid.playerOnline = $false
    Assert ((Lease-State $valid $now) -eq 'offline') 'An offline lease can run a client.'
    $roomLease = [pscustomobject]@{
        schemaVersion=2; sessionId=$data.sessionId; issuedUtc=$data.issuedUtc; expiresUtc=$data.expiresUtc
        playerOnline=$true; roomReady=$true; roomId=0; roomCapacity=2
    }
    $room = Validate-Lease $roomLease $now
    Assert ($room.roomId -eq 0 -and $room.roomCapacity -eq 2 -and
        (@(Get-RoomBotNames $room.roomCapacity) -join ',') -ceq 'BotOne') 'A two-slot room, including native room ID zero, did not select exactly BotOne.'
    $roomLease.roomId = 23; $roomLease.roomCapacity = 4
    $room = Validate-Lease $roomLease $now
    Assert ((@(Get-RoomBotNames $room.roomCapacity) -join ',') -ceq 'BotOne,BotTwo,BotThree') 'A four-slot room did not select the three configured bots.'
    $roomLease.roomReady = $false
    Assert ((Validate-Lease $roomLease $now).roomCapacity -eq 4) 'Battle transitions lost their known room target.'
    foreach ($capacity in @(6,8)) {
        $roomLease.roomCapacity = $capacity
        Assert ((Validate-Lease $roomLease $now).roomCapacity -eq $capacity) 'An unsupported room cannot be reported without expiring the Player lease.'
        $rejected = $false
        try { Get-RoomBotNames $capacity | Out-Null } catch [ArgumentException] { $rejected = $true }
        Assert $rejected 'A larger room silently selected a smaller bot count.'
        $roomLease.roomReady = $true
        $rejected = $false
        try { Validate-Lease $roomLease $now | Out-Null } catch [ArgumentException] { $rejected = $true }
        Assert $rejected 'An unsupported room was authorized for bot joining.'
        $roomLease.roomReady = $false
    }
    $roomLease.roomCapacity = 0; $roomLease.roomId = $null
    Assert ((Validate-Lease $roomLease $now).roomCapacity -eq 0 -and
        @(Get-RoomBotNames 0).Count -eq 0) 'Leaving a room did not remove its bot target.'
    foreach ($case in @('missing-id','bad-id','capacity-type','offline-room')) {
        $badRoom = [pscustomobject]@{
            schemaVersion=2; sessionId=$data.sessionId; issuedUtc=$data.issuedUtc; expiresUtc=$data.expiresUtc
            playerOnline=$true; roomReady=$true; roomId=23; roomCapacity=4
        }
        switch ($case) {
            'missing-id' { $badRoom.roomId = $null }
            'bad-id' { $badRoom.roomId = 65536 }
            'capacity-type' { $badRoom.roomCapacity = '4' }
            'offline-room' { $badRoom.playerOnline = $false }
        }
        $rejected = $false
        try { Validate-Lease $badRoom $now | Out-Null } catch [ArgumentException] { $rejected = $true }
        Assert $rejected "Invalid room lease case was accepted: $case."
    }
    foreach ($case in @('guid','guid-format','guid-space','zero','long','negative','future','boolean','shape','date')) {
        $bad = $data | ConvertTo-Json | ConvertFrom-Json
        switch ($case) {
            'guid' { $bad.sessionId = 'not-a-guid' }
            'guid-format' { $bad.sessionId = '11111111222233334444555555555555' }
            'guid-space' { $bad.sessionId = ' ' + $bad.sessionId }
            'zero' { $bad.expiresUtc = $bad.issuedUtc }
            'long' { $bad.expiresUtc = $now.AddSeconds(121).ToString('o') }
            'negative' { $bad.expiresUtc = $now.AddSeconds(-1).ToString('o') }
            'future' { $bad.issuedUtc = $now.AddSeconds(31).ToString('o'); $bad.expiresUtc = $now.AddSeconds(60).ToString('o') }
            'boolean' { $bad.playerOnline = 'true' }
            'shape' { $bad.PSObject.Properties.Remove('roomReady') }
            'date' { $bad.expiresUtc = 'NaN' }
        }
        $rejected = $false
        try { Validate-Lease $bad $now | Out-Null } catch { $rejected = $true }
        Assert $rejected "Invalid lease case was accepted: $case."
    }
    $path = 'C:\GunBoundAI\client-image\GunBound.gme'
    $owned = [pscustomobject]@{pid=200;path=$path;startedUtcTicks=639248679502371076L}
    $observed = $owned | ConvertTo-Json | ConvertFrom-Json
    Assert (Matches-Identity $owned $observed $path) 'An exact synthetic identity was rejected.'
    Assert ((Startup-Identity $owned $observed $path) -eq 'ready') 'A published startup identity was rejected.'
    $observed.path = $null
    Assert (!(Matches-Identity $owned $observed $path) -and
        (Startup-Identity $owned $observed $path) -eq 'pending' -and
        (Startup-Identity $owned $null $path) -eq 'pending') 'An unpublished image path was accepted as ownership or rejected before startup could finish.'
    $observed.startedUtcTicks++
    $rejected = $false
    try { Startup-Identity $owned $observed $path | Out-Null } catch { $rejected = $true }
    Assert $rejected 'A mismatched creation time was treated as a pending startup.'
    $observed.startedUtcTicks = $owned.startedUtcTicks; $observed.path = $path
    $observed.startedUtcTicks++
    Assert (!(Matches-Identity $owned $observed $path)) 'A reused PID was accepted.'
    $observed.startedUtcTicks = $owned.startedUtcTicks; $observed.path = 'C:\Other\GunBound.gme'
    Assert (!(Matches-Identity $owned $observed $path)) 'An unowned executable path was accepted.'
    $observed.path = $path; $observed.pid = 201
    Assert (!(Matches-Identity $owned $observed $path) -and !(Matches-Identity $owned $null $path)) 'A foreign or missing process was accepted.'
    $observed.pid = 200; $observed.startedUtcTicks = [double]$owned.startedUtcTicks
    Assert (!(Matches-Identity $owned $observed $path)) 'Rounded floating-point process ticks were accepted.'
    $marker = [pscustomobject]@{
        schemaVersion=1;root='C:\GunBoundAI';computerName='GUNBOUND-BOT';leaseSeconds=120
        provider='virtualbox';ownerId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    }
    Assert ((Matches-GuestMarker $marker 'C:\GunBoundAI' 'GUNBOUND-BOT') -and
        !(Matches-GuestMarker $marker 'C:\GunBoundAI' 'PARENT-HOST') -and
        !(Matches-GuestMarker $marker 'C:\Other' 'GUNBOUND-BOT')) 'A host/root mismatch was accepted.'
    Assert (!(Room-FillEnabled $marker)) 'A legacy marker enabled multiple instances.'
    $marker | Add-Member serverRoot 'C:\GunBoundServer'
    $marker | Add-Member roomFill $true
    $marker | Add-Member botInstances @(
        [pscustomobject]@{name='BotOne';address='192.168.56.10'}
        [pscustomobject]@{name='BotTwo';address='192.168.56.11'}
        [pscustomobject]@{name='BotThree';address='192.168.56.12'}
    )
    Assert ((Room-FillEnabled $marker) -and (Instance-Root 'BotTwo') -ceq 'C:\GunBoundAI\instances\BotTwo') 'The fixed room-fill marker was rejected.'
    foreach ($name in @('Player','..\BotOne','BotFour','')) {
        $rejected = $false
        try { Instance-Root $name | Out-Null } catch { $rejected = $true }
        Assert $rejected "An arbitrary instance identity/path was accepted: $name."
    }
    foreach ($case in @('address','name','count','flag','server','name-type','address-type','server-type')) {
        $badMarker = $marker | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        switch ($case) {
            'address' { $badMarker.botInstances[1].address = '192.168.56.10' }
            'name' { $badMarker.botInstances[1].name = '..\Player' }
            'count' { $badMarker.botInstances = @($badMarker.botInstances[0]) }
            'flag' { $badMarker.roomFill = 'true' }
            'server' { $badMarker.serverRoot = 'C:\GunBoundAI' }
            'name-type' { $badMarker.botInstances[0].name = $true }
            'address-type' { $badMarker.botInstances[0].address = $true }
            'server-type' { $badMarker.serverRoot = $true }
        }
        $rejected = $false
        try { Room-FillEnabled $badMarker | Out-Null } catch { $rejected = $true }
        Assert $rejected "Unsafe room-fill marker was accepted: $case."
    }
    $badMarker = $marker | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $badMarker.provider = $true
    Assert (!(Matches-GuestMarker $badMarker 'C:\GunBoundAI' 'GUNBOUND-BOT')) 'A boolean provider was coerced into the protected marker identity.'
    $roomLease.roomId = 23; $roomLease.roomCapacity = 4; $roomLease.roomReady = $true
    $targetLease = Validate-Lease $roomLease $now
    $target = Lease-Target $targetLease $now
    $battle = $targetLease | ConvertTo-Json | ConvertFrom-Json; $battle.roomReady = $false
    Assert ((Same-Target $target (Lease-Target $battle $now)) -and
        (Room-Phase $battle $now) -eq 'waiting-room') 'Battle incorrectly removed the active target or allowed new joins.'
    foreach ($field in @('roomId','roomCapacity','sessionId')) {
        $changed = $targetLease | ConvertTo-Json | ConvertFrom-Json
        switch ($field) {
            'roomId' { $changed.roomId++ }
            'roomCapacity' { $changed.roomCapacity = 2 }
            'sessionId' { $changed.sessionId = '22222222-2222-3333-4444-555555555555' }
        }
        Assert (!(Same-Target $target (Lease-Target $changed $now))) "Target change did not retire existing workers: $field."
    }
    Assert (!(Same-Target $target (Lease-Target $null $now)) -and
        $null -eq (Lease-Target $targetLease $now.AddSeconds(120))) 'Missing/expired leases retained a room.'
    foreach ($capacity in @(6,8)) {
        $unsupported = $targetLease | ConvertTo-Json | ConvertFrom-Json
        $unsupported.roomCapacity = $capacity; $unsupported.roomReady = $false
        Assert ((Room-Phase $unsupported $now) -eq 'unsupported-room-size' -and
            (Lease-State $unsupported $now) -eq 'online' -and
            (Lease-Target $unsupported $now).roomCapacity -eq $capacity) 'Unsupported capacity disconnected Player or silently lost its actual room size.'
    }
    $shell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $coordinator = [pscustomobject]@{pid=100;path=$shell;startedUtcTicks=$now.AddSeconds(-20).Ticks}
    $worker = [pscustomobject]@{pid=101;path=$shell;startedUtcTicks=$now.AddSeconds(-10).Ticks}
    $registration = [pscustomobject]@{schemaVersion=1;name='BotTwo';sessionId=$target.sessionId;roomId=23;roomCapacity=4
        script='C:\GunBoundAI\vm\guest-session.ps1';coordinator=$coordinator;worker=$worker}
    $peerClient = [pscustomobject]@{pid=102;path='C:\GunBoundAI\instances\BotTwo\client-image\GunBound.gme';startedUtcTicks=$now.AddSeconds(-5).Ticks}
    $peer = [pscustomobject]@{schemaVersion=2;name='BotTwo';sessionId=$target.sessionId;roomId=23;roomCapacity=4
        worker=$worker;coordinator=$coordinator;client=$peerClient;controller=$null;launcher=$null;tool=$null;probe=$null}
    Assert (Matches-PeerProcess $registration $peer $peerClient $coordinator $worker $target $shell) 'An exact registered managed peer was rejected.'
    $foreign = $peerClient | ConvertTo-Json | ConvertFrom-Json; $foreign.startedUtcTicks++
    Assert (!(Matches-PeerProcess $registration $peer $foreign $coordinator $worker $target $shell)) 'A reused peer client PID was accepted.'
    $foreign.startedUtcTicks = $peerClient.startedUtcTicks; $foreign.path = 'C:\Other\GunBound.gme'
    Assert (!(Matches-PeerProcess $registration $peer $foreign $coordinator $worker $target $shell)) 'An arbitrary matching executable name was allowed as a peer.'
    $staleWorker = $worker | ConvertTo-Json | ConvertFrom-Json; $staleWorker.startedUtcTicks++
    Assert (!(Matches-PeerProcess $registration $peer $peerClient $coordinator $staleWorker $target $shell) -and
        !(Matches-PeerProcess $null $peer $peerClient $coordinator $worker $target $shell)) 'A stale or unregistered worker authorized a client.'
    foreach ($field in @('name','script')) {
        $badRegistration = $registration | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $badRegistration.$field = $true
        Assert (!(Matches-WorkerRegistration $badRegistration $coordinator $worker $target 'BotTwo' $shell)) "A boolean worker $field was accepted by string coercion."
    }
    $stop = [pscustomobject]@{schemaVersion=1;action='stop';name='BotTwo';sessionId=$target.sessionId;roomId=23;roomCapacity=4
        coordinator=$coordinator;worker=$worker;issuedUtc=$now.ToString('o')}
    Assert (Matches-StopRequest $stop $registration $now $shell) 'An exact current scoped stop request was rejected.'
    foreach ($case in @('worker','coordinator','session','room','old','future','name-type','action-type')) {
        $badStop = $stop | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        switch ($case) {
            'worker' { $badStop.worker.startedUtcTicks++ }
            'coordinator' { $badStop.coordinator.startedUtcTicks++ }
            'session' { $badStop.sessionId = '22222222-2222-3333-4444-555555555555' }
            'room' { $badStop.roomId++ }
            'old' { $badStop.issuedUtc = $now.AddSeconds(-121).ToString('o') }
            'future' { $badStop.issuedUtc = $now.AddSeconds(31).ToString('o') }
            'name-type' { $badStop.name = $true }
            'action-type' { $badStop.action = $true }
        }
        Assert (!(Matches-StopRequest $badStop $registration $now $shell)) "A stale scoped stop was accepted: $case."
    }
    $native = [pscustomobject]@{Available=$true;Mode=9;RoomId=23;Capacity=4;SelfSlot=6;SelfName='BotTwo';MasterSlot=3;Occupied=2
        Names=@($null,$null,$null,'Player',$null,$null,'BotTwo',$null)
        States=@(0,0,0,1,0,0,1,0);Teams=@(0,0,0,0,0,0,0,0)}
    $summary = Native-RoomSummary $native $targetLease 'BotTwo' -Joining
    Assert ($summary.selfSlot -eq 6 -and !$summary.nativeReady) 'A non-slot1 worker was refused or controller liveness was confused with native Ready.'
    Assert ((Native-Observation $native) -ceq 'room') 'Legacy read-only room diagnostics were rejected.'
    foreach ($observation in @('non-room','snapshot-busy')) {
        $retry = [pscustomobject]@{Available=$false;Mode=11;Observation=$observation;Retryable=$true;Diagnostic='Native state is settling.'}
        Assert ((Native-Observation $retry) -ceq 'retryable') 'A retryable diagnostic was treated as a structural failure.'
    }
    $openFailure = [pscustomobject]@{Available=$false;Mode=$null;Observation='structural-error';Retryable=$false;Diagnostic='Synthetic read-only open failure.'}
    $rejected = $false
    try { Native-Observation $openFailure | Out-Null }
    catch { $rejected = $_.Exception.Message -like 'Non-retryable native structural error:*' }
    Assert $rejected 'A nullable-mode structural failure was retried or lost its explicit diagnostic.'
    $openFailure.Retryable = $true
    $rejected = $false
    try { Native-Observation $openFailure | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Contradictory retryability authorized a native structural error.'
    $native.States[6] = 3
    Assert ((Native-RoomSummary $native $targetLease 'BotTwo').nativeReady) 'Server-confirmed native Ready was not reported.'
    $native.Mode = 11
    Assert (!(Native-RoomSummary $native $targetLease 'BotTwo').nativeReady) 'A battle snapshot claimed room Ready.'
    $native.Teams[6] = 255
    Assert ((Native-RoomSummary $native $targetLease 'BotTwo').mode -eq 11) 'A controller-paused team byte discarded an existing battle worker.'
    $native.Mode = 9
    $rejected = $false
    try { Native-RoomSummary $native $targetLease 'BotTwo' -Joining | Out-Null } catch { $rejected = $true }
    Assert $rejected 'An unsettled team byte was accepted before handoff.'
    $native.Teams[6] = 0
    foreach ($case in @('room','capacity','self','master','duplicate','occupancy','self-type','game-type')) {
        $badNative = $native | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        switch ($case) {
            'room' { $badNative.RoomId++ }
            'capacity' { $badNative.Capacity = 6 }
            'self' { $badNative.SelfName = 'BotOne' }
            'master' { $badNative.MasterSlot = 6 }
            'duplicate' { $badNative.Names[1] = 'Player'; $badNative.States[1] = 1; $badNative.Occupied++ }
            'occupancy' { $badNative.Occupied = 4 }
            'self-type' { $badNative.SelfName = $true }
            'game-type' { $badNative | Add-Member GameType 1 }
        }
        $rejected = $false
        try { Native-RoomSummary $badNative $targetLease 'BotTwo' -Joining | Out-Null } catch { $rejected = $true }
        Assert $rejected "Unverified native handoff was accepted: $case."
    }
    $aggregate = [ordered]@{schemaVersion=2;instances=@($peer);desiredCount=1;readyCount=0}
    $roundTrip = ConvertTo-Json -InputObject $aggregate -Depth 6 | ConvertFrom-Json
    Assert ($roundTrip.instances -is [array] -and $roundTrip.instances.Count -eq 1) 'A singleton instance array collapsed in PowerShell 5.1 JSON.'
    & {
        function Require-WorkerContext {}
        function Read-JsonFile { return $batch }
        $Instance = 'BotTwo'; $selfIdentity = $worker
        $batch = [pscustomobject]@{schemaVersion=2;phase='starting-bots';inputBatch=$true;inputInstance='BotTwo'
            inputWorker=$worker;coordinator=$coordinator;sessionId=$target.sessionId;roomId=23;roomCapacity=4}
        Assert-BatchGrant
        $batch.inputInstance = 'BotThree'
        $rejected = $false
        try { Assert-BatchGrant } catch { $rejected = $true }
        Assert $rejected 'A peer received another worker''s setup input grant.'
        $batch.inputInstance = 'BotTwo'; $batch.inputWorker = $staleWorker
        $rejected = $false
        try { Assert-BatchGrant } catch { $rejected = $true }
        Assert $rejected 'A reused worker PID received a setup input grant.'
        $batch.inputWorker = $worker; $batch.phase = $true
        $rejected = $false
        try { Assert-BatchGrant } catch { $rejected = $true }
        Assert $rejected 'A boolean phase granted setup input by string coercion.'
    }
    & {
        $leasePath = 'synthetic-player-lease'
        $publication = [ordered]@{schemaVersion=1;sessionId=[Guid]::NewGuid().ToString('D')
            issuedUtc=[DateTime]::UtcNow.ToString('o');expiresUtc=[DateTime]::UtcNow.AddSeconds(119).ToString('o')
            playerOnline=$true;roomReady=$false}
        $leaseText = $publication | ConvertTo-Json -Compress
        function Open-SharedReader([string]$Path, [switch]$WaitForPublication) {
            Assert ($Path -ceq $leasePath -and $WaitForPublication) 'A lease consumer bypassed bounded publication waiting.'
            [IO.StreamReader]::new([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($leaseText)))
        }
        $observed = Read-Lease
        Assert ($observed.sessionId -ceq $publication.sessionId -and $observed.playerOnline) 'A published Player lease was treated as missing.'
        $leaseText = '{'
        $rejected = $false
        try { Read-Lease | Out-Null } catch { $rejected = $true }
        Assert $rejected 'Malformed lease data was hidden as a publication gap.'
        $leaseText = ' ' * 4097
        $rejected = $false
        try { Read-Lease | Out-Null } catch { $rejected = $true }
        Assert $rejected 'An oversized lease was accepted.'
        function Open-SharedReader([string]$Path, [switch]$WaitForPublication) {
            Assert $WaitForPublication 'A missing lease was not given its bounded publication wait.'
            throw [IO.FileNotFoundException]::new('Synthetic missing lease after the bounded wait.')
        }
        Assert ($null -eq (Read-Lease)) 'A genuinely missing lease invented Player authority.'
    }
    & {
        Assert ([regex]::Matches([IO.File]::ReadAllText($PSCommandPath), 'Read-JsonFile\s+\$baseStatusPath\b').Count -eq 1) `
            'A coordinator-status consumer bypasses the bounded publication reader.'
        $script:contextReads = 0
        $registration = [pscustomobject]@{coordinator=$coordinator}
        $baseStatusPath = 'synthetic-coordinator-status'
        function Read-JsonFile {
            $script:contextReads++
            if ($script:contextReads -lt 3) { return $null }
            [pscustomobject]@{schemaVersion=2;roomId=0;roomCapacity=4}
        }
        function Owned { return $true }
        $observed = Read-CoordinatorStatus
        Assert ($script:contextReads -eq 3 -and $observed.roomId -eq 0) 'A transient missing coordinator publication cancelled a live worker.'
        $script:contextReads = 0
        function Read-JsonFile { $script:contextReads++; return $null }
        function Owned { return $false }
        Assert ($null -eq (Read-CoordinatorStatus) -and $script:contextReads -eq 1) 'A missing coordinator was treated as live publication contention.'
        function Owned { return $true }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Assert ($null -eq (Read-CoordinatorStatus)) 'A missing status invented coordinator authority.'
        Assert ($watch.ElapsedMilliseconds -ge 900 -and $watch.ElapsedMilliseconds -lt 3000) 'Coordinator publication retry is not bounded to one second.'
    }
    & {
        $now = [DateTime]::UtcNow
        $entry = [pscustomobject]@{alive=$true;status=[pscustomobject]@{updatedUtc=$now.ToString('o')}}
        Assert (Recent-WorkerPublication $entry $now) 'A just-verified worker publication was discarded during replacement.'
        $entry.status.updatedUtc = $now.AddSeconds(-3).ToString('o')
        Assert (!(Recent-WorkerPublication $entry $now)) 'A stale worker publication retained readiness indefinitely.'
        $entry.status.updatedUtc = $now.ToString('o'); $entry.alive = $false
        Assert (!(Recent-WorkerPublication $entry $now)) 'An exited worker was kept alive by a cached publication.'
    }
    & {
        $selection = [pscustomobject]@{mobile=5;nativeReady=$true}
        $actions = New-Object 'Collections.Generic.List[string]'
        function Byte { return $selection.mobile }
        function Require-Lease { param([switch]$Joining) return [pscustomobject]@{roomReady=$true} }
        function Read-NativeRoom { return [pscustomobject]@{} }
        function Native-RoomSummary { return [pscustomobject]@{nativeReady=$selection.nativeReady} }
        function Log {}
        function Input([string]$Action, [string[]]$Arguments, [int]$ExpectedMode, [switch]$Joining) {
            Assert ($Action -eq 'click' -and $ExpectedMode -eq 9 -and $Joining) 'Room mobile input escaped the verified joining room.'
            $actions.Add(($Arguments -join ','))
            if ($Arguments[0] -eq '756') { $selection.nativeReady = $false }
            if ($Arguments[0] -eq '565') { $selection.mobile = 0 }
        }
        Select-RoomArmor
        Assert (($actions -join '|') -ceq '756,568,250|320,180,250|211,189,250|565,423,250' -and $selection.mobile -eq 0) 'Verified room Armor selection or native Unready sequencing changed.'
        $actions.Clear()
        Select-RoomArmor
        Assert ($actions.Count -eq 0) 'An already-selected Armor mobile received unnecessary input.'
        $selection.nativeReady = $true
        Select-RoomArmor
        Assert (($actions -join '|') -ceq '756,568,250' -and !$selection.nativeReady) `
            'An already-selected Armor bot stayed auto-Ready before team setup finished.'
    }
    & {
        function Save-Status {}
        $state = [ordered]@{schemaVersion=2;sessionId=$target.sessionId;roomId=23;roomCapacity=4;instances=@();readyCount=0}
        $workerStatus = [pscustomobject]@{phase='controller-running';clientMode=9;nativeReady=$true;lastError=$null}
        $entry = [pscustomobject]@{registration=$registration;status=$workerStatus;error=$null;alive=$true}
        $workers = [ordered]@{BotTwo=$entry}
        Save-CoordinatorStatus
        Assert ($state.instances -is [array] -and $state.instances.Count -eq 3 -and $state.readyCount -eq 1) 'Aggregate status lost its fixed instance array or native Ready count.'
        $entry.alive = $false
        Save-CoordinatorStatus
        Assert ($state.readyCount -eq 0) 'A dead worker retained aggregate Ready credit.'
    }
    & {
        function Assert-Guest {}
        $roomFill = $true; $isCoordinator = $false; $Instance = 'BotOne'
        $state = [ordered]@{client=$null;launcher=$null;controller=$null;tool=$null;probe=$null}
        $peer | Add-Member updatedUtc ([DateTime]::UtcNow.ToString('o'))
        $observedWorker = $worker
        function Read-JsonFile([string]$Path, [int]$Limit) {
            if ($Path -ceq 'C:\GunBoundAI\instances\BotTwo\session\worker-registration.json') { return $registration }
            if ($Path -ceq 'C:\GunBoundAI\instances\BotTwo\session\guest-status.json') { return $peer }
            return $null
        }
        function Get-CimInstance { [pscustomobject]@{ProcessId=$peerClient.pid} }
        function Observe([int]$ProcessId) {
            if ($ProcessId -eq $worker.pid) { return $observedWorker }
            if ($ProcessId -eq $peerClient.pid) { return $peerClient }
            return $null
        }
        No-ForeignProcesses
        $observedWorker = $staleWorker
        $rejected = $false
        try { No-ForeignProcesses } catch { $rejected = $true }
        Assert $rejected 'A stale peer worker authorized a client in the real process-enumeration guard.'
    }
    & {
        $previous = $script:inputStateMethod
        try {
            Initialize-InputReader
            $method = $script:inputStateMethod
            $import = @($method.GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false))[0]
            Assert ($method.ReturnType -eq [int16] -and $method.GetParameters().Count -eq 1 -and
                $method.GetParameters()[0].ParameterType -eq [int] -and $import.Value -ceq 'user32.dll' -and
                $import.EntryPoint -ceq 'GetAsyncKeyState') 'The in-memory read-only input import has an incorrect native signature.'
        } finally { $script:inputStateMethod = $previous }
    }
    & {
        $seen = [Collections.Generic.List[int]]::new()
        $heldKey = 0
        function Native-KeyDown([int]$VirtualKey) { $seen.Add($VirtualKey); return $VirtualKey -eq $heldKey }
        function Read-InputFault { return $null }
        function Publish-InputFault { $script:inputFault = $true }
        try {
            Assert-InputIdle 0
            Assert ($seen.Count -eq 255 -and $seen[0] -eq 1 -and $seen[254] -eq 255) 'The input guard did not inspect every virtual key and mouse button.'
            foreach ($key in @(1,32,255)) {
                $heldKey = $key; $script:inputFault = $false
                $rejected = $false
                try { Assert-InputIdle 0 } catch { $rejected = $true }
                Assert ($rejected -and $script:inputFault) "Held virtual key $key did not prevent further input/forced termination."
            }
        } finally { $script:inputFault = $false }
    }
    & {
        function Assert-Guest {}
        function Native-KeyDown { return $false }
        function Read-InputFault { return $null }
        $inputMutex = [Threading.Mutex]::new($false, ('Local\GunBoundAI.GuestSessionCheck.' + [Guid]::NewGuid().ToString('N')))
        try {
            $acquired = Enter-GuestInput 1
            Assert ($acquired -and $script:inputHeld) 'The isolated input arbiter was not acquired.'
            $nested = Enter-GuestInput 1
            Exit-GuestInput $nested
            Assert (!$nested -and $script:inputHeld) 'Nested cleanup released an outer input batch.'
            Exit-GuestInput $acquired
            Assert (!$script:inputHeld) 'The isolated input arbiter was not released.'
            $script:inputFault = $true
            $rejected = $false
            try { Enter-GuestInput 1 | Out-Null } catch { $rejected = $true }
            Assert ($rejected -and !$script:inputHeld) 'An unsafe input session reacquired permission to act.'
        } finally {
            Exit-GuestInput $true
            $script:inputFault = $false
            $inputMutex.Dispose()
        }
    }
    & {
        $present = $false; $malformed = $false
        function Assert-DataPath {}
        function Get-Item {
            if (!$present) { throw [IO.FileNotFoundException]::new('Synthetic absent marker.') }
            [pscustomobject]@{PSIsContainer=$false}
        }
        function Read-JsonFile {
            if ($malformed) { throw 'Synthetic malformed fault JSON.' }
            [pscustomobject]@{event='guest-input-abandoned';diagnostic='A peer consumed abandonment before this worker acquired the mutex.'}
        }
        try {
            Assert ($null -eq (Read-InputFault)) 'An absent fault marker blocked a clean coordinator.'
            $present = $true
            $message = Read-InputFault
            Assert ($script:inputFault -and $message -like '*peer consumed abandonment*') 'A peer-consumed abandonment was not latched.'
            $present = $false
            Assert ((Read-InputFault) -ceq $message) 'A later normal acquisition or removed file cleared an unacknowledged fault in this coordinator.'
            $script:inputFault = $false; $script:inputFaultMessage = $null
            $present = $true
            Assert ((Read-InputFault) -ceq $message -and $script:inputFault) 'Restarting a coordinator skipped a persistent, unacknowledged fault.'
            $script:inputFault = $false; $script:inputFaultMessage = $null
            $present = $true; $malformed = $true
            Assert ((Read-InputFault) -like '*malformed fault marker*' -and $script:inputFault) 'A malformed sticky marker authorized input.'
        } finally { $script:inputFault = $false; $script:inputFaultMessage = $null }
    }
    & {
        $queue = [Collections.Generic.Queue[object]]::new()
        $events = [Collections.Generic.List[string]]::new()
        $snapshots = [Collections.Generic.List[object]]::new()
        $state = [ordered]@{schemaVersion=2;sessionId=$null;phase='waiting-player';roomId=$null;roomCapacity=0;desiredCount=0;lastError=$null}
        $workers = [ordered]@{}
        function Assert-Guest {}
        function No-ForeignProcesses {}
        function Refresh-Workers {}
        function Read-InputFault { return $null }
        function Start-Sleep {}
        function Read-Lease {
            if ($queue.Count -eq 0) { throw [InvalidOperationException]::new('synthetic-sequence-complete') }
            return $queue.Dequeue()
        }
        function Save-CoordinatorStatus {
            $snapshots.Add([pscustomobject]@{phase=$state.phase;capacity=$state.roomCapacity;desired=$state.desiredCount;error=$state.lastError})
        }
        function Stop-Workers {
            if ($workers.Count) { $events.Add('stop:' + ($workers.Keys -join ',')) }
            foreach ($entry in @($workers.Values)) { $entry.alive = $false; $entry.stopRequested = $true }
            return $true
        }
        function Fill-Room($Target) {
            $names = @(Get-RoomBotNames $Target.roomCapacity)
            $events.Add('fill:' + ($names -join ','))
            $state.phase = 'starting-bots'
            foreach ($name in $names) {
                $handle = [pscustomobject]@{}
                $handle | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
                $workers[$name] = [pscustomobject]@{alive=$true;error=$null;stopRequested=$false;handle=$handle
                    status=[pscustomobject]@{phase='controller-running'}}
            }
        }
        $normalFill = (Get-Command Fill-Room).ScriptBlock
        $two = $targetLease | ConvertTo-Json | ConvertFrom-Json
        $two.roomCapacity = 2
        $two.issuedUtcTicks = [DateTime]::UtcNow.Ticks
        $two.expiresUtcTicks = [DateTime]::UtcNow.AddSeconds(120).Ticks
        $queue.Enqueue($two)
        $battle = $two | ConvertTo-Json | ConvertFrom-Json; $battle.roomReady = $false; $queue.Enqueue($battle)
        $four = $two | ConvertTo-Json | ConvertFrom-Json; $four.roomCapacity = 4; $queue.Enqueue($four)
        foreach ($capacity in @(6,8)) {
            $larger = $four | ConvertTo-Json | ConvertFrom-Json
            $larger.roomCapacity = $capacity; $larger.roomReady = $false; $queue.Enqueue($larger)
        }
        $lobby = $two | ConvertTo-Json | ConvertFrom-Json
        $lobby.roomId = $null; $lobby.roomCapacity = 0; $lobby.roomReady = $false; $queue.Enqueue($lobby)
        $queue.Enqueue($four)
        $offline = $lobby | ConvertTo-Json | ConvertFrom-Json; $offline.playerOnline = $false; $queue.Enqueue($offline)
        $queue.Enqueue($null)
        try { Run-Coordinator } catch { if ($_.Exception.Message -cne 'synthetic-sequence-complete') { throw } }
        Assert (($events -join '|') -ceq 'fill:BotOne|stop:BotOne|fill:BotOne,BotTwo,BotThree|stop:BotOne,BotTwo,BotThree|fill:BotOne,BotTwo,BotThree|stop:BotOne,BotTwo,BotThree') 'Coordinator selection/drain ordering changed, or battle alone stopped existing bots.'
        Assert (@($snapshots | Where-Object { $_.phase -eq 'unsupported-room-size' -and $_.capacity -in @(6,8) -and $_.desired -eq 0 }).Count -eq 2) 'Coordinator hid actual unsupported sizes or attempted a capped fill.'
        Assert (@($snapshots | Where-Object { $_.phase -eq 'controller-running' -and $_.capacity -eq 2 }).Count -eq 1) 'Coordinator did not retain the handed-off worker during battle.'
        $attempts = [Collections.Generic.List[int]]::new()
        function Fill-Room($Target) { $attempts.Add($Target.roomId); throw 'synthetic-startup-failure' }
        $queue.Enqueue($two); $queue.Enqueue($two); $queue.Enqueue($two)
        $newRoom = $two | ConvertTo-Json | ConvertFrom-Json; $newRoom.roomId++; $queue.Enqueue($newRoom)
        try { Run-Coordinator } catch { if ($_.Exception.Message -cne 'synthetic-sequence-complete') { throw } }
        Assert ($attempts.Count -eq 2 -and $attempts[0] -ne $attempts[1]) 'A degraded target restarted indefinitely or a new-room retry was lost.'
        Assert (@($snapshots | Where-Object { $_.phase -eq 'degraded' -and $_.error -eq 'synthetic-startup-failure' }).Count -ge 2) 'Startup failures were absent from aggregate diagnostics.'
        function Fill-Room($Target) { & $normalFill $Target }
        function Stop-Workers { return $workers.Count -eq 0 }
        $queue.Enqueue($four)
        $larger = $four | ConvertTo-Json | ConvertFrom-Json
        $larger.roomCapacity = 6; $larger.roomReady = $false; $queue.Enqueue($larger)
        try { Run-Coordinator } catch { if ($_.Exception.Message -cne 'synthetic-sequence-complete') { throw } }
        Assert ($state.phase -eq 'unsupported-room-size' -and $state.lastError -like '*capacity 6 is unsupported*' -and
            $state.desiredCount -eq 0) 'A failed old-worker drain hid an unsupported room size or permitted a replacement fill.'
        $workers.Clear()
        $blockedStarts = [Collections.Generic.List[int]]::new()
        function Fill-Room($Target) { $blockedStarts.Add($Target.roomId) }
        function Stop-Workers { return $true }
        function Read-InputFault {
            $script:inputFault = $true; $script:inputFaultMessage = 'synthetic-persistent-input-fault'
            return $script:inputFaultMessage
        }
        try {
            foreach ($run in @(1,2)) {
                $script:inputFault = $false; $script:inputFaultMessage = $null
                $queue.Enqueue($two); $queue.Enqueue($newRoom)
                try { Run-Coordinator } catch { if ($_.Exception.Message -cne 'synthetic-sequence-complete') { throw } }
                Assert ($state.phase -eq 'degraded' -and $blockedStarts.Count -eq 0) 'A room change or coordinator restart permitted launch despite the persistent input fault.'
            }
        } finally { $script:inputFault = $false; $script:inputFaultMessage = $null }
    }
    Write-Output 'PASS: legacy/lease/identity guards; fixed selection; mocked coordinator drains/retries; native target/self/Player/Ready and observations; peer ownership; scoped stops/input grants; all-VK/sticky-fault guards; and PowerShell 5.1 aggregate arrays. No files, processes, guest configuration, or input were touched.'
    return
}

$baseRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$baseScript = Join-Path $baseRoot 'vm\guest-session.ps1'
$root = if ($Instance) { Instance-Root $Instance } else { $baseRoot }
$botName = if ($Instance) { $Instance } else { 'BotOne' }
$gamePath = Join-Path $root 'client-image\GunBound.gme'
$executables = @{launcher="$root\lab-client.exe";controller="$root\bot-controller.exe";tool="$root\lab-tools.exe";probe="$root\bot-controller.exe"}
$workerShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$leasePath = 'C:\ProgramData\GunBoundAIControl\lease.json'
$sessionDir = Join-Path $root 'session'
$statusPath = Join-Path $sessionDir 'guest-status.json'
$baseStatusPath = Join-Path $baseRoot 'session\guest-status.json'
$inputFaultPath = Join-Path $baseRoot 'session\guest-input-fault.json'
$registrationPath = Join-Path $sessionDir 'worker-registration.json'
$workerStopPath = Join-Path $sessionDir 'worker-stop.json'
$stopPath = Join-Path $root 'bot.stop'
$interactiveChecked = $false
$markerOwner = $null
$roomFill = $false
$isCoordinator = $false
$registration = $null
$selfIdentity = $null
$workers = [ordered]@{}
$inputMutex = $null
$inputStateMethod = $null
$inputHeld = $false
$inputFault = $false
$inputFaultMessage = $null
$controllerRequested = $false
$sessionTarget = $null
$normalStop = $null
$state = [ordered]@{
    schemaVersion=1;sessionId=$null;updatedUtc='';phase='waiting-player';clientMode=$null
    client=$null;launcher=$null;controller=$null;tool=$null;probe=$null;toolAction='';lastError=$null;logDirectory=$null
    nativeReadyVerified=$false;gameplayVerified=$false
}
if ($Instance) {
    $state.schemaVersion = 2
    $state.name = $Instance
    $state.roomId = $null; $state.roomCapacity = 0
    $state.worker = $null; $state.coordinator = $null; $state.nativeReady = $false
    $state.selfSlot = $null; $state.nativeDiagnostic = $null
}

function Assert-DataPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($baseRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Guest data must remain below the fixed application root.' }
    $part = $full
    while ($part.Length -ge $baseRoot.Length) {
        try { $attributes = [IO.File]::GetAttributes($part) }
        catch [IO.FileNotFoundException] { $attributes = 0 }
        catch [IO.DirectoryNotFoundException] { $attributes = 0 }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Redirected guest path refused: $part" }
        $part = Split-Path -Parent $part
    }
}
function Read-JsonFile([string]$Path, [int]$Limit = 32768) {
    Assert-DataPath $Path
    try { $reader = Open-SharedReader $Path }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    try {
        if ($reader.BaseStream.Length -gt $Limit) { throw "Oversized guest JSON file: $Path" }
        $buffer = New-Object char[] ($Limit + 1)
        $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($count -gt $Limit) { throw 'Guest JSON grew past its size limit.' }
        $json = [string]::new($buffer, 0, $count)
        if ($count -eq 0 -or [string]::IsNullOrWhiteSpace($json)) { return $null }
        $json | ConvertFrom-Json
    } finally { $reader.Dispose() }
}
function Write-JsonFile([string]$Path, $Value) {
    Assert-DataPath $Path
    Assert-DataPath ($Path + '.new')
    $json = ConvertTo-Json -InputObject $Value -Depth 7 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768) { throw 'Guest status/registration exceeded its bounded JSON size.' }
    [IO.File]::WriteAllText(($Path + '.new'), $json, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace(($Path + '.new'), $Path, [NullString]::Value) }
    else { [IO.File]::Move(($Path + '.new'), $Path) }
}
function Assert-Guest {
    if (![String]::Equals($baseRoot, 'C:\GunBoundAI', [StringComparison]::OrdinalIgnoreCase) -or
        ![String]::Equals($PSCommandPath, $baseScript, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Guest orchestration may run only from C:\GunBoundAI\vm. Use -Check on the host.'
    }
    try { $marker = Read-JsonFile (Join-Path $baseRoot 'vm\guest.json') 4096 }
    catch { throw 'The required guest marker could not be read as JSON.' }
    if (!(Matches-GuestMarker $marker $baseRoot ([Environment]::MachineName))) {
        throw 'Guest marker/root/computer-name/lease limit mismatch; no process or input action is allowed.'
    }
    $enabled = Room-FillEnabled $marker
    if ($Instance -and !$enabled) { throw '-Instance requires the protected fixed-list roomFill marker.' }
    if ($script:markerOwner -and ($script:markerOwner -ne $marker.ownerId -or $enabled -ne $script:roomFill)) {
        throw 'The protected guest owner or orchestration mode changed during this session.'
    }
    $script:markerOwner = $marker.ownerId; $script:roomFill = $enabled
    Assert-DataPath (Join-Path $root 'session')
    if (!$script:interactiveChecked) {
        Assert-GuestIdentity -OwnerId $marker.ownerId
        $self = [Diagnostics.Process]::GetCurrentProcess()
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            if (![Environment]::UserInteractive -or $self.SessionId -eq 0 -or
                $identity.Name -ne ([Environment]::MachineName + '\LabBot') -or ($enabled -and $self.SessionId -ne 1) -or
                ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'Run unelevated in the logged-in local LabBot desktop (Session 1 for roomFill), never as administrator or in Session 0.'
            }
            $script:selfIdentity = Snapshot $self
            if ($enabled -and !(Matches-Identity $script:selfIdentity $script:selfIdentity $workerShell)) {
                throw 'The room-fill coordinator and workers require the fixed Windows PowerShell executable.'
            }
        } finally { $identity.Dispose(); $self.Dispose() }
        $script:interactiveChecked = $true
    }
}
function Save-Status {
    $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $state.inputFault = [bool]$script:inputFault
    if ($script:inputFaultMessage -and (!$state.lastError -or !$state.lastError.Contains($script:inputFaultMessage))) {
        $state.lastError = $script:inputFaultMessage + $(if ($state.lastError) { '; ' + $state.lastError })
    }
    if ($state.lastError -and $state.lastError.Length -gt 2048) { $state.lastError = $state.lastError.Substring(0,2048) }
    Write-JsonFile $statusPath $state
}
function Log([string]$Message) {
    $line = [DateTime]::UtcNow.ToString('o') + ' ' + $Message
    Write-Host $line
    if ($state.logDirectory) { [IO.File]::AppendAllText((Join-Path $state.logDirectory 'orchestration.log'), $line + [Environment]::NewLine) }
}
function Phase([string]$Name) { $state.phase = $Name; Save-Status; Log $Name }
function Issue([string]$Message) {
    $state.phase = 'failed'
    if (!$state.lastError) { $state.lastError = $Message }
    elseif (!$state.lastError.Contains($Message)) { $state.lastError += '; ' + $Message }
    Save-Status
    Log ('ERROR: ' + $Message)
}
function Read-Lease {
    try {
        $reader = Open-SharedReader $leasePath -WaitForPublication
        try {
            if ($reader.BaseStream.Length -gt 4096) { throw 'Oversized Player lease.' }
            $buffer = New-Object char[] 4097
            $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
            if ($count -gt 4096) { throw 'Player lease grew past its size limit.' }
            $data = [string]::new($buffer, 0, $count) | ConvertFrom-Json
        } finally { $reader.Dispose() }
    }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    catch { throw 'Lease JSON is unreadable, oversized, redirected, or malformed; no client action is allowed.' }
    Validate-Lease $data ([DateTime]::UtcNow)
}
function Stop-Session([string]$Reason) {
    $script:normalStop = $Reason
    throw [OperationCanceledException]::new($Reason)
}
function Read-CoordinatorStatus {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $current = Read-JsonFile $baseStatusPath
        if ($current) { return $current }
        if (!(Owned $registration.coordinator $workerShell)) { return $null }
        if ($watch.Elapsed.TotalMilliseconds -ge 1000) { return $null }
        Start-Sleep -Milliseconds 50
    } while ($true)
}
function Require-WorkerContext {
    if (!$Instance) { return }
    $current = Read-JsonFile $registrationPath 4096
    if (!(Matches-WorkerRegistration $current $registration.coordinator $selfIdentity $registration $Instance $workerShell)) {
        Stop-Session 'worker-registration-changed'
    }
    if (!(Owned $registration.coordinator $workerShell)) { Stop-Session 'coordinator-exit' }
    $coordinatorStatus = Read-CoordinatorStatus
    if (!$coordinatorStatus -or !(Integer (Property $coordinatorStatus 'schemaVersion')) -or $coordinatorStatus.schemaVersion -ne 2 -or
        !(Same-Target $coordinatorStatus $registration) -or
        !(Matches-Identity (Property $coordinatorStatus 'coordinator') $registration.coordinator $workerShell)) {
        Log ('Coordinator context mismatch: ' + ([ordered]@{
            observedVersion=(Property $coordinatorStatus 'schemaVersion')
            observedSession=(Property $coordinatorStatus 'sessionId')
            observedRoom=(Property $coordinatorStatus 'roomId')
            observedCapacity=(Property $coordinatorStatus 'roomCapacity')
            observedCoordinator=(Property $coordinatorStatus 'coordinator')
            expectedSession=$registration.sessionId;expectedRoom=$registration.roomId
            expectedCapacity=$registration.roomCapacity;expectedCoordinator=$registration.coordinator
        } | ConvertTo-Json -Depth 4 -Compress))
        Stop-Session 'coordinator-room-target-changed'
    }
    $request = Read-JsonFile $workerStopPath 4096
    if (Matches-StopRequest $request $registration ([DateTime]::UtcNow) $workerShell) { Stop-Session 'coordinator-stop' }
}
function Require-Lease([switch]$Joining) {
    Require-WorkerContext
    $fault = Read-InputFault
    if ($fault) { Stop-Session ('guest-input-fault: ' + $fault) }
    $lease = Read-Lease
    $presence = Lease-State $lease ([DateTime]::UtcNow)
    if ($presence -ne 'online') { Stop-Session ('lease-' + $presence) }
    if ($lease.sessionId -ne $state.sessionId) { Stop-Session 'lease-session-changed' }
    if ($sessionTarget -and !(Same-Target $sessionTarget $lease)) { Stop-Session 'lease-room-target-changed' }
    if (($Joining -or ($Instance -and !$script:controllerRequested)) -and !$lease.roomReady) {
        Stop-Session 'room-not-ready-during-startup'
    }
    return $lease
}
function Snapshot($Process) {
    [pscustomobject]@{pid=$Process.Id;path=$Process.MainModule.FileName;startedUtcTicks=$Process.StartTime.ToUniversalTime().Ticks}
}
function Observe([int]$ProcessId) {
    Assert-Guest
    try { $p = [Diagnostics.Process]::GetProcessById($ProcessId) }
    catch [ArgumentException] { return $null }
    try {
        if ($p.HasExited) { return $null }
        Snapshot $p
    }
    catch [InvalidOperationException] {
        if (!$p.HasExited) { throw }
        return $null
    }
    finally { $p.Dispose() }
}
function Owned($Record, [string]$Path) {
    if (!$Record) { return $false }
    Matches-Identity $Record (Observe $Record.pid) $Path
}
function Require-Client {
    $actual = if ($state.client) { Observe $state.client.pid } else { $null }
    if (!$actual) {
        if ($state.phase -eq 'controller-running') { Stop-Session 'client-exit' }
        throw 'The owned client is missing or exited during setup.'
    }
    if (!(Matches-Identity $state.client $actual $gamePath)) { throw 'Client identity changed; the unowned PID will not be touched.' }
}
function No-ForeignProcesses([switch]$ControllersOnly) {
    Assert-Guest
    $peers = @()
    if ($roomFill) {
        $coordinator = if ($isCoordinator) { $selfIdentity } else { $registration.coordinator }
        $target = if ($isCoordinator) { $state } else { $registration }
        foreach ($name in @('BotOne','BotTwo','BotThree')) {
            if ($name -ceq $Instance) { continue }
            $peerRoot = Instance-Root $name
            $peerRegistration = Read-JsonFile "$peerRoot\session\worker-registration.json" 4096
            if (!$peerRegistration) { continue }
            $worker = if ($isCoordinator -and $workers.Contains($name)) { $workers[$name].registration.worker }
                elseif (!$isCoordinator) { Property $peerRegistration 'worker' } else { $null }
            if (!(Matches-WorkerRegistration $peerRegistration $coordinator $worker $target $name $workerShell) -or
                !(Owned $worker $workerShell)) { continue }
            $peerStatus = Read-JsonFile "$peerRoot\session\guest-status.json"
            if (!(Matches-WorkerStatus $peerStatus $peerRegistration $workerShell)) { continue }
            $updated = Utc-Ticks (Property $peerStatus 'updatedUtc')
            if ($updated -lt [DateTime]::UtcNow.AddSeconds(-30).Ticks -or $updated -gt [DateTime]::UtcNow.AddSeconds(30).Ticks) { continue }
            $peers += [pscustomobject]@{registration=$peerRegistration;status=$peerStatus;worker=$worker}
        }
    }
    $filter = "Name='bot-controller.exe'"
    if (!$ControllersOnly) { $filter += " OR Name='GunBound.gme' OR Name='GunBound.exe' OR Name='lab-client.exe' OR Name='lab-tools.exe'" }
    foreach ($row in @(Get-CimInstance Win32_Process -Filter $filter)) {
        $actual = Observe $row.ProcessId
        if (!$actual) { continue }
        $allowed = $false
        foreach ($kind in @('client','launcher','controller','tool','probe')) {
            $path = if ($kind -eq 'client') { $gamePath } else { $executables[$kind] }
            if (Matches-Identity (Property $state $kind) $actual $path) { $allowed = $true; break }
        }
        if (!$allowed) {
            foreach ($peer in $peers) {
                if (Matches-PeerProcess $peer.registration $peer.status $actual $coordinator $peer.worker $target $workerShell) {
                    $allowed = $true; break
                }
            }
        }
        if (!$allowed) { throw "Preexisting/unowned lab process PID $($row.ProcessId) was refused and left untouched." }
    }
}
function Assert-BatchGrant {
    Require-WorkerContext
    $batch = Read-CoordinatorStatus
    if (!$batch -or !(Integer (Property $batch 'schemaVersion')) -or $batch.schemaVersion -ne 2 -or
        (Property $batch 'inputBatch') -isnot [bool] -or !$batch.inputBatch -or
        (Property $batch 'phase') -isnot [string] -or $batch.phase -cne 'starting-bots' -or
        (Property $batch 'inputInstance') -isnot [string] -or $batch.inputInstance -cne $Instance -or
        !(Same-Target $batch $registration) -or
        !(Matches-Identity (Property $batch 'coordinator') $registration.coordinator $workerShell) -or
        !(Matches-Identity (Property $batch 'inputWorker') $selfIdentity $workerShell)) {
        throw 'This worker has no identity-scoped coordinator input grant; no focus or helper input is allowed.'
    }
}
function Read-InputFault {
    if ($script:inputFault) {
        if ($script:inputFaultMessage) { return $script:inputFaultMessage }
        return 'Guest input is unsafe; verified manual recovery and a new coordinator are required.'
    }
    try {
        Assert-DataPath $inputFaultPath
        $file = Get-Item -LiteralPath $inputFaultPath -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] { return $null }
    catch [IO.FileNotFoundException] { return $null }
    catch {
        $script:inputFault = $true
        $script:inputFaultMessage = 'The sticky guest input fault path is inaccessible or redirected; no new input is permitted.'
        return $script:inputFaultMessage
    }
    $description = 'An unreadable or malformed fault marker is present.'
    try {
        if ($file.PSIsContainer) { throw 'The fault marker is a directory.' }
        $fault = Read-JsonFile $inputFaultPath 8192
        if ((Property $fault 'event') -is [string] -and (Property $fault 'diagnostic') -is [string]) {
            $description = $fault.event + ': ' + $fault.diagnostic
            if ($description.Length -gt 640) { $description = $description.Substring(0,640) }
        }
    } catch { }
    $script:inputFault = $true
    $script:inputFaultMessage = "Sticky guest input fault: $description Verified parent/manual recovery must archive $inputFaultPath and restart the coordinator."
    return $script:inputFaultMessage
}
function Publish-InputFault([string]$Event, [string]$Diagnostic) {
    $script:inputFault = $true
    if ($Diagnostic.Length -gt 1024) { $Diagnostic = $Diagnostic.Substring(0,1024) }
    $script:inputFaultMessage = "Sticky guest input fault ($Event): $Diagnostic Verified manual recovery and a new coordinator are required."
    $next = $null
    try {
        Assert-Guest
        Assert-DataPath $inputFaultPath
        if (![IO.File]::Exists($inputFaultPath) -and ![IO.Directory]::Exists($inputFaultPath)) {
            $record = [pscustomobject]@{schemaVersion=1;event=$Event;issuedUtc=[DateTime]::UtcNow.ToString('o')
                sourceRoot=$root;process=$selfIdentity;diagnostic=$Diagnostic}
            $json = ConvertTo-Json -InputObject $record -Depth 5 -Compress
            if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 8192) { throw 'Input fault metadata exceeded eight KiB.' }
            $next = $inputFaultPath + '.' + [Guid]::NewGuid().ToString('N') + '.new'
            Assert-DataPath $next
            [IO.File]::WriteAllText($next, $json, [Text.UTF8Encoding]::new($false))
            try { [IO.File]::Move($next, $inputFaultPath) }
            catch [IO.IOException] {
                if (![IO.File]::Exists($inputFaultPath) -and ![IO.Directory]::Exists($inputFaultPath)) { throw }
            }
        }
    } catch {
        $script:inputFaultMessage += ' Fault persistence failed; cooperative stop/manual recovery is mandatory.'
        Log $script:inputFaultMessage
    } finally {
        if ($next -and [IO.File]::Exists($next)) {
            try { [IO.File]::Delete($next) } catch { Log 'An owned unpublished fault staging file could not be removed.' }
        }
    }
}
function Initialize-InputReader {
    if ($script:inputStateMethod) { return }
    # Emit only a read-only Win32 import in memory; no compiler, temporary DLL, or key-release API.
    $name = [Reflection.AssemblyName]::new('GunBoundGuestInputState')
    if (@([AppDomain]::CurrentDomain.PSObject.Methods.Name) -contains 'DefineDynamicAssembly') {
        $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly($name, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    } else {
        $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    }
    $module = $assembly.DefineDynamicModule('InputState')
    $type = $module.DefineType('GunBoundGuestInputState', [Reflection.TypeAttributes]::Public)
    $method = $type.DefinePInvokeMethod('GetAsyncKeyState', 'user32.dll',
        ([Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::Static -bor [Reflection.MethodAttributes]::PinvokeImpl),
        [Reflection.CallingConventions]::Standard, [int16], [type[]]@([int]),
        [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Auto)
    $method.SetImplementationFlags($method.GetMethodImplementationFlags() -bor [Reflection.MethodImplAttributes]::PreserveSig)
    $script:inputStateMethod = $type.CreateType().GetMethod('GetAsyncKeyState')
}
function Native-KeyDown([int]$VirtualKey) {
    Initialize-InputReader
    ([int]$script:inputStateMethod.Invoke($null, [object[]]@($VirtualKey)) -band 0x8000) -ne 0
}
function Assert-InputIdle([int]$Milliseconds = 1000) {
    $fault = Read-InputFault
    if ($fault) { throw $fault }
    if ($script:inputFault) { throw 'Guest input is unsafe; manual recovery is required before a new coordinator session.' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $held = 0
        for ($key = 1; $key -le 255; $key++) {
            if (Native-KeyDown $key) { $held = $key; break }
        }
        if (!$held) { return }
        if ($timer.ElapsedMilliseconds -ge $Milliseconds) {
            $message = "Guest virtual key/button $held remains held; no focus, input, forced termination, or automatic input recovery is permitted."
            Publish-InputFault 'held-input' $message
            throw $message
        }
        Start-Sleep -Milliseconds 25
    } while ($true)
}
function Enter-GuestInput([int]$Seconds = 15) {
    $fault = Read-InputFault
    if ($fault) { throw $fault }
    if ($script:inputFault) { throw 'Guest input ownership was abandoned; this session cannot issue further input.' }
    if ($script:inputHeld) { Assert-InputIdle; return $false }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-Guest
        try { $acquired = $inputMutex.WaitOne(200) }
        catch [Threading.AbandonedMutexException] {
            $script:inputHeld = $true
            Publish-InputFault 'guest-input-abandoned' 'The guest input mutex was abandoned; held keys and cleanup cannot be assumed safe.'
            throw 'The guest input mutex was abandoned. Held keys cannot be assumed released; no new batch/input is allowed.'
        }
        if ($acquired) { $script:inputHeld = $true; Assert-InputIdle; return $true }
    } while ($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw 'Timed out waiting for exclusive guest input; no focus, close, or input was attempted.'
}
function Exit-GuestInput([bool]$Acquired) {
    if ($Acquired -and $script:inputHeld) { $inputMutex.ReleaseMutex(); $script:inputHeld = $false }
}
function Enter-SetupInput {
    if ($Instance) { Assert-BatchGrant; return $false }
    Enter-GuestInput
}
function Start-Tracked([string]$Name, [string[]]$Arguments, [switch]$Joining) {
    Assert-Guest
    Require-Lease -Joining:$Joining | Out-Null
    if ($Name -ne 'launcher') { Require-Client }
    $path = $executables[$Name]
    if (!$path) { throw 'Unsupported guest process request.' }
    Assert-DataPath $path
    if ($Instance -and $Name -in @('launcher','controller')) { Assert-BatchGrant }
    Assert-DataPath (Join-Path $state.logDirectory "$Name.out.log")
    Assert-DataPath (Join-Path $state.logDirectory "$Name.err.log")
    try {
        $p = Start-Process -FilePath $path -ArgumentList ($Arguments -join ' ') -WorkingDirectory $root -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $state.logDirectory "$Name.out.log") `
            -RedirectStandardError (Join-Path $state.logDirectory "$Name.err.log")
    } catch { throw "$Name creation failed before an identity was returned; unregistered children are left for the watchdog. $($_.Exception.Message)" }
    $state[$Name] = [pscustomobject]@{name=$Name;pid=$p.Id;path=$path;startedUtcTicks=$null}
    try {
        $null = $p.Handle
        $state[$Name].startedUtcTicks = $p.StartTime.ToUniversalTime().Ticks
        Save-Status
        $published = [Diagnostics.Stopwatch]::StartNew()
        while (!$p.HasExited) {
            try { $actual = Observe $p.Id }
            catch [ComponentModel.Win32Exception] { if (!$p.HasExited) { throw }; break }
            if ($p.HasExited) { break }
            if ((Startup-Identity $state[$Name] $actual $path) -eq 'ready') { break }
            if ($published.Elapsed.TotalSeconds -ge 5) { throw 'The newly created process did not publish its image path within five seconds.' }
            Require-Lease -Joining:$Joining | Out-Null
            Start-Sleep -Milliseconds 25
        }
        return $p
    } catch {
        Save-Status
        $p.Dispose()
        throw "$Name was created but ownership could not be established; partial identity retained, no guessed PID cleanup. $($_.Exception.Message)"
    }
}
function Tool([string]$Action, [string[]]$Arguments = @(), [switch]$Joining) {
    if ($Action -notin @('read','focus','click','double-click','key')) { throw 'Unsupported lab-tools action.' }
    if ($Action -ne 'read') {
        if ($script:controllerRequested) { throw 'GUI orchestration is forbidden after controller startup was requested.' }
        if ($Instance) { Assert-BatchGrant }
        elseif (!$script:inputHeld) { throw 'Legacy helper input requires the shared guest input mutex.' }
        No-ForeignProcesses
        Assert-InputIdle
    }
    Require-Client
    $state.toolAction = $Action
    $p = Start-Tracked 'tool' (@($Action,[string]$state.client.pid) + $Arguments) -Joining:$Joining
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        # Keep the created-process handle; reopening a finished helper PID can observe a reused PID.
        while (!$p.HasExited) {
            Require-Lease -Joining:$Joining | Out-Null
            Require-Client
            if ($timer.Elapsed.TotalSeconds -ge 10) {
                if ($Action -ne 'read') { Publish-InputFault 'input-cleanup-failed' "Owned lab-tools $Action exceeded ten seconds; completion/input release is unknown." }
                throw 'lab-tools exceeded 10 seconds; no further input will be issued, and no PID will be force-killed.'
            }
            Start-Sleep -Milliseconds 100
        }
        $p.WaitForExit()
        $output = '' + (Get-Content -LiteralPath (Join-Path $state.logDirectory 'tool.out.log') -Raw)
        $errors = '' + (Get-Content -LiteralPath (Join-Path $state.logDirectory 'tool.err.log') -Raw)
        $header = [DateTime]::UtcNow.ToString('o') + " $Action $($Arguments -join ' ')`r`n"
        [IO.File]::AppendAllText((Join-Path $state.logDirectory 'tools.out.log'), $header + $output)
        if ($errors) { [IO.File]::AppendAllText((Join-Path $state.logDirectory 'tools.err.log'), $header + $errors) }
        if ($p.ExitCode -ne 0) {
            if ($Action -ne 'read') { Publish-InputFault 'input-cleanup-failed' "Owned lab-tools $Action failed; synthetic input cleanup cannot be assumed." }
            throw "lab-tools $Action failed; inspect tool.err.log and tools.err.log."
        }
        Require-Lease -Joining:$Joining | Out-Null
        Require-Client
        return $output.Trim()
    } finally { $p.Dispose() }
}
function Mode {
    $mode = Decode-Mode (Tool 'read' @('0087053C','4'))
    if ($state.clientMode -ne $mode) { Log "Observed client mode $mode." }
    $state.clientMode = $mode
    Save-Status
    return $state.clientMode
}
function Byte([string]$Address) {
    $hex = Tool 'read' @($Address,'1')
    if ($hex -notmatch '^[0-9a-fA-F]{2}$') { throw 'Invalid one-byte response from lab-tools.' }
    [Convert]::ToByte($hex,16)
}
function Input([string]$Action, [string[]]$Arguments, [int]$ExpectedMode, [switch]$Joining) {
    $acquired = Enter-SetupInput
    try {
        if ((Mode) -ne $ExpectedMode) { throw "Unexpected mode before $Action; no GUI input was sent." }
        Tool 'focus' -Joining:$Joining | Out-Null
        if ((Mode) -ne $ExpectedMode) { throw "Mode changed while focusing; $Action was abandoned." }
        # The software-rendered guest runs near 20 FPS; hold across three frames.
        if ($Action -in @('click','double-click') -and $Arguments.Count -eq 2) { $Arguments += '150' }
        Tool $Action $Arguments -Joining:$Joining | Out-Null
    } finally { Exit-GuestInput $acquired }
}
function Wait-Mode([int[]]$Expected, [int[]]$Allowed, [int]$Seconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $mode = Mode
        if ($mode -in $Expected) { return $mode }
        if ($Allowed.Count -and $mode -notin $Allowed) { throw "Unexpected client mode $mode while waiting for $($Expected -join '/')." }
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw "Client did not reach mode $($Expected -join '/') within ${Seconds}s; last mode=$mode."
}
function Read-NativeRoom {
    $p = Start-Tracked 'probe' @('--room-state',[string]$state.client.pid)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (!$p.HasExited) {
            Require-Lease | Out-Null
            Require-Client
            if ($timer.Elapsed.TotalSeconds -ge 8) { throw 'Read-only native room probe exceeded eight seconds.' }
            Start-Sleep -Milliseconds 100
        }
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw 'Native room probe failed; inspect probe.err.log. No readiness was inferred.' }
        $native = Read-JsonFile (Join-Path $state.logDirectory 'probe.out.log') 16384
        Native-Observation $native | Out-Null
        Require-Lease | Out-Null
        Require-Client
        $state.clientMode = $native.Mode
        if ($Instance) {
            $state.nativeDiagnostic = '' + (Property $native 'Diagnostic')
            if ($state.nativeDiagnostic.Length -gt 512) { $state.nativeDiagnostic = $state.nativeDiagnostic.Substring(0,512) }
        }
        return $native
    } finally { $p.Dispose() }
}
function Update-NativeStatus($Summary) {
    $state.clientMode = $Summary.mode
    $state.nativeReadyVerified = $Summary.nativeReady
    if ($Instance) { $state.nativeReady = $Summary.nativeReady; $state.selfSlot = $Summary.selfSlot }
    Save-Status
}
function Select-RoomArmor {
    $lease = Require-Lease -Joining
    $summary = Native-RoomSummary (Read-NativeRoom) $lease $botName -Joining
    if ($summary.nativeReady) {
        Input 'click' @('756','568','250') 9 -Joining
        $watch = [Diagnostics.Stopwatch]::StartNew()
        do {
            $lease = Require-Lease -Joining
            $summary = Native-RoomSummary (Read-NativeRoom) $lease $botName -Joining
            if (!$summary.nativeReady) { break }
            if ($watch.Elapsed.TotalSeconds -ge 8) { throw 'Native Unready was not confirmed before team/mobile setup.' }
            Start-Sleep -Milliseconds 200
        } while ($true)
    }
    if ((Byte '00897368') -eq 0) { return }
    Log 'Selecting Armor in the verified room mobile popup; room mode remains 9.'
    Input 'click' @('320','180','250') 9 -Joining
    Start-Sleep -Milliseconds 500
    Input 'click' @('211','189','250') 9 -Joining
    Input 'click' @('565','423','250') 9 -Joining
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ((Byte '00897368') -ne 0) {
        Require-Lease -Joining | Out-Null
        if ($watch.Elapsed.TotalSeconds -ge 5) { throw 'Room mobile selection did not confirm Armor in native memory.' }
        Start-Sleep -Milliseconds 200
    }
}
function Read-ClientRecord($Context = $state, [string]$ContextRoot = $root, [string]$Name = $botName) {
    if ($Context.client -or !$Context.launcher) { return }
    $file = Join-Path $Context.logDirectory 'launcher.out.log'
    Assert-DataPath $file
    if (![IO.File]::Exists($file)) { return }
    if ((Get-Item -LiteralPath $file).Length -gt 65536) { throw 'Launcher registration output exceeded its bounded startup size.' }
    $clientPath = Join-Path $ContextRoot 'client-image\GunBound.gme'
    foreach ($line in @(Get-Content -LiteralPath $file)) {
        if (!$line.TrimStart().StartsWith('{')) { continue }
        try { $record = $line | ConvertFrom-Json }
        catch { Log 'Incomplete launcher JSON record; waiting within the startup deadline.'; continue }
        if ((Property $record 'Role') -isnot [string] -or $record.Role -cne 'bot' -or
            (Property $record 'Username') -isnot [string] -or $record.Username -cne $Name -or !(Integer $record.ProcessId) -or
            $record.ProcessId -le 0 -or $record.ProcessId -gt [int]::MaxValue) {
            throw "Launcher did not identify the expected $Name client; its record was refused."
        }
        $client = [pscustomobject]@{name='client';pid=$record.ProcessId;path=$clientPath;startedUtcTicks=(Utc-Ticks $record.StartedUtc)}
        if (!(Integer $Context.launcher.startedUtcTicks) -or $client.startedUtcTicks -lt $Context.launcher.startedUtcTicks -or
            !(Owned $client $clientPath)) { throw 'Launcher timestamp/path does not identify its newly created client.' }
        $row = Get-CimInstance Win32_Process -Filter "ProcessId=$($client.pid)"
        if (!$row -or $row.ParentProcessId -ne $Context.launcher.pid) { throw 'The reported client is not a child of this launcher.' }
        $Context.client = $client
        if ([object]::ReferenceEquals($Context, $state)) { Save-Status }
        Log "$Name PID, exact start ticks, executable path and launcher parent verified."
        return
    }
}
function Registered {
    $file = Join-Path $root 'bot-process.json'
    if (![IO.File]::Exists($file)) { return $false }
    try {
        $record = Read-JsonFile $file 8192
        $entry = [pscustomobject]@{pid=$record.ProcessId;path=$record.Executable;startedUtcTicks=$record.StartedUtcTicks}
        return (Matches-Identity $state.controller $entry $executables.controller) -and
            (Integer $record.BotProcessId) -and $record.BotProcessId -eq $state.client.pid -and
            (Property $record 'Mode') -is [string] -and $record.Mode -ceq 'standalone' -and
            @($record.PSObject.Properties.Name) -notcontains 'HumanProcessId' -and
            (!$Instance -or ((Property $record 'BotAccount') -is [string] -and $record.BotAccount -ceq $botName -and
                (Property $record 'Root') -is [string] -and
                [String]::Equals($record.Root, $root, [StringComparison]::OrdinalIgnoreCase)))
    } catch { Log 'Controller registration is incomplete or malformed; no readiness was inferred.'; return $false }
}
function Wait-Ended($Record, [string]$Path, [int]$Seconds) {
    if (!$Record) { return $true }
    if (!(Matches-Identity $Record $Record $Path)) { throw 'A process never published a complete owned identity; its PID cannot be treated as exited.' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (Owned $Record $Path) {
        if ($timer.Elapsed.TotalSeconds -ge $Seconds) { return $false }
        Save-Status
        Start-Sleep -Milliseconds 200
    }
    return $true
}
function Stop-Exact($Record, [string]$Path, [string]$Reason) {
    Assert-Guest
    if (!$script:inputHeld -or $script:inputFault) { throw 'Last-resort owned termination requires clean exclusive guest input ownership.' }
    Assert-InputIdle
    if (!(Matches-Identity $Record $Record $Path)) { throw 'Incomplete termination identity; no guessed PID was touched.' }
    if (!(Owned $Record $Path)) { return }
    try { $p = [Diagnostics.Process]::GetProcessById($Record.pid) }
    catch [ArgumentException] { return }
    try {
        $null = $p.Handle
        if (!(Matches-Identity $Record (Snapshot $p) $Path)) { throw 'Identity changed before termination; the unowned process was left untouched.' }
        Log "LAST RESORT: $Reason; terminating only owned PID $($Record.pid), start $($Record.startedUtcTicks), path $Path."
        $p.Kill()
        if (!$p.WaitForExit(5000)) { throw 'The identity-checked process did not terminate within five seconds.' }
    } finally { $p.Dispose() }
}
function Request-ControllerStop($Context, [string]$ContextRoot) {
    $path = Join-Path $ContextRoot 'bot-controller.exe'
    if (!(Owned $Context.controller $path)) { return }
    foreach ($row in @(Get-CimInstance Win32_Process -Filter "Name='bot-controller.exe'")) {
        $actual = Observe $row.ProcessId
        if ($actual -and $actual.path -eq $path -and
            !(Matches-Identity $Context.controller $actual $path) -and
            !(Matches-Identity (Property $Context 'probe') $actual $path)) {
            throw 'An unowned controller shares this instance stop file; no unscoped stop was written.'
        }
    }
    $path = Join-Path $ContextRoot 'bot.stop'
    Assert-DataPath $path
    [IO.File]::WriteAllText($path, 'guest-session ' + $Context.sessionId)
    Log "Requested the identity-checked controller in $ContextRoot to release input and stop via bot.stop."
}
function Cleanup($Context = $state, [string]$ContextRoot = $root, [string]$Name = $botName) {
    Assert-Guest
    $acquired = $false
    $paths = @{client="$ContextRoot\client-image\GunBound.gme";controller="$ContextRoot\bot-controller.exe"
        probe="$ContextRoot\bot-controller.exe";tool="$ContextRoot\lab-tools.exe";launcher="$ContextRoot\lab-client.exe"}
    try {
        Request-ControllerStop $Context $ContextRoot
        $controllerEnded = Wait-Ended $Context.controller $paths.controller 8
        $toolEnded = Wait-Ended $Context.tool $paths.tool 8
        if (!$toolEnded -and (Property $Context 'toolAction') -cne 'read') {
            throw 'An owned input helper is still running; no force kill, client close, or subsequent batch is safe.'
        }
        $probeEnded = Wait-Ended (Property $Context 'probe') $paths.probe 2
        if (!$Context.client -and $Context.launcher) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            do {
                Read-ClientRecord $Context $ContextRoot $Name
                if ($Context.client -or !(Owned $Context.launcher $paths.launcher)) { break }
                Start-Sleep -Milliseconds 200
            } while ($timer.Elapsed.TotalSeconds -lt 8)
            if (!$Context.client) { Log "$Name has no verified client record; no unregistered child PID will be guessed." }
        }
        $acquired = Enter-GuestInput
        if (!$controllerEnded) { Stop-Exact $Context.controller $paths.controller 'Controller ignored its scoped bot.stop for eight seconds' }
        if (!$toolEnded) { Stop-Exact $Context.tool $paths.tool 'Read-only helper did not finish during bounded cleanup' }
        if (!$probeEnded) { Stop-Exact $Context.probe $paths.probe 'Read-only native probe did not finish during bounded cleanup' }
        if (Owned $Context.client $paths.client) {
            $p = [Diagnostics.Process]::GetProcessById($Context.client.pid)
            try {
                $null = $p.Handle
                if (!(Matches-Identity $Context.client (Snapshot $p) $paths.client)) { throw 'Client identity changed before CloseMainWindow; no request was sent.' }
                $accepted = $p.CloseMainWindow()
                Log "$Name owned client CloseMainWindow accepted=$accepted (not proof of exit)."
            } finally { $p.Dispose() }
            if (!(Wait-Ended $Context.client $paths.client 8)) {
                Stop-Exact $Context.client $paths.client 'Owned bot remained at shutdown/exit dialog; no guessed dialog input or game-data writes'
            }
        }
        if (!(Wait-Ended $Context.launcher $paths.launcher 3)) {
            Stop-Exact $Context.launcher $paths.launcher 'Owned launcher remained after its client was closed'
        }
        $Context.nativeReadyVerified = $false
        if ($Instance -or (Property $Context 'schemaVersion') -eq 2) { $Context.nativeReady = $false }
        if ([object]::ReferenceEquals($Context, $state)) { Save-Status }
        return $true
    } catch {
        $message = "$Name owned cleanup could not finish: $($_.Exception.Message)"
        $Context.lastError = (('' + $Context.lastError + '; ' + $message).TrimStart('; '))
        if ($Context.lastError.Length -gt 2048) { $Context.lastError = $Context.lastError.Substring(0,2048) }
        if ([object]::ReferenceEquals($Context, $state)) { Save-Status }
        Log $message
        return $false
    } finally {
        Exit-GuestInput $acquired
    }
}

function Worker-LogDirectory($Registration) {
    Join-Path (Instance-Root $Registration.name) ('session\guest-' + $Registration.sessionId + '-room-' +
        $Registration.roomId + '-' + $Registration.roomCapacity + '-' + $Registration.worker.startedUtcTicks)
}
function Initialize-Worker {
    $state.worker = $selfIdentity
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $candidate = Read-JsonFile $registrationPath 4096
        $coordinator = Property $candidate 'coordinator'
        if (Matches-WorkerRegistration $candidate $coordinator $selfIdentity $candidate $Instance $workerShell) {
            if (!(Owned $coordinator $workerShell) -or $selfIdentity.startedUtcTicks -lt $coordinator.startedUtcTicks) {
                throw 'The worker coordinator is stale or was created after this worker.'
            }
            $row = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
            if (!$row -or $row.ParentProcessId -ne $coordinator.pid) { throw 'This worker was not created by its registered coordinator.' }
            $script:registration = $candidate
            $script:sessionTarget = $candidate
            $state.coordinator = $candidate.coordinator; $state.sessionId = $candidate.sessionId
            $state.roomId = $candidate.roomId; $state.roomCapacity = $candidate.roomCapacity
            $state.logDirectory = Worker-LogDirectory $candidate
            Assert-DataPath $state.logDirectory
            New-Item -ItemType Directory -Path $state.logDirectory -Force | Out-Null
            Require-Lease -Joining | Out-Null
            Assert-BatchGrant
            Save-Status
            return
        }
        Start-Sleep -Milliseconds 100
    } while ($timer.Elapsed.TotalSeconds -lt 5)
    throw 'No exact coordinator/session/room/worker registration arrived within five seconds; direct -Instance startup is refused.'
}
function Refresh-Workers {
    foreach ($entry in @($workers.Values)) {
        $record = $entry.registration
        $entry.alive = !$entry.handle.HasExited -and (Owned $record.worker $workerShell)
        try {
            $current = Read-JsonFile ((Instance-Root $entry.name) + '\session\worker-registration.json') 4096
            if (!(Matches-WorkerRegistration $current $selfIdentity $record.worker $record $entry.name $workerShell)) {
                throw 'Worker registration changed or is missing.'
            }
            $candidate = Read-JsonFile ((Instance-Root $entry.name) + '\session\guest-status.json')
            if (Matches-WorkerStatus $candidate $record $workerShell) {
                if ((Property $candidate 'logDirectory') -isnot [string] -or $candidate.logDirectory -cne (Worker-LogDirectory $record) -or
                    (Property $candidate 'nativeReady') -isnot [bool] -or
                    (Property $candidate 'nativeReadyVerified') -isnot [bool] -or
                    $candidate.nativeReady -ne $candidate.nativeReadyVerified -or
                    ($candidate.nativeReady -and (Property $candidate 'clientMode') -ne 9) -or
                    (Property $candidate 'phase') -isnot [string] -or
                    $candidate.phase -notin @('waiting-player','waiting-room','starting-client','lobby','joining','room','controller-running','stopping','stopped','failed')) {
                    throw 'Worker status has an invalid log path, readiness flag, or phase.'
                }
                foreach ($field in @('clientMode','selfSlot')) {
                    $value = Property $candidate $field
                    $maximum = if ($field -eq 'selfSlot') { 7 } else { 65535 }
                    if ($null -ne $value -and (!(Integer $value) -or $value -lt 0 -or $value -gt $maximum)) { throw "Worker $field is outside its native integer range." }
                }
                foreach ($field in @('lastError','nativeDiagnostic')) {
                    $value = Property $candidate $field
                    $maximum = if ($field -eq 'lastError') { 2048 } else { 512 }
                    if ($null -ne $value -and ($value -isnot [string] -or $value.Length -gt $maximum)) { throw "Worker $field is not bounded diagnostic text." }
                }
                $updated = Utc-Ticks $candidate.updatedUtc
                if ($updated -lt $record.worker.startedUtcTicks -or $updated -gt [DateTime]::UtcNow.AddSeconds(30).Ticks -or
                    ($entry.alive -and $updated -lt [DateTime]::UtcNow.AddSeconds(-30).Ticks)) { throw 'Worker status is stale or has an invalid exact timestamp.' }
                $peerRoot = Instance-Root $entry.name
                foreach ($kind in @('client','launcher','controller','tool','probe')) {
                    $process = Property $candidate $kind
                    $path = switch ($kind) {
                        'client' { "$peerRoot\client-image\GunBound.gme" }
                        'launcher' { "$peerRoot\lab-client.exe" }
                        'tool' { "$peerRoot\lab-tools.exe" }
                        default { "$peerRoot\bot-controller.exe" }
                    }
                    if ($process -and !(Matches-Identity $process $process $path)) { throw "Worker published an incomplete or foreign $kind identity." }
                    $processName = Property $process 'name'
                    if ($process -and (@($process.PSObject.Properties.Name | Where-Object { $_ -cnotin @('pid','path','startedUtcTicks','name') }).Count -or
                        ($null -ne $processName -and ($processName -isnot [string] -or $processName -cne $kind)))) { throw "Worker $kind identity contains unrecognized metadata." }
                }
                if ($candidate.phase -eq 'controller-running' -and
                    (!(Owned $candidate.client "$peerRoot\client-image\GunBound.gme") -or
                    !(Owned $candidate.controller "$peerRoot\bot-controller.exe"))) { throw 'Worker handoff lost its owned client/controller identity.' }
                $entry.status = $candidate
                if (!$entry.stopRequested -and $candidate.phase -in @('stopping','stopped','failed')) {
                    $entry.error = "$($entry.name) $($candidate.phase): $($candidate.lastError)"
                }
            } elseif (!$candidate -and (Recent-WorkerPublication $entry ([DateTime]::UtcNow))) {
                # Keep only a very recent verified snapshot across a brief atomic publication gap.
            } elseif ($entry.status) {
                throw 'An established worker status disappeared beyond its bounded publication window or changed identity.'
            } elseif ($entry.startup.Elapsed.TotalSeconds -gt 8) {
                throw 'No identity-matching worker status was first published within eight seconds.'
            }
        } catch { $entry.error = "$($entry.name): $($_.Exception.Message)" }
        if (!$entry.alive -and !$entry.stopRequested -and !$entry.error) { $entry.error = "$($entry.name) worker exited unexpectedly; no restart will be attempted for this target." }
    }
}
function Save-CoordinatorStatus {
    $instances = @(
        foreach ($name in @('BotOne','BotTwo','BotThree')) {
            $entry = if ($workers.Contains($name)) { $workers[$name] } else { $null }
            $status = if ($entry) { $entry.status } else { $null }
            $phase = if ($entry -and $entry.error) { 'failed' } elseif ($status) { $status.phase }
                elseif ($entry) { 'starting-client' } else { 'stopped' }
            $errorText = if ($entry -and $entry.error) { '' + $entry.error } else { Property $status 'lastError' }
            if ($errorText -and $errorText.Length -gt 2048) { $errorText = $errorText.Substring(0,2048) }
            [pscustomobject]@{
                name=$name;phase=$phase;roomId=$(if ($entry) { $entry.registration.roomId } else { $null })
                roomCapacity=$(if ($entry) { $entry.registration.roomCapacity } else { 0 })
                worker=$(if ($entry) { $entry.registration.worker } else { $null })
                client=(Property $status 'client');controller=(Property $status 'controller')
                launcher=(Property $status 'launcher');tool=(Property $status 'tool');probe=(Property $status 'probe')
                clientMode=(Property $status 'clientMode')
                selfSlot=(Property $status 'selfSlot');nativeDiagnostic=(Property $status 'nativeDiagnostic')
                nativeReady=($null -ne $entry -and $entry.alive -and !$entry.error -and $phase -eq 'controller-running' -and
                    (Property $status 'clientMode') -eq 9 -and (Property $status 'nativeReady') -eq $true)
                lastError=$errorText
            }
        }
    )
    $state.instances = @($instances)
    $state.inputFault = [bool]$script:inputFault
    $state.readyCount = @($instances | Where-Object { $_.nativeReady -and (Same-Target $state $workers[$_.name].registration) }).Count
    Save-Status
}
function Start-Worker([string]$Name, $Target) {
    if (!$script:inputHeld -or $script:inputFault) { throw 'A worker launch requires the coordinator to own the guest input batch.' }
    Assert-InputIdle
    if ($workers.Contains($Name)) { throw 'An instance was already attempted for this room; automatic restarts are forbidden.' }
    $instanceRoot = Instance-Root $Name
    foreach ($file in @('lab-client.exe','lab-tools.exe','bot-controller.exe','client-image\GunBound.gme',
        'profiles\difficulty.json','private\accounts.json','network.json')) {
        $path = Join-Path $instanceRoot $file
        Assert-DataPath $path
        if (![IO.File]::Exists($path)) { throw "Required $Name file is missing: $file" }
    }
    $directory = Join-Path $instanceRoot 'session'
    Assert-DataPath $directory
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $probeLock = [IO.File]::Open((Join-Path $directory 'guest-session.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $probeLock.Dispose()
    $output = Join-Path $directory ('worker-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $output | Out-Null
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"' + $baseScript + '"'),'-Instance',$Name)
    $p = Start-Process -FilePath $workerShell -ArgumentList ($arguments -join ' ') -WorkingDirectory $instanceRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $output 'worker.out.log') -RedirectStandardError (Join-Path $output 'worker.err.log')
    $record = [pscustomobject]@{schemaVersion=1;name=$Name;sessionId=$Target.sessionId;roomId=$Target.roomId;roomCapacity=$Target.roomCapacity
        script=$baseScript;coordinator=$selfIdentity;worker=[pscustomobject]@{pid=$p.Id;path=$workerShell;startedUtcTicks=$null}}
    $entry = [pscustomobject]@{name=$Name;registration=$record;handle=$p;status=$null;error=$null;alive=$true
        stopRequested=$false;startup=[Diagnostics.Stopwatch]::StartNew()}
    $workers[$Name] = $entry
    $null = $p.Handle
    $record.worker.startedUtcTicks = $p.StartTime.ToUniversalTime().Ticks
    $state.inputInstance = $Name; $state.inputWorker = $record.worker
    Save-CoordinatorStatus
    Write-JsonFile (Join-Path $directory 'worker-registration.json') $record
    $published = [Diagnostics.Stopwatch]::StartNew()
    while (!$p.HasExited) {
        if ((Startup-Identity $record.worker (Observe $p.Id) $workerShell) -eq 'ready') { break }
        if ($published.Elapsed.TotalSeconds -ge 5) { throw "$Name worker did not publish its requested Windows PowerShell image within five seconds." }
        Start-Sleep -Milliseconds 25
    }
    if ($p.HasExited) { throw "$Name worker exited during identity publication; inspect $output\worker.err.log." }
    Log "Started identity-tracked $Name worker PID $($p.Id) for room $($Target.roomId), capacity $($Target.roomCapacity)."
}
function Stop-Workers {
    $clean = $true
    $state.phase = 'stopping-bots'
    foreach ($entry in @($workers.Values)) {
        $entry.stopRequested = $true
        try {
            $record = $entry.registration
            if (!(Matches-WorkerRegistration $record $selfIdentity $record.worker $record $entry.name $workerShell)) {
                throw 'Incomplete worker identity; no guessed worker stop or termination is permitted.'
            }
            $request = [pscustomobject]@{schemaVersion=1;action='stop';name=$entry.name;sessionId=$record.sessionId
                roomId=$record.roomId;roomCapacity=$record.roomCapacity;coordinator=$selfIdentity;worker=$record.worker;issuedUtc=[DateTime]::UtcNow.ToString('o')}
            Write-JsonFile ((Instance-Root $entry.name) + '\session\worker-stop.json') $request
            if ($entry.status -and ($state.inputBatch -or !$entry.alive)) { Request-ControllerStop $entry.status (Instance-Root $entry.name) }
        } catch { $entry.error = "$($entry.name) stop request failed: $($_.Exception.Message)"; $clean = $false }
    }
    if ($script:inputHeld -and $state.inputBatch) {
        # Quiesce setup and stop every controller before releasing a failed batch around a finishing input helper.
        $quiesce = [Diagnostics.Stopwatch]::StartNew()
        do {
            Refresh-Workers
            $busy = @($workers.Values | Where-Object { $_.alive -and (!$_.status -or $_.status.phase -notin @('stopping','stopped','failed')) })
            if (!$busy.Count) { break }
            Save-CoordinatorStatus
            Start-Sleep -Milliseconds 100
        } while ($quiesce.Elapsed.TotalSeconds -lt 10)
        if ($busy.Count) { $clean = $false; $state.lastError = 'A worker did not quiesce setup within ten seconds of its scoped stop.' }
        foreach ($entry in @($workers.Values)) {
            if (!$entry.status) { continue }
            try {
                $controllerPath = (Instance-Root $entry.name) + '\bot-controller.exe'
                Request-ControllerStop $entry.status (Instance-Root $entry.name)
                if (!(Wait-Ended $entry.status.controller $controllerPath 8)) {
                    Stop-Exact $entry.status.controller $controllerPath 'Owned controller ignored bot.stop while the coordinator retained the input batch'
                }
            } catch { $entry.error = "$($entry.name) batch input drain failed: $($_.Exception.Message)"; $clean = $false }
        }
    }
    $state.inputBatch = $false; $state.inputWorker = $null; $state.inputInstance = $null
    Save-CoordinatorStatus
    Exit-GuestInput $true
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Refresh-Workers
        Save-CoordinatorStatus
        if (@($workers.Values | Where-Object { $_.alive }).Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ($timer.Elapsed.TotalSeconds -lt 75)
    foreach ($entry in @($workers.Values)) {
        $acquired = $false
        try {
            if ($entry.alive) {
                $acquired = Enter-GuestInput
                Stop-Exact $entry.registration.worker $workerShell 'Registered worker ignored its identity-scoped stop for 75 seconds'
                $entry.alive = $false
            }
            if ($entry.status -and !(Cleanup $entry.status (Instance-Root $entry.name) $entry.name)) { $clean = $false }
        } catch { $entry.error = "$($entry.name) cleanup failed: $($_.Exception.Message)"; $clean = $false }
        finally { Exit-GuestInput $acquired }
    }
    try { No-ForeignProcesses } catch { $state.lastError = $_.Exception.Message; $clean = $false }
    Save-CoordinatorStatus
    return $clean
}
function Fill-Room($Target) {
    $acquired = Enter-GuestInput
    $state.inputBatch = $true; $state.phase = 'starting-bots'
    Save-CoordinatorStatus
    try {
        foreach ($name in @(Get-RoomBotNames $Target.roomCapacity)) {
            $lease = Read-Lease
            if ((Lease-State $lease ([DateTime]::UtcNow)) -ne 'online' -or !(Same-Target $Target $lease)) {
                throw [OperationCanceledException]::new('The Player target changed during the launch/join batch.')
            }
            if (!$lease.roomReady) { return }
            No-ForeignProcesses
            Start-Worker $name $Target
            $entry = $workers[$name]
            do {
                $lease = Read-Lease
                if ((Lease-State $lease ([DateTime]::UtcNow)) -ne 'online' -or !(Same-Target $Target $lease)) {
                    throw [OperationCanceledException]::new('The Player target changed before worker handoff.')
                }
                Refresh-Workers
                Save-CoordinatorStatus
                $failed = @($workers.Values | Where-Object { $_.error -and !$_.stopRequested })
                if ($failed.Count) {
                    $current = Read-Lease
                    if ((Lease-State $current ([DateTime]::UtcNow)) -eq 'online' -and (Same-Target $Target $current) -and
                        !$current.roomReady -and
                        @($failed | Where-Object { !$_.status -or $_.status.lastError -notlike 'room-not-ready-during-startup*' }).Count -eq 0) { return }
                    throw (($failed | ForEach-Object { $_.error }) -join '; ')
                }
                if ($entry.status -and $entry.status.phase -eq 'controller-running') { break }
                if ($entry.startup.Elapsed.TotalSeconds -ge 240) { throw "$name did not complete bounded startup/handoff within 240 seconds." }
                Start-Sleep -Milliseconds 200
            } while ($true)
        }
    } catch {
        try { Stop-Workers | Out-Null } catch { Log ('Batch cleanup failed: ' + $_.Exception.Message) }
        throw
    } finally {
        $state.inputBatch = $false; $state.inputInstance = $null; $state.inputWorker = $null
        Save-CoordinatorStatus
        Exit-GuestInput $acquired
    }
}
function Run-Coordinator {
    $target = $null
    $attempted = $false
    $blocked = $false
    $waiting = [Diagnostics.Stopwatch]::StartNew()
    $initialFault = Read-InputFault
    if ($initialFault) { $blocked = $true; $state.lastError = $initialFault }
    else { No-ForeignProcesses }
    while ($true) {
        Assert-Guest
        $lease = Read-Lease
        $presence = Lease-State $lease ([DateTime]::UtcNow)
        $nextTarget = Lease-Target $lease ([DateTime]::UtcNow)
        $state.sessionId = if ($lease) { $lease.sessionId } else { $null }
        $state.roomId = if ($nextTarget) { $nextTarget.roomId } else { $null }
        $state.roomCapacity = if ($nextTarget) { $nextTarget.roomCapacity } else { 0 }
        $state.desiredCount = if ($nextTarget -and $nextTarget.roomCapacity -in @(2,4)) { @(Get-RoomBotNames $nextTarget.roomCapacity).Count } else { 0 }
        $changed = (($null -eq $target) -ne ($null -eq $nextTarget)) -or ($target -and !(Same-Target $target $nextTarget))
        if ($changed) {
            $state.phase = 'stopping-bots'
            if ($nextTarget -and $nextTarget.roomCapacity -in @(6,8)) {
                $state.lastError = "Actual room capacity $($nextTarget.roomCapacity) is unsupported; draining old bots without disconnecting Player."
            }
            Save-CoordinatorStatus
            if (!(Stop-Workers)) { $blocked = $true; $state.lastError = 'Owned workers could not be fully drained; no replacement bots will be launched. ' + $state.lastError }
            else {
                foreach ($entry in @($workers.Values)) { $entry.handle.Dispose() }
                $workers.Clear()
                $blocked = $false; $state.lastError = $null
            }
            $target = $nextTarget; $attempted = $false
        }
        if ($presence -eq 'online') { $waiting.Restart() }
        elseif ($waiting.Elapsed.TotalSeconds -ge 120) { Stop-Session ('No live Player lease within 120 seconds; last state=' + $presence) }
        $inputProblem = Read-InputFault
        if ($inputProblem) {
            if (@($workers.Values | Where-Object { !$_.stopRequested }).Count) { Stop-Workers | Out-Null }
            $blocked = $true; $state.lastError = $inputProblem
        }
        Refresh-Workers
        $failure = @($workers.Values | Where-Object { $_.error -and !$_.stopRequested })
        if ($failure.Count -and !$blocked) {
            $state.lastError = ($failure | ForEach-Object { $_.error }) -join '; '
            $blocked = $true
            $joinPaused = $lease -and !$lease.roomReady -and $nextTarget -and
                @($failure | Where-Object { !$_.status -or $_.status.lastError -notlike 'room-not-ready-during-startup*' }).Count -eq 0
            if (!$joinPaused) { Stop-Workers | Out-Null }
        }
        if ($blocked) {
            $state.phase = 'degraded'
            if ($nextTarget -and $nextTarget.roomCapacity -in @(6,8)) {
                $state.phase = 'unsupported-room-size'
                $message = "Actual room capacity $($nextTarget.roomCapacity) is unsupported; Player remains connected. Owned-worker cleanup is also degraded. "
                if (!$state.lastError -or !$state.lastError.StartsWith($message)) { $state.lastError = $message + $state.lastError }
            }
        }
        elseif (!$nextTarget -or $nextTarget.roomCapacity -notin @(2,4)) {
            $state.phase = Room-Phase $lease ([DateTime]::UtcNow)
            if ($state.phase -eq 'unsupported-room-size') {
                $state.lastError = "Actual room capacity $($nextTarget.roomCapacity) is unsupported. Player stays connected; choose a 2-player or 4-player room."
            } elseif ($lease -and $lease.schemaVersion -ne 2 -and $presence -eq 'online') {
                $state.lastError = 'roomFill requires a schemaVersion 2 Player lease with the native room ID and actual capacity.'
            }
        } elseif (!$attempted -and $lease.roomReady) {
            $attempted = $true; $state.lastError = $null
            try { Fill-Room $nextTarget }
            catch [OperationCanceledException] { Stop-Workers | Out-Null; continue }
            catch {
                $state.lastError = $_.Exception.Message; $blocked = $true
                Stop-Workers | Out-Null
                $state.phase = 'degraded'
            }
        } else {
            $running = @($workers.Values | Where-Object { $_.alive -and !$_.error -and $_.status -and $_.status.phase -eq 'controller-running' }).Count
            if ($running -eq $state.desiredCount) { $state.phase = 'controller-running' }
            elseif ($attempted) {
                $blocked = $true; $state.phase = 'degraded'
                $state.lastError = 'The room stopped accepting joins before the whole batch handed off; existing controllers are retained. Choose a new room/session to retry.'
            } else { $state.phase = 'waiting-room' }
        }
        Save-CoordinatorStatus
        Start-Sleep -Seconds 1
    }
}

if ($Check) { Invoke-Checks; return }

Assert-Guest
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
Assert-DataPath (Join-Path $sessionDir 'guest-session.lock')
$lock = [IO.File]::Open((Join-Path $sessionDir 'guest-session.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$inputMutex = [Threading.Mutex]::new($false, 'Local\GunBoundAILab.GuestInput')
$isCoordinator = $roomFill -and !$Instance
if ($isCoordinator) {
    $state = [ordered]@{
        schemaVersion=2;sessionId=$null;updatedUtc='';phase='waiting-player';roomId=$null;roomCapacity=0
        desiredCount=0;readyCount=0;instances=@();lastError=$null;coordinator=$selfIdentity
        inputBatch=$false;inputInstance=$null;inputWorker=$null
        logDirectory=(Join-Path $sessionDir ('coordinator-' + $selfIdentity.startedUtcTicks))
    }
}
$launcherHandle = $null
$controllerHandle = $null
$exitCode = 0
try {
    if ($isCoordinator) {
        New-Item -ItemType Directory -Path $state.logDirectory -Force | Out-Null
        Save-CoordinatorStatus
        Run-Coordinator
    } else {
    if ($Instance) { Initialize-Worker }
    Save-Status
    foreach ($file in @('lab-client.exe','lab-tools.exe','bot-controller.exe','client-image\GunBound.gme',
        'profiles\difficulty.json','private\accounts.json','network.json')) {
        Assert-DataPath (Join-Path $root $file)
        if (!(Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) { throw "Required guest file is missing: $file" }
    }
    No-ForeignProcesses
    if ($Instance) { $lease = Require-Lease -Joining }
    else {
    $waiting = [Diagnostics.Stopwatch]::StartNew()
    $lastPresence = ''
    do {
        $lease = Read-Lease
        $presence = Lease-State $lease ([DateTime]::UtcNow)
        if (Player-RoomReady $lease ([DateTime]::UtcNow)) {
            if ($lease.schemaVersion -eq 2 -and $lease.roomCapacity -ne 2) { throw 'Legacy single-root mode requires an actual two-player room; enable the protected roomFill marker for 2v2.' }
            break
        }
        if ($lease -and $lease.schemaVersion -eq 2 -and $presence -eq 'online') {
            $state.phase = Room-Phase $lease ([DateTime]::UtcNow)
            if ($state.phase -eq 'unsupported-room-size') { $state.lastError = "Actual capacity $($lease.roomCapacity) is unsupported; Player remains connected." }
        }
        if ($presence -in @('offline','online')) { $waiting.Restart() }
        if ($presence -ne $lastPresence) { Log ("waiting-player: lease-$presence; waiting for Player's room; no client launch or input."); $lastPresence = $presence }
        Save-Status
        if ($waiting.Elapsed.TotalSeconds -ge 120) { Stop-Session 'No valid online lease arrived within 120 seconds.' }
        Start-Sleep -Seconds 1
    } while ($true)
    $state.sessionId = $lease.sessionId
    $state.logDirectory = Join-Path $sessionDir ('guest-' + $lease.sessionId)
    }
    $script:sessionTarget = $lease
    Assert-DataPath $state.logDirectory
    New-Item -ItemType Directory -Path $state.logDirectory -Force | Out-Null
    Assert-DataPath (Join-Path $root 'logs')
    New-Item -ItemType Directory -Path (Join-Path $root 'logs') -Force | Out-Null
    No-ForeignProcesses
    Phase 'starting-client'
    $launcherHandle = Start-Tracked 'launcher' @('bot-client') -Joining
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Require-Lease | Out-Null
        Read-ClientRecord
        if ($state.client) { break }
        if (!(Owned $state.launcher $executables.launcher)) { throw 'Launcher exited before registering its client; inspect launcher.err.log.' }
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt 60)
    if (!$state.client) { throw 'Launcher did not register its client within 60 seconds.' }
    $mode = Wait-Mode @(2,3,4,13) @() 60
    Phase 'lobby'
    for ($attempt = 1; $attempt -le 4 -and $mode -eq 2; $attempt++) {
        Log "Requesting world selection ($attempt/4); native world entry is not yet verified."
        Input 'double-click' @('170','65') 2
        $selection = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 200
            $mode = Mode
            if ($mode -notin @(2,3,4,13)) { throw "Unexpected world-selection mode $mode; no retry was sent." }
        } while ($mode -eq 2 -and $selection.Elapsed.TotalSeconds -lt 5)
    }
    if ($mode -eq 2) { throw "$botName did not enter the world after four bounded selection requests." }
    if ($mode -eq 4) { Input 'click' @('42','560') 4; $mode = Wait-Mode @(3) @(3,4) 15 }
    if ($mode -eq 13) { Input 'click' @('37','563') 13; $mode = Wait-Mode @(3) @(3,13) 15 }
    if ($mode -ne 3) { throw "$botName did not reach the lobby; no room action was attempted." }
    if (!$Instance -and (Byte '00897368') -ne 0) {
        Log 'Requesting Armor selection.'
        Input 'click' @('593','13') 3
        Wait-Mode @(13) @(3,13) 10 | Out-Null
        Input 'click' @('74','123') 13
        $mode = Mode
        if ($mode -eq 13) { Input 'click' @('37','563') 13 }
        elseif ($mode -ne 3) { throw "Unexpected mode $mode after Armor selection." }
        Wait-Mode @(3) @(3,13) 10 | Out-Null
        if ((Byte '00897368') -ne 0) { throw 'Armor selection was not verified in client memory.' }
    }
    Log 'Waiting for the host lease to confirm room mode 9; instance mobile selection is verified after joining.'
    $timer.Restart()
    do {
        $lease = Require-Lease
        if ((Mode) -ne 3) { throw 'Client left the lobby while waiting for host room confirmation.' }
        if ($lease.roomReady) { break }
        if ($timer.Elapsed.TotalSeconds -ge 120) { Stop-Session 'Room confirmation did not return within 120 seconds.' }
        Start-Sleep -Milliseconds 500
    } while ($true)
    # ponytail: try only the first room row, then verify the leased native ID/capacity; add verified list enumeration for multiple private rooms.
    Phase 'joining'
    Start-Sleep -Seconds 1
    $joined = $false
    for ($attempt = 1; $attempt -le 4 -and !$joined; $attempt++) {
        Log "Requesting first-room join ($attempt/4); native room entry is not yet verified."
        Input 'click' @('84','64','150') 3 -Joining
        $timer.Restart()
        do {
            $mode = Mode
            if ($mode -eq 9) { $joined = $true; break }
            if ($mode -ne 3) { throw "Unexpected mode $mode after the room-row click; no retry was sent." }
            Start-Sleep -Milliseconds 250
        } while ($timer.Elapsed.TotalSeconds -lt 6)
    }
    if (!$joined) { throw "$botName did not enter the first room after four bounded requests." }
    if (!$Instance -and (Byte '00897368') -ne 0) { throw 'The joined client Armor contract was not verified.' }
    $timer.Restart()
    $summary = $null
    $verificationError = ''
    do {
        $lease = Require-Lease -Joining
        $native = Read-NativeRoom
        try { $summary = Native-RoomSummary $native $lease $botName -Joining; break }
        catch { $verificationError = $_.Exception.Message }
        Start-Sleep -Milliseconds 250
    } while ($timer.Elapsed.TotalSeconds -lt 10)
    if (!$summary) { throw "Native room/self/Player verification did not settle within ten seconds: $verificationError" }
    if ($Instance) {
        Select-RoomArmor
        $lease = Require-Lease -Joining
        $summary = Native-RoomSummary (Read-NativeRoom) $lease $botName -Joining
    }
    Update-NativeStatus $summary
    Phase 'room'
    Log "Verified $botName native self slot $($summary.selfSlot), Player master, room $($summary.roomId), capacity $($summary.roomCapacity). Ready and Start remain controller/manual actions."
    $acquired = Enter-SetupInput
    try {
        if ((Mode) -ne 9) { throw 'Client left the room before controller handoff.' }
        Tool 'focus' -Joining | Out-Null
        $lease = Require-Lease -Joining
        Update-NativeStatus (Native-RoomSummary (Read-NativeRoom) $lease $botName -Joining)
    } finally { Exit-GuestInput $acquired }
    No-ForeignProcesses
    if ($state.controller -and (Owned $state.controller $executables.controller)) { throw 'An owned controller is already active; bot.stop was not cleared.' }
    Assert-DataPath $stopPath
    if ([IO.File]::Exists($stopPath)) { Remove-Item -LiteralPath $stopPath }
    $script:controllerRequested = $true
    $controllerHandle = Start-Tracked 'controller' @('--standalone',[string]$state.client.pid) -Joining
    $timer.Restart()
    do {
        Require-Lease | Out-Null
        Require-Client
        if (!(Owned $state.controller $executables.controller)) { throw 'Controller exited before registration; it will not be restarted.' }
        if (Registered) { break }
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt 12)
    if (!(Registered)) { throw 'Controller did not register its exact standalone identity within 12 seconds.' }
    Phase 'controller-running'
    Log 'Controller is alive and registered, not proof of native Ready, attacks, or hits. GUI orchestration has ended.'
    $unavailable = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $lease = Require-Lease
        Require-Client
        if (!(Owned $state.controller $executables.controller) -or !(Registered)) { throw 'Controller exited, changed identity, or lost registration; no restart is allowed.' }
        if (!(Owned $state.launcher $executables.launcher)) { throw 'Launcher exited while its recorded client remains alive.' }
        $batch = if ($Instance) { Read-CoordinatorStatus } else { $null }
        if ($Instance -and (!$batch -or (Property $batch 'inputBatch') -isnot [bool] -or
            !(Matches-Identity (Property $batch 'coordinator') $registration.coordinator $workerShell))) { Stop-Session 'coordinator-status-unavailable' }
        if ($Instance -and (Property $batch 'inputBatch') -eq $true) {
            # No peer probe-creation/status-publication race while another worker performs guarded setup.
            $state.nativeReady = $false; $state.nativeReadyVerified = $false
            $unavailable.Restart()
        } else {
            $native = Read-NativeRoom
            if ($native.Available) {
                Update-NativeStatus (Native-RoomSummary $native (Require-Lease) $botName)
                $unavailable.Restart()
            } else {
                $state.nativeReadyVerified = $false
                if ($Instance) { $state.nativeReady = $false }
                if ($unavailable.Elapsed.TotalSeconds -ge 30) { throw 'Native room/battle identity remained unavailable for 30 seconds; no recovery input will be guessed.' }
            }
        }
        if (!(Owned $state.controller $executables.controller)) { throw 'Controller stopped during supervision; no restart is allowed.' }
        Save-Status
        Start-Sleep -Seconds 1
    }
    }
}
catch [OperationCanceledException] {
    if ($normalStop) {
        $state.lastError = $normalStop
        Save-Status
        Log ('Stopping: ' + $normalStop)
    } else {
        $exitCode = 1
        Issue ('Unexpected cancellation: ' + $_.Exception.Message)
    }
}
catch {
    $exitCode = 1
    Issue ($_.Exception.Message + [Environment]::NewLine + $_.ScriptStackTrace)
}
finally {
    try {
        if ($isCoordinator) {
            if (!(Stop-Workers)) { $exitCode = 1 }
        } else {
            Phase 'stopping'
            if (!(Cleanup)) { $exitCode = 1 }
        }
    } catch {
        $exitCode = 1
        Issue ('Owned cleanup could not finish: ' + $_.Exception.Message)
    }
    try { if ($exitCode) { Phase 'failed' } else { Phase 'stopped' } }
    finally {
        if ($launcherHandle) { $launcherHandle.Dispose() }
        if ($controllerHandle) { $controllerHandle.Dispose() }
        foreach ($entry in @($workers.Values)) { $entry.handle.Dispose() }
        Exit-GuestInput $true
        $inputMutex.Dispose()
        $lock.Dispose()
    }
}
exit $exitCode
