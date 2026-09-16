#requires -Version 7.0
[CmdletBinding()]
param([Alias('SourceDirectory')][string]$BindingSourceDirectory, [Alias('Check')][switch]$CheckBindings)
$ErrorActionPreference = 'Stop'

function Get-LabNativeHashes {
    @{
        'Server8360\Gunboundserv3.exe' = @{
            original='d82513950d4db08be664d538e09e5b00a07c795d76a0a7ed0eede8a8553fa511'
            legacy='00dae3201695a5e543801305c0c2b74052ef61adc921e978db817302164f50e7'
        }
        'Central\GunBoundBroker3.exe' = @{
            original='db6f6765aef74c702ceb6ae035fa022f3d309670d804e4679a681781fb448a63'
            legacy='4495498cd4267e175dcd3475699346bee9d948155418d7a24ee71221fd55d0bd'
        }
    }
}

function New-LabNativeBindingPlan([byte[]]$Original, [string]$Relative, [string]$BindAddress, [switch]$DisableBrokerIdleTimeout) {
    $known = (Get-LabNativeHashes)[$Relative]
    $hash = [RetroClientBuild.ClientPatch]::Hash($Original)
    if (!$known -or $hash -cne $known.original) { throw 'Only the two exact supplied native core images are supported.' }
    if ($BindAddress -cne '127.0.0.1' -and ![RetroClientBuild.NetworkProfile]::IsPrivateIPv4($BindAddress)) {
        throw 'Native game bindings require loopback or canonical RFC1918 IPv4.'
    }
    if ($DisableBrokerIdleTimeout -and
        ($Relative -cne 'Central\GunBoundBroker3.exe' -or $BindAddress -ceq '127.0.0.1')) {
        throw 'Disabling idle expiry is supported only for the identified private broker.'
    }
    $addressBytes = [Net.IPAddress]::Parse($BindAddress).GetAddressBytes()
    $bytes = [byte[]]$Original.Clone()
    $reverts = @()
    $pe = [BitConverter]::ToInt32($bytes, 60)
    $opt = $pe + 24
    if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x14c -or
        [BitConverter]::ToUInt16($bytes, $opt) -ne 0x10b -or
        [BitConverter]::ToUInt32($bytes, $opt + 140) -ne 0 -or
        [BitConverter]::ToUInt32($bytes, $opt + 132) -ne 0) {
        throw 'Only the supplied unsigned, non-relocating x86 images are supported.'
    }
    $base = [BitConverter]::ToUInt32($bytes, $opt + 28)
    $sectionHeaders = $opt + [BitConverter]::ToUInt16($bytes, $pe + 20)
    $sections = for ($i = 0; $i -lt [BitConverter]::ToUInt16($bytes, $pe + 6); $i++) {
        $offset = $sectionHeaders + 40 * $i
        [pscustomobject]@{
            name = [Text.Encoding]::ASCII.GetString($bytes, $offset, 8).Trim([char]0)
            header = $offset
            rva = [BitConverter]::ToUInt32($bytes, $offset + 12)
            virtualSize = [BitConverter]::ToUInt32($bytes, $offset + 8)
            raw = [BitConverter]::ToUInt32($bytes, $offset + 20)
            rawSize = [BitConverter]::ToUInt32($bytes, $offset + 16)
        }
    }
    function Get-Offset([uint32]$Rva) {
        foreach ($section in $sections) {
            if ($Rva -ge $section.rva -and $Rva -lt $section.rva + $section.rawSize) { return [int]($Rva - $section.rva + $section.raw) }
        }
        throw 'Import RVA is outside the image.'
    }
    function Get-CString([int]$Offset) {
        $end = $Offset
        while ($end -lt $bytes.Length -and $bytes[$end]) { $end++ }
        if ($end -eq $bytes.Length) { throw 'Unterminated image string.' }
        [Text.Encoding]::ASCII.GetString($bytes, $Offset, $end - $Offset)
    }
    $imports = @{}
    $directory = Get-Offset ([BitConverter]::ToUInt32($bytes, $opt + 104))
    for ($entry = $directory; [BitConverter]::ToUInt32($bytes, $entry + 12); $entry += 20) {
        $dll = Get-CString (Get-Offset ([BitConverter]::ToUInt32($bytes, $entry + 12)))
        if ($dll -notmatch '^(WS2_32|WSOCK32|KERNEL32)\.dll$') { continue }
        $lookup = [BitConverter]::ToUInt32($bytes, $entry)
        $iat = [BitConverter]::ToUInt32($bytes, $entry + 16)
        if (!$lookup) { $lookup = $iat }
        $lookupOffset = Get-Offset $lookup
        for ($i = 0; $value = [BitConverter]::ToUInt32($bytes, $lookupOffset + 4 * $i); $i++) {
            $name = if ($value -band 0x80000000) {
                switch ($value -band 65535) { 2 { 'bind' } 20 { 'sendto' } 111 { 'WSAGetLastError' } default { '' } }
            } else { Get-CString ((Get-Offset $value) + 2) }
            if ($name -in @('bind','sendto','WSAGetLastError','GetModuleHandleA','GetProcAddress')) { $imports[$name] = [uint32]($base + $iat + 4 * $i) }
        }
    }
    if (!$imports.ContainsKey('bind')) { throw 'Expected Winsock bind import is missing.' }
    $text = $sections | Where-Object name -eq '.text'
    $cursor = [int](($text.virtualSize + 15) -band -16)
    $patches = @()

    # The wrappers copy sockaddr_in to the stack; caller memory and socket ports are unchanged.
    $bindCode = [byte[]](('55 8B EC 83 EC 10 56 57 83 7D 10 10 75 35 8B 75 0C 85 F6 74 2E 66 83 3E 02 75 28 8D 7D F0 B9 04 00 00 00 F3 A5 C7 45 F4 7F 00 00 01 6A 10 8D 45 F0 50 FF 75 08 FF 15 00 00 00 00 5F 5E 8B E5 5D C2 0C 00 5F 5E 8B E5 5D FF 25 00 00 00 00' -split ' ') | ForEach-Object { [Convert]::ToByte($_, 16) })
    [Array]::Copy($addressBytes, 0, $bindCode, 40, 4)
    [Array]::Copy([BitConverter]::GetBytes($imports.bind), 0, $bindCode, 55, 4)
    [Array]::Copy([BitConverter]::GetBytes($imports.bind), 0, $bindCode, 74, 4)
    $wrappers = @([pscustomobject]@{ name='bind'; code=$bindCode })
    if ($relative -like 'Central\*') {
        if (!$imports.ContainsKey('sendto')) { throw 'Expected broker sendto import is missing.' }
        # The broker otherwise lets sendto implicitly create a wildcard UDP binding.
        $sendCode = [byte[]](('55 8B EC 83 EC 10 31 C0 89 45 F0 89 45 F4 89 45 F8 89 45 FC C6 45 F0 02 C7 45 F4 7F 00 00 01 6A 10 8D 45 F0 50 FF 75 08 FF 15 00 00 00 00 8B E5 5D FF 25 00 00 00 00' -split ' ') | ForEach-Object { [Convert]::ToByte($_, 16) })
        [Array]::Copy($addressBytes, 0, $sendCode, 27, 4)
        [Array]::Copy([BitConverter]::GetBytes($imports.bind), 0, $sendCode, 42, 4)
        [Array]::Copy([BitConverter]::GetBytes($imports.sendto), 0, $sendCode, 51, 4)
        if ($BindAddress -cne '127.0.0.1') {
            foreach ($api in @('WSAGetLastError','GetModuleHandleA','GetProcAddress')) {
                if (!$imports.ContainsKey($api)) { throw "Expected private broker $api import is missing." }
            }
            $sendRva = $text.rva + (($cursor + $bindCode.Length + 15) -band -16)
            $sendCode = [RetroClientBuild.ClientPatch]::BuildPrivateBrokerSendTo(
                [uint32]($base + $sendRva), $BindAddress, $imports.bind, $imports.sendto,
                $imports.WSAGetLastError, $imports.GetModuleHandleA, $imports.GetProcAddress)
        }
        $wrappers += [pscustomobject]@{ name='sendto'; code=$sendCode }
    }
    foreach ($wrapper in $wrappers) {
        if ($cursor + $wrapper.code.Length -gt $text.rawSize) { throw 'Insufficient existing executable padding; no image sections will be added.' }
        $needle = [BitConverter]::GetBytes($imports[$wrapper.name])
        $sites = @(
            for ($at = [int]$text.raw + 2; $at -lt $text.raw + $text.virtualSize - 4; $at++) {
                if ($bytes[$at] -eq $needle[0] -and $bytes[$at+1] -eq $needle[1] -and $bytes[$at+2] -eq $needle[2] -and $bytes[$at+3] -eq $needle[3]) {
                    if ($bytes[$at-2] -ne 0xff -or $bytes[$at-1] -notin @(0x15,0x25)) { throw 'Unrecognized Winsock import reference; refusing an unsafe patch.' }
                    $at - 2
                }
            }
        )
        if (!$sites.Count) { throw "No supported $($wrapper.name) call site found." }
        $stub = [int]($text.raw + $cursor)
        if (@($bytes[$stub..($stub + $wrapper.code.Length - 1)] | Where-Object { $_ -notin @(0,0xcc) }).Count) { throw 'Executable padding contains data; refusing to overwrite it.' }
        foreach ($site in $sites) {
            $reverts += [ordered]@{ offset=$site; originalHex=[BitConverter]::ToString($bytes, $site, 6).Replace('-', '') }
            $bytes[$site] = if ($bytes[$site+1] -eq 0x15) { 0xe8 } else { 0xe9 }
            [Array]::Copy([BitConverter]::GetBytes([int]($stub - $site - 5)), 0, $bytes, $site + 1, 4)
            $bytes[$site + 5] = 0x90
        }
        $reverts += [ordered]@{ offset=$stub; originalHex=[BitConverter]::ToString($bytes, $stub, $wrapper.code.Length).Replace('-', '') }
        [Array]::Copy($wrapper.code, 0, $bytes, $stub, $wrapper.code.Length)
        $patches += [pscustomobject]@{ api=$wrapper.name; callSites=$sites; stubOffset=$stub; stubLength=$wrapper.code.Length }
        $cursor = ($cursor + $wrapper.code.Length + 15) -band -16
    }
    $reverts += [ordered]@{ offset=($text.header + 8); originalHex=[BitConverter]::ToString($bytes, $text.header + 8, 4).Replace('-', '') }
    [Array]::Copy([BitConverter]::GetBytes([uint32]$cursor), 0, $bytes, $text.header + 8, 4)
    if ($DisableBrokerIdleTimeout) {
        $idle = Get-Offset 0x50fc
        [RetroClientBuild.ClientPatch]::RequireBytes($bytes, $idle - 6, [Convert]::FromHexString('56FF500C84C0745C837E10FF'))
        # ponytail: this verified broker alone skips idle closure; new binaries need a new native profile.
        $reverts += [ordered]@{ offset=$idle; originalHex='745C' }
        $bytes[$idle] = 0xeb
    }
    $record = [ordered]@{
        schemaVersion=2; bindAddress=$BindAddress; brokerIdleTimeoutDisabled=[bool]$DisableBrokerIdleTimeout
        file=$relative; originalSha256=$hash
        patchedSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        purpose="Force native game IPv4 TCP/UDP bindings to $BindAddress; preserve ports, SQL, protocol, and original source files."
        patches=$patches; reverts=$reverts
    }
    if ($DisableBrokerIdleTimeout) {
        $record.purpose += ' Disable private broker idle expiry only; retain native socket-error cleanup and shutdown.'
    }
    [pscustomobject]@{ bytes=$bytes; record=$record }
}

