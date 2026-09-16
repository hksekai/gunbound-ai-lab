#requires -Version 7.0
[CmdletBinding()]
param([switch]$Prepare, [switch]$Check, [string]$SourceDirectory)
$ErrorActionPreference = 'Stop'

function Get-LabNetwork {
    if (!('RetroClientBuild.NetworkProfile' -as [type])) { Add-Type -Path "$(Split-Path $PSScriptRoot)\client-build\ClientPatch.cs" }
    [RetroClientBuild.NetworkProfile]::Load((Split-Path $PSScriptRoot))
}

function Assert-LabCoreStopped {
    $paths = @("$PSScriptRoot\native\Server8360\Gunboundserv3.exe", "$PSScriptRoot\native\Central\GunBoundBroker3.exe")
    foreach ($process in Get-CimInstance Win32_Process) {
        if ($process.ExecutablePath -in $paths -or
            ([string]$process.CommandLine).IndexOf("$PSScriptRoot\mysql-compat.ps1", [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw 'Stop the owned Core before preparing its network configuration. No process was stopped.'
        }
    }
}

function Convert-LabNetworkSettingBytes([byte[]]$Bytes, [string]$Key, [string]$Allowlist, [int]$Port) {
    # Latin1 round-trips every untouched byte, including non-ASCII settings and credentials.
    $text = [Text.Encoding]::Latin1.GetString($Bytes)
    $accept = [regex]::Matches($text, '(?m)^(?<key>Accept|StarAccept)=(?<value>[^\r\n]*)')
    $ports = [regex]::Matches($text, '(?m)^Port=(?<value>[^\r\n]*)')
    if ($accept.Count -ne 1 -or $accept[0].Groups['key'].Value -cne $Key -or
        $ports.Count -ne 1 -or $ports[0].Groups['value'].Value -cne [string]$Port) {
        throw 'Unsupported native allowlist/port layout. No settings or credentials were changed.'
    }
    $old = $accept[0].Groups['value']
    if (!$old.Value.EndsWith(';')) { throw 'Native allowlists must retain the supplied semicolon format.' }
    foreach ($address in $old.Value.TrimEnd(';').Split(';')) {
        if ($address -cnotin @('127.0.0.1','127.0.0.2') -and ![RetroClientBuild.NetworkProfile]::IsPrivateIPv4($address)) {
            throw 'An existing native allowlist contains an unsupported address.'
        }
    }
    $database = [regex]::Matches($text, '(?m)^(?<key>\w*DB\w*_(?<kind>Host|Port))=(?<value>[^\r\n]*)')
    if ($database.Count -lt 2) { throw 'Expected native SQL endpoint fields are missing.' }
    $seen = @{}
    foreach ($field in $database) {
        $keyName = $field.Groups['key'].Value
        $expected = if ($field.Groups['kind'].Value -ceq 'Host') { '127.0.0.1' } else { '3308' }
        if ($seen.ContainsKey($keyName) -or $field.Groups['value'].Value -cne $expected) {
            throw 'Native SQL settings must remain exclusively 127.0.0.1:3308; the compiled world route remains 127.0.0.1:3306.'
        }
        $seen[$keyName] = $true
    }
    foreach ($field in $database) {
        $pair = if ($field.Groups['kind'].Value -ceq 'Host') {
            $field.Groups['key'].Value -creplace '_Host$', '_Port'
        } else { $field.Groups['key'].Value -creplace '_Port$', '_Host' }
        if (!$seen.ContainsKey($pair)) { throw 'A native SQL Host/Port pair is incomplete.' }
    }
    return ,([Text.Encoding]::Latin1.GetBytes($text.Remove($old.Index, $old.Length).Insert($old.Index, $Allowlist)))
}

function Convert-LabWorldListBytes([byte[]]$Bytes, [string]$Address) {
    $text = [Text.Encoding]::Latin1.GetString($Bytes)
    $row = [regex]::Match($text, '\A[^;\r\n]+;[^;\r\n]+;(?<address>[^;\r\n]+);8360;0;(?:\r?\n)?\z')
    if (!$row.Success) { throw 'Expected one native world entry on port 8360, with the original six-field format.' }
    $old = $row.Groups['address']
    if ($old.Value -cne '127.0.0.1' -and ![RetroClientBuild.NetworkProfile]::IsPrivateIPv4($old.Value)) {
        throw 'The existing native world list contains an unsupported address.'
    }
    return ,([Text.Encoding]::Latin1.GetBytes($text.Remove($old.Index, $old.Length).Insert($old.Index, $Address)))
}

function Get-LabNetworkSettingsChanges($Network, [switch]$VerifyOnly) {
    $world = ((@($Network.HumanAddress) + @($Network.BotAddresses)) -join ';') + ';'
    $broker = if ($Network.IsPrivate) { $world } else { '127.0.0.1;' }
    $specs = @(
        @{ component='Server8360'; key='Accept'; acl=$world; port=8360 },
        @{ component='Central'; key='Accept'; acl=$broker; port=8372 },
        @{ component='BuddyCenter'; key='Accept'; acl='127.0.0.1;'; port=8339 },
        @{ component='BuddyServ'; key='StarAccept'; acl='127.0.0.1;'; port=8352 }
    )
    foreach ($spec in $specs) {
        $path = "$PSScriptRoot\native\$($spec.component)\setting.txt"
        $before = [IO.File]::ReadAllBytes($path)
        $after = Convert-LabNetworkSettingBytes $before $spec.key $spec.acl $spec.port
        $hash = [RetroClientBuild.ClientPatch]::Hash($before)
        if ($hash -ceq [RetroClientBuild.ClientPatch]::Hash($after)) { continue }
        if ($VerifyOnly -or $spec.component -in @('BuddyCenter','BuddyServ')) {
            throw "Native $($spec.component) settings do not match the selected profile. Buddy must remain loopback-only."
        }
        [pscustomobject]@{ path=$path; beforeSha256=$hash; bytes=$after }
    }
    $path = "$PSScriptRoot\native\Central\GameServerList.txt"
    $before = [IO.File]::ReadAllBytes($path)
    $after = Convert-LabWorldListBytes $before $Network.ServerAddress
    $hash = [RetroClientBuild.ClientPatch]::Hash($before)
    if ($hash -cne [RetroClientBuild.ClientPatch]::Hash($after)) {
        if ($VerifyOnly) { throw 'The broker world list does not match network.json.' }
        [pscustomobject]@{ path=$path; beforeSha256=$hash; bytes=$after }
    }
}

function Assert-LabNetworkPrepared($Network) {
    . "$PSScriptRoot\bind-loopback.ps1"
    Get-LabNetworkSettingsChanges $Network -VerifyOnly | Out-Null
    Get-LabNativeBindingChanges $Network -VerifyOnly | Out-Null
}

function Assert-LabNetworkUnchanged($Network, [string]$Message = 'network.json changed during preparation.') {
    $current = Get-LabNetwork
    if (((@($current.SchemaVersion,$current.Mode,$current.ServerAddress,$current.HumanAddress,$current.BotAddress) +
            @($current.BotAddresses)) -join ';') -cne
        ((@($Network.SchemaVersion,$Network.Mode,$Network.ServerAddress,$Network.HumanAddress,$Network.BotAddress) +
            @($Network.BotAddresses)) -join ';')) {
        throw $Message
    }
}

function Write-LabNetworkChanges($Plans, $Network) {
    if (!@($Plans).Count) { return }
    $allowed = @(
        "$PSScriptRoot\native\Server8360\Gunboundserv3.exe", "$PSScriptRoot\native\Central\GunBoundBroker3.exe",
        "$PSScriptRoot\native\Server8360\setting.txt", "$PSScriptRoot\native\Central\setting.txt",
        "$PSScriptRoot\native\Central\GameServerList.txt", "$PSScriptRoot\loopback-patches.json"
    )
    $staged = [Collections.Generic.List[object]]::new()
    $complete = $false
    try {
        foreach ($plan in $Plans) {
            if ($plan.path -notin $allowed) { throw 'Network preparation may write only the six owned core configuration/provenance files.' }
            $item = [IO.FileInfo]::new($plan.path)
            for ($parent = $item; $parent -and $parent.FullName -ne (Split-Path $PSScriptRoot); $parent = if ($parent -is [IO.FileInfo]) { $parent.Directory } else { $parent.Parent }) {
                if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Network preparation refuses redirected files/directories.'
                }
            }
            $exists = $item.Exists
            if (($exists -and (Get-FileHash -LiteralPath $plan.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $plan.beforeSha256) -or
                (!$exists -and $plan.beforeSha256)) { throw 'A core file changed during network preparation.' }
            $suffix = '.network-' + [Guid]::NewGuid().ToString('N')
            $entry = [pscustomobject]@{ plan=$plan; stage=($plan.path + $suffix + '.new'); backup=($plan.path + $suffix + '.backup'); existed=$exists; published=$false; access=$null }
            $staged.Add($entry)
            if ($exists) {
                $security = [IO.FileSystemAclExtensions]::GetAccessControl($item, [Security.AccessControl.AccessControlSections]::Access)
            } else {
                $security = [Security.AccessControl.FileSecurity]::new()
                $security.SetAccessRuleProtection($true, $false)
                foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
                    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
                }
            }
            $entry.access = $security.GetSecurityDescriptorBinaryForm()
            $stream = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($entry.stage), [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough, $security)
            try { $stream.Write($plan.bytes, 0, $plan.bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            # Create/Replace can materialize inherited ACEs; restore the original access rules without requesting SACL privileges.
            $security.SetSecurityDescriptorBinaryForm($entry.access, [Security.AccessControl.AccessControlSections]::Access)
            [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($entry.stage), $security)
        }
        foreach ($entry in $staged) {
            Assert-LabCoreStopped
            Assert-LabNetworkUnchanged $Network
            $path = $entry.plan.path
            if ((Test-Path -LiteralPath $path) -ne $entry.existed -or
                ($entry.existed -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.plan.beforeSha256)) {
                throw 'A core file changed before publication; restoring the previous files.'
            }
            if ($entry.existed) { [IO.File]::Replace($entry.stage, $path, $entry.backup) }
            else { [IO.File]::Move($entry.stage, $path) }
            $entry.published = $true
            $security = [Security.AccessControl.FileSecurity]::new()
            $security.SetSecurityDescriptorBinaryForm($entry.access, [Security.AccessControl.AccessControlSections]::Access)
            [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($path), $security)
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [RetroClientBuild.ClientPatch]::Hash($entry.plan.bytes)) {
                throw 'Network preparation read-back verification failed.'
            }
        }
        Assert-LabCoreStopped
        Assert-LabNetworkUnchanged $Network
        $complete = $true
    } catch {
        $failure = $_
        for ($i = $staged.Count - 1; $i -ge 0; $i--) {
            $entry = $staged[$i]
            if (!$entry.published) { continue }
            try {
                if ((Get-FileHash -LiteralPath $entry.plan.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                    [RetroClientBuild.ClientPatch]::Hash($entry.plan.bytes)) { throw 'A published file was edited again; its recovery backup must be retained.' }
                if ($entry.existed) {
                    [IO.File]::Replace($entry.backup, $entry.plan.path, [NullString]::Value)
                    $security = [Security.AccessControl.FileSecurity]::new()
                    $security.SetSecurityDescriptorBinaryForm($entry.access, [Security.AccessControl.AccessControlSections]::Access)
                    [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($entry.plan.path), $security)
                }
                else { [IO.File]::Delete($entry.plan.path) }
                $entry.published = $false
            } catch { Write-Warning "Inspect $($entry.plan.path) and any remaining backup $($entry.backup) before starting Core; rollback could not finish." }
        }
        throw $failure
    } finally {
        foreach ($entry in $staged) {
            if ([IO.File]::Exists($entry.stage)) { [IO.File]::Delete($entry.stage) }
            if ($complete -and [IO.File]::Exists($entry.backup)) { [IO.File]::Delete($entry.backup) }
        }
    }
}

function Assert-LabServiceEndpoints($Entry, $Network, [switch]$AllowStarting) {
    $ports = switch ($Entry.name) {
        'mariadb' { @(3307) }
        'db-compat' { @(3308,3306) }
        'world' { @(8360) }
        'broker' { @(8372) }
        'buddy-center' { @(8339) }
        'buddy' { @(8352) }
        default { throw 'Unsupported supervised backend identity.' }
    }
    $recorded = @($Entry.port) + @($Entry.extraPorts | Where-Object { $_ })
    if (($ports | Sort-Object | Join-String -Separator ',') -ne ($recorded | Sort-Object | Join-String -Separator ',')) {
        throw 'Supervised backend port metadata differs from the fixed lab ports.'
    }
    $game = $Entry.name -in @('world','broker')
    $address = if ($game) { $Network.ServerAddress } else { '127.0.0.1' }
    $tcp = @(Get-NetTCPConnection -State Listen -OwningProcess $Entry.pid -ErrorAction SilentlyContinue)
    $udp = @(Get-NetUDPEndpoint -OwningProcess $Entry.pid -ErrorAction SilentlyContinue)
    if (@($tcp | Where-Object { $_.LocalAddress -cne $address -or $_.LocalPort -notin $ports }).Count -or
        @($udp | Where-Object LocalAddress -CNE $address).Count) {
        throw "$($Entry.name) has an unexpected listener; only $address is permitted."
    }
    if (@(Get-NetTCPConnection -State Listen -LocalPort $ports -ErrorAction SilentlyContinue |
        Where-Object OwningProcess -NE $Entry.pid).Count) { throw "$($Entry.name) required ports have an unowned listener." }
    if ($Entry.name -eq 'world' -and
        (@($udp | Where-Object LocalPort -NE 8360).Count -or
        @(Get-NetUDPEndpoint -LocalPort 8360 -ErrorAction SilentlyContinue | Where-Object OwningProcess -NE $Entry.pid).Count)) {
        throw 'World UDP must be owned exclusively on the configured address, port 8360.'
    }
    if (($game -and $udp.Count -gt 1) -or ($Entry.name -in @('mariadb','db-compat') -and $udp.Count)) {
        throw "$($Entry.name) has unexpected UDP endpoints."
    }
    $ready = $tcp.Count -eq @($ports).Count -and (!$game -or $udp.Count -eq 1)
    if (!$ready -and !$AllowStarting) { throw "$($Entry.name) has not completed its required TCP/UDP startup." }
    if ($ready) { $tcp }
}

function Test-LabWorldResponse($Network) {
    $udp = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Parse($Network.ServerAddress), 0))
    try {
        $udp.Client.ReceiveTimeout = 3000
        $udp.Connect($Network.ServerAddress, 8360)
        $request = [byte[]]@(8,0,0,0xf0,0,0,0,0)
        $udp.Send($request, $request.Length) | Out-Null
        $peer = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $reply = $udp.Receive([ref]$peer)
        if ($peer.Address.ToString() -cne $Network.ServerAddress -or $peer.Port -ne 8360 -or
            $reply.Length -lt 8 -or [BitConverter]::ToUInt16($reply, 0) -ne $reply.Length -or $reply[2] -ne 1 -or $reply[3] -ne 0xf0) {
            throw 'The configured native world returned an invalid UDP state response.'
        }
    } finally { $udp.Dispose() }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Prepare -and $Check) { throw 'Choose -Prepare or -Check, not both.' }
    if ($SourceDirectory -and !$Prepare) { throw '-SourceDirectory is only used with -Prepare.' }
    $network = Get-LabNetwork
    if ($Prepare) {
        Assert-LabCoreStopped
        . "$PSScriptRoot\bind-loopback.ps1"
        $settings = @(Get-LabNetworkSettingsChanges $network)
        $bindings = Get-LabNativeBindingChanges $network $SourceDirectory
        Write-LabNetworkChanges (@($settings) + @($bindings.plans)) $network
    }
    Assert-LabNetworkPrepared $network
    Write-Output "PASS: $($network.Mode) game configuration at $($network.ServerAddress); SQL/Buddy stay loopback. No process, firewall, adapter or registry changes."
}
