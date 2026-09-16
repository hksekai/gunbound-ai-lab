#requires -Version 5.1
[CmdletBinding()]
param([switch]$Check)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\shared-io.ps1"

function Lease-Expires($Lease, [DateTime]$Now) {
    $parsed = Convert-PlayerLease $Lease $Now
    [DateTime]::new($parsed.expiresUtcTicks, [DateTimeKind]::Utc)
}
function Boot-Grace([DateTime]$Now, [DateTime]$Boot, $Issued) {
    $age = ($Now - $Boot).TotalSeconds
    $age -ge 0 -and $age -lt 180 -and ($null -eq $Issued -or ([DateTime]$Issued) -lt $Boot)
}
function Backend-Stopped($ExitCode) {
    ($ExitCode -is [int] -or $ExitCode -is [long]) -and $ExitCode -eq 0
}
if ($Check) {
    $now = [DateTime]::UtcNow
    $lease = @{schemaVersion=1;sessionId=[Guid]::NewGuid().ToString('D');issuedUtc=$now.ToString('o')
        expiresUtc=$now.AddSeconds(120).ToString('o');playerOnline=$true;roomReady=$true}
    if ((Lease-Expires $lease $now) -le $now) { throw 'A valid lease was rejected.' }
    $lease.expiresUtc = $now.AddSeconds(121).ToString('o')
    $rejected = $false
    try { Lease-Expires $lease $now | Out-Null } catch [ArgumentException] { $rejected = $true }
    if (!$rejected) { throw 'An excessive lease was accepted.' }
    $lease.issuedUtc = $now.AddSeconds(-121).ToString('o')
    $lease.expiresUtc = $now.AddSeconds(-1).ToString('o')
    if ((Lease-Expires $lease $now) -gt $now) { throw 'An expired lease became active.' }
    $boot = $now.AddSeconds(-179)
    if (!(Boot-Grace $now $boot $boot.AddSeconds(-1)) -or !(Boot-Grace $now $boot $null) -or
        (Boot-Grace $now $boot $boot.AddSeconds(1)) -or
        (Boot-Grace $now $now.AddSeconds(-180) $now.AddSeconds(-181))) { throw 'The 180-second pre-boot lease/missing-lease grace changed.' }
    if (!(Backend-Stopped 0) -or (Backend-Stopped 1) -or (Backend-Stopped -1) -or
        (Backend-Stopped $null) -or (Backend-Stopped '0')) { throw 'Shutdown can proceed without a successful backend stop.' }
    Write-Output 'PASS: bounded leases, expiry, 180-second pre-boot grace, and fail-closed backend shutdown gate; no machine or power action performed.'
    return
}

$root = Split-Path $PSScriptRoot
function Assert-LocalGuest {
    if ($root -ne 'C:\GunBoundAI') { throw 'Idle shutdown is restricted to the installed local lab guest.' }
    $marker = Get-Content -LiteralPath "$PSScriptRoot\guest.json" -Raw | ConvertFrom-Json
    $owner = [Guid]::Empty
    if ($marker.schemaVersion -ne 1 -or $marker.root -ne $root -or
        ($marker.PSObject.Properties.Name -contains 'serverRoot' -and $marker.serverRoot -cne 'C:\GunBoundServer') -or
        $marker.computerName -ne 'GUNBOUND-BOT' -or $marker.computerName -ne $env:COMPUTERNAME -or
        $marker.provider -ne 'virtualbox' -or
        ![Guid]::TryParseExact([string]$marker.ownerId, 'D', [ref]$owner) -or $owner -eq [Guid]::Empty) {
        throw 'Idle shutdown is restricted to the identified local lab guest. Azure requires deallocation, not Windows shutdown.'
    }
    Assert-GuestIdentity -OwnerId $marker.ownerId
    $script:serverInstalled = $marker.PSObject.Properties.Name -contains 'serverRoot'
    $script:guestOwner = $marker.ownerId
}
Assert-LocalGuest
$control = 'C:\ProgramData\GunBoundAIControl'
$now = [DateTime]::UtcNow
$reason = $null
$active = $false
try {
    $file = Join-Path $control 'lease.json'
    $reader = $null
    try { $reader = Open-SharedReader $file -WaitForPublication }
    catch [IO.FileNotFoundException] {}
    catch [IO.DirectoryNotFoundException] {}
    $now = [DateTime]::UtcNow
    if ($reader) {
        try {
            if ($reader.BaseStream.Length -gt 4096) { throw [ArgumentException]::new('Oversized Player lease.') }
            $buffer = New-Object char[] 4097
            $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
            $content = [string]::new($buffer, 0, $count)
        } finally { $reader.Dispose() }
        if ($content.Length -gt 4096) { throw [ArgumentException]::new('Oversized Player lease.') }
        $lease = $content | ConvertFrom-Json
        if ((Lease-Expires $lease $now) -gt $now) {
            $active = $true
        } else {
            $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
            if (Boot-Grace $now $boot ([DateTimeOffset]::Parse([string]$lease.issuedUtc).UtcDateTime)) { return }
            $reason = 'Player lease expired; its owner stopped renewing.'
        }
    } else {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
        if (Boot-Grace $now $boot $null) { return }
        $reason = 'No Player lease was delivered during boot.'
    }
}
catch [ArgumentException] { $reason = 'Invalid Player lease: ' + $_.Exception.Message }
catch [IO.InvalidDataException] { $reason = 'Invalid Player lease file: ' + $_.Exception.Message }
catch [IO.IOException] { $reason = 'Player lease read failed: ' + $_.Exception.Message }
catch [UnauthorizedAccessException] { $reason = 'Player lease access failed: ' + $_.Exception.Message }
catch [System.Management.Automation.ItemNotFoundException] { $reason = 'Player lease disappeared during the read.' }

