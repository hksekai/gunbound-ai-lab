#requires -Version 7.4
. "$PSScriptRoot\shared-io.ps1"

function Assert-VmPath([string]$Path, [string]$Below) {
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Contains('::')) { throw 'VM paths must be absolute local Windows paths.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($Below -and !$full.StartsWith([IO.Path]::GetFullPath($Below).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The VM path escapes its owned directory.'
    }
    for ($part = $full; $part; $part = Split-Path -Parent $part) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Redirected VM path refused: $part"
        }
    }
    $full
}

function Protect-VmDirectory([string]$Path) {
    $null = Assert-VmPath $Path
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path), $acl)
}

function Assert-VmPrivateFile([string]$Path) {
    $null = Assert-VmPath $Path
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    $acl = Get-Acl -LiteralPath $Path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @($allowed + 'S-1-5-32-544')) {
        throw 'A private VM ownership/password file is owned by an unrelated identity.'
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and
            $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
            throw 'VM ownership/password files must be readable only by the installing Windows user and SYSTEM.'
        }
    }
}

function Write-VmJson([string]$Path, $Value) {
    $null = Assert-VmPath $Path
    $next = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.new'
    try {
        [IO.File]::WriteAllText($next, (ConvertTo-Json -InputObject $Value -Depth 12), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($next, $Path, [NullString]::Value) }
        else { [IO.File]::Move($next, $Path) }
    } finally { if ([IO.File]::Exists($next)) { [IO.File]::Delete($next) } }
}

function Convert-VBoxInfo([string[]]$Lines) {
    $result = @{}
    foreach ($line in $Lines) {
        if ($line -notmatch '^("[^"]+"|[^=]+)=(.*)$') { continue }
        $name = $Matches[1].Trim('"')
        $value = $Matches[2]
        if ($name -match '^GuestProperty') { continue }
        if ($result.ContainsKey($name)) { throw 'Duplicate VirtualBox identity/configuration field.' }
        $result[$name] = if ($value.StartsWith('"')) { $value | ConvertFrom-Json } else { $value }
    }
    $result
}

function Convert-VBoxBlocks([string[]]$Lines) {
    $record = @{}
    foreach ($line in @($Lines) + @('')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($record.Count) { [pscustomobject]$record; $record = @{} }
        } elseif ($line -match '^([^:]+):\s*(.*)$') {
            if ($record.ContainsKey($Matches[1].Trim())) { throw 'Duplicate VirtualBox adapter field.' }
            $record[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
}

function Convert-VBoxRegistrations([string[]]$Lines) {
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^("(?:[^"\\]|\\.)*")\s+\{([0-9a-fA-F-]{36})\}$') { throw 'Unrecognized registered VM identity.' }
        $name = $Matches[1] | ConvertFrom-Json
        $id = [Guid]::ParseExact($Matches[2], 'D')
        if ($id -eq [Guid]::Empty) { throw 'Empty registered VM identity.' }
        [pscustomobject]@{ name=$name; id=$id.ToString('D') }
    }
}

function Get-VmCreatedDiskId([string]$Log) {
    $matches = [regex]::Matches($Log, '(?m)^Medium created\. UUID:\s*([0-9a-fA-F-]{36})\s*$')
    if ($matches.Count -ne 1) { throw 'The existing disk lacks an unambiguous protected VBox creation receipt; it will not be adopted or overwritten.' }
    $id = [Guid]::ParseExact($matches[0].Groups[1].Value, 'D')
    if ($id -eq [Guid]::Empty) { throw 'Invalid created-medium UUID.' }
    $id.ToString('D')
}

