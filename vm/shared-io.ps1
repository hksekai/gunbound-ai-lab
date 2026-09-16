function Open-SharedReader {
    param([string]$Path, [switch]$WaitForPublication)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            if ($WaitForPublication) {
                $attributes = [IO.File]::GetAttributes($Path)
                if ($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) {
                    throw [IO.InvalidDataException]::new('A published control file cannot be a directory or redirected path.')
                }
            }
            return [IO.StreamReader]::new([IO.File]::Open($Path, 'Open', 'Read',
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)))
        } catch [IO.IOException] {
            $code = $_.Exception.GetBaseException().HResult -band 0xffff
            $retry = $code -in @(32,33) -or ($WaitForPublication -and $code -in @(2,3))
            if (!$retry -or $watch.ElapsedMilliseconds -ge 1000) { throw }
            Start-Sleep -Milliseconds 10
        } catch [UnauthorizedAccessException] {
            # Windows can report access denied while a published file is delete-pending.
            if (!$WaitForPublication -or $watch.ElapsedMilliseconds -ge 1000) { throw }
            Start-Sleep -Milliseconds 10
        }
    }
}

function Utc-Ticks($Value) {
    $date = [DateTime]::MinValue
    if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}(Z|\+00:00)$' -or
        ![DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$date)) {
        throw [ArgumentException]::new('Expected an exact UTC round-trip timestamp with seven fractional digits.')
    }
    $date.ToUniversalTime().Ticks
}

function Convert-PlayerLease($Data, [DateTime]$Now) {
    $names = if ($Data -is [Collections.IDictionary]) { @($Data.Keys) }
        elseif ($Data -is [pscustomobject]) { @($Data.PSObject.Properties.Name) }
        else { throw [ArgumentException]::new('Invalid Player lease object.') }
    if ($names -cnotcontains 'schemaVersion') { throw [ArgumentException]::new('A Player lease version is required.') }
    $fields = @('schemaVersion','sessionId','issuedUtc','expiresUtc','playerOnline','roomReady')
    if ($Data.schemaVersion -eq 2) { $fields += @('roomId','roomCapacity') }
    if (($Data.schemaVersion -isnot [int] -and $Data.schemaVersion -isnot [long]) -or
        $Data.schemaVersion -notin @(1,2) -or $names.Count -ne $fields.Count) {
        throw [ArgumentException]::new('Invalid Player lease version or shape.')
    }
    foreach ($field in $fields) {
        if ($names -cnotcontains $field) { throw [ArgumentException]::new('A required Player lease field is missing.') }
    }
    $id = [Guid]::Empty
    if ($Data.sessionId -isnot [string] -or $Data.sessionId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or
        ![Guid]::TryParseExact($Data.sessionId, 'D', [ref]$id) -or $id -eq [Guid]::Empty -or
        $Data.playerOnline -isnot [bool] -or $Data.roomReady -isnot [bool]) {
        throw [ArgumentException]::new('Invalid Player lease identity or presence flags.')
    }
    $issued = Utc-Ticks $Data.issuedUtc
    $expires = Utc-Ticks $Data.expiresUtc
    if ($expires -le $issued -or $expires - $issued -gt 120 * [TimeSpan]::TicksPerSecond -or
        $issued - $Now.ToUniversalTime().Ticks -gt 30 * [TimeSpan]::TicksPerSecond) {
        throw [ArgumentException]::new('Player leases must last at most 120 seconds and cannot be issued over 30 seconds ahead.')
    }
    $roomId = $null
    $capacity = 0
    if ($Data.schemaVersion -eq 2) {
        $roomId = $Data.roomId
        $capacity = $Data.roomCapacity
        if (($capacity -isnot [int] -and $capacity -isnot [long]) -or $capacity -notin @(0,2,4,6,8) -or
            ($null -ne $roomId -and (($roomId -isnot [int] -and $roomId -isnot [long]) -or $roomId -lt 0 -or $roomId -gt 65535)) -or
            (($null -eq $roomId) -ne ($capacity -eq 0)) -or
            (!$Data.playerOnline -and ($null -ne $roomId -or $Data.roomReady)) -or
            ($Data.roomReady -and ($null -eq $roomId -or $capacity -notin @(2,4)))) {
            throw [ArgumentException]::new('Invalid or unsupported room-ready lease target.')
        }
    }
    [pscustomobject]@{
        schemaVersion=[int]$Data.schemaVersion; sessionId=$id.ToString('D')
        issuedUtcTicks=$issued; expiresUtcTicks=$expires
        playerOnline=$Data.playerOnline; roomReady=$Data.roomReady
        roomId=$roomId; roomCapacity=[int]$capacity
    }
}