if ($active) {
    try {
        if ((Get-Service -Name VBoxService).Status -ne 'Running') {
            [ordered]@{timeUtc=$now.ToString('o');action='restore-guest-management'} |
                ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $control 'idle-events.jsonl')
            Start-Service -Name VBoxService
        }
    } catch {
        [ordered]@{timeUtc=[DateTime]::UtcNow.ToString('o');action='restore-guest-management-failed';reason=$_.Exception.Message} |
            ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $control 'idle-events.jsonl')
        Write-Warning 'Guest-management recovery failed while the lease was valid; it was not treated as lease expiry.'
    }
    return
}
if (!$reason) { throw 'No expired/missing/invalid lease reason was established; no shutdown was attempted.' }
[ordered]@{timeUtc=[DateTime]::UtcNow.ToString('o');action='backend-stop-requested';reason=$reason} |
    ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $control 'idle-events.jsonl')
try {
    $LASTEXITCODE = $null
    if ($serverInstalled) {
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive `
            -File "$PSScriptRoot\guest-server.ps1" -Action Stop `
            1> (Join-Path $control 'idle-backend-stop.out.log') 2> (Join-Path $control 'idle-backend-stop.err.log')
        $stopCode = $LASTEXITCODE
    } else {
        Assert-UnstartedGuestServer -OwnerId $guestOwner
        $stopCode = 0
    }
    if (!(Backend-Stopped $stopCode)) { throw "Guest backend Stop returned '$stopCode'; graceful shutdown was not verified." }
} catch {
    [ordered]@{timeUtc=[DateTime]::UtcNow.ToString('o');action='backend-stop-failed-shutdown-skipped';reason=$_.Exception.Message} |
        ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $control 'idle-events.jsonl')
    throw 'Backend/database stop failed; Windows shutdown was NOT requested. Inspect protected server and idle-backend-stop logs.'
}
Assert-LocalGuest
if (Test-Path -LiteralPath (Join-Path $control 'lease.json')) {
    $reader = Open-SharedReader (Join-Path $control 'lease.json')
    try { $latest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($latest.Length -gt 4096) { throw 'Oversized lease during shutdown recheck.' }
    if ((Lease-Expires ($latest | ConvertFrom-Json) ([DateTime]::UtcNow)) -gt [DateTime]::UtcNow) {
        Write-Output 'A current owner renewed the lease during cleanup; Windows shutdown was not requested.'
        return
    }
}
[ordered]@{timeUtc=[DateTime]::UtcNow.ToString('o');action='guest-shutdown';reason=$reason;backendExitCode=$stopCode} |
    ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $control 'idle-events.jsonl')
& "$env:SystemRoot\System32\shutdown.exe" /s /t 10 /c 'GunBound AI Lab: Player lease ended.'
if ($LASTEXITCODE -ne 0) { throw "The owned guest could not shut down ($LASTEXITCODE). Reason: $reason" }
