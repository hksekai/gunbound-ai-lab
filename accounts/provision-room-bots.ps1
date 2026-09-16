#requires -Version 7.0
<#
Legacy guest maintenance only: .\accounts\provision-room-bots.ps1 [-Apply]
Fresh onboarding already provisions all three bots and does not need this script.
Without -Apply, only read-only SQL/session locks are used; no credentials or files are created.
-Check uses synthetic accounts and the locally generated schema, never a database.

The owner must stop clients/controllers/native services, provide a fresh OFFLINE 120-second
lease, and supervise ONLY the owned database. This script neither starts nor stops services.
The lease file is pinned against replacement during the operation; do not renew it concurrently.
Schema 1 has exactly schemaVersion/sessionId/issuedUtc/expiresUtc/playerOnline/roomReady.
Schema 2 adds exactly roomId=null and roomCapacity=0. Both booleans must be false in either
version. -Apply needs more than 60 seconds remaining initially; obtain a new lease to retry.

Protected artifacts: accounts.original.json (exact original bytes), pending.json (new passwords),
before.json (hex rows for the five scoped tables, excluding the new identities), intent.json
(input/SQL digests), verified.json (initial fresh-registration proof), and codes-only SQL errors.
Interrupted .stage files also stay private for inspection; none are automatically restored.
Unexpected failures report platform exception types/HRESULTs and this script's line numbers.
Exception messages, source text, arguments, foreign script paths and raw stack traces are never
included in those diagnostics; use the matching script SHA256 to locate the reported lines.

