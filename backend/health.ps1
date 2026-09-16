#requires -Version 7.0
[CmdletBinding()]
param([switch]$DatabaseOnly)
$ErrorActionPreference = 'Stop'
function Assert-HealthAccounts($Accounts) {
    if ($Accounts -isnot [array] -or $Accounts.Count -notin @(2,4)) { throw 'Fresh account metadata is invalid.' }
    $names = @('Player','BotOne','BotTwo','BotThree')
    $fields = @('role','username','password','id','nickname')
    for ($i = 0; $i -lt $Accounts.Count; $i++) {
        $a = $Accounts[$i]
        $role = if ($i -eq 0) { 'human' } else { 'bot' }
        if ($a -isnot [pscustomobject] -or @($a.PSObject.Properties).Count -ne $fields.Count -or
            @($fields | Where-Object { $a.PSObject.Properties.Name -cnotcontains $_ }).Count -or
            $a.role -isnot [string] -or $a.role -cne $role -or
            $a.username -isnot [string] -or $a.username -cne $names[$i] -or
            $a.id -isnot [string] -or $a.id -cne $names[$i] -or
            $a.nickname -isnot [string] -or $a.nickname -cne $names[$i] -or
            $a.password -isnot [string] -or $a.password -cnotmatch '\A[A-Za-z0-9]{4,12}\z') {
            throw 'Account metadata must be exactly Player/BotOne or Player/BotOne/BotTwo/BotThree, with matching identities, roles and bounded credentials.'
        }
    }
}
function New-HealthSql($Accounts) {
    Assert-HealthAccounts $Accounts
    $query = @"
SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='gunbound';
SELECT COUNT(*) FROM gunbound.User;
SELECT COUNT(*) FROM gunbound.GunWcUser;
SELECT COUNT(*) FROM gunbound.Game;
SELECT COUNT(*) FROM gunbound.Cash;
SELECT COUNT(*) FROM gunbound.Item;
SELECT COUNT(*) FROM gunbound.Menu;
"@
    foreach ($a in $Accounts) {
        $query += "`nSELECT COUNT(*) FROM gunbound.User u JOIN gunbound.GunWcUser w ON u.Id=w.Id JOIN gunbound.Game g ON g.Id=u.Id JOIN gunbound.Cash c ON c.ID=u.Id WHERE BINARY u.Id='$($a.username)' AND BINARY w.Id='$($a.username)' AND BINARY g.Id='$($a.username)' AND BINARY c.ID='$($a.username)' AND BINARY u.user='$($a.username)' AND BINARY w.user='$($a.username)' AND BINARY u.NickName='$($a.nickname)' AND BINARY w.NickName='$($a.nickname)' AND BINARY g.Nickname='$($a.nickname)' AND BINARY u.Password='$($a.password)' AND BINARY w.Password='$($a.password)' AND u.Authority>0 AND w.Authority>0 AND UNIX_TIMESTAMP(u.MuteTime) IS NOT NULL AND UNIX_TIMESTAMP(u.RestrictTime) IS NOT NULL AND UNIX_TIMESTAMP(w.MuteTime) IS NOT NULL AND UNIX_TIMESTAMP(w.RestrictTime) IS NOT NULL AND UNIX_TIMESTAMP(g.GiftProhibitTime) IS NOT NULL;"
    }
    $query
}
function Assert-HealthCounts([object[]]$Result, [int]$AccountCount) {
    if ($AccountCount -notin @(2,4) -or $Result.Count -ne (7 + $AccountCount) -or
        @($Result | Where-Object { [string]$_ -cnotmatch '\A[0-9]{1,10}\z' }).Count) {
        throw 'SQL health query failed; inspect logs\backend-health-sql-errors.log.'
    }
    if ([long]$Result[0] -ne 57 -or @($Result[1..4] | Where-Object { [long]$_ -ne $AccountCount }).Count -or
        [long]$Result[5] -lt 1000 -or [long]$Result[6] -lt 1000 -or
        @($Result[7..($Result.Count - 1)] | Where-Object { [long]$_ -ne 1 }).Count) {
        throw "Schema/account/static-data health check failed (counts: $($Result -join ','))."
    }
}
$lab = Split-Path $PSScriptRoot
. "$PSScriptRoot\network-config.ps1"
$network = Get-LabNetwork
if (!$DatabaseOnly) { Assert-LabNetworkPrepared $network }
$bin = "$lab\runtime\mariadb\mariadb-11.4.13-winx64\bin"
try {
    $canonical = Test-Path -LiteralPath "$lab\private\backend\accounts.json"
    # Older guest packages intentionally keep their server metadata at the root.
    $accountPath = if ($canonical) { "$lab\private\backend\accounts.json" } else { "$lab\private\accounts.json" }
    $text = Get-Content -LiteralPath $accountPath -Raw
    if ($text.Length -gt 16384) { throw 'Oversized account metadata.' }
    $document = [Text.Json.JsonDocument]::Parse($text.TrimStart([char]0xFEFF))
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw 'Account metadata must be an array.' }
        foreach ($record in $document.RootElement.EnumerateArray()) {
            if ($record.ValueKind -ne [Text.Json.JsonValueKind]::Object -or @($record.EnumerateObject()).Count -ne 5) {
                throw 'Unexpected or duplicate account fields.'
            }
        }
    } finally { $document.Dispose() }
    $accounts = @($text | ConvertFrom-Json)
    if ($canonical -and $accounts.Count -ne 4) { throw 'Canonical backend metadata must contain all four accounts.' }
}
catch { throw 'Account metadata could not be read/decoded; no SQL health query was issued.' }
$sql = New-HealthSql $accounts
$result = @($sql | & "$bin\mariadb.exe" "--defaults-file=$lab\private\backend\admin.ini" --batch --skip-column-names 2> "$lab\private\backend\health-errors.log")
$queryExit = $LASTEXITCODE
$errorText = [IO.File]::ReadAllText("$lab\private\backend\health-errors.log")
foreach ($account in $accounts) { $errorText = $errorText.Replace($account.password, '[REDACTED]') }
foreach ($match in [regex]::Matches([IO.File]::ReadAllText("$lab\private\backend\admin.ini"), '(?m)^\s*password\s*=\s*([^\r\n]+)')) {
    $secret = $match.Groups[1].Value.Trim().Trim('"', "'")
    if ($secret) { $errorText = $errorText.Replace($secret, '[REDACTED]') }
}
# A syntax error can echo only part of a password, defeating exact-value replacement.
if ($errorText) {
    $codes = @([regex]::Matches($errorText, '(?m)^ERROR [0-9]{3,5}(?: \([A-Z0-9]{5}\))?(?: at line [0-9]+)?') | ForEach-Object Value) -join ', '
    $errorText = "$codes`nClient diagnostics: [REDACTED]; SQL can contain private credentials."
}
[IO.File]::WriteAllText("$lab\private\backend\health-errors.log", $errorText)
[IO.File]::WriteAllText("$lab\logs\backend-health-sql-errors.log", $errorText)
if ($queryExit) { throw 'SQL health query failed; inspect logs\backend-health-sql-errors.log.' }
Assert-HealthCounts $result $accounts.Count
$found = @()
foreach ($state in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*-processes.json') {
    foreach ($entry in @(Get-Content -LiteralPath $state.FullName -Raw | ConvertFrom-Json)) {
        if ($DatabaseOnly -and $entry.name -ne 'mariadb') { continue }
        $p = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
        if (!$p -or $p.Path -ne $entry.path -or $p.StartTime.ToUniversalTime().Ticks -ne $entry.startedUtcTicks) { throw "$($entry.name) process identity is stale." }
        $ports = @($entry.port) + @($entry.extraPorts | Where-Object { $_ })
        $listener = @(Assert-LabServiceEndpoints $entry $network)
        $address = if ($entry.name -in @('world','broker')) { $network.ServerAddress } else { '127.0.0.1' }
        foreach ($port in $ports) {
            $client = if ($network.IsPrivate -and $entry.name -in @('world','broker')) {
                [Net.Sockets.TcpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Parse($address), 0))
            } else { [Net.Sockets.TcpClient]::new() }
            try {
                $client.ConnectAsync($address, [int]$port).Wait(3000) | Out-Null
                if (!$client.Connected) { throw "$($entry.name) did not accept a connection at its configured address." }
                if ($entry.name -in @('mariadb','db-compat')) {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 3000
                    $header = [byte[]]::new(4)
                    $stream.ReadExactly($header, 0, $header.Length)
                    $length = [int]$header[0] + ([int]$header[1] -shl 8) + ([int]$header[2] -shl 16)
                    if ($length -lt 1 -or $length -gt 4096) { throw 'Invalid database greeting length.' }
                    $greeting = [byte[]]::new($length)
                    $stream.ReadExactly($greeting, 0, $greeting.Length)
                    if ($greeting[0] -ne 10) { throw 'Invalid database protocol greeting.' }
                }
            } finally { $client.Dispose() }
        }
        if ($entry.name -eq 'world') {
            Test-LabWorldResponse $network
        }
        $found += $entry.name
        Write-Output "$($entry.name): PID=$($entry.pid), TCP=$($listener | ForEach-Object { $_.LocalAddress + ':' + $_.LocalPort } | Join-String -Separator ',')"
    }
}
$requiredServices = if ($DatabaseOnly) { @('mariadb') } else { @('mariadb','db-compat','world','broker') }
foreach ($required in $requiredServices) { if ($required -notin $found) { throw "Missing supervised $required process." } }
$fw = New-Object -ComObject HNetCfg.FwPolicy2
foreach ($profile in @(1,2,4)) { if (!$fw.FirewallEnabled($profile) -or $fw.DefaultInboundAction($profile) -ne 0) { throw 'Firewall baseline no longer holds.' } }
foreach ($config in Get-ChildItem -LiteralPath "$PSScriptRoot\native" -Filter setting.txt -Recurse) {
    if ($config.Directory.Name -notin @('Server8360','Central','BuddyCenter','BuddyServ')) { throw 'Unexpected native application configuration.' }
}
if ($DatabaseOnly) { Get-LabNetworkSettingsChanges $network -VerifyOnly | Out-Null }
Write-Output "PASS ($($requiredServices -join ', ')): $($result[0]) table schemas, only $($accounts.username -join '/'), matching plaintext legacy credentials, static game data, owned $($network.Mode) services and unchanged firewall baseline."
if ($DatabaseOnly) { Write-Output 'Database-only success does NOT mean the native world/broker is ready.' }
Write-Output 'This checks backend readiness, not successful client login or gameplay.'