function Assert-VmIdentity($Config, $Owner, [string]$Root, $Info) {
    $id = [Guid]::Empty
    $expected = Join-Path $Root 'runtime\vm\GunBound-BotOne\GunBound-BotOne.vbox'
    if (!$Config -or !$Owner -or $Config.schemaVersion -ne 1 -or $Owner.schemaVersion -ne 1 -or
        $Config.provider -cne 'virtualbox' -or $Config.machineName -cne 'GunBound-BotOne' -or
        ![Guid]::TryParseExact([string]$Config.machineId, 'D', [ref]$id) -or $id -eq [Guid]::Empty -or
        $Config.machineFile -ine $expected -or $Owner.root -ine $Root -or $Owner.machineId -ine $Config.machineId -or
        $Owner.machineFile -ine $expected -or $Owner.virtualBox -ine $Config.virtualBox -or
        $Config.virtualBox -notmatch '^[A-Za-z]:\\.+\\VBoxManage\.exe$' -or
        $Config.guestRoot -cne 'C:\GunBoundAI' -or $Config.guestUser -cne 'LabBot' -or $Config.leaseSeconds -ne 120 -or
        $Config.enabled -isnot [bool] -or ($Config.enabled -and $Config.phase -cne 'ready') -or
        $Config.phase -cnotin @('preparing','installing','deploying','app-provisioned','migrating','provisioned','ready') -or
        $Config.hostAddress -cne '192.168.56.1' -or $Config.botAddress -cne '192.168.56.10' -or
        $Config.guestPrivateMac -cnotmatch '^080027[0-9A-F]{6}$' -or $Owner.guestPrivateMac -cne $Config.guestPrivateMac -or
        $Config.roomFill -isnot [bool] -or !$Config.roomFill -or @($Config.botInstances).Count -ne 3) {
        throw 'VM configuration does not match the protected UUID, root, hardware, and installation ownership record.'
    }
    for ($i = 0; $i -lt 3; $i++) {
        if ($Config.botInstances[$i].name -cne @('BotOne','BotTwo','BotThree')[$i] -or
            $Config.botInstances[$i].address -cne ('192.168.56.' + (10 + $i))) { throw 'The fixed room-bot mapping changed.' }
    }
    if ($Config.hostAdapter) {
        $adapterId = [Guid]::Empty
        if (![Guid]::TryParseExact([string]$Config.hostAdapterId, 'D', [ref]$adapterId) -or $adapterId -eq [Guid]::Empty -or
            $Owner.hostAdapter -cne $Config.hostAdapter -or $Owner.hostAdapterId -ine $Config.hostAdapterId) {
            throw 'The protected host-only adapter identity differs.'
        }
    } elseif ($Config.phase -ne 'preparing') { throw 'The owned host-only adapter was not recorded.' }
    if ($Info -and ($Info.UUID -ine $Config.machineId -or $Info.CfgFile -ine $expected)) {
        throw 'Registered VM UUID/CfgFile differs from the protected ownership record; no VM action is allowed.'
    }
}

function Read-VmConfig([string]$Root) {
    $path = Join-Path $Root 'private\vm\owner.json'
    Assert-VmPrivateFile $path
    $owner = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $config = Get-Content -LiteralPath (Join-Path $Root 'vm\config.json') -Raw | ConvertFrom-Json
    Assert-VmIdentity $config $owner $Root
    $null = Assert-VmPath $config.machineFile (Join-Path $Root 'runtime\vm')
    $null = Assert-VmPath $config.virtualBox
    $config
}

function Invoke-VBox {
    param([string]$VirtualBoxPath, [string[]]$Arguments, [ValidateRange(1,1800)][int]$TimeoutSeconds = 60, [string]$PrivateLog)
    if (@($Arguments | Where-Object { $_ -match '^--(?:password|user-password|admin-password)=' }).Count) {
        throw 'Plaintext command-line passwords are forbidden; use restricted passwordfiles.'
    }
    $start = [Diagnostics.ProcessStartInfo]::new($VirtualBoxPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw "VBoxManage $($Arguments[0]) exceeded ${TimeoutSeconds}s. Only its command process was stopped, not a VM."
        }
        $text = $output.GetAwaiter().GetResult()
        $errorText = $errors.GetAwaiter().GetResult()
        if ($PrivateLog) {
            $null = Assert-VmPath $PrivateLog
            [IO.File]::WriteAllText($PrivateLog, $text + $errorText, [Text.UTF8Encoding]::new($false))
            Assert-VmPrivateFile $PrivateLog
        }
        if ($process.ExitCode -ne 0) {
            # Guest/setup diagnostics can contain secrets. Never interpolate captured output into an exception.
            if (($text + $errorText) -match 'MAINTENANCE_YIELD') {
                throw [InvalidOperationException]::new('Maintenance yielded to another live Player lease.')
            }
            if ($errorText -match '(?s)Failed to get a console object from the direct session.*VBOX_E_INVALID_OBJECT_STATE') {
                throw [InvalidOperationException]::new('Failed to get a console object from the direct session (VBOX_E_INVALID_OBJECT_STATE)')
            }
            throw [InvalidOperationException]::new("VBoxManage $($Arguments[0]) failed (exit $($process.ExitCode)); inspect its restricted VM log when present.")
        }
        if ($text) { $text.TrimEnd("`r","`n") -split '\r?\n' }
    } finally { $process.Dispose() }
}

function Get-OwnedVmInfo([string]$Root, $Config) {
    $current = Read-VmConfig $Root
    if ($current.machineId -ine $Config.machineId) { throw 'VM ownership changed during the operation.' }
    $info = Convert-VBoxInfo @(Invoke-VBox $Config.virtualBox @('showvminfo', $Config.machineId, '--machinereadable'))
    $owner = Get-Content -LiteralPath (Join-Path $Root 'private\vm\owner.json') -Raw | ConvertFrom-Json
    Assert-VmIdentity $current $owner $Root $info
    $info
}