MyISAM has no rollback. Keep private\account-updates\room-bots and the core stopped on failure.
A retry accepts only all-absent targets, or all-complete targets with this saved intent.
Partial/foreign rows require separately reviewed, row-scoped reconciliation using the saved
credentials and hex row backup. Never restore a database/server snapshot or delete the intent.
Publication is bot-only metadata first, accounts.json last; -Apply can finish an interrupted
publication after verifying every row again. Existing accounts are never updated or deleted.
#>
[CmdletBinding()]
param([switch]$Apply, [switch]$Check)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot)).TrimEnd('\')
$guestRoot = 'C:\GunBoundAI'
$ownerId = $null
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$accountNames = @('Player','BotOne','BotTwo','BotThree')
$newNames = @('BotTwo','BotThree')
$botNames = @('BotOne','BotTwo','BotThree')
$writeTables = @('user','gunwcuser','game','cash','chest')
$hardIds = @(98345,32807,163847,229381)
# These fingerprints include every column's type, nullability, default, collation and extras.
# They are derived from backend\schema-static.sql, not from the running database.
$layoutHashes = [ordered]@{
    cash='aa53e1556396b34a76fb779a61bc47371fe610fe2bb3d43c512afc33bfc435e2'
    chest='241b1e8b713304ec28a04bfe1628e25bc9bcb2d7988dbe648fa12067b243884c'
    game='2ee55540391ddbff5e41c6b8dcdb09006b8fd8d5e0bb31c4203037579bc7f247'
    gunwcuser='1e7139a616986b27f635a23e2e9a7bbc06e60b38fc004c741a9e453e386decbb'
    item='8a28f2cc49e0db8ebc8fc44c29db64697e4bb68d87e5b13252364a26add42468'
    menu='79a73e77521d459e19dcce0f9db251b23fa61e5ad9cd99821cea7239a2f0dd1a'
    menudat='bd26a6bdd795b9ec699f8a373baa16b9b1e017d56b5befa601af67635a822a59'
    user='82c2c5c6a6f823f9f46e6c8d5672cbc166a7a5e2aa5367ca7ee9664f12cd2404'
}
$tableNamesHash = '320b0eab6b4d87f2e73b9989f46459aa249c74fb32604d8986e0086ff0f22e07'

function Assert([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw [InvalidOperationException]::new("RoomBots: $Message") }
}
function Assert-ServerOwnership($Owner, $Marker, [string]$ServerRoot, [string]$MachineName) {
    foreach ($spec in @(
        @{record=$Owner; fields=@('schemaVersion','ownerId','root','databaseVersion','originalHostDataPreserved')},
        @{record=$Marker; fields=@('schemaVersion','root','serverRoot','ownerId','computerName','provider','leaseSeconds')}
    )) {
        Assert ($spec.record -is [pscustomobject]) 'Missing protected server/guest ownership metadata.'
        foreach ($field in $spec.fields) {
            Assert ($spec.record.PSObject.Properties.Name -ccontains $field) 'A protected ownership field is missing.'
        }
    }
    $guid = [Guid]::Empty
    Assert ((Integer $Owner.schemaVersion) -and $Owner.schemaVersion -eq 1 -and
        $Owner.ownerId -is [string] -and $Owner.ownerId -cmatch '\A[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z' -and
        [Guid]::TryParseExact($Owner.ownerId,'D',[ref]$guid) -and $guid -ne [Guid]::Empty -and
        $Owner.root -is [string] -and $Owner.root -ceq $ServerRoot -and
        $Owner.databaseVersion -ceq '11.4.13' -and $Owner.originalHostDataPreserved -is [bool] -and
        $Owner.originalHostDataPreserved) 'The protected server owner must identify this root and its preserved offline source.'
    foreach ($field in @('root','serverRoot','ownerId','computerName','provider')) {
        Assert ($Marker.$field -is [string]) 'Guest ownership fields must be strings.'
    }
    Assert ((Integer $Marker.schemaVersion) -and $Marker.schemaVersion -eq 1 -and
        $Marker.root -ceq $guestRoot -and $Marker.serverRoot -ceq $ServerRoot -and
        $Marker.ownerId -ceq $Owner.ownerId -and $MachineName -and $Marker.computerName -ieq $MachineName -and
        $Marker.provider -ceq 'virtualbox' -and (Integer $Marker.leaseSeconds) -and $Marker.leaseSeconds -eq 120) 'Guest marker/owner/computer mismatch.'
    $Owner.ownerId
}
function Safe-ExceptionDiagnostic([Management.Automation.ErrorRecord]$Record) {
    try {
        $types = [Collections.Generic.List[string]]::new()
        $exception = $Record.Exception
        for ($i=0; $exception -and $i -lt 4; $i++) {
            $name = $exception.GetType().FullName
            if ($name -cnotmatch '\A(?:System|Microsoft)\.[A-Za-z0-9_.+`]{1,200}\z') { $name = '[non-platform exception]' }
            $types.Add($name + '/0x' + $exception.HResult.ToString('X8'))
            $exception = $exception.InnerException
        }
        $origin = 'unavailable'
        $info = $Record.InvocationInfo
        if ($info -and [string]::Equals($info.ScriptName, $PSCommandPath, [StringComparison]::OrdinalIgnoreCase) -and
            $info.ScriptLineNumber -gt 0) {
            $origin = "accounts\provision-room-bots.ps1:$($info.ScriptLineNumber):$($info.OffsetInLine)"
        }
        $lines = [Collections.Generic.List[string]]::new()
        if ($PSCommandPath -and $Record.ScriptStackTrace) {
            # Extract only numeric locations in this known script, never emit the raw trace.
            $pattern = '(?m)^at [^\r\n]*, ' + [regex]::Escape($PSCommandPath) + ': line ([0-9]{1,7})\r?$'
            foreach ($frame in [regex]::Matches($Record.ScriptStackTrace, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                if ($lines.Count -eq 8) { break }
                $lines.Add($frame.Groups[1].Value)
            }
        }
        $frames = if ($lines.Count) { $lines -join '>' } else { 'unavailable' }
        "Exception types=$($types -join '>'); origin=$origin; own-script lines=$frames; details=[REDACTED]."
    } catch {
        'Exception diagnostic unavailable; details=[REDACTED].'
    }
}
function Hash-Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Hash-Text([string]$Text) { Hash-Bytes $utf8.GetBytes($Text) }
function Integer($Value) { $Value -is [int] -or $Value -is [long] }
function Assert-Fields($Record, [string[]]$Fields) {
    Assert ($Record -is [pscustomobject] -and @($Record.PSObject.Properties).Count -eq $Fields.Count -and
        @($Fields | Where-Object { $Record.PSObject.Properties.Name -cnotcontains $_ }).Count -eq 0) 'Unexpected metadata fields.'
}
function Convert-JsonElement([Text.Json.JsonElement]$Element) {
    switch ($Element.ValueKind) {
        Object {
            $properties = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                Assert (!$properties.Contains($property.Name)) 'Duplicate or case-conflicting JSON properties.'
                $properties.Add($property.Name, (Convert-JsonElement $property.Value))
            }
            return [pscustomobject]$properties
        }
        Array {
            $items = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $items.Add((Convert-JsonElement $item)) }
            return ,$items.ToArray()
        }
        String { return $Element.GetString() }
        Number {
            $integer = 0L
            if ($Element.TryGetInt64([ref]$integer)) { return $integer }
            return $Element.GetDouble()
        }
        True { return $true }
        False { return $false }
        Null { return $null }
        default { Assert $false 'Unsupported JSON value.' }
    }
}
function Parse-Record([string]$Text) {
    # JsonElement.GetString preserves timestamps on PS7 versions where ConvertFrom-Json auto-dates.
    $document = [Text.Json.JsonDocument]::Parse($Text.TrimStart([char]0xFEFF))
    try {
        Assert ($document.RootElement.ValueKind -eq [Text.Json.JsonValueKind]::Object) 'Metadata must be a JSON object.'
        Convert-JsonElement $document.RootElement
    } finally { $document.Dispose() }
}
function Assert-Accounts($Accounts, [string[]]$Names) {
    Assert (($Names -join ',') -cin @('Player,BotOne','Player,BotOne,BotTwo,BotThree','BotTwo,BotThree','BotOne,BotTwo,BotThree')) 'Unsupported account scope.'
    Assert ($Accounts -is [array] -and $Accounts.Count -eq $Names.Count) 'Incomplete or unexpected account set.'
    for ($i=0; $i -lt $Names.Count; $i++) {
        $a = $Accounts[$i]
        Assert-Fields $a @('role','username','password','id','nickname')
        $role = if ($Names[$i] -ceq 'Player') { 'human' } else { 'bot' }
        foreach ($field in @('role','username','password','id','nickname')) {
            Assert ($a.$field -is [string]) 'Account fields must be strings.'
        }
        Assert ($a.role -ceq $role -and $a.username -ceq $Names[$i] -and $a.id -ceq $Names[$i] -and
            $a.nickname -ceq $Names[$i] -and $a.password -cmatch '\A[A-Za-z0-9]{4,12}\z') 'Invalid identity, role or credential bounds.'
        if ($Names[$i] -cin $newNames) { Assert ($a.password.Length -eq 12) 'New bot passwords must have exactly 12 alphanumeric characters.' }
    }
}
function Parse-Accounts([string]$Text, [string[]]$Names) {
    Assert ($Text.Length -le 16384) 'Oversized account metadata.'
    $document = [Text.Json.JsonDocument]::Parse($Text.TrimStart([char]0xFEFF))
    try {
        Assert ($document.RootElement.ValueKind -eq [Text.Json.JsonValueKind]::Array) 'Account metadata must be an array.'
        $raw = @($document.RootElement.EnumerateArray() | ForEach-Object {
            Assert ($_.ValueKind -eq [Text.Json.JsonValueKind]::Object -and @($_.EnumerateObject()).Count -eq 5) 'Duplicate or unexpected account properties.'
            $_.GetRawText()
        })
        $records = @($Text.TrimStart([char]0xFEFF) | ConvertFrom-Json)
        if (!$Names) { $Names = if ($records.Count -eq 2) { $accountNames[0..1] } else { $accountNames } }
        Assert-Accounts $records $Names
        [pscustomobject]@{ records=$records; raw=$raw }
    } finally { $document.Dispose() }
}
function New-GamePassword {
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    -join (1..12 | ForEach-Object { $alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)] })
}
function New-Publication($Original, $Added) {
    Assert-Accounts $Original.records $accountNames[0..1]
    Assert-Accounts $Added $newNames
    $addedRaw = @($Added | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress })
    $allText = "[`r`n" + ((@($Original.raw) + $addedRaw) -join ",`r`n") + "`r`n]`r`n"
    $botText = "[`r`n" + ((@($Original.raw[1]) + $addedRaw) -join ",`r`n") + "`r`n]`r`n"
    $all = Parse-Accounts $allText $accountNames
    $bots = Parse-Accounts $botText $botNames
    Assert ($all.raw[0] -ceq $Original.raw[0] -and $all.raw[1] -ceq $Original.raw[1] -and
        $bots.records.username -cnotcontains 'Player') 'Publication changed original records or exposed the human account.'
    [pscustomobject]@{ allText=$allText; botText=$botText; accounts=$all.records }
}
function Assert-OfflineLease($Lease, [DateTime]$Now, [int]$RemainingSeconds) {
    Assert ($Lease -is [pscustomobject] -and $Lease.PSObject.Properties.Name -ccontains 'schemaVersion') 'A lease schema version is required.'
    $fields = @('schemaVersion','sessionId','issuedUtc','expiresUtc','playerOnline','roomReady')
    if ((Integer $Lease.schemaVersion) -and $Lease.schemaVersion -eq 2) { $fields += @('roomId','roomCapacity') }
    Assert-Fields $Lease $fields
    $guid = [Guid]::Empty
    Assert ((Integer $Lease.schemaVersion) -and $Lease.schemaVersion -in @(1,2) -and $Lease.sessionId -is [string] -and
        $Lease.sessionId -cmatch '\A[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z' -and
        [Guid]::TryParseExact($Lease.sessionId, 'D', [ref]$guid) -and $guid -ne [Guid]::Empty -and
        $Lease.playerOnline -is [bool] -and !$Lease.playerOnline -and $Lease.roomReady -is [bool] -and !$Lease.roomReady) 'A valid OFFLINE, not room-ready maintenance lease is required.'
    if ($Lease.schemaVersion -eq 2) {
        Assert ($null -eq $Lease.roomId -and (Integer $Lease.roomCapacity) -and $Lease.roomCapacity -eq 0) 'A schema 2 maintenance lease must have a null roomId and integer roomCapacity 0.'
    }
    $times = @()
    foreach ($field in @('issuedUtc','expiresUtc')) {
        $date = [DateTime]::MinValue
        Assert ($Lease.$field -is [string] -and $Lease.$field -cmatch '\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}(Z|\+00:00)\z' -and
            [DateTime]::TryParseExact($Lease.$field, 'o', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$date)) 'Lease timestamps must be exact UTC round-trip strings.'
        $times += $date.ToUniversalTime()
    }
    Assert ($times[0] -le $Now -and $times[1] -gt $Now.AddSeconds($RemainingSeconds) -and
        ($times[1] - $times[0]).TotalSeconds -gt 0 -and ($times[1] - $times[0]).TotalSeconds -le 120) 'Lease is future-issued, expired, excessive, or too close to expiry.'
    $times[1]
}
function Client-Arguments {
    @("--defaults-file=$root\private\backend\admin.ini", '--protocol=TCP', '--host=127.0.0.1', '--port=3307',
        '--database=gunbound', '--default-character-set=utf8mb4', '--batch', '--raw', '--skip-column-names',
        '--unbuffered', '--skip-reconnect', '--connect-timeout=5', '--local-infile=0')
}
function New-InsertSql($Accounts) {
    Assert-Accounts $Accounts $newNames
    foreach ($a in $Accounts) {
        $id = $a.username
        $password = $a.password
        $items = ($hardIds | ForEach-Object { "($_,1,'T',NULL,1,0,0,'$id','I')" }) -join ','
        # Registration defaults, not a copy of BotOne's live/session/progress fields.
        @"
INSERT INTO User (Id, user, Gender, NickName, Password, Status, MuteTime, RestrictTime, Authority, E_Mail, Country, User_Level, Authority2, RegDate, BirthDate, RegIp) VALUES ('$id','$id',0,'$id','$password','0',FROM_UNIXTIME(0),FROM_UNIXTIME(0),'1','$id@localhost.invalid','1',0,1,NOW(),'2000-01-01 00:00:00','127.0.0.1');
INSERT INTO GunWcUser (Id, user, Gender, NickName, Password, Status, MuteTime, RestrictTime, Authority, E_Mail, Country, User_Level, Authority2, AuthorityBackup) VALUES ('$id','$id',0,'$id','$password','0',FROM_UNIXTIME(0),FROM_UNIXTIME(0),'1','$id@localhost.invalid','999',1,1,'1');
INSERT INTO Game (Id, Nickname, Money, TotalScore, SeasonScore, TotalGrade, SeasonGrade, TotalRank, SeasonRank, SeasonRankHistory, NoRankUpdate, Country, CountryGrade, GiftProhibitTime) VALUES ('$id','$id',100000000,1000,1000,19,19,0,0,0,0,'999','19',FROM_UNIXTIME(0));
INSERT INTO Cash (ID, Cash) VALUES ('$id',100000000);
INSERT INTO Chest (Item,Wearing,Acquisition,Expire,Volume,PlaceOrder,Recovered,Owner,ExpireType) VALUES $items;
"@
    }
}
function Gear-Test([string]$Name) {
    Assert ($Name -cin $botNames) 'Unsupported equipment owner.'
    "(SELECT COUNT(*)=4 AND COUNT(DISTINCT Item)=4 AND COUNT(DISTINCT No)=4 AND MIN(COALESCE(BINARY Owner='$Name' AND No>0 AND Item IN ($($hardIds -join ',')) AND Wearing=1 AND BINARY Acquisition='T' AND Expire IS NULL AND Volume=1 AND PlaceOrder=0 AND Recovered=0 AND BINARY ExpireType='I',0))=1 FROM Chest WHERE Owner='$Name')"
}
function Account-Checks($Accounts, [switch]$Fresh) {
    foreach ($a in $Accounts) {
        Assert ($a.username -cin $accountNames -and $a.password -cmatch '\A[A-Za-z0-9]{4,12}\z') 'Unsafe SQL account input.'
        $id = $a.username
        $male = if ($id -ceq 'Player') { '' } else { ' AND Gender=0' }
        foreach ($table in @('User','GunWcUser')) {
            "SELECT COUNT(*)=1 FROM $table WHERE BINARY Id='$id' AND BINARY user='$id' AND BINARY NickName='$id' AND BINARY Password='$($a.password)' AND Authority>0 AND UNIX_TIMESTAMP(MuteTime) IS NOT NULL AND UNIX_TIMESTAMP(RestrictTime) IS NOT NULL$male;"
        }
        "SELECT COUNT(*)=1 FROM Game WHERE BINARY Id='$id' AND BINARY Nickname='$id' AND UNIX_TIMESTAMP(GiftProhibitTime) IS NOT NULL;"
        "SELECT COUNT(*)=1 FROM Cash WHERE BINARY ID='$id';"
        if ($id -cin $botNames) { "SELECT $(Gear-Test $id);" }
        if ($Fresh -and $id -cin $newNames) {
            @"
SELECT COUNT(*)=1 FROM User WHERE BINARY Id='$id' AND Gender=0 AND BINARY Status='0' AND UNIX_TIMESTAMP(MuteTime)=0 AND UNIX_TIMESTAMP(RestrictTime)=0 AND BINARY Authority='1' AND BINARY E_Mail='$id@localhost.invalid' AND BINARY Country='1' AND User_Level=0 AND Authority2=1 AND LastClick IS NULL AND UNIX_TIMESTAMP(RegDate)>0 AND BirthDate='2000-01-01 00:00:00' AND BINARY RegIp='127.0.0.1' AND PasswordResetToken IS NULL AND NickNameWarn=0 AND E_MailCampaign=0;
SELECT COUNT(*)=1 FROM GunWcUser WHERE BINARY Id='$id' AND Gender=0 AND BINARY Status='0' AND UNIX_TIMESTAMP(MuteTime)=0 AND UNIX_TIMESTAMP(RestrictTime)=0 AND BINARY Authority='1' AND BINARY E_Mail='$id@localhost.invalid' AND BINARY Country='999' AND User_Level=1 AND Authority2=1 AND BINARY AuthorityBackup='1';
SELECT COUNT(*)=1 FROM Game WHERE BINARY Id='$id' AND Money=100000000 AND BINARY Guild='' AND MemberCount=0 AND GuildRank=0 AND EventScore0=0 AND EventScore1=0 AND EventScore2=0 AND EventScore3=0 AND AvatarWear=0 AND BINARY Prop1='' AND BINARY Prop2='' AND AdminGift=0 AND TotalScore=1000 AND TotalScoreHistory=0 AND SeasonScore=1000 AND SeasonScoreHistory=0 AND TotalGrade=19 AND SeasonGrade=19 AND TotalRank=0 AND TotalRankHistory=0 AND SeasonRank=0 AND SeasonRankHistory=0 AND DailyRankUpdate IS NULL AND AccumShot=0 AND AccumDamage=0 AND BINARY StageRecords='' AND BINARY MobileRecords='' AND LastUpdateTime='0000-00-00 00:00:00' AND NoRankUpdate=0 AND ClientData IS NULL AND BINARY Country='999' AND BINARY CountryGrade='19' AND BINARY CountryRank='0' AND UNIX_TIMESTAMP(GiftProhibitTime)=0;
SELECT COUNT(*)=1 FROM Cash WHERE BINARY ID='$id' AND Cash=100000000;
"@
        }
    }
}
function Assert-ProtectedPath([string]$Path) {
    Assert ([IO.Path]::GetFullPath($Path).StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or $Path -eq $root) 'A private/server path escaped the protected root.'
    $item = Get-Item -LiteralPath $Path -Force
    while ($item -and $item.FullName.Length -ge $root.Length) {
        Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Reparse points are not allowed in server/private paths.'
        $acl = Get-Acl -LiteralPath $item.FullName
        Assert ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -in $script:allowedSids) 'A server/private path has an untrusted owner.'
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -eq 'Allow') {
                Assert ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in $script:allowedSids) 'Server/private access is not restricted to administrators and SYSTEM.'
            }
        }
        if ($item.FullName -eq $root) {
            Assert $acl.AreAccessRulesProtected 'The server root must not inherit a public DACL.'
            break
        }
        # CLR parents do not carry Get-Item's PSIsContainer provider property.
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}
function Protect-NewPath([string]$Path) {
    $rights = if ((Get-Item -LiteralPath $Path).PSIsContainer) { '(OI)(CI)F' } else { 'F' }
    & icacls.exe $Path '/inheritance:r' '/grant:r' "*S-1-5-18:$rights" "*S-1-5-32-544:$rights" '/Q' 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Cannot restrict a newly created private artifact.'
    Assert-ProtectedPath $Path
}
function Assert-ControlFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    Assert (!$item.PSIsContainer -and $item.Length -le 4096) 'Invalid guest marker/lease file.'
    $writes = [Security.AccessControl.FileSystemRights]'WriteData,AppendData,WriteExtendedAttributes,WriteAttributes,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    foreach ($entry in @($item,$item.Directory)) {
        Assert (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'A guest marker/lease path is redirected.'
        $acl = Get-Acl -LiteralPath $entry.FullName
        Assert ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -in $script:allowedSids) 'Guest marker/lease ownership is not privileged.'
        foreach ($rule in $acl.Access) {
            Assert ($rule.AccessControlType -ne 'Allow' -or ($rule.FileSystemRights -band $writes) -eq 0 -or
                $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in $script:allowedSids) 'An unprivileged identity can change the guest marker/lease.'
        }
    }
    Assert ((Get-Acl -LiteralPath $item.DirectoryName).AreAccessRulesProtected) 'Guest control directories must not inherit public write access.'
    $ancestor = $item.Directory.Parent
    while ($ancestor) {
        Assert (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'A guest marker/lease ancestor is redirected.'
        $ancestor = $ancestor.Parent
    }
}
function Read-PrivateBytes([string]$Path) {
    Assert-ProtectedPath $Path
    Assert ((Get-Item -LiteralPath $Path).Length -le 33554432) 'Oversized private artifact.'
    ,([IO.File]::ReadAllBytes($Path))
}
function Write-PrivateAtomic([string]$Path, [byte[]]$Bytes, [string]$ExpectedHash = '') {
    Assert-ProtectedPath (Split-Path -Parent $Path)
    $exists = [IO.File]::Exists($Path)
    if ($exists) {
        Assert ($ExpectedHash -and (Hash-Bytes (Read-PrivateBytes $Path)) -ceq $ExpectedHash) 'Metadata changed concurrently; replacement refused.'
    } else { Assert (!$ExpectedHash) 'Expected private metadata disappeared.' }
    $stage = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.stage'
    $file = [IO.File]::Open($stage, 'CreateNew', 'Write', 'None')
    try {
        Protect-NewPath $stage
        $file.Write($Bytes, 0, $Bytes.Length)
        $file.Flush($true)
    } finally { $file.Dispose() }
    Assert ((Hash-Bytes (Read-PrivateBytes $stage)) -ceq (Hash-Bytes $Bytes)) 'Staged private write was not durable/readable.'
    if ($exists) {
        Assert ((Hash-Bytes (Read-PrivateBytes $Path)) -ceq $ExpectedHash) 'Metadata changed during staging; replacement refused.'
        [IO.File]::Replace($stage, $Path, [NullString]::Value)
    } else { [IO.File]::Move($stage, $Path) }
    Assert ((Hash-Bytes (Read-PrivateBytes $Path)) -ceq (Hash-Bytes $Bytes)) 'Atomic private publication did not verify.'
}
function Ensure-Artifact([string]$Name, [string]$Text) {
    $path = Join-Path $script:artifacts $Name
    $bytes = $utf8.GetBytes($Text)
    if ([IO.File]::Exists($path)) {
        Assert ((Hash-Bytes (Read-PrivateBytes $path)) -ceq (Hash-Bytes $bytes)) 'Saved recovery artifacts conflict with this operation.'
    } else { Write-PrivateAtomic $path $bytes }
}
function Assert-StoppedRuntime {
    $entry = @($utf8.GetString((Read-PrivateBytes "$root\backend\database-processes.json")) | ConvertFrom-Json)
    Assert ($entry.Count -eq 1) 'Exactly one supervised database identity is required.'
    $db = $entry[0]
    Assert ($db.name -ceq 'mariadb' -and $db.path -eq "$root\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe" -and
        (Integer $db.pid) -and $db.pid -gt 0 -and (Integer $db.startedUtcTicks) -and $db.port -eq 3307) 'Invalid owned database process metadata.'
    $p = Get-Process -Id $db.pid -ErrorAction Stop
    Assert ($p.Path -eq $db.path -and $p.StartTime.ToUniversalTime().Ticks -eq $db.startedUtcTicks) 'The database PID/path/start-time identity is stale.'
    if ($script:ownedDatabase) {
        Assert ($db.pid -eq $script:ownedDatabase.pid -and $db.path -eq $script:ownedDatabase.path -and
            $db.startedUtcTicks -eq $script:ownedDatabase.startedUtcTicks) 'Database ownership changed during maintenance.'
    }
    $script:ownedDatabase = $db
    $processes = @(Get-CimInstance Win32_Process -OperationTimeoutSec 10)
    $databases = @($processes | Where-Object { $_.Name -match '^(mariadbd|mysqld)\.exe$' })
    Assert ($databases.Count -eq 1 -and $databases[0].ProcessId -eq $db.pid -and
        $databases[0].CommandLine -and $databases[0].CommandLine.Contains("$root\private\backend\my.ini")) 'Only the owned portable database may be running.'
    foreach ($row in $processes) {
        if ($row.ProcessId -eq $PID) { continue }
        Assert ($row.Name -notmatch '^(GunBound.*\.(exe|gme)|Buddy(Center|Serv).*\.exe|GbSet\.exe|bot-controller\.exe|lab-client\.exe)$') 'A game, native core, or controller process is running.'
        if ($row.ExecutablePath) {
            Assert (!$row.ExecutablePath.StartsWith("$root\backend\native\", [StringComparison]::OrdinalIgnoreCase) -and
                !$row.ExecutablePath.StartsWith("$guestRoot\client-image\", [StringComparison]::OrdinalIgnoreCase)) 'A native core/client image is running.'
        }
        if ($row.Name -match '^(pwsh|powershell)\.exe$') {
            Assert ([bool]$row.CommandLine) 'A possible PowerShell starter has unreadable command identity.'
            Assert ($row.CommandLine -notmatch '(guest-session\.ps1|mysql-compat\.ps1|guest-server\.ps1.+-Action\s+Start)') 'A client/core starter or compatibility supervisor is running.'
            if ($row.CommandLine -match 'backend\\start\.ps1') {
                Assert ($row.CommandLine -match '-Part\s+"?Database"?(\s|$)') 'A backend supervisor could start native services.'
            }
        }
    }
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    $owned = @($listeners | Where-Object LocalPort -eq 3307)
    Assert ($owned.Count -eq 1 -and $owned[0].LocalAddress -eq '127.0.0.1' -and $owned[0].OwningProcess -eq $db.pid) 'MariaDB must listen only on owned 127.0.0.1:3307.'
    $blockedPorts = @(3306,3308,8360,8361,8372,8339,8352)
    Assert (@($listeners | Where-Object LocalPort -in $blockedPorts).Count -eq 0 -and
        @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object LocalPort -in $blockedPorts).Count -eq 0) 'Core/compatibility network endpoints are still active.'
}
function Open-Sql {
    $info = [Diagnostics.ProcessStartInfo]::new("$root\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe")
    foreach ($arg in (Client-Arguments)) { $info.ArgumentList.Add($arg) }
    $info.UseShellExecute = $false
    $info.WorkingDirectory = $root
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardInputEncoding = $utf8
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    foreach ($name in @('MYSQL_PWD','MYSQL_DEBUG','MYSQL_HISTFILE')) { $null = $info.Environment.Remove($name) }
    $script:sqlProcess = [Diagnostics.Process]::Start($info)
    $script:sqlErrors = $script:sqlProcess.StandardError.ReadToEndAsync()
    # Native sessions use the server's time zone; forcing UTC can invalidate existing epoch dates.
    Sql "SET SESSION sql_mode='STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION'; SET SESSION lock_wait_timeout=5; SET SESSION max_statement_time=8; SET SESSION group_concat_max_len=16777216;" | Out-Null
    Require-Ones @(Sql "SELECT GET_LOCK('gunbound-room-bots-$ownerId',0);") 1 'Another room-bot operation is active.'
}
function Sql([string]$Statement) {
    $marker = 'GB_ROOM_BOTS_' + [Guid]::NewGuid().ToString('N')
    $script:sqlProcess.StandardInput.WriteLine($Statement + "`nSHOW COUNT(*) WARNINGS;`nSELECT '$marker';")
    $script:sqlProcess.StandardInput.Flush()
    $lines = [Collections.Generic.List[string]]::new()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $size = 0
    while ($true) {
        $task = $script:sqlProcess.StandardOutput.ReadLineAsync()
        $wait = [Math]::Max(1, 20000 - [int]$timer.ElapsedMilliseconds)
        Assert ($task.Wait($wait)) 'SQL timed out; writes, if attempted, may be partial.'
        $line = $task.GetAwaiter().GetResult()
        Assert ($null -ne $line) 'MariaDB rejected the guarded SQL; no success or rollback was inferred.'
        if ($line -ceq $marker) { break }
        $size += $line.Length
        Assert ($size -le 33554432) 'SQL result exceeded the bounded private backup size.'
        $lines.Add($line)
    }
    Assert ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ceq '0') 'SQL produced warnings; refusing truncated or coerced results.'
    $lines.RemoveAt($lines.Count - 1)
    $lines.ToArray()
}
function Close-Sql {
    if (!$script:sqlProcess) { return }
    try {
        if (!$script:sqlProcess.HasExited) {
            $script:sqlProcess.StandardInput.Close()
            if (!$script:sqlProcess.WaitForExit(5000)) {
                Stop-Process -Id $script:sqlProcess.Id -Force -ErrorAction Stop
                $script:sqlProcess.WaitForExit()
            }
        }
        $text = $script:sqlErrors.GetAwaiter().GetResult()
        # Even a truncated SQL error can contain a partial password; retain codes, never raw stderr.
        if ($Apply -and $text -and [IO.Directory]::Exists($script:artifacts)) {
            $codes = @([regex]::Matches($text, '(?m)^ERROR ([0-9]{3,5})(?: \(([A-Z0-9]{5})\))?') |
                ForEach-Object { $_.Value }) -join ', '
            $redacted = "Phase: $script:phase. MariaDB client exit: $($script:sqlProcess.ExitCode). Codes: $codes. Client diagnostics: [REDACTED]."
            Write-PrivateAtomic (Join-Path $script:artifacts ('sql-error-' + [Guid]::NewGuid().ToString('N') + '.log')) $utf8.GetBytes($redacted)
        }
    } finally { $script:sqlProcess.Dispose(); $script:sqlProcess = $null }
}
function Require-Ones([object[]]$Rows, [int]$Count, [string]$Message) {
    Assert ($Rows.Count -eq $Count -and @($Rows | Where-Object { $_ -cne '1' }).Count -eq 0) $Message
}
function Assert-Database {
    $identity = @(Sql "SELECT JSON_OBJECT('version',VERSION(),'database',DATABASE(),'port',@@port,'host',@@hostname,'datadir',@@datadir,'basedir',@@basedir,'bind',@@bind_address,'clock',UNIX_TIMESTAMP());")
    Assert ($identity.Count -eq 1) 'Missing database identity.'
    $db = $identity[0] | ConvertFrom-Json
    Assert ($db.version -cmatch '^11\.4\.13-MariaDB' -and $db.database -ceq 'gunbound' -and $db.port -eq 3307 -and
        $db.host -ieq [Environment]::MachineName -and $db.bind -ceq '127.0.0.1' -and
        $db.datadir.Replace('/','\').TrimEnd('\') -eq "$root\runtime\mariadb\data" -and
        $db.basedir.Replace('/','\').TrimEnd('\') -eq "$root\runtime\mariadb\mariadb-11.4.13-winx64" -and
        [Math]::Abs([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$db.clock) -le 5) 'Wrong database/version/datadir/binding or excessive guest/database clock skew.'
    Require-Ones @(Sql @"
SELECT @@general_log=0 AND @@slow_query_log=0 AND @@log_bin=0 AND @@performance_schema=0 AND @@event_scheduler IN ('OFF','DISABLED') AND @@lower_case_table_names=1;
SELECT COUNT(*)=0 FROM information_schema.PLUGINS WHERE PLUGIN_TYPE='AUDIT' AND PLUGIN_STATUS='ACTIVE';
SELECT COUNT(*)=0 FROM information_schema.PROCESSLIST WHERE ID<>CONNECTION_ID();
SELECT COUNT(*)=0 FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='gunbound';
SELECT COUNT(*)=1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='gunbound' AND DEFAULT_CHARACTER_SET_NAME='latin1' AND DEFAULT_COLLATION_NAME='latin1_swedish_ci';
SELECT @@session.time_zone=@@global.time_zone AND UNIX_TIMESTAMP(FROM_UNIXTIME(0))=0;
"@) 6 'Database logging/audit/events, sessions, triggers, schema or native date compatibility is unsafe.'
    $tables = @(Sql "SELECT LOWER(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA='gunbound' AND TABLE_TYPE='BASE TABLE' ORDER BY BINARY LOWER(TABLE_NAME);")
    Assert ($tables.Count -eq 57 -and (Hash-Text ($tables -join "`n")) -ceq $tableNamesHash) 'The reviewed 57-table schema has drifted.'
    Require-Ones @(Sql "SELECT COUNT(*)=57 FROM information_schema.TABLES WHERE TABLE_SCHEMA='gunbound';") 1 'Unexpected database views/tables.'
    $selected = ($layoutHashes.Keys | ForEach-Object { "'$_'" }) -join ','
    Require-Ones @(Sql @"
SELECT COUNT(*)=8 AND MIN(ENGINE='MyISAM' AND ((LOWER(TABLE_NAME)='menudat' AND REPLACE(TABLE_COLLATION,'utf8mb3_','utf8_')='utf8_general_ci') OR (LOWER(TABLE_NAME)<>'menudat' AND TABLE_COLLATION='latin1_swedish_ci')) AND LOWER(CREATE_OPTIONS)=CONCAT('row_format=',LOWER(ROW_FORMAT)) AND LOWER(ROW_FORMAT)=IF(LOWER(TABLE_NAME) IN ('cash','chest','item'),'fixed','dynamic'))=1 FROM information_schema.TABLES WHERE TABLE_SCHEMA='gunbound' AND LOWER(TABLE_NAME) IN ($selected);
"@) 1 'Account/Chest/catalog engines or collations differ from the native MyISAM layout.'
    $columns = @(Sql @"
SELECT CONCAT_WS('|',LOWER(TABLE_NAME),LOWER(COLUMN_NAME),LOWER(COLUMN_TYPE),IS_NULLABLE,
 CASE WHEN COLUMN_DEFAULT IS NULL OR UPPER(COLUMN_DEFAULT)='NULL' THEN '<null>' ELSE TRIM(BOTH CHAR(39) FROM COLUMN_DEFAULT) END,
 COALESCE(REPLACE(LOWER(COLLATION_NAME),'utf8mb3_','utf8_'),''),LOWER(EXTRA),COALESCE(GENERATION_EXPRESSION,''))
FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='gunbound' AND LOWER(TABLE_NAME) IN ($selected) ORDER BY BINARY LOWER(TABLE_NAME),ORDINAL_POSITION;
"@)
    $names = [ordered]@{}
    foreach ($table in $layoutHashes.Keys) {
        $rows = @($columns | Where-Object { $_.StartsWith($table + '|', [StringComparison]::Ordinal) })
        Assert ((Hash-Text ($rows -join "`n")) -ceq $layoutHashes[$table]) "Unreviewed $table columns/defaults; no layout was adopted from live data."
        $names[$table] = @($rows | ForEach-Object { $_.Split('|')[1] })
    }
    $indexes = @(Sql "SELECT CONCAT_WS('|',LOWER(TABLE_NAME),LOWER(INDEX_NAME),NON_UNIQUE,SEQ_IN_INDEX,LOWER(COLUMN_NAME),COALESCE(SUB_PART,''),INDEX_TYPE,IGNORED) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='gunbound' AND LOWER(TABLE_NAME) IN ($selected) ORDER BY BINARY LOWER(TABLE_NAME),BINARY LOWER(INDEX_NAME),SEQ_IN_INDEX;")
    $expectedIndexes = @('cash|primary|0|1|id||BTREE|NO','chest|primary|0|1|no||BTREE|NO',
        'game|guild|1|1|guild||BTREE|NO','game|primary|0|1|id||BTREE|NO','item|primary|0|1|no||BTREE|NO',
        'menu|primary|0|1|no||BTREE|NO','menudat|primary|0|1|id||BTREE|NO','user|primary|0|1|id||BTREE|NO')
    Assert (($indexes -join "`n") -ceq ($expectedIndexes -join "`n")) 'Unreviewed indexes or account uniqueness constraints.'
    Require-Ones @(Sql "SELECT COUNT(*)=7 AND MIN(CONSTRAINT_TYPE='PRIMARY KEY' AND CONSTRAINT_NAME='PRIMARY')=1 FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='gunbound' AND LOWER(TABLE_NAME) IN ($selected);") 1 'Unreviewed table constraints.'
    [pscustomobject]@{ tables=$tables; columns=$names }
}
function Lock-Database([switch]$Write) {
    $layout = Assert-Database
    $locks = @($layout.tables | ForEach-Object {
        $mode = if ($Write -and $_ -in $writeTables) { 'WRITE' } else { 'READ' }
        '`' + $_ + '` ' + $mode
    })
    Sql ('LOCK TABLES ' + ($locks -join ',') + ';') | Out-Null
    # All other tables are READ-locked too: registration cannot race unrelated activity/DDL.
    Assert-Database
}
function Assert-Catalog {
    Require-Ones @(Sql @"
SELECT COUNT(*)=4 AND COUNT(DISTINCT Item.No)=4 AND MIN(COALESCE(
 Menu.Item1=expected.id AND Menu.Item2 IS NULL AND Menu.Item3 IS NULL AND Menu.Item4 IS NULL AND Menu.Item5 IS NULL AND Menu.Volume1=1
 AND BINARY Menu.Menu_Name=BINARY expected.name AND BINARY MenuDat.Name=BINARY expected.name AND MenuDat.Visible=1 AND MenuDat.EnableEternal=1,0))=1
FROM (SELECT 98345 AS id,41 AS localId,'mh' AS kind,'Golden Helmet' AS name
 UNION ALL SELECT 32807,39,'mb','Golden Armour' UNION ALL SELECT 163847,7,'mg','Zoro Mask'
 UNION ALL SELECT 229381,5,'mf','Yellow Flag') AS expected
LEFT JOIN Item ON Item.No=expected.id LEFT JOIN Menu ON Menu.No=expected.id
LEFT JOIN MenuDat ON MenuDat.No=expected.localId AND BINARY MenuDat.Type=BINARY expected.kind;
"@) 1 'Golden Sentinel catalog identity, gender slots or eternal ownership fields differ.'
}
function Account-State($Original, $Added, [bool]$Receipt) {
    $counts = @(Sql 'SELECT COUNT(*) FROM User; SELECT COUNT(*) FROM GunWcUser; SELECT COUNT(*) FROM Game; SELECT COUNT(*) FROM Cash;')
    Assert ($counts.Count -eq 4 -and (($counts -join ',') -cin @('2,2,2,2','4,4,4,4'))) 'Partial or unexpected account table cardinalities; preserve recovery artifacts and reconcile manually.'
    $accounts = @($Original.records)
    $complete = $counts[0] -ceq '4'
    if ($complete) {
        Assert ($null -ne $Added) 'Preexisting BotTwo/BotThree rows have no saved pending credentials; no rows were adopted.'
        $accounts += $Added
    } else {
        Assert (!$Receipt) 'Previously verified bot identities disappeared; automatic recreation is forbidden.'
        Require-Ones @(Sql "SELECT COUNT(*)=0 FROM Chest WHERE Owner IN ('BotTwo','BotThree');") 1 'Unknown/partial target inventory exists.'
    }
    $checks = @(Account-Checks $accounts -Fresh:($complete -and !$Receipt))
    $resultCount = 4 * $accounts.Count + $accounts.Count - 1
    if ($complete -and !$Receipt) { $resultCount += 8 }
    Require-Ones @(Sql ($checks -join "`n")) $resultCount 'Account identity, credentials, native dates, fresh defaults or hard inventory did not verify.'
    if ($complete) { 'complete' } else { 'absent' }
}
function Protected-Snapshot($Layout) {
    $rows = [ordered]@{}
    foreach ($table in $writeTables) {
        $columns = @($Layout.columns[$table])
        $fields = ($columns | ForEach-Object { 'HEX(CAST(`' + $_ + '` AS BINARY))' }) -join ','
        $where = if ($table -ceq 'chest') { "Owner IS NULL OR Owner NOT IN ('BotTwo','BotThree')" } else { "Id NOT IN ('BotTwo','BotThree')" }
        $result = @(Sql ('SELECT COALESCE(JSON_ARRAYAGG(JSON_ARRAY(' + $fields + ') ORDER BY `' + $columns[0] + '`),JSON_ARRAY()) FROM `' + $table + '` WHERE ' + $where + ';'))
        Assert ($result.Count -eq 1) 'A protected row snapshot is incomplete.'
        $null = $result[0] | ConvertFrom-Json
        $rows[$table] = $result[0]
    }
    [pscustomobject]$rows
}
function Assert-NoOtherTargetData {
    $columns = @(Sql "SELECT CONCAT(LOWER(TABLE_NAME),'|',COLUMN_NAME) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='gunbound' AND LOWER(TABLE_NAME) NOT IN ('user','gunwcuser','game','cash','chest') AND DATA_TYPE IN ('char','varchar','tinytext','text','mediumtext','longtext') ORDER BY BINARY LOWER(TABLE_NAME),ORDINAL_POSITION;")
    foreach ($group in ($columns | Group-Object { $_.Split('|')[0] })) {
        Assert ($group.Name -cmatch '\A[a-z0-9_]+\z') 'Unsafe schema identifier.'
        $conditions = @($group.Group | ForEach-Object {
            $column = $_.Split('|')[1]
            Assert ($column -cmatch '\A[A-Za-z0-9_]+\z') 'Unsafe column identifier.'
            '`' + $column + '` IN (''BotTwo'',''BotThree'')'
        })
        Require-Ones @(Sql ('SELECT COUNT(*)=0 FROM `' + $group.Name + '` WHERE ' + ($conditions -join ' OR ') + ';')) 1 'Unknown BotTwo/BotThree references exist outside the registration tables.'
    }
}
function Parse-Proof([string]$Text, [string[]]$Fields) {
    $record = Parse-Record $Text
    Assert-Fields $record $Fields
    Assert ((Integer $record.schemaVersion) -and $record.schemaVersion -eq 1 -and
        $record.ownerId -is [string] -and $record.ownerId -ceq $ownerId -and
        $record.serverRoot -is [string] -and $record.serverRoot -ceq $root) 'Recovery artifact identity/version mismatch.'
    foreach ($field in $Fields) {
        if ($field.EndsWith('Sha256', [StringComparison]::Ordinal)) {
            Assert ($record.$field -is [string] -and $record.$field -cmatch '\A[0-9a-f]{64}\z') 'A recovery digest is malformed.'
        }
        if ($field -in @('createdUtc','verifiedUtc')) {
            $date = [DateTime]::MinValue
            Assert ($record.$field -is [string] -and $record.$field -cmatch '\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z\z' -and
                [DateTime]::TryParseExact($record.$field, 'o', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$date)) 'A recovery timestamp is malformed.'
        }
    }
    $record
}
function Read-Proof([string]$Name, [string[]]$Fields) {
    Parse-Proof $utf8.GetString((Read-PrivateBytes (Join-Path $script:artifacts $Name))) $Fields
}

Assert (!($Apply -and $Check)) '-Check and -Apply cannot be combined.'
if ($Check) {
    $ownerId = [Guid]::NewGuid().ToString('D')
    function Rejected([scriptblock]$Code) {
        $failed = $false
        try { & $Code | Out-Null } catch { $failed = $true }
        Assert $failed 'An unsafe synthetic input was accepted.'
    }
    $probeSecret = 'PRIVATE-DIAGNOSTIC-FIXTURE'
    function Diagnostic-Probe([string]$PrivateValue) {
        $inner = [IO.IOException]::new('SELECT Password FROM User; ' + $PrivateValue)
        $inner.Data['password'] = $PrivateValue
        throw [InvalidOperationException]::new('private argument=' + $PrivateValue, $inner)
    }
    $diagnostic = ''
    try { Diagnostic-Probe $probeSecret } catch { $diagnostic = Safe-ExceptionDiagnostic $_ }
    Assert ($diagnostic.Contains('System.InvalidOperationException/0x') -and $diagnostic.Contains('System.IO.IOException/0x') -and
        $diagnostic -match 'origin=accounts\\provision-room-bots\.ps1:[1-9][0-9]*:[0-9]+' -and
        $diagnostic -match 'own-script lines=[1-9][0-9]*' -and !$diagnostic.Contains($probeSecret) -and
        !$diagnostic.Contains('SELECT') -and !$diagnostic.Contains('private argument') -and
        !$diagnostic.Contains($PSCommandPath)) 'Safe diagnostics lost the error location or exposed exception/source/private data.'
    $probeError = [Management.Automation.ErrorRecord]::new([ArgumentException]::new($probeSecret), $probeSecret,
        [Management.Automation.ErrorCategory]::InvalidArgument, $probeSecret)
    $probeError.ErrorDetails = [Management.Automation.ErrorDetails]::new($probeSecret)
    $diagnostic = Safe-ExceptionDiagnostic $probeError
    Assert ($diagnostic.Contains('System.ArgumentException/0x') -and $diagnostic.Contains('origin=unavailable') -and
        !$diagnostic.Contains($probeSecret)) 'Error details, target data or identifiers escaped into diagnostics.'

    $savedRoot = $root
    $allowedSids = @('S-1-5-18','S-1-5-32-544')
    $mockAcl = [pscustomobject]@{
        Owner=[Security.Principal.SecurityIdentifier]::new('S-1-5-18');AreAccessRulesProtected=$true
        Access=@([pscustomobject]@{AccessControlType='Allow';IdentityReference=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')})
    }
    $mockAcl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param([type]$Target) $this.Owner }
    $aclPaths = [Collections.Generic.List[string]]::new()
    try {
        $root = Split-Path $PSScriptRoot
        function Get-Acl([string]$LiteralPath) { $aclPaths.Add($LiteralPath); $mockAcl }
        # Real source-file/CLR parent objects, but entirely in-memory ACLs; no ACL is read or written.
        Assert-ProtectedPath $PSCommandPath
        Assert (($aclPaths -join '|') -ceq (@($PSCommandPath,$PSScriptRoot,$root) -join '|')) 'File/directory/root ACL traversal skipped an ancestor.'
        $mockAcl.AreAccessRulesProtected = $false
        Rejected { Assert-ProtectedPath $PSCommandPath }
        $mockAcl.AreAccessRulesProtected = $true
        $mockAcl.Owner = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        Rejected { Assert-ProtectedPath $PSCommandPath }
        $mockAcl.Owner = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $mockAcl.Access[0].IdentityReference = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        Rejected { Assert-ProtectedPath $PSCommandPath }
        Rejected { Assert-ProtectedPath (Split-Path $root) }
    } finally {
        $root = $savedRoot
        Remove-Item -LiteralPath 'Function:\Get-Acl'
        Remove-Variable -Name allowedSids -Scope Script
    }
    $sample = @(for ($i=0; $i -lt 4; $i++) {
        [pscustomobject][ordered]@{ role=$(if ($i -eq 0) { 'human' } else { 'bot' }); username=$accountNames[$i]
            password=('ExamplePass' + $i); id=$accountNames[$i]; nickname=$accountNames[$i] }
    })
    Assert-Accounts $sample $accountNames
    Assert-Accounts $sample[0..1] $accountNames[0..1]
    Assert-Accounts $sample[2..3] $newNames
    $originalJson = (ConvertTo-Json -InputObject $sample[0..1]).Replace('"Player"', '"\u0050layer"').Replace('"BotOne"', '"Bot\u004Fne"')
    $original = Parse-Accounts $originalJson $accountNames[0..1]
    $publication = New-Publication $original $sample[2..3]
    Assert ($original.raw[0].Contains('\u0050layer') -and $original.raw[1].Contains('Bot\u004Fne') -and
        $publication.allText.Contains($original.raw[0]) -and $publication.allText.Contains($original.raw[1])) 'Original account JSON spans, escapes and whitespace were not preserved exactly.'
    $bots = Parse-Accounts $publication.botText $botNames
    Assert ($bots.records.Count -eq 3 -and !$publication.botText.Contains('Player') -and
        !$publication.botText.Contains($sample[0].password) -and !$publication.botText.Contains('admin') -and
        !$publication.botText.Contains('rootPassword')) 'Bot-only credential scoping failed.'
    Rejected { Assert-Accounts $sample[0..2] $accountNames }
    Rejected { Assert-Accounts @($sample[0],$sample[1],$sample[2],$sample[2]) $accountNames }
    foreach ($field in @('username','id','nickname','role','password')) {
        $bad = $sample | ConvertTo-Json | ConvertFrom-Json
        $bad[2].$field = "x'; DROP TABLE User;--"
        Rejected { Assert-Accounts $bad $accountNames }
    }
    $bad = $sample | ConvertTo-Json | ConvertFrom-Json
    $bad[2].password = "ElevenChars`n"
    Rejected { Assert-Accounts $bad $accountNames }
    $bad = $sample | ConvertTo-Json | ConvertFrom-Json
    $bad[2] | Add-Member -NotePropertyName rootPassword -NotePropertyValue 'not-a-real-secret'
    Rejected { Assert-Accounts $bad $accountNames }
    Rejected { New-InsertSql $sample[0..1] }
    $insert = @(New-InsertSql $sample[2..3]) -join "`n"
    Assert ([regex]::Matches($insert, '(?m)^INSERT INTO (User|GunWcUser|Game|Cash|Chest) ').Count -eq 10 -and
        $insert -notmatch '\b(UPDATE|DELETE|REPLACE|TRUNCATE|ROLLBACK|COMMIT|TRANSACTION)\b' -and
        !$insert.Contains("'Player'") -and !$insert.Contains("'BotOne'") -and
        [regex]::Matches($insert, 'FROM_UNIXTIME\(0\)').Count -eq 10 -and
        [regex]::Matches($insert, '100000000').Count -eq 4) 'Insert-only registration scope/defaults changed.'
    foreach ($name in $newNames) {
        foreach ($id in $hardIds) { Assert ($insert.Contains("($id,1,'T',NULL,1,0,0,'$name','I')")) 'Native Chest insert encoding changed.' }
    }
    Assert ((Gear-Test 'BotOne').Contains('MIN(COALESCE(') -and
        ${function:Assert-Catalog}.ToString().Contains('MIN(COALESCE(')) 'Nullable native catalog/inventory fields must fail closed per row.'
    foreach ($a in $sample) { Assert (!((Client-Arguments) -join ' ').Contains($a.password)) 'SQL credentials leaked into client arguments.' }
    $passwords = @(1..32 | ForEach-Object { New-GamePassword })
    Assert (@($passwords | Where-Object { $_ -cnotmatch '^[A-Za-z0-9]{12}$' }).Count -eq 0 -and
        @($passwords | Sort-Object -Unique).Count -eq 32) 'Secure password generator bounds/independence failed.'
    $stamp = '2026-09-15T04:00:00.1234567Z'
    $now = [DateTime]::ParseExact($stamp, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    foreach ($version in @(1,2)) {
        $lease = [pscustomobject][ordered]@{schemaVersion=$version;sessionId='11111111-2222-3333-4444-555555555555'
            issuedUtc=$stamp;expiresUtc=$now.AddSeconds(120).ToString('o');playerOnline=$false;roomReady=$false}
        if ($version -eq 2) {
            $lease | Add-Member -NotePropertyName roomId -NotePropertyValue $null
            $lease | Add-Member -NotePropertyName roomCapacity -NotePropertyValue 0
        }
        $leaseJson = ConvertTo-Json -InputObject $lease -Compress
        $stream = [IO.MemoryStream]::new($utf8.GetBytes($leaseJson))
        $reader = [IO.StreamReader]::new($stream, $utf8, $true, 4096, $true)
        try { $decoded = Parse-Record $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
        Assert ($decoded.issuedUtc -is [string] -and $decoded.issuedUtc -ceq $stamp -and
            $decoded.expiresUtc -is [string] -and $decoded.expiresUtc -ceq $lease.expiresUtc -and
            (Assert-OfflineLease $decoded $now 60).Ticks -eq $now.AddSeconds(120).Ticks -and
            (ConvertTo-Json -InputObject $decoded -Compress) -ceq $leaseJson) 'Valid serialized lease timestamps/types lost precision or were auto-converted.'
        Rejected { Assert-OfflineLease $decoded $now.AddSeconds(60) 60 }
        $offset = Parse-Record $leaseJson
        $offset.issuedUtc = $offset.issuedUtc.Replace('Z','+00:00')
        $offset.expiresUtc = $offset.expiresUtc.Replace('Z','+00:00')
        Assert ((Assert-OfflineLease (Parse-Record (ConvertTo-Json -InputObject $offset -Compress)) $now 60).Ticks -eq
            $now.AddSeconds(120).Ticks) 'An exact UTC-offset lease lost timestamp precision.'
        foreach ($case in @('online','ready','expired','future','excessive','coerced','version','timestamp-type','timestamp-format','timestamp-newline')) {
            $bad = Parse-Record $leaseJson
            switch ($case) {
                online { $bad.playerOnline=$true }
                ready { $bad.roomReady=$true }
                expired { $bad.expiresUtc=$now.ToString('o') }
                future { $bad.issuedUtc=$now.AddSeconds(1).ToString('o') }
                excessive { $bad.expiresUtc=$now.AddSeconds(121).ToString('o') }
                coerced { $bad.playerOnline='false' }
                version { $bad.schemaVersion=[string]$version }
                timestamp-type { $bad.issuedUtc=123 }
                timestamp-format { $bad.issuedUtc=$stamp.Replace('.1234567','.123456') }
                timestamp-newline { $bad.issuedUtc=$stamp + "`n" }
            }
            Rejected { Assert-OfflineLease (Parse-Record (ConvertTo-Json -InputObject $bad -Compress)) $now 0 }
        }
        Rejected { Parse-Record $leaseJson.Replace('"issuedUtc":', '"issuedUtc":null,"issuedUtc":') }
        Rejected { Parse-Record $leaseJson.Replace('"issuedUtc":', '"IssuedUtc":null,"issuedUtc":') }
        $bad = Parse-Record $leaseJson
        if ($version -eq 1) { $bad | Add-Member -NotePropertyName roomId -NotePropertyValue $null }
        else { $bad.PSObject.Properties.Remove('roomId') }
        Rejected { Assert-OfflineLease $bad $now 60 }
        if ($version -eq 2) {
            foreach ($value in @('',0,$false,@(),@($null))) {
                $bad = Parse-Record $leaseJson
                $bad.roomId = $value
                Rejected { Assert-OfflineLease (Parse-Record (ConvertTo-Json -InputObject $bad -Compress -Depth 8)) $now 60 }
            }
            foreach ($value in @($null,'0',0.0,-1,2,4)) {
                $bad = Parse-Record $leaseJson
                $bad.roomCapacity = $value
                Rejected { Assert-OfflineLease (Parse-Record (ConvertTo-Json -InputObject $bad -Compress)) $now 60 }
            }
        }
    }
    $proofCases = @(
        @{stampField='createdUtc';fields=@('schemaVersion','ownerId','serverRoot','createdUtc','originalAccountsSha256','accounts')
            record=[pscustomobject][ordered]@{schemaVersion=1;ownerId=$ownerId;serverRoot=$root;createdUtc=$stamp
                originalAccountsSha256=('a' * 64);accounts=$sample[2..3]}},
        @{stampField='verifiedUtc';fields=@('schemaVersion','ownerId','serverRoot','intentSha256','verifiedUtc','initialFreshAccounts')
            record=[pscustomobject][ordered]@{schemaVersion=1;ownerId=$ownerId;serverRoot=$root;intentSha256=('b' * 64)
                verifiedUtc=$stamp;initialFreshAccounts=$newNames}}
    )
    foreach ($case in $proofCases) {
        $proofJson = ConvertTo-Json -InputObject $case.record -Compress -Depth 8
        $decoded = Parse-Proof $utf8.GetString($utf8.GetBytes($proofJson)) $case.fields
        Assert ($decoded.($case.stampField) -is [string] -and $decoded.($case.stampField) -ceq $stamp -and
            (ConvertTo-Json -InputObject $decoded -Compress -Depth 8) -ceq $proofJson) 'Recovery timestamp JSON readback changed strings, types, nesting or exact fractional digits.'
        if ($case.stampField -ceq 'createdUtc') { Assert-Accounts $decoded.accounts $newNames }
        foreach ($value in @($null,123,@($stamp),$stamp.Replace('.1234567','.123456'),$stamp.Replace('Z','+01:00'),($stamp + "`n"))) {
            $bad = Parse-Record $proofJson
            $bad.($case.stampField) = $value
            Rejected { Parse-Proof (ConvertTo-Json -InputObject $bad -Compress -Depth 8) $case.fields }
        }
        $token = '"' + $case.stampField + '":'
        Rejected { Parse-Proof $proofJson.Replace($token, ($token + 'null,' + $token)) $case.fields }
    }
    Rejected { Parse-Record '{"nested":{"issuedUtc":"first","issued\u0055tc":"second"}}' }
    $types = Parse-Record '{"empty":[],"singleton":[null],"nested":[[]],"flag":false,"integer":0,"fraction":0.0}'
    Assert ($types.empty -is [array] -and $types.empty.Count -eq 0 -and $types.singleton -is [array] -and
        $types.singleton.Count -eq 1 -and $null -eq $types.singleton[0] -and $types.nested.Count -eq 1 -and
        $types.nested[0] -is [array] -and $types.nested[0].Count -eq 0 -and $types.flag -is [bool] -and !$types.flag -and
        (Integer $types.integer) -and !(Integer $types.fraction)) 'JSON array/null/boolean/integer types were coerced.'
    $ddl = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot) 'backend\schema-static.sql'))
    $tables = [regex]::Matches($ddl, '(?ms)^CREATE TABLE `([^`]+)`.*?;')
    $sorted = [string[]]@($tables | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    Assert ($tables.Count -eq 57 -and (Hash-Text ($sorted -join "`n")) -ceq $tableNamesHash) 'Reviewed table-name fingerprint changed.'
    foreach ($table in $layoutHashes.Keys) {
        $definition = @($tables | Where-Object { $_.Groups[1].Value -ieq $table })[0].Value
        $rows = @(foreach ($line in $definition -split '\r?\n') {
            if ($line -match '^\s*`(\w+)`\s+(\w+(?:\(\d+(?:,\d+)?\))?(?: UNSIGNED)?)(.*)') {
                $name = $Matches[1].ToLowerInvariant(); $type = $Matches[2].ToLowerInvariant(); $tail = $Matches[3]
                $default = if ($tail -match " DEFAULT ('[^']*'|[^,\s]+)") { $Matches[1].Trim("'") } else { '<null>' }
                if ($default -ceq 'NULL') { $default = '<null>' }
                $collation = if ($tail -match ' COLLATE (\w+)') { $Matches[1].ToLowerInvariant() } else { '' }
                $nullable = if ($tail.Contains('NOT NULL')) { 'NO' } else { 'YES' }
                $extra = if ($tail.Contains('AUTO_INCREMENT')) { 'auto_increment' } else { '' }
                @($table,$name,$type,$nullable,$default,$collation,$extra,'') -join '|'
            }
        })
        Assert ((Hash-Text ($rows -join "`n")) -ceq $layoutHashes[$table]) "Reviewed $table column fingerprint changed."
    }
    # Load only pure definitions, not health.ps1's network/process/SQL entry point.
    $tokens=$null; $errors=$null
    $health = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot) 'backend\health.ps1'), [ref]$tokens, [ref]$errors)
    Assert (!$errors.Count) 'Health script parsing failed.'
    foreach ($name in @('Assert-HealthAccounts','New-HealthSql','Assert-HealthCounts')) {
        $definition = $health.Find({param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -ceq $name}, $false)
        Assert ($null -ne $definition) 'A pure health validator is missing.'
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    foreach ($count in @(2,4)) {
        $accounts = @($sample[0..($count-1)])
        Assert-HealthAccounts $accounts
        $counts = @('57') + @([string]$count) * 4 + @('1200','1200') + @('1') * $count
        Assert-HealthCounts $counts $count
        Assert ([regex]::Matches((New-HealthSql $accounts), 'SELECT COUNT\(\*\)').Count -eq 7+$count) 'Health SQL cardinality changed.'
        $counts[1] = [string]($count+1)
        Rejected { Assert-HealthCounts $counts $count }
        $counts[1] = [string]$count; $counts[-1]='0'
        Rejected { Assert-HealthCounts $counts $count }
    }
    Rejected { Assert-HealthAccounts $sample[0..2] }
    Rejected { Assert-HealthAccounts @($sample[0],$sample[1],$sample[2],$sample[2]) }
    foreach ($field in @('username','id','nickname','role','password')) {
        $bad = $sample | ConvertTo-Json | ConvertFrom-Json
        $bad[2].$field = "invalid`n"
        Rejected { Assert-HealthAccounts $bad }
    }
    Rejected { Assert-HealthCounts @('57','2','2','2','2','1200','1200','1') 2 }
    $realSql = ${function:Sql}
    try {
        $mockCounts = @('2','2','2','2')
        function Sql([string]$Statement) {
            if ($Statement.StartsWith('SELECT COUNT(*) FROM User;')) { return $mockCounts }
            if ($Statement -like "SELECT COUNT(*)=0 FROM Chest*") { return '1' }
            @('1') * [regex]::Matches($Statement, '(?m)^SELECT ').Count
        }
        Assert ((Account-State $original $null $false) -ceq 'absent') 'Absent-target verification failed.'
        Rejected { Account-State $original $sample[2..3] $true }
        $mockCounts = @('4','4','4','4')
        Rejected { Account-State $original $null $false }
        Assert ((Account-State $original $sample[2..3] $false) -ceq 'complete' -and
            (Account-State $original $sample[2..3] $true) -ceq 'complete') 'Saved complete identities failed verification.'
        Assert ((@(Account-Checks $sample) -join "`n") -notmatch 'Money=100000000|Cash=100000000') 'Idempotent verification must not require/reset original balances.'
        $mockCounts = @('3','4','3','3')
        Rejected { Account-State $original $sample[2..3] $false }
    } finally { Set-Item -LiteralPath 'Function:\Sql' -Value $realSql }
    Write-Output 'PASS: safe exception diagnostics, strict CLR ancestor/ACL guards, bounded 2/4-account health checks, exact raw account publication, bot-only credential scoping, insert-only SQL/native gear, secure password bounds, v1/v2 OFFLINE leases, serialized lease/recovery timestamps, strict JSON types/duplicates and reviewed schema fingerprints. No runtime, private metadata, process, network or SQL action.'
    return
}

$artifacts = "$root\private\account-updates\room-bots"
$sqlProcess = $null
$sqlErrors = $null
$ownedDatabase = $null
$secrets = [Collections.Generic.List[string]]::new()
$handles = [Collections.Generic.List[IDisposable]]::new()
$phase = 'guest/root/lease guards'
$attempted = $false
try {
    Assert ([IO.Path]::GetFullPath((Split-Path $PSScriptRoot)).TrimEnd('\') -eq $root -and
        [IO.File]::Exists("$root\server-owner.json")) 'Run only on a marked, installed guest server root; fresh onboarding does not need this legacy maintenance script.'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        Assert ($identity.User.Value -eq 'S-1-5-18' -or
            ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Provisioning requires an elevated administrator or SYSTEM.'
        $administrator = @(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE '%-500'" -OperationTimeoutSec 10)
        Assert ($administrator.Count -eq 1 -and $administrator[0].Domain -ieq [Environment]::MachineName) 'The guest built-in administrator could not be identified.'
        $allowedSids = @('S-1-5-18','S-1-5-32-544',$identity.User.Value,$administrator[0].SID)
    } finally { $identity.Dispose() }
    foreach ($path in @($root,$PSCommandPath,"$root\private","$root\private\backend","$root\runtime\mariadb\data\gunbound",
        "$root\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe","$root\logs")) { Assert-ProtectedPath $path }
    foreach ($table in $layoutHashes.Keys) {
        foreach ($extension in @('frm','MYD','MYI')) { Assert-ProtectedPath "$root\runtime\mariadb\data\gunbound\$table.$extension" }
    }
    $owner = Parse-Record $utf8.GetString((Read-PrivateBytes "$root\server-owner.json"))
    $markerPath = "$guestRoot\vm\guest.json"
    $leasePath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'GunBoundAIControl\lease.json'
    foreach ($path in @($markerPath,$leasePath)) { Assert-ControlFile $path }
    $marker = Parse-Record ([IO.File]::ReadAllText($markerPath))
    $ownerId = Assert-ServerOwnership $owner $marker $root ([Environment]::MachineName)
    $leaseFile = [IO.File]::Open($leasePath, 'Open', 'Read', 'Read')
    $handles.Add($leaseFile)
    $reader = [IO.StreamReader]::new($leaseFile, $utf8, $true, 4096, $true)
    try { $lease = Parse-Record $reader.ReadToEnd() } finally { $reader.Dispose() }
    $expires = Assert-OfflineLease $lease ([DateTime]::UtcNow) $(if ($Apply) { 60 } else { 15 })
    Assert-StoppedRuntime
    if ($Apply) {
        foreach ($path in @("$root\private\account-updates",$artifacts,"$root\session")) {
            if (![IO.Directory]::Exists($path)) {
                Assert-ProtectedPath (Split-Path $path)
                New-Item -ItemType Directory -Path $path | Out-Null
                Protect-NewPath $path
            } else { Assert-ProtectedPath $path }
        }
        foreach ($path in @("$artifacts\provision.lock","$root\session\play.lock","$root\logs\guest-server.control.lock")) {
            if ([IO.File]::Exists($path)) { Assert-ProtectedPath $path }
            $handle = [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None')
            $handles.Add($handle)
            Protect-NewPath $path
        }
    }
    $phase = 'private credentials and recovery metadata'
    $ini = $utf8.GetString((Read-PrivateBytes "$root\private\backend\admin.ini"))
    $options = @{}
    $lines = @($ini -split '\r?\n' | Where-Object { $_.Trim() })
    Assert ($lines.Count -eq 7 -and $lines[0].Trim() -ceq '[client]') 'Unexpected portable client option layout.'
    foreach ($line in $lines[1..6]) {
        Assert ($line -cmatch '^([a-z-]+)=(.*)$') 'Unexpected portable client option.'
        Assert (!$options.ContainsKey($Matches[1])) 'Duplicate portable client option.'
        $options[$Matches[1]] = $Matches[2]
    }
    Assert ($options.Count -eq 6 -and $options.user -ceq 'root' -and $options.host -ceq '127.0.0.1' -and
        $options.port -ceq '3307' -and $options.protocol -ceq 'tcp' -and $options['default-character-set'] -ceq 'latin1' -and
        $options.password -cmatch '^[A-Za-z0-9]{40}$') 'Portable administrator connection options differ from the reviewed private configuration.'
    $secrets.Add($options.password)
    $sourceBytes = Read-PrivateBytes "$root\private\accounts.json"
    $sourceHash = Hash-Bytes $sourceBytes
    $source = Parse-Accounts $utf8.GetString($sourceBytes)
    foreach ($a in $source.records) { $secrets.Add($a.password) }
    $originalPath = "$artifacts\accounts.original.json"
    if ([IO.File]::Exists($originalPath)) { $originalBytes = Read-PrivateBytes $originalPath }
    else {
        Assert ($source.records.Count -eq 2 -and ![IO.File]::Exists("$artifacts\pending.json")) 'Original two-account backup is missing; existing targets were not adopted.'
        $originalBytes = $sourceBytes
    }
    $original = Parse-Accounts $utf8.GetString($originalBytes) $accountNames[0..1]
    $originalHash = Hash-Bytes $originalBytes
    Assert ($source.raw[0] -ceq $original.raw[0] -and $source.raw[1] -ceq $original.raw[1]) 'Original Player/BotOne metadata records changed.'
    if ($source.records.Count -eq 2) { Assert ($sourceHash -ceq $originalHash) 'Original account metadata bytes changed after backup.' }
    $pending = $null
    $added = $null
    $pendingFields = @('schemaVersion','ownerId','serverRoot','createdUtc','originalAccountsSha256','accounts')
    if ([IO.File]::Exists("$artifacts\pending.json")) {
        $pending = Read-Proof 'pending.json' $pendingFields
        Assert ($pending.originalAccountsSha256 -ceq $originalHash) 'Pending credentials belong to different original metadata.'
        $added = @($pending.accounts)
        Assert-Accounts $added $newNames
        foreach ($a in $added) { $secrets.Add($a.password) }
        Assert ($added[0].password -cne $added[1].password -and
            @($added | Where-Object { $_.password -cin $original.records.password }).Count -eq 0) 'Pending bot passwords are not independent.'
    }
    $receiptExists = [IO.File]::Exists("$artifacts\verified.json")
    Assert ($source.records.Count -eq 2 -or ($pending -and $receiptExists)) 'Published four-account metadata has no saved provisioning proof.'
    $beforeFields = @('schemaVersion','ownerId','serverRoot','originalAccountsSha256','pendingSha256','encoding','columns','protectedRows')
    $intentFields = @('schemaVersion','ownerId','serverRoot','originalAccountsSha256','pendingSha256','beforeSha256','engine','insertSqlSha256')
    $receiptFields = @('schemaVersion','ownerId','serverRoot','intentSha256','verifiedUtc','initialFreshAccounts')
    $before = $null; $intent = $null
    if ($pending) {
        $pendingHash = Hash-Bytes (Read-PrivateBytes "$artifacts\pending.json")
        if ([IO.File]::Exists("$artifacts\before.json")) {
            $before = Read-Proof 'before.json' $beforeFields
            Assert ($before.originalAccountsSha256 -ceq $originalHash -and $before.pendingSha256 -ceq $pendingHash) 'Scoped backup and pending credentials conflict.'
        }
        if ([IO.File]::Exists("$artifacts\intent.json")) {
            $intent = Read-Proof 'intent.json' $intentFields
            Assert ($before -and $intent.originalAccountsSha256 -ceq $originalHash -and $intent.pendingSha256 -ceq $pendingHash -and
                $intent.beforeSha256 -ceq (Hash-Bytes (Read-PrivateBytes "$artifacts\before.json")) -and
                $intent.engine -ceq 'MyISAM' -and $intent.insertSqlSha256 -ceq (Hash-Text (@(New-InsertSql $added) -join "`n"))) 'Saved insert-only intent does not match its protected inputs.'
        }
        $publication = New-Publication $original $added
        if ($source.records.Count -eq 4) {
            Assert ((ConvertTo-Json -InputObject $source.records -Compress) -ceq
                (ConvertTo-Json -InputObject $publication.accounts -Compress)) 'Published bot credentials differ from the saved intent.'
        }
    } else {
        Assert (!([IO.File]::Exists("$artifacts\before.json") -or [IO.File]::Exists("$artifacts\intent.json") -or $receiptExists)) 'Recovery artifacts exist without pending credentials.'
    }
    if ($receiptExists) {
        $receipt = Read-Proof 'verified.json' $receiptFields
        Assert ($intent -and $receipt.intentSha256 -ceq (Hash-Bytes (Read-PrivateBytes "$artifacts\intent.json")) -and
            $receipt.initialFreshAccounts -is [array] -and ($receipt.initialFreshAccounts -join ',') -ceq 'BotTwo,BotThree') 'Provisioning receipt is incomplete or foreign.'
    }
    if ([IO.File]::Exists("$root\private\room-bot-accounts.json")) {
        Assert ($pending -and $intent) 'An unknown bot-only credential publication already exists.'
        $botBytes = Read-PrivateBytes "$root\private\room-bot-accounts.json"
        $botMetadata = Parse-Accounts $utf8.GetString($botBytes) $botNames
        Assert ((ConvertTo-Json -InputObject $botMetadata.records -Compress) -ceq
            (ConvertTo-Json -InputObject $publication.accounts[1..3] -Compress)) 'Existing bot-only publication is not the saved three bots.'
    }
    $phase = 'locked database/schema/catalog validation'
    Open-Sql
    $layout = Lock-Database -Write:$Apply
    Assert-Catalog
    $state = Account-State $original $added $receiptExists
    Assert ($state -ne 'complete' -or ($pending -and $before -and $intent)) 'Preexisting complete rows lack the required durable backup/intent.'
    if (!$receiptExists) { Assert-NoOtherTargetData }
    $protected = Protected-Snapshot $layout
    $protectedText = ConvertTo-Json -InputObject $protected -Compress
    if ($before -and (!$receiptExists -or $source.records.Count -eq 2)) {
        Assert ($protectedText -ceq (ConvertTo-Json -InputObject $before.protectedRows -Compress)) 'Protected Player/BotOne or unrelated Chest rows changed since the pending backup.'
    }
    if (!$Apply) {
        Write-Output "PASS (read-only): reviewed guest/database/catalog and exact accounts. Targets: $state. Saved verification: $receiptExists. No credentials/files/rows were created or reset. -Apply requires a fresh OFFLINE lease."
        return
    }
    $phase = 'durable pending credentials, scoped backup and intent'
    $null = Assert-OfflineLease $lease ([DateTime]::UtcNow) 30
    Assert ((Hash-Bytes (Read-PrivateBytes "$root\private\accounts.json")) -ceq $sourceHash) 'Source account metadata changed during validation.'
    if (!$pending) {
        Assert ($state -ceq 'absent') 'Only wholly absent targets may receive newly generated credentials.'
        if (![IO.File]::Exists($originalPath)) { Write-PrivateAtomic $originalPath $originalBytes }
        $added = @(foreach ($name in $newNames) {
            do { $password = New-GamePassword } while ($password -cin $secrets)
            $secrets.Add($password)
            [pscustomobject][ordered]@{role='bot';username=$name;password=$password;id=$name;nickname=$name}
        })
        $pending = [pscustomobject][ordered]@{schemaVersion=1;ownerId=$ownerId;serverRoot=$root;createdUtc=[DateTime]::UtcNow.ToString('o')
            originalAccountsSha256=$originalHash;accounts=$added}
        Ensure-Artifact 'pending.json' (ConvertTo-Json -InputObject $pending -Depth 6)
        $pendingHash = Hash-Bytes (Read-PrivateBytes "$artifacts\pending.json")
    }
    if (!$before) {
        $before = [pscustomobject][ordered]@{schemaVersion=1;ownerId=$ownerId;serverRoot=$root;originalAccountsSha256=$originalHash
            pendingSha256=$pendingHash;encoding='Each column is HEX(CAST(column AS BINARY)); SQL NULL stays JSON null.'
            columns=$layout.columns;protectedRows=$protected}
        Ensure-Artifact 'before.json' (ConvertTo-Json -InputObject $before -Depth 8)
    }
    $insert = @(New-InsertSql $added) -join "`n"
    if (!$intent) {
        $intent = [pscustomobject][ordered]@{schemaVersion=1;ownerId=$ownerId;serverRoot=$root;originalAccountsSha256=$originalHash
            pendingSha256=$pendingHash;beforeSha256=(Hash-Bytes (Read-PrivateBytes "$artifacts\before.json"));engine='MyISAM';insertSqlSha256=(Hash-Text $insert)}
        Ensure-Artifact 'intent.json' (ConvertTo-Json -InputObject $intent)
    }
    if ($state -ceq 'absent') {
        $phase = 'insert-only MyISAM writes'
        $expires = Assert-OfflineLease $lease ([DateTime]::UtcNow) 30
        Assert-StoppedRuntime
        $null = Assert-Database
        $cutoff = $expires.AddSeconds(-15).ToString('yyyy-MM-dd HH:mm:ss.ffffff', [Globalization.CultureInfo]::InvariantCulture)
        $attempted = $true
        # ponytail: no partial-row repair. MyISAM failures retain intent/passwords for reviewed row-scoped recovery.
        Sql @"
DELIMITER //
BEGIN NOT ATOMIC
 IF UTC_TIMESTAMP(6)>='$cutoff' OR (SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID<>CONNECTION_ID())<>0 THEN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Maintenance lease/session guard changed';
 END IF;
 $insert
END//
DELIMITER ;
"@ | Out-Null
    }
    $phase = 'verification on locked and fresh connections'
    Assert ((Account-State $original $added $receiptExists) -ceq 'complete') 'Inserted identities did not verify.'
    Assert ((ConvertTo-Json -InputObject (Protected-Snapshot $layout) -Compress) -ceq $protectedText) 'A protected row changed during provisioning.'
    Close-Sql
    Open-Sql
    $layout = Lock-Database
    Assert-Catalog
    Assert ((Account-State $original $added $receiptExists) -ceq 'complete') 'Fresh-connection verification did not match saved credentials/gear.'
    Assert ((ConvertTo-Json -InputObject (Protected-Snapshot $layout) -Compress) -ceq $protectedText) 'Protected rows changed between verification connections.'
    if (!$receiptExists) { Assert-NoOtherTargetData }
    $phase = 'atomic verified metadata publication'
    $null = Assert-OfflineLease $lease ([DateTime]::UtcNow) 15
    Assert-StoppedRuntime
    Require-Ones @(Sql 'SELECT COUNT(*)=0 FROM information_schema.PROCESSLIST WHERE ID<>CONNECTION_ID();') 1 'Concurrent database activity appeared before publication.'
    $publication = New-Publication $original $added
    if (!$receiptExists) {
        $null = Assert-OfflineLease $lease ([DateTime]::UtcNow) 5
        $receipt = [pscustomobject][ordered]@{schemaVersion=1;ownerId=$ownerId;serverRoot=$root
            intentSha256=(Hash-Bytes (Read-PrivateBytes "$artifacts\intent.json"));verifiedUtc=[DateTime]::UtcNow.ToString('o');initialFreshAccounts=$newNames}
        Ensure-Artifact 'verified.json' (ConvertTo-Json -InputObject $receipt)
    }
    foreach ($file in @(
        @{path="$root\private\room-bot-accounts.json";text=$publication.botText},
        @{path="$root\private\accounts.json";text=$publication.allText}
    )) {
        $null = Assert-OfflineLease $lease ([DateTime]::UtcNow) 1
        $bytes = $utf8.GetBytes($file.text)
        $expectedHash = ''
        if ([IO.File]::Exists($file.path)) {
            $expectedHash = Hash-Bytes (Read-PrivateBytes $file.path)
            if ($file.path.EndsWith('\accounts.json')) { Assert ($expectedHash -ceq $sourceHash) 'Source account metadata changed before publication.' }
            else {
                $existing = Parse-Accounts $utf8.GetString((Read-PrivateBytes $file.path)) $botNames
                Assert ((ConvertTo-Json -InputObject $existing.records -Compress) -ceq
                    (ConvertTo-Json -InputObject $publication.accounts[1..3] -Compress)) 'Bot-only metadata changed concurrently.'
            }
        }
        if ($expectedHash -cne (Hash-Bytes $bytes)) { Write-PrivateAtomic $file.path $bytes $expectedHash }
        Assert ((Hash-Bytes (Read-PrivateBytes $file.path)) -ceq (Hash-Bytes $bytes)) 'Published metadata readback failed.'
    }
    Write-Output 'VERIFIED: Player/BotOne preserved; BotTwo/BotThree provisioned with native Golden Sentinel gear. Protected four-account and bot-only metadata published. Existing balances/inventory were never reset; host originals were not touched.'
}
catch {
    $reason = if ($_.Exception.Message.StartsWith('RoomBots: ', [StringComparison]::Ordinal)) { $_.Exception.Message } else { Safe-ExceptionDiagnostic $_ }
    $effect = if ($attempted) { 'MyISAM writes may be partial; there is NO rollback.' } else { 'No registration INSERT was issued by this invocation.' }
    throw [InvalidOperationException]::new("Room-bot provisioning failed during $phase. $reason $effect Keep the core/clients stopped and preserve $artifacts; do not restore snapshots or remove pending credentials.")
}
finally {
    try { Close-Sql } catch { Write-Warning ("Private SQL client cleanup/logging failed; preserve all recovery artifacts and keep the core stopped. " + (Safe-ExceptionDiagnostic $_)) }
    for ($i=$handles.Count-1; $i -ge 0; $i--) { $handles[$i].Dispose() }
}