function Get-RoomBotNames([int]$Capacity) {
    switch ($Capacity) {
        0 { return }
        2 { return 'BotOne' }
        4 { return @('BotOne','BotTwo','BotThree') }
        default { throw [ArgumentException]::new("Room capacity $Capacity is unsupported; choose a 2-player or 4-player room.") }
    }
}

function Assert-GuestIdentity {
    param([string]$OwnerId, [switch]$HardwareOnly, [switch]$Server, [switch]$AllowUnlinkedServer)
    $id = [Guid]::Empty
    if (![Guid]::TryParseExact($OwnerId, 'D', [ref]$id) -or $id -eq [Guid]::Empty -or
        $env:COMPUTERNAME -cne 'GUNBOUND-BOT' -or
        (Get-CimInstance Win32_ComputerSystemProduct -OperationTimeoutSec 10).UUID -ine $OwnerId) {
        throw 'The guest SMBIOS UUID/computer identity differs from its protected VM owner.'
    }
    if ($HardwareOnly) { return }
    $paths = @('C:\GunBoundAI\vm', 'C:\GunBoundAI\vm\guest.json', 'C:\GunBoundAI\vm\package-manifest.json')
    if ($Server) { $paths += @('C:\GunBoundServer', 'C:\GunBoundServer\server-owner.json') }
    foreach ($path in $paths) {
        for ($part = $path; $part -and $part.Length -gt 3; $part = Split-Path -Parent $part) {
            if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'A guest ownership/package path is redirected.'
            }
        }
        $acl = Get-Acl -LiteralPath $path
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Guest ownership files must be owned by Administrators or SYSTEM.' }
        $writes = [Security.AccessControl.FileSystemRights]'Write,Delete,ChangePermissions,TakeOwnership,DeleteSubdirectoriesAndFiles'
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writes) -and
                $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')) {
                throw 'An unprivileged identity can change a protected guest/package marker.'
            }
        }
    }
    $marker = Get-Content -LiteralPath 'C:\GunBoundAI\vm\guest.json' -Raw | ConvertFrom-Json
    $package = Get-Content -LiteralPath 'C:\GunBoundAI\vm\package-manifest.json' -Raw | ConvertFrom-Json
    if ($marker.schemaVersion -ne 1 -or $marker.provider -cne 'virtualbox' -or $marker.root -cne 'C:\GunBoundAI' -or
        $marker.computerName -cne $env:COMPUTERNAME -or $marker.ownerId -ine $OwnerId -or
        $marker.leaseSeconds -ne 120 -or $package.ownerId -ine $OwnerId -or $package.schemaVersion -ne 1) {
        throw 'Protected guest and package owners differ.'
    }
    if ($Server) {
        $serverOwner = Get-Content -LiteralPath 'C:\GunBoundServer\server-owner.json' -Raw | ConvertFrom-Json
        $unlinked = $AllowUnlinkedServer -and $marker.PSObject.Properties.Name -notcontains 'serverRoot'
        if ((!$unlinked -and $marker.serverRoot -cne 'C:\GunBoundServer') -or $serverOwner.ownerId -ine $OwnerId -or
            $serverOwner.root -cne 'C:\GunBoundServer' -or !$serverOwner.originalHostDataPreserved) {
            throw 'The protected server snapshot belongs to another VM.'
        }
    }
}

function Assert-UnstartedGuestServer([string]$OwnerId) {
    if (Test-Path -LiteralPath 'C:\GunBoundServer') {
        Assert-GuestIdentity -OwnerId $OwnerId -Server -AllowUnlinkedServer
    }
    foreach ($process in Get-CimInstance Win32_Process -OperationTimeoutSec 10) {
        if ($process.Name -in @('mariadbd.exe','mysqld.exe','Gunboundserv3.exe','GunBoundBroker3.exe','BuddyCenter2.exe','BuddyServ2.exe') -or
            ($process.ExecutablePath -and $process.ExecutablePath.StartsWith('C:\GunBoundServer\',[StringComparison]::OrdinalIgnoreCase)) -or
            ($process.CommandLine -and $process.CommandLine.IndexOf('C:\GunBoundServer\backend\',[StringComparison]::OrdinalIgnoreCase) -ge 0)) {
            throw 'An unfinished server migration has a possible backend process; its stopped state cannot be inferred.'
        }
    }
}