function Assert-VmRuntimeInfo($Config, $Info, $Adapter) {
    if (!$Adapter -or $Adapter.Name -cne $Config.hostAdapter -or $Adapter.GUID -ine $Config.hostAdapterId -or
        $Adapter.IPAddress -cne '192.168.56.1' -or $Adapter.NetworkMask -cne '255.255.255.0' -or
        $Info.nic2 -cne 'hostonly' -or $Info.hostonlyadapter2 -cne $Config.hostAdapter -or
        $Info.macaddress2 -cne $Config.guestPrivateMac -or
        $Info.nic1 -notin @('nat','none') -or ($Config.phase -eq 'ready' -and $Info.nic1 -ne 'none') -or
        @($Info.Keys | Where-Object { $_ -match '^Forwarding\(|^SharedFolderName|^natpf' }).Count) {
        throw 'The real adapter GUID/private NIC or isolation settings differ; no power action was taken.'
    }
}

function Assert-VmHostAdapter([string]$Root, $Config) {
    $info = Get-OwnedVmInfo $Root $Config
    $adapters = @(Convert-VBoxBlocks @(Invoke-VBox $Config.virtualBox @('list','hostonlyifs')) |
        Where-Object GUID -ieq $Config.hostAdapterId)
    if ($adapters.Count -ne 1) { throw 'The recorded host-only adapter GUID is missing or ambiguous.' }
    Assert-VmRuntimeInfo $Config $info $adapters[0]
    $windows = @(Get-NetAdapter -IncludeHidden | Where-Object { ([Guid]$_.InterfaceGuid).ToString('D') -ieq $Config.hostAdapterId })
    if ($windows.Count -ne 1 -or $windows[0].Status -eq 'Disabled' -or !@(Get-NetIPAddress -InterfaceIndex $windows[0].ifIndex -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ceq '192.168.56.1' -and $_.PrefixLength -eq 24 }).Count) {
        throw 'Windows no longer reports the owned adapter GUID/address.'
    }
}