function Restore-LabNativeSource([byte[]]$Current, $Record) {
    $known = (Get-LabNativeHashes)[$Record.file]
    if (!$known -or $Record.schemaVersion -ne 2 -or $Record.originalSha256 -cne $known.original -or
        [RetroClientBuild.ClientPatch]::Hash($Current) -cne $Record.patchedSha256 -or
        @($Record.reverts).Count -lt 3 -or @($Record.reverts).Count -gt 32) {
        throw 'Invalid native patch provenance; no byte replacement is permitted.'
    }
    $original = [byte[]]$Current.Clone()
    foreach ($edit in $Record.reverts) {
        if ($edit.originalHex -cnotmatch '^(?:[0-9A-F]{2}){1,512}$') { throw 'Invalid native recovery bytes.' }
        $restore = [Convert]::FromHexString($edit.originalHex)
        $at = [int]$edit.offset
        if ($at -lt 0 -or $at -gt $original.Length - $restore.Length) { throw 'Native recovery range is outside the image.' }
        [Array]::Copy($restore, 0, $original, $at, $restore.Length)
    }
    if ([RetroClientBuild.ClientPatch]::Hash($original) -cne $known.original) {
        throw 'Recovered native source does not match the supplied original SHA256.'
    }
    if ($null -ne $Record.brokerIdleTimeoutDisabled -and $Record.brokerIdleTimeoutDisabled -isnot [bool]) {
        throw 'Invalid broker idle-expiry policy in native patch provenance.'
    }
    $previous = New-LabNativeBindingPlan $original $Record.file $Record.bindAddress -DisableBrokerIdleTimeout:([bool]$Record.brokerIdleTimeoutDisabled)
    if ($previous.record.patchedSha256 -cne $Record.patchedSha256) {
        throw 'The current native image cannot be reproduced from its guarded source and recorded address.'
    }
    return ,$original
}