function Invoke-VmGuest {
    param([string]$Root, $Config, [string]$Script, [ValidateRange(1,1500)][int]$TimeoutSeconds = 60,
        [switch]$HardwareOnly, [string]$LogName = 'guest-command.log')
    if ((Get-OwnedVmInfo $Root $Config).VMState -cne 'running') { throw 'The owned guest is not running.' }
    $password = Join-Path $Root 'private\vm\guest-admin.txt'
    Assert-VmPrivateFile $password
    $guard = "function Assert-GuestIdentity {`n" + ${function:Assert-GuestIdentity}.ToString() + "`n}`n"
    $guard += "Assert-GuestIdentity -OwnerId '$($Config.machineId)' " + $(if ($HardwareOnly) { '-HardwareOnly' }) + "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
        "`$ProgressPreference='SilentlyContinue';`$ErrorActionPreference='Stop';`n" + $guard + $Script))
    Invoke-VBox -VirtualBoxPath $Config.virtualBox -TimeoutSeconds ($TimeoutSeconds + 15) `
        -PrivateLog (Join-Path $Root "private\vm\$LogName") -Arguments @(
            'guestcontrol', $Config.machineId, 'run', '--quiet', '--username=Administrator',
            "--passwordfile=$password", "--timeout=$($TimeoutSeconds * 1000)", '--wait-stdout', '--wait-stderr',
            '--exe=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', '--arg0=powershell.exe', '--',
            '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
}

function Test-VmProcess($Record) {
    if (!$Record -or $Record.pid -isnot [long] -and $Record.pid -isnot [int] -or
        $Record.startedUtcTicks -isnot [long] -or $Record.pid -le 0 -or !$Record.path) { return $false }
    $process = Get-Process -Id $Record.pid -ErrorAction SilentlyContinue
    if (!$process) { return $false }
    try { $process.Path -ieq $Record.path -and $process.StartTime.ToUniversalTime().Ticks -eq $Record.startedUtcTicks }
    finally { $process.Dispose() }
}

function Get-VmUtcTicks($Value) {
    if ($Value -is [DateTime] -and $Value.Kind -ne [DateTimeKind]::Unspecified) { return $Value.ToUniversalTime().Ticks }
    Utc-Ticks $Value
}

function Get-VmWatchAction($Session, [string]$SessionId, [DateTime]$Now, [bool]$OwnerAlive, [bool]$PlayerOwns) {
    if (!$Session -or $Session.sessionId -ine $SessionId -or $Session.status -eq 'complete') { return 'retire' }
    if ($PlayerOwns) { return 'yield' }
    $start = Get-VmUtcTicks $Session.startedUtc
    $deadline = Get-VmUtcTicks $Session.deadlineUtc
    if ($Session.schemaVersion -ne 1 -or $Session.status -notin @('active','failed') -or $deadline -le $start -or
        $deadline - $start -gt 7200 * [TimeSpan]::TicksPerSecond -or $start - $Now.ToUniversalTime().Ticks -gt 30 * [TimeSpan]::TicksPerSecond) {
        throw 'Invalid or unbounded provisioning session intent.'
    }
    if (!$OwnerAlive -or $Session.status -eq 'failed' -or $Now.ToUniversalTime().Ticks -ge $deadline) { return 'stop' }
    'renew'
}

function Test-VmPlayerOwner([string]$Root) {
    $path = Join-Path $Root 'session\lab-session.json'
    if (!(Test-Path -LiteralPath $path)) { return $false }
    $reader = Open-SharedReader $path
    try { $state = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    $state.root -ieq $Root -and $state.supervisorActive -and (Test-VmProcess $state.supervisor)
}

function Assert-VmResume($Config, [bool]$Resume, [string[]]$Allowed) {
    if (!$Config) {
        if ($Resume) { throw '-Resume requires this workspace''s protected interrupted-installation metadata; it cannot adopt a VM.' }
        return
    }
    if (!$Resume -or $Config.enabled -or $Config.phase -notin $Allowed) {
        throw 'Existing VM data was not changed. Resume is only for the recorded unfinished phase, never an update/reset of an installed guest.'
    }
}

function Assert-VmAccounts($Accounts, [ValidateSet('Server','Bots','Client')][string]$Kind) {
    $names = switch ($Kind) {
        'Server' { @('Player','BotOne','BotTwo','BotThree') }
        'Bots' { @('BotOne','BotTwo','BotThree') }
        'Client' { @('Player','BotOne') }
    }
    if ($Accounts -isnot [array] -or $Accounts.Count -ne $names.Count) { throw "Invalid $Kind account cardinality." }
    for ($i = 0; $i -lt $names.Count; $i++) {
        $account = $Accounts[$i]
        if (@($account.PSObject.Properties).Count -ne 5 -or $account.username -cne $names[$i] -or
            $account.id -cne $names[$i] -or $account.nickname -cne $names[$i] -or
            $account.password -isnot [string] -or $account.password -cnotmatch '^[A-Za-z0-9]{12}$' -or
            $account.role -cne $(if ($names[$i] -ceq 'Player') { 'human' } else { 'bot' })) {
            throw "Invalid $Kind account identity, role, or bounded credential."
        }
    }
}

function Test-VmSubnetOverlap([string]$Address, [int]$PrefixLength) {
    $ip = $null
    if (![Net.IPAddress]::TryParse($Address, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork' -or
        $PrefixLength -lt 0 -or $PrefixLength -gt 32) { throw 'Invalid host IPv4 network metadata.' }
    if ($PrefixLength -eq 0) { return $false }
    $bytes = $ip.GetAddressBytes()
    $number = ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
    $bits = [Math]::Min(24, $PrefixLength)
    $mask = [uint32]::MaxValue -shl (32 - $bits)
    ($number -band $mask) -eq ([uint32]3232249856 -band $mask)
}

function Select-VmHostAdapter($Interfaces, $HostAddresses, $Routes, $DhcpServers, $VmInfos, [string]$OwnedId) {
    $compatible = @($Interfaces | Where-Object { $_.IPAddress -ceq '192.168.56.1' -and $_.NetworkMask -ceq '255.255.255.0' })
    if ($compatible.Count -gt 1) { throw 'More than one host-only adapter uses the fixed private subnet.' }
    $candidate = if ($compatible.Count) { $compatible[0] } else { $null }
    if ($candidate) {
        $id = [Guid]::Empty
        if (!$candidate.Name -or ![Guid]::TryParseExact([string]$candidate.GUID, 'D', [ref]$id) -or $id -eq [Guid]::Empty -or
            $candidate.DHCP -notin @('Disabled','No','false','0')) {
            throw 'The host-only adapter has no verifiable real name/GUID.'
        }
    }
    $rows = @($HostAddresses | Where-Object { Test-VmSubnetOverlap $_.IPAddress ([int]$_.PrefixLength) })
    foreach ($row in $rows) {
        if (!$candidate -or $row.InterfaceGuid -ine $candidate.GUID -or $row.Disabled -or
            $row.IPAddress -cne '192.168.56.1' -or $row.PrefixLength -ne 24) {
            throw 'An unrelated host/VPN interface overlaps 192.168.56.0/24. It was not modified; resolve the conflict explicitly.'
        }
    }
    if ($candidate -and $rows.Count -ne 1) { throw 'VBox and Windows do not agree on the real host-only adapter address/GUID.' }
    foreach ($route in $Routes) {
        $parts = $route.DestinationPrefix.Split('/')
        if ($parts.Count -ne 2) { throw 'Invalid host IPv4 route.' }
        if ((Test-VmSubnetOverlap $parts[0] ([int]$parts[1])) -and
            (!$candidate -or $route.InterfaceGuid -ine $candidate.GUID -or $route.NextHop -cne '0.0.0.0')) {
            throw 'An unrelated host/VPN route overlaps the fixed private subnet; no route or adapter was changed.'
        }
    }
    foreach ($adapter in $Interfaces) {
        if ($adapter -eq $candidate -or $adapter.IPAddress -in @('0.0.0.0','')) { continue }
        if ((Test-VmSubnetOverlap $adapter.IPAddress 24)) { throw 'Another host-only network conflicts with the fixed private subnet.' }
    }
    foreach ($info in $VmInfos) {
        if ($info.UUID -ieq $OwnedId) { continue }
        foreach ($key in @($info.Keys | Where-Object { $_ -match '^hostonlyadapter\d+$' })) {
            if ($candidate -and $info[$key] -ceq $candidate.Name) {
                throw 'The compatible host-only adapter is attached to another registered VM; it was not reused or changed.'
            }
        }
    }
    foreach ($dhcp in $DhcpServers) {
        if ($dhcp.Enabled -notin @('Yes','true','1')) { continue }
        $same = $candidate -and $dhcp.NetworkName -ceq ('HostInterfaceNetworking-' + $candidate.Name)
        $serverAddress = if ($dhcp.'Dhcpd IP') { $dhcp.'Dhcpd IP' } elseif ($dhcp.IP) { $dhcp.IP } else { $dhcp.IPAddress }
        $overlap = $serverAddress -and (Test-VmSubnetOverlap $serverAddress 24)
        if (!$same -and !$overlap) { continue }
        if (!$same -or $dhcp.NetworkMask -cne '255.255.255.0' -or
            $dhcp.lowerIPAddress -notmatch '^192\.168\.56\.(\d{1,3})$') { throw 'An incompatible DHCP scope overlaps the private subnet.' }
        $lower = [int]$Matches[1]
        if ($dhcp.upperIPAddress -notmatch '^192\.168\.56\.(\d{1,3})$') { throw 'Unrecognized host-only DHCP range.' }
        $upper = [int]$Matches[1]
        if ($lower -gt $upper -or $upper -gt 254 -or $lower -lt 2 -or ($lower -le 12 -and $upper -ge 10)) {
            throw 'The existing DHCP pool can lease a fixed bot address; it was not changed.'
        }
    }
    if ($candidate) { [pscustomobject]@{ action='reuse'; name=$candidate.Name; id=([Guid]$candidate.GUID).ToString('D') } }
    else { [pscustomobject]@{ action='create'; name=$null; id=$null } }
}

function Get-VmTreeManifest([string]$Path) {
    $null = Assert-VmPath $Path
    foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A VM package/snapshot input contains a redirected path.' }
        if (!$item.PSIsContainer) {
            [pscustomobject]@{ path=$item.FullName.Substring($Path.TrimEnd('\').Length + 1); bytes=$item.Length
                sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
        }
    }
}

function Assert-VmTreeManifest([string]$Path, $Files) {
    $actual = @(Get-VmTreeManifest $Path | Sort-Object path)
    $expected = @($Files | Sort-Object path)
    if (!$actual.Count -or $actual.Count -ne $expected.Count) { throw 'Snapshot/package file cardinality changed.' }
    for ($i = 0; $i -lt $actual.Count; $i++) {
        if ($actual[$i].path -cne $expected[$i].path -or $actual[$i].bytes -ne $expected[$i].bytes -or
            $actual[$i].sha256 -ine $expected[$i].sha256) { throw 'Snapshot/package provenance hash changed.' }
    }
}

function Assert-VmBackendStopped([string]$Root) {
    $prefixes = @((Join-Path $Root 'runtime\mariadb\'), (Join-Path $Root 'backend\native\'))
    foreach ($process in Get-CimInstance Win32_Process -OperationTimeoutSec 15) {
        foreach ($prefix in $prefixes) {
            if ($process.ExecutablePath -and $process.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The host backend must be stopped before an offline snapshot or migration. No process or original data was changed.'
            }
        }
        if ($process.CommandLine -and
            ($process.CommandLine.IndexOf((Join-Path $Root 'backend\start.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $process.CommandLine.IndexOf((Join-Path $Root 'backend\mysql-compat.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
            throw 'A host backend supervisor is still active. Finish its graceful shutdown first.'
        }
    }
}
        function Convert-VmUnattendedTemplate([string]$Text) {
            if ($Text -match '<!DOCTYPE|<!ENTITY') { throw 'Unattended templates cannot contain external XML declarations.' }
            $xml = [xml]::new()
            $xml.XmlResolver = $null
            $xml.PreserveWhitespace = $true
            $xml.LoadXml($Text)
            $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
            $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
            foreach ($block in @($xml.SelectNodes('//u:RunAsynchronous', $ns))) {
                $commands = @($block.SelectNodes('u:RunAsynchronousCommand/u:Path', $ns))
                if ($commands.Count -ne 5 -or @($commands | Where-Object {
                    $_.InnerText -cnotmatch '^reg\.exe ADD HKLM\\SYSTEM\\Setup\\LabConfig /v Bypass(CPU|RAM|SecureBoot|Storage|TPM)Check /t REG_DWORD /d 1 /f$'
                }).Count -or @($commands.InnerText | Sort-Object -Unique).Count -ne 5) {
                    throw 'The vendor template contains unfamiliar asynchronous commands; review it instead of removing unchecked commands.'
                }
                $block.ParentNode.RemoveChild($block) | Out-Null
            }
            $protection = $xml.SelectSingleNode('//u:ProtectYourPC', $ns)
            $location = $xml.SelectSingleNode('//u:NetworkLocation', $ns)
            $group = $xml.SelectSingleNode('//u:LocalAccounts/u:LocalAccount/u:Group', $ns)
            if (!$protection -or !$location -or !$group -or
                $xml.OuterXml -notmatch '@@VBOX_INSERT_IMAGE_INDEX_ELEMENT@@' -or
                $xml.OuterXml -notmatch '@@VBOX_INSERT_USER_PASSWORD_ELEMENT@@') {
                throw 'The installed vendor unattended template layout is unsupported.'
            }
            $protection.InnerText = '1'
            $location.InnerText = 'Other'
            $group.InnerText = 'users'
            foreach ($key in @($xml.SelectNodes('//u:UserData/u:ProductKey', $ns))) { $key.ParentNode.RemoveChild($key) | Out-Null }
            if ($xml.OuterXml -match 'Bypass(CPU|RAM|TPM|Storage|SecureBoot)Check|DisableAntiSpyware|DisableRealtimeMonitoring|Set-MpPreference') {
                throw 'Windows requirement/security overrides remain in the unattended template.'
            }
            return ,$xml
        }

        function Select-VmWindowsImage($Images) {
            $valid = @(foreach ($image in $Images) {
                $version = $null
                if ($image.ImageName -match 'Windows Server 2022.*\(Desktop Experience\)' -and
                    $image.ImageName -match 'Standard|Datacenter' -and
                    [version]::TryParse([string]$image.Version, [ref]$version) -and $version.Major -eq 10 -and $version.Build -eq 20348 -and
                    [int]$image.Architecture -eq 9 -and ($image.Languages -join ',') -match '(^|[,\s])en-US([,\s(]|$)' -and
                    [int]$image.ImageIndex -gt 0) { $image }
            })
            if (!$valid.Count) {
                throw 'Supply Microsoft English x64 Windows Server 2022 media containing Standard or Datacenter (Desktop Experience), build 20348; Server Core/client Windows are unsupported.'
            }
            $valid | Sort-Object @{Expression={ if ($_.ImageName -match 'Standard') { 0 } else { 1 } }}, ImageIndex | Select-Object -First 1
        }

        function Resolve-VmPrerequisites([string]$WindowsIso, [string]$VirtualBoxPath) {
            if (!$WindowsIso -or [IO.Path]::GetExtension($WindowsIso) -ine '.iso' -or
                !(Test-Path -LiteralPath $WindowsIso -PathType Leaf)) { throw 'Provide -WindowsIso pointing to your locally supplied Microsoft Windows Server 2022 Desktop Experience ISO.' }
            $iso = Assert-VmPath ([IO.Path]::GetFullPath($WindowsIso))
            if (!$VirtualBoxPath) {
                $command = Get-Command VBoxManage.exe -CommandType Application -ErrorAction SilentlyContinue
                $VirtualBoxPath = if ($command) { $command.Source } else { Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe' }
            }
            if (!(Test-Path -LiteralPath $VirtualBoxPath -PathType Leaf) -or [IO.Path]::GetFileName($VirtualBoxPath) -ine 'VBoxManage.exe') {
                throw 'Install Oracle VirtualBox 7.2.x with host-only networking separately, or provide -VirtualBoxPath to its VBoxManage.exe. Setup never downloads or installs host tools.'
            }
            $vbox = Assert-VmPath ([IO.Path]::GetFullPath($VirtualBoxPath))
            $directory = Split-Path $vbox
            $template = Join-Path $directory 'UnattendedTemplates\win_nt6_unattended.xml'
            $additions = Join-Path $directory 'VBoxGuestAdditions.iso'
            foreach ($path in @($template, $additions)) {
                if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The installed VirtualBox vendor unattended template or Guest Additions ISO is missing; repair the VirtualBox installation separately.' }
                $null = Assert-VmPath $path
            }
            Convert-VmUnattendedTemplate ([IO.File]::ReadAllText($template)) | Out-Null
            [pscustomobject]@{ virtualBox=$vbox; windowsIso=$iso; template=$template; additionsIso=$additions }
        }

        function Disconnect-VmInstallMedia([string]$Root, $Config) {
            $info = Get-OwnedVmInfo $Root $Config
            if ($info.VMState -cne 'poweroff') { throw 'Installation media may be detached only from the powered-off owned VM.' }
            $controllers = @($info.Keys | Where-Object { $_ -match '^storagecontrollername\d+$' } | ForEach-Object { $info[$_] })
            foreach ($key in @($info.Keys)) {
                if ($key -notmatch '^(.+)-(\d+)-(\d+)$') { continue }
                $controller = $Matches[1]; $port = $Matches[2]; $device = $Matches[3]
                if ($controller -cnotin $controllers) { continue }
                $medium = [string]$info[$key]
                if ($medium -in @('none','emptydrive','') -or $medium -ieq $Config.diskFile) { continue }
                if ($medium -notmatch '\.(iso|viso|img|flp)$' -or
                    ($medium -ine $Config.windowsIso -and $medium -ine $Config.additionsIso -and
                    !$medium.StartsWith((Join-Path $Root 'private\vm\unattended\'), [StringComparison]::OrdinalIgnoreCase))) {
                    throw 'An unexpected attached medium was not removed.'
                }
                $type = if ($medium -match '\.(img|flp)$') { 'fdd' } else { 'dvddrive' }
                Invoke-VBox $Config.virtualBox @('storageattach', $Config.machineId, "--storagectl=$controller",
                    "--port=$port", "--device=$device", "--type=$type", '--medium=emptydrive') | Out-Null
            }
        }

        function Get-VmGuestPackageScript([ValidateSet('app','server')][string]$Kind, $Package, [bool]$Resume) {
            if ($Package.sha256 -cnotmatch '^[0-9A-F]{64}$' -or $Package.packageId -cnotmatch '^[0-9a-f]{32}$' -or
                $Package.ownerId -notmatch '^[0-9a-f-]{36}$') { throw 'Invalid guest package identity/hash.' }
            $script = @'
        $base = 'C:\ProgramData\GunBoundAIProvision'
        $kind = '__KIND__'
        $destination = if ($kind -eq 'app') { 'C:\GunBoundAI' } else { 'C:\GunBoundServer' }
        $archive = Join-Path $base $(if ($kind -eq 'app') { 'bot-package.zip' } else { 'server-package.zip' })
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne '__HASH__') { throw 'Guest archive transfer hash mismatch.' }
        $intentFile = Join-Path $base ($kind + '-intent.json')
        if (Test-Path -LiteralPath $intentFile) {
            $intent = Get-Content -LiteralPath $intentFile -Raw | ConvertFrom-Json
            if ($intent.ownerId -ine '__OWNER__' -or $intent.packageId -cne '__PACKAGE__' -or $intent.sha256 -cne '__HASH__') {
                throw 'The protected first-install package intent differs.'
            }
        } else {
            if (Test-Path -LiteralPath $destination) { throw 'An existing guest root has no matching first-install intent.' }
            @{ownerId='__OWNER__';packageId='__PACKAGE__';sha256='__HASH__'} | ConvertTo-Json | Set-Content -LiteralPath $intentFile -Encoding utf8
        }
        if (Test-Path -LiteralPath $destination) {
            if ('__RESUME__' -cne 'yes') { throw 'An existing guest root requires explicit interrupted-first-install recovery.' }
            $markerFile = if ($kind -eq 'app') { "$destination\vm\guest.json" } else { "$destination\server-owner.json" }
            $existing = Get-Content -LiteralPath $markerFile -Raw | ConvertFrom-Json
            if ($existing.ownerId -ine '__OWNER__' -or $existing.packageId -cne '__PACKAGE__' -or $existing.root -cne $destination) {
                throw 'The existing root belongs to a different package/VM; it will not be overwritten.'
            }
        } else {
            $stage = Join-Path $base ($kind + '-__PACKAGE__')
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            $access = New-Object Security.AccessControl.DirectorySecurity
            $access.SetAccessRuleProtection($true,$false)
            $access.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
            foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
                $access.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    (New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
            }
            Set-Acl -LiteralPath $stage -AclObject $access
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($archive)
            try {
                $seen = @{}
                foreach ($entry in $zip.Entries) {
                    $relative = $entry.FullName.Replace('/', '\')
                    if (!$relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or
                        @($relative.Split('\') | Where-Object { $_ -and ($_ -in @('.','..') -or $_.TrimEnd(' ','.') -cne $_) }).Count -or
                        (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or
                        ($entry.ExternalAttributes -band 0x400)) { throw 'Unsafe archive entry.' }
                    $target = [IO.Path]::GetFullPath((Join-Path $stage $relative))
                    if (!$target.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($target)) {
                        throw 'Escaping/duplicate archive entry.'
                    }
                    $seen[$target] = $true
                }
            } finally { $zip.Dispose() }
            if (@(Get-ChildItem -LiteralPath $stage -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
                throw 'The protected staging directory contains a redirected path.'
            }
            Expand-Archive -LiteralPath $archive -DestinationPath $stage -Force
            $manifestFile = if ($kind -eq 'app') { "$stage\vm\package-manifest.json" } else { "$stage\package-manifest.json" }
            $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($manifest.schemaVersion -ne 1 -or $manifest.ownerId -ine '__OWNER__' -or
                @($manifest.files).Count -ne (@(Get-ChildItem -LiteralPath $stage -File -Recurse -Force).Count - 1)) {
                throw 'Guest package owner/file cardinality differs.'
            }
            $seen = @{}
            foreach ($file in $manifest.files) {
                if ([IO.Path]::IsPathRooted($file.path) -or $file.path.Contains(':') -or
                    @($file.path.Split('\') | Where-Object { !$_ -or $_ -in @('.','..') -or $_.TrimEnd(' ','.') -cne $_ }).Count) {
                    throw 'Unsafe manifest path.'
                }
                $target = [IO.Path]::GetFullPath((Join-Path $stage $file.path))
                if (!$target.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($target) -or
                    (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $file.sha256) { throw 'Guest payload integrity mismatch.' }
                $seen[$target] = $true
            }
            foreach ($path in @($stage) + @(Get-ChildItem -LiteralPath $stage -Recurse -Force | ForEach-Object FullName)) {
                $acl = Get-Acl -LiteralPath $path
                $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
                Set-Acl -LiteralPath $path -AclObject $acl
            }
            Move-Item -LiteralPath $stage -Destination $destination
        }
'@
            $script.Replace('__KIND__', $Kind).Replace('__HASH__', $Package.sha256).Replace('__OWNER__', $Package.ownerId).
                Replace('__PACKAGE__', $Package.packageId).Replace('__RESUME__', $(if ($Resume) { 'yes' } else { 'no' }))
        }

        function Assert-VmSourceInputs([string]$Root, [string]$ServerSourceDirectory) {
            if (!$ServerSourceDirectory -or !(Test-Path -LiteralPath $ServerSourceDirectory -PathType Container)) {
                throw 'Provide -ServerSourceDirectory pointing to your original extracted server bundle (Database and Server Binaries folders).'
            }
            $source = Assert-VmPath ([IO.Path]::GetFullPath($ServerSourceDirectory))
            foreach ($file in @('Database\gunbound.sql',
                'Server Binaries\GunBoundXP\Central\GunBoundBroker3.exe','Server Binaries\GunBoundXP\Server8360\Gunboundserv3.exe')) {
                $path = Assert-VmPath (Join-Path $source $file) $source
                if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "The supplied original server bundle is missing $file." }
            }
            foreach ($file in @('client-image\GunBound.gme','lab-client.exe','lab-tools.exe','bot-controller.exe',
                'runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe',
                'backend\manifest.json','backend\loopback-patches.json','backend\schema-static.sql',
                'private\backend\admin.ini','private\backend\my.ini','private\backend\credentials.json','private\backend\legacy-agent.json',
                'private\backend\accounts.json','private\accounts.json','private\vm\bot-accounts.json')) {
                $path = Assert-VmPath (Join-Path $Root $file) $Root
                if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
                    throw "VM prerequisite $file is missing. Run the root client build and setup\prepare-backend.ps1 first; VM setup does not initialize another database."
                }
            }
            foreach ($folder in @('runtime\mariadb\data\mysql','runtime\mariadb\data\gunbound')) {
                $path = Assert-VmPath (Join-Path $Root $folder) $Root
                if (!(Test-Path -LiteralPath $path -PathType Container)) { throw 'The canonical host database has not been initialized/provisioned by setup\prepare-backend.ps1.' }
            }
            if ((Get-FileHash -LiteralPath (Join-Path $Root 'client-image\GunBound.gme') -Algorithm SHA256).Hash -cne
                '683CB237147C8DE28C2A5EA3343E9A6B6082EC5D1851F5D20DFBF8BA81A530A8') { throw 'The exact supplied GunBound.gme fingerprint differs.' }
            $server = @(Get-Content -LiteralPath (Join-Path $Root 'private\backend\accounts.json') -Raw | ConvertFrom-Json)
            $bots = @(Get-Content -LiteralPath (Join-Path $Root 'private\vm\bot-accounts.json') -Raw | ConvertFrom-Json)
            $client = @(Get-Content -LiteralPath (Join-Path $Root 'private\accounts.json') -Raw | ConvertFrom-Json)
            Assert-VmAccounts $server 'Server'
            Assert-VmAccounts $bots 'Bots'
            Assert-VmAccounts $client 'Client'
            foreach ($account in @($bots) + @($client)) {
                if ($account.password -cne @($server | Where-Object username -ceq $account.username)[0].password) {
                    throw 'Client/bot metadata differs from the canonical four-account seed; no account will be reset.'
                }
            }
            $source
        }