function Get-LabNativeBindingChanges($Network, [string]$SourceDirectory, [switch]$VerifyOnly) {
    $manifest = Get-Content -LiteralPath "$PSScriptRoot\manifest.json" -Raw | ConvertFrom-Json
    $recordPath = "$PSScriptRoot\loopback-patches.json"
    [byte[]]$priorBytes = if (Test-Path -LiteralPath $recordPath) { [IO.File]::ReadAllBytes($recordPath) } else { $null }
    $priorHash = if ($null -ne $priorBytes) { [RetroClientBuild.ClientPatch]::Hash($priorBytes) } else { $null }
    $prior = if ($null -ne $priorBytes) { @([Text.Encoding]::UTF8.GetString($priorBytes).TrimStart([char]0xfeff) | ConvertFrom-Json) } else { @() }
    if (@($prior | Where-Object { $_.file -cnotin @('Server8360\Gunboundserv3.exe','Central\GunBoundBroker3.exe') }).Count -or
        @($prior | Group-Object file | Where-Object Count -NE 1).Count) { throw 'Unexpected or duplicate native patch provenance entries.' }
    $plans = @()
    $records = @()
    foreach ($relative in @('Server8360\Gunboundserv3.exe','Central\GunBoundBroker3.exe')) {
        $path = "$PSScriptRoot\native\$relative"
        $known = (Get-LabNativeHashes)[$relative]
        $disableBrokerIdleTimeout = $Network.IsPrivate -and $relative -ceq 'Central\GunBoundBroker3.exe'
        if ($manifest.nativeBackend.binaries.((Split-Path $path -Leaf)) -cne $known.original) {
            throw 'The native source manifest no longer matches the supported binaries.'
        }
        $current = [IO.File]::ReadAllBytes($path)
        $hash = [RetroClientBuild.ClientPatch]::Hash($current)
        $original = $null
        if ($hash -ceq $known.original) {
            if ($VerifyOnly) { throw "Native bindings are not prepared: $relative." }
            $original = $current
        } else {
            $matches = @($prior | Where-Object file -ceq $relative)
            if ($matches.Count -ne 1 -or $matches[0].patchedSha256 -cne $hash -or $matches[0].originalSha256 -cne $known.original) {
                throw "Unrecognized native image or missing provenance: $relative. No patch applied."
            }
            $existing = $matches[0]
            $oldAddress = '127.0.0.1'
            if ('schemaVersion' -in $existing.PSObject.Properties.Name -and $existing.schemaVersion -ne 2) {
                throw 'Unsupported native patch provenance version.'
            }
            if ($existing.schemaVersion -eq 2) {
                $original = Restore-LabNativeSource $current $existing
                $oldAddress = $existing.bindAddress
            } elseif ($hash -cne $known.legacy -or ($existing.bindAddress -and $existing.bindAddress -cne $oldAddress)) {
                throw 'Only the exact recorded legacy loopback patch can be upgraded with an original source.'
            }
            if ($oldAddress -ceq $Network.ServerAddress -and
                [bool]$existing.brokerIdleTimeoutDisabled -eq $disableBrokerIdleTimeout) { $records += $existing; continue }
            if ($VerifyOnly) { throw 'Native bindings or private broker idle policy differ from network.json. Stop Core and run backend\network-config.ps1 -Prepare.' }
            if (!$original) {
                if (!$SourceDirectory) { throw 'The first legacy mode change requires -SourceDirectory pointing to the read-only original GunBoundXP folder.' }
                $original = [IO.File]::ReadAllBytes((Join-Path $SourceDirectory $relative))
                $previous = New-LabNativeBindingPlan $original $relative $oldAddress
                if ($previous.record.patchedSha256 -cne $hash) { throw 'The supplied source does not reproduce the existing native patch.' }
            }
        }
        $next = New-LabNativeBindingPlan $original $relative $Network.ServerAddress -DisableBrokerIdleTimeout:$disableBrokerIdleTimeout
        $records += $next.record
        $plans += [pscustomobject]@{ path=$path; beforeSha256=$hash; bytes=$next.bytes }
    }
    if ($plans.Count) {
        $plans += [pscustomobject]@{
            path=$recordPath; beforeSha256=$priorHash
            bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $records -Depth 8) + "`r`n")
        }
    }
    [pscustomobject]@{ plans=$plans; records=$records }
}

if ($MyInvocation.InvocationName -ne '.') {
    . "$PSScriptRoot\network-config.ps1"
    $network = Get-LabNetwork
    if ($CheckBindings) {
        Get-LabNativeBindingChanges $network -VerifyOnly | Out-Null
        Write-Output "PASS: guarded native game bindings match $($network.ServerAddress)."
    } else {
        Assert-LabCoreStopped
        $changes = Get-LabNativeBindingChanges $network $BindingSourceDirectory
        Write-LabNetworkChanges $changes.plans $network
        Write-Output "Lab-only native game bindings configured for $($network.ServerAddress). No firewall, adapter, SQL or original-source changes."
    }
}
