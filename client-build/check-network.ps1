#requires -Version 7.0
[CmdletBinding()]
param([string]$NativeSourceDirectory)
$ErrorActionPreference = 'Stop'
$lab = Split-Path $PSScriptRoot
$backend = "$lab\backend"
$work = "$PSScriptRoot\work\network-" + [Guid]::NewGuid().ToString('N')
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
function Assert-Check([bool]$Condition, [string]$Name) { if (!$Condition) { throw $Name } }
function Assert-Rejected([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Check $rejected "Expected rejection: $Name"
}
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:TEMP = $work
$env:TMP = $work
try {
    foreach ($name in @('network-config.ps1','bind-loopback.ps1','start.ps1','health.ps1')) {
        $tokens = $null; $errors = $null
        $parsed = [Management.Automation.Language.Parser]::ParseFile("$backend\$name", [ref]$tokens, [ref]$errors)
        Assert-Check (!$errors) "PowerShell syntax error in $name"
        if ($name -ceq 'start.ps1') { $startAst = $parsed }
    }
    Add-Type -Path "$PSScriptRoot\ClientPatch.cs"
    $BindingSourceDirectory = 'binding-source-marker'; $CheckBindings = $true
    . "$backend\network-config.ps1"
    Assert-Check ($BindingSourceDirectory -ceq 'binding-source-marker' -and $CheckBindings) 'Loading configuration helpers overwrote binding CLI options'
    $SourceDirectory = 'configuration-source-marker'; $Check = $true; $Prepare = $true
    . "$backend\bind-loopback.ps1"
    Assert-Check ($SourceDirectory -ceq 'configuration-source-marker' -and $Check -and $Prepare) 'Loading binding helpers overwrote configuration CLI options'
    $loopback = [RetroClientBuild.NetworkProfile]::Loopback
    $privateNetwork = [RetroClientBuild.NetworkProfile]::Create('private', '192.168.56.1', '192.168.56.1', '192.168.56.10')
    $botServerNetwork = [RetroClientBuild.NetworkProfile]::Parse('{"schemaVersion":1,"mode":"private","serverAddress":"192.168.56.10","humanAddress":"192.168.56.1","botAddress":"192.168.56.10"}')
    $peerJson = '["192.168.56.10","192.168.56.11","192.168.56.12"]'
    $sharedJson = '{"schemaVersion":2,"mode":"private","serverAddress":"192.168.56.10","humanAddress":"192.168.56.1","botAddress":"192.168.56.11","botAddresses":' + $peerJson + '}'
    $sharedNetwork = [RetroClientBuild.NetworkProfile]::Parse($sharedJson)
    $instances = @($sharedNetwork.BotAddresses | ForEach-Object {
        [RetroClientBuild.NetworkProfile]::Parse($sharedJson.Replace('"botAddress":"192.168.56.11"', '"botAddress":"' + $_ + '"'))
    })
    $singleBotNetwork = [RetroClientBuild.NetworkProfile]::Parse($sharedJson.Replace('"botAddress":"192.168.56.11"', '"botAddress":"192.168.56.10"').Replace($peerJson, '["192.168.56.10"]'))
    $twoBotNetwork = [RetroClientBuild.NetworkProfile]::Parse($sharedJson.Replace($peerJson, '["192.168.56.10","192.168.56.11"]'))
    $v1PrivateHashes = @{
        'human-01000000' = @('874780e5b7afa61e6bc8443e95bd59250d060fb32f747ba33106fe0c43076d37','c3d2286c8f9bfc74e4f3afb47bffc37ef1bdf2b4cf6ac502c9372e00d317ad7b')
        'human-02000000' = @('874780e5b7afa61e6bc8443e95bd59250d060fb32f747ba33106fe0c43076d37','f2bed45107dd324023653f7870678dba4828072649d51a85c13a716ad6710110')
        'bot-01000000' = @('170762b93444e5cc0925eb9bb6d14b5621d509a0069c2a343f9cb7c8e12c744f','8c198a6d799fc14f55f1de0ba1744dfdede6522cd31053375d39b7b6be914e63')
        'bot-02000000' = @('322f946c8097430dde3550f14d8fd69cb351caf1d4b92c243a2fb3bd17e49ee8','1337430c9777698dd71e363057ef454fbdc66e990ce888cb94513ca291ffb422')
    }
    Assert-Check (![RetroClientBuild.NetworkProfile]::Load($work).IsPrivate) 'Missing profile must preserve loopback'
    $source = "$lab\client-image\GunBound.gme"
    $original = [IO.File]::ReadAllBytes($source)
    $sourceHash = [RetroClientBuild.ClientPatch]::Hash($original)
    $manifest = Get-Content -LiteralPath "$PSScriptRoot\manifest.json" -Raw | ConvertFrom-Json
    foreach ($role in @('human','bot')) {
        $record = Get-Content -LiteralPath "$PSScriptRoot\$role\patches.json" -Raw | ConvertFrom-Json
        $arena = [Convert]::ToUInt32($record.arenaBase.Substring(2), 16)
        foreach ($plan in @(
            [RetroClientBuild.ClientPatch]::Build($original, $role, $arena),
            [RetroClientBuild.ClientPatch]::Build($original, $role, $arena, $loopback)
        )) {
            Assert-Check ([RetroClientBuild.ClientPatch]::Hash($plan.Arena) -ceq $record.codeSha256) "$role default code changed"
            Assert-Check ([RetroClientBuild.ClientPatch]::Hash($plan.ImageModel) -ceq $record.imageModelSha256) "$role default model changed"
            foreach ($edit in $plan.Edits) {
                $staged = $record.patches | Where-Object fileOffset -EQ $edit.Rva
                Assert-Check ($edit.Purpose -ceq $staged.purpose) "$role default patch provenance changed"
            }
            if ($plan.InitialTrace) { Assert-Check ([RetroClientBuild.ClientPatch]::Hash($plan.InitialTrace) -ceq $record.initialTraceSha256) 'Default trace changed' }
        }
        foreach ($placement in @($privateNetwork) + $instances) {
            foreach ($arenaBase in @([RetroClientBuild.ClientPatch]::DefaultArena, [uint32]0x02000000)) {
                $plan = [RetroClientBuild.ClientPatch]::Build($original, $role, $arenaBase, $placement)
                [RetroClientBuild.ClientPatch]::RequireBytes($plan.ImageModel, 0, [byte[]]$original[0..4095])
                [RetroClientBuild.ClientPatch]::RequireBytes($plan.ImageModel, 0x47053c, [byte[]]$original[0x47053c..0x47054b])
                [RetroClientBuild.ClientPatch]::RequireBytes($plan.ImageModel, 0xc3d7, [byte[]]$original[0xc3d7..0xc3f1])
                foreach ($edit in $plan.Edits) { [RetroClientBuild.ClientPatch]::RequireBytes($original, [int]$edit.Rva, $edit.Expected) }
                if ($placement.SchemaVersion -eq 1) {
                    $knownPrivate = $v1PrivateHashes["$role-$($arenaBase.ToString('x8'))"]
                    Assert-Check ([RetroClientBuild.ClientPatch]::Hash($plan.Arena) -ceq $knownPrivate[0] -and
                        [RetroClientBuild.ClientPatch]::Hash($plan.ImageModel) -ceq $knownPrivate[1]) 'v1 private native bytes changed'
                }
                if ($role -eq 'bot') {
                    Assert-Check ([RetroClientBuild.ClientPatch]::Hash($plan.InitialTrace) -ceq $record.initialTraceSha256) 'Bot initial trace bytes changed'
                    $expectedMutex = 'SoftnyxGunBound.bot'
                    if ($placement.SchemaVersion -eq 2) { $expectedMutex += '.' + [Convert]::ToHexString([Net.IPAddress]::Parse($placement.BotAddress).GetAddressBytes()).ToLowerInvariant() }
                    Assert-Check ($plan.MutexName -ceq $expectedMutex -and $plan.MutexName.Length -le 31) 'Native mutex name is not stable and bounded'
                    foreach ($offset in @(0xc3c2,0x1344e)) {
                        Assert-Check ([BitConverter]::ToUInt32($plan.ImageModel,$offset) -eq $arenaBase + $plan.Entries['bot_mutex_name']) 'Private arena mutex relocation changed'
                    }
                }
            }
        }
    }
    foreach ($artifact in @(@('RetroClientPatch.dll','integrationDllSha256'),@('check-native.exe','checkerSha256'))) {
        Assert-Check ((Get-FileHash -LiteralPath "$PSScriptRoot\$($artifact[0])" -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $manifest.($artifact[1])) 'Staged executable hash changed'
    }
    $changed = [byte[]]$original.Clone(); $changed[0x2000] = $changed[0x2000] -bxor 1
    Assert-Rejected { [RetroClientBuild.ClientPatch]::Build($changed, 'bot', 0x01000000, $privateNetwork) } 'altered client image'
    Assert-Rejected { [RetroClientBuild.ClientPatch]::Build($original, 'bot', 0x00400000, $privateNetwork) } 'overlapping private arena'
    $sharedPlans = @($instances | ForEach-Object { [RetroClientBuild.ClientPatch]::Build($original, 'bot', 0x01000000, $_) })
    Assert-Check (@($sharedPlans.MutexName | Select-Object -Unique).Count -eq 3 -and
        @($sharedPlans | ForEach-Object { [RetroClientBuild.ClientPatch]::Hash($_.Arena) } | Select-Object -Unique).Count -eq 3) 'Shared guest bots lost independent mutex/source bytes'
    $reorderedNetwork = [RetroClientBuild.NetworkProfile]::Parse($sharedJson.Replace($peerJson, '["192.168.56.12","192.168.56.10","192.168.56.11"]'))
    $reorderedPlan = [RetroClientBuild.ClientPatch]::Build($original, 'bot', 0x02000000, $reorderedNetwork)
    Assert-Check ($reorderedPlan.MutexName -ceq $sharedPlans[1].MutexName) 'Peer ordering or relocation changed the instance mutex identity'
    Write-Output 'PASS exact staged v1 default/private models/code/trace/provenance; three v2 identities, stable mutexes and relocation/startup guards.'

    foreach ($relative in @('Server8360\Gunboundserv3.exe','Central\GunBoundBroker3.exe')) {
        if (!$NativeSourceDirectory) { throw 'Pass -NativeSourceDirectory with the read-only supplied GunBoundXP directory for offline native provenance checks.' }
        $path = Join-Path $NativeSourceDirectory $relative
        $nativeSource = [IO.File]::ReadAllBytes($path)
        $known = (Get-LabNativeHashes)[$relative]
        $default = New-LabNativeBindingPlan $nativeSource $relative '127.0.0.1'
        Assert-Check ($default.record.patchedSha256 -ceq $known.legacy) 'Legacy backend patch bytes changed'
        foreach ($address in @($privateNetwork.ServerAddress,$botServerNetwork.ServerAddress,'10.40.50.1')) {
            $privatePlan = New-LabNativeBindingPlan $nativeSource $relative $address
            $oldRecord = $privatePlan.record | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $oldRecord.PSObject.Properties.Remove('brokerIdleTimeoutDisabled')
            Assert-Check ([RetroClientBuild.ClientPatch]::Hash((Restore-LabNativeSource $privatePlan.bytes $oldRecord)) -ceq $known.original) 'Prior native provenance cannot be upgraded'
            if ($relative -ceq 'Central\GunBoundBroker3.exe') {
                $keepOpen = New-LabNativeBindingPlan $nativeSource $relative $address -DisableBrokerIdleTimeout
                $changedOffsets = @(for ($i = 0; $i -lt $privatePlan.bytes.Length; $i++) {
                    if ($privatePlan.bytes[$i] -ne $keepOpen.bytes[$i]) { $i }
                })
                Assert-Check ($changedOffsets.Count -eq 1 -and $changedOffsets[0] -eq 0x50fc) 'Keeping the broker open changed more than its idle-only branch'
                [RetroClientBuild.ClientPatch]::RequireBytes($keepOpen.bytes, 0x50fc, [Convert]::FromHexString('EB5C'))
                Assert-Check ([RetroClientBuild.ClientPatch]::Hash((Restore-LabNativeSource $keepOpen.bytes $keepOpen.record)) -ceq $known.original) 'Idle-policy rollback did not recover the exact native source'
                $falsePolicy = $keepOpen.record | ConvertTo-Json -Depth 8 | ConvertFrom-Json
                $falsePolicy.brokerIdleTimeoutDisabled = $false
                Assert-Rejected { Restore-LabNativeSource $keepOpen.bytes $falsePolicy } 'forged broker idle policy'
                $falsePolicy.brokerIdleTimeoutDisabled = 'true'
                Assert-Rejected { Restore-LabNativeSource $keepOpen.bytes $falsePolicy } 'non-boolean broker idle policy'
            } else {
                Assert-Rejected { New-LabNativeBindingPlan $nativeSource $relative $address -DisableBrokerIdleTimeout } 'world idle-policy changes'
            }
            $recovered = Restore-LabNativeSource $privatePlan.bytes $privatePlan.record
            $again = New-LabNativeBindingPlan $recovered $relative '127.0.0.1'
            Assert-Check ($again.record.patchedSha256 -ceq $known.legacy) 'Guarded private-to-loopback reconstruction failed'
            $stub = $privatePlan.record.patches | Where-Object api -EQ 'bind'
            [RetroClientBuild.ClientPatch]::RequireBytes($privatePlan.bytes, $stub.stubOffset + 40, [Net.IPAddress]::Parse($address).GetAddressBytes())
            $corrupt = [byte[]]$privatePlan.bytes.Clone()
            $corrupt[$stub.stubOffset] = $corrupt[$stub.stubOffset] -bxor 1
            $falseRecord = $privatePlan.record | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $falseRecord.patchedSha256 = [RetroClientBuild.ClientPatch]::Hash($corrupt)
            Assert-Rejected { Restore-LabNativeSource $corrupt $falseRecord } 'forged native patch provenance'
        }
        $corrupt = [byte[]]$nativeSource.Clone(); $corrupt[0x2000] = $corrupt[0x2000] -bxor 1
        Assert-Rejected { New-LabNativeBindingPlan $corrupt $relative '192.168.56.1' } 'modified native source'
        Assert-Rejected { New-LabNativeBindingPlan $nativeSource $relative '8.8.8.8' } 'public native binding'
        Assert-Rejected { New-LabNativeBindingPlan $nativeSource $relative '127.0.0.1' -DisableBrokerIdleTimeout } 'loopback idle-policy changes'
        Assert-Check ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $known.original) 'Original native source changed'
    }
    Write-Output 'PASS native default hashes, private bindings and idle-only policy, prior provenance upgrades, reversible recovery, and forged-source/patch rejection.'

    $text = "Port=8360`r`nAccept=127.0.0.1;127.0.0.2;`r`nUserDB_Host=127.0.0.1`r`nUserDB_Port=3308`r`nUnrelated=$([char]255)do-not-alter`r`n"
    $bytes = [Text.Encoding]::Latin1.GetBytes($text)
    $next = Convert-LabNetworkSettingBytes $bytes 'Accept' '192.168.56.1;192.168.56.10;' 8360
    Assert-Check ([Text.Encoding]::Latin1.GetString($next) -ceq $text.Replace('Accept=127.0.0.1;127.0.0.2;', 'Accept=192.168.56.1;192.168.56.10;')) 'Unrelated native bytes changed'
    $back = Convert-LabNetworkSettingBytes $next 'Accept' '127.0.0.1;127.0.0.2;' 8360
    Assert-Check ([RetroClientBuild.ClientPatch]::Hash($back) -ceq [RetroClientBuild.ClientPatch]::Hash($bytes)) 'Settings round-trip changed bytes'
    foreach ($invalid in @($text.Replace('3308','3307'), $text.Replace('UserDB_Host=127.0.0.1','UserDB_Host=192.168.56.1'),
        $text.Replace('8360','8361'), ($text + "Accept=127.0.0.1;`r`n"), $text.Replace('127.0.0.2;', '8.8.8.8;'))) {
        Assert-Rejected { Convert-LabNetworkSettingBytes ([Text.Encoding]::Latin1.GetBytes($invalid)) 'Accept' '192.168.56.1;192.168.56.10;' 8360 } 'unsafe native settings'
    }
    $worldText = "Local Practice;GunBound AI Lab;127.0.0.1;8360;0;`r`n"
    $worldBytes = [Text.Encoding]::Latin1.GetBytes($worldText)
    foreach ($placement in @($privateNetwork,$botServerNetwork)) {
        $nextWorld = Convert-LabWorldListBytes $worldBytes $placement.ServerAddress
        Assert-Check ([Text.Encoding]::Latin1.GetString($nextWorld) -ceq $worldText.Replace('127.0.0.1',$placement.ServerAddress)) 'World metadata or selected server address changed'
    }
    foreach ($invalid in @($worldText + $worldText, $worldText.Replace('8360','8372'), $worldText.Replace('127.0.0.1','8.8.8.8'))) {
        Assert-Rejected { Convert-LabWorldListBytes ([Text.Encoding]::Latin1.GetBytes($invalid)) '192.168.56.1' } 'unsupported world list'
    }
    Write-Output 'PASS native setting/world-list byte preservation and fixed local SQL/port guards (synthetic bytes only).'

    function Get-NetTCPConnection {
        [CmdletBinding()]param($State, $OwningProcess, [int[]]$LocalPort)
        $testTcp | Where-Object { (!$PSBoundParameters.ContainsKey('OwningProcess') -or $_.OwningProcess -eq $OwningProcess) -and
            (!$LocalPort -or $_.LocalPort -in $LocalPort) }
    }
    function Get-NetUDPEndpoint {
        [CmdletBinding()]param($OwningProcess, [int[]]$LocalPort)
        $testUdp | Where-Object { (!$PSBoundParameters.ContainsKey('OwningProcess') -or $_.OwningProcess -eq $OwningProcess) -and
            (!$LocalPort -or $_.LocalPort -in $LocalPort) }
    }
    $entry = [pscustomobject]@{ name='world'; pid=123; port=8360; extraPorts=@() }
    $testTcp = @([pscustomobject]@{ OwningProcess=123; LocalAddress='192.168.56.1'; LocalPort=8360 })
    $testUdp = @([pscustomobject]@{ OwningProcess=123; LocalAddress='192.168.56.1'; LocalPort=8360 })
    Assert-Check (@(Assert-LabServiceEndpoints $entry $privateNetwork).Count -eq 1) 'Configured world listeners rejected'
    Assert-Rejected { Assert-LabServiceEndpoints $entry $botServerNetwork } 'host listener under a bot-hosted server profile'
    $testTcp[0].LocalAddress = $testUdp[0].LocalAddress = $botServerNetwork.ServerAddress
    Assert-Check (@(Assert-LabServiceEndpoints $entry $botServerNetwork).Count -eq 1) 'Bot-hosted world listeners rejected'
    $testTcp[0].OwningProcess = 999
    Assert-Rejected { Assert-LabServiceEndpoints $entry $botServerNetwork } 'unowned bot-hosted world listener'
    $testTcp[0].OwningProcess = 123
    $testTcp[0].LocalAddress = $testUdp[0].LocalAddress = $privateNetwork.ServerAddress
    $testTcp[0].LocalAddress = '0.0.0.0'
    Assert-Rejected { Assert-LabServiceEndpoints $entry $privateNetwork } 'wildcard TCP'
    $testTcp[0].LocalAddress = '192.168.56.1'; $testUdp[0].LocalAddress = '127.0.0.1'
    Assert-Rejected { Assert-LabServiceEndpoints $entry $privateNetwork } 'wrong world UDP address'
    $testUdp[0].LocalAddress = '192.168.56.1'; $testUdp[0].LocalPort = 8363
    Assert-Rejected { Assert-LabServiceEndpoints $entry $privateNetwork } 'wrong world UDP port'
    $testUdp = @()
    Assert-Check (@(Assert-LabServiceEndpoints $entry $privateNetwork -AllowStarting).Count -eq 0) 'TCP-only process was considered ready'
    Assert-Rejected { Assert-LabServiceEndpoints $entry $privateNetwork } 'missing world UDP'
    $entry = [pscustomobject]@{ name='mariadb'; pid=123; port=3307; extraPorts=@() }
    $testTcp[0].LocalPort = 3307
    Assert-Rejected { Assert-LabServiceEndpoints $entry $privateNetwork } 'private SQL exposure'
    $testTcp[0].LocalAddress = '127.0.0.1'
    Assert-Check (@(Assert-LabServiceEndpoints $entry $privateNetwork).Count -eq 1) 'Loopback database rejected'
    Assert-Check (@(Assert-LabServiceEndpoints $entry $botServerNetwork).Count -eq 1) 'Bot-hosted server changed SQL loopback policy'
    $testTcp += [pscustomobject]@{ OwningProcess=999; LocalAddress='192.168.56.1'; LocalPort=3307 }
    Assert-Rejected { Assert-LabServiceEndpoints $entry $privateNetwork } 'unowned SQL listener'
    Remove-Item Function:\Get-NetTCPConnection,Function:\Get-NetUDPEndpoint
    Write-Output 'PASS listener/readiness policy with mocked endpoints; no network-policy or live-state queries.'

    $isolatedBackend = "$work\backend"
    New-Item -ItemType Directory -Path "$isolatedBackend\native\Server8360","$isolatedBackend\native\Central",
        "$isolatedBackend\native\BuddyCenter","$isolatedBackend\native\BuddyServ" -Force | Out-Null
    Copy-Item -LiteralPath "$backend\network-config.ps1" -Destination "$isolatedBackend\network-config.ps1"
    . "$isolatedBackend\network-config.ps1"
    $testNetwork = $loopback
    function Get-LabNetwork { $testNetwork }
    function Assert-LabCoreStopped { }
    $first = "$isolatedBackend\native\Server8360\setting.txt"
    $second = "$isolatedBackend\native\Central\setting.txt"
    [IO.File]::WriteAllBytes($first, $bytes)
    [IO.File]::WriteAllBytes($second, [Text.Encoding]::Latin1.GetBytes($text.Replace('Port=8360', 'Port=8372').Replace('127.0.0.1;127.0.0.2;', '127.0.0.1;')))
    [IO.File]::WriteAllBytes("$isolatedBackend\native\BuddyCenter\setting.txt", [Text.Encoding]::Latin1.GetBytes($text.Replace('Port=8360', 'Port=8339').Replace('127.0.0.1;127.0.0.2;', '127.0.0.1;')))
    [IO.File]::WriteAllBytes("$isolatedBackend\native\BuddyServ\setting.txt", [Text.Encoding]::Latin1.GetBytes($text.Replace('Port=8360', 'Port=8352').Replace('Accept=', 'StarAccept=').Replace('127.0.0.1;127.0.0.2;', '127.0.0.1;')))
    [IO.File]::WriteAllBytes("$isolatedBackend\native\Central\GameServerList.txt", $worldBytes)
    Assert-Check (@(Get-LabNetworkSettingsChanges $loopback).Count -eq 0) 'Default backend settings changed'
    foreach ($placement in @($privateNetwork,$singleBotNetwork,$twoBotNetwork,$sharedNetwork)) {
        $changes = @(Get-LabNetworkSettingsChanges $placement)
        $allowlist = ((@($placement.HumanAddress) + @($placement.BotAddresses)) -join ';') + ';'
        Assert-Check ($changes.Count -eq 3) 'Unexpected core/Buddy setting changes'
        foreach ($change in $changes) {
            if ($change.path -ceq $first) {
                $expected = $text.Replace('127.0.0.1;127.0.0.2;', $allowlist)
            } elseif ($change.path -ceq $second) {
                $expected = $text.Replace('Port=8360', 'Port=8372').Replace('127.0.0.1;127.0.0.2;', $allowlist)
            } else {
                Assert-Check ($change.path -ceq "$isolatedBackend\native\Central\GameServerList.txt") 'Buddy was included in private preparation'
                $expected = $worldText.Replace('127.0.0.1', $placement.ServerAddress)
            }
            Assert-Check ([Text.Encoding]::Latin1.GetString($change.bytes) -ceq $expected) 'Full peer allowlists changed SQL, ports or unrelated bytes'
        }
    }
    Assert-Rejected { Get-LabNetworkSettingsChanges $sharedNetwork -VerifyOnly } 'missing v2 peer allowlists'
    $testNetwork = $sharedNetwork
    Write-LabNetworkChanges $changes $sharedNetwork
    Assert-Check (@(Get-LabNetworkSettingsChanges $sharedNetwork -VerifyOnly).Count -eq 0) 'Published v2 settings did not verify'
    $testNetwork = $loopback
    Write-Output 'PASS full v1/v2 1-3-bot world/broker allowlists; SQL, Buddy, fixed ports and unrelated bytes preserved (disposable settings only).'

    [IO.File]::WriteAllText($first, 'first dummy')
    [IO.File]::WriteAllText($second, 'second dummy')
    $writes = @(
        [pscustomobject]@{ path=$first; beforeSha256=(Get-FileHash -LiteralPath $first).Hash.ToLowerInvariant(); bytes=[Text.Encoding]::ASCII.GetBytes('first updated') },
        [pscustomobject]@{ path=$second; beforeSha256=(Get-FileHash -LiteralPath $second).Hash.ToLowerInvariant(); bytes=[Text.Encoding]::ASCII.GetBytes('second updated') }
    )
    $aclBefore = Get-Acl -LiteralPath $first
    Write-LabNetworkChanges $writes $loopback
    Assert-Check ([IO.File]::ReadAllText($first) -ceq 'first updated' -and [IO.File]::ReadAllText($second) -ceq 'second updated') 'Atomic publication failed'
    $aclAfter = Get-Acl -LiteralPath $first
    $rulesBefore = @($aclBefore.Access | ForEach-Object { ($_.IdentityReference.Value,[int]$_.FileSystemRights,$_.AccessControlType,$_.IsInherited,$_.InheritanceFlags,$_.PropagationFlags -join '|') } | Sort-Object)
    $rulesAfter = @($aclAfter.Access | ForEach-Object { ($_.IdentityReference.Value,[int]$_.FileSystemRights,$_.AccessControlType,$_.IsInherited,$_.InheritanceFlags,$_.PropagationFlags -join '|') } | Sort-Object)
    Assert-Check (($rulesBefore -join ';') -ceq ($rulesAfter -join ';') -and $aclBefore.Owner -eq $aclAfter.Owner -and
        $aclBefore.Group -eq $aclAfter.Group -and $aclBefore.AreAccessRulesProtected -eq $aclAfter.AreAccessRulesProtected) 'Publication changed the existing access rules/ownership/inheritance'
    foreach ($write in $writes) {
        $write.beforeSha256 = (Get-FileHash -LiteralPath $write.path).Hash.ToLowerInvariant()
        $write.bytes = [Text.Encoding]::ASCII.GetBytes('should roll back')
    }
    function Assert-LabCoreStopped { [IO.File]::WriteAllText($second, 'concurrent dummy edit') }
    Assert-Rejected { Write-LabNetworkChanges $writes $loopback } 'concurrent settings edit'
    Assert-Check ([IO.File]::ReadAllText($first) -ceq 'first updated' -and [IO.File]::ReadAllText($second) -ceq 'concurrent dummy edit') 'Rollback overwrote unrelated concurrent data'
    Assert-Check (@(Get-ChildItem -LiteralPath $isolatedBackend -Filter '*.network-*' -Recurse).Count -eq 0) 'Successful publication/rollback left scratch files'
    Write-Output 'PASS ACL-preserving publication and rollback after a concurrent edit (disposable dummy copies only).'

    function Assert-LabCoreStopped { }
    $firstBefore = [IO.File]::ReadAllBytes($first)
    $secondBefore = [IO.File]::ReadAllBytes($second)
    foreach ($write in $writes) { $write.beforeSha256 = (Get-FileHash -LiteralPath $write.path).Hash.ToLowerInvariant() }
    foreach ($case in @(
        @{ expected=$sharedNetwork; changed=$twoBotNetwork; name='removed peer' },
        @{ expected=$sharedNetwork; changed=$reorderedNetwork; name='reordered peers' },
        @{ expected=$botServerNetwork; changed=$singleBotNetwork; name='v1 to v2 schema' },
        @{ expected=$singleBotNetwork; changed=$botServerNetwork; name='v2 to v1 schema' }
    )) {
        foreach ($changeAt in @(1,2,3)) {
            $profileReads = @(0)
            function Get-LabNetwork {
                $profileReads[0]++
                if ($profileReads[0] -ge $changeAt) { $case.changed } else { $case.expected }
            }
            Assert-Rejected { Write-LabNetworkChanges $writes $case.expected } "$($case.name) before/during/after publication"
            Assert-Check ([RetroClientBuild.ClientPatch]::Hash([IO.File]::ReadAllBytes($first)) -ceq [RetroClientBuild.ClientPatch]::Hash($firstBefore) -and
                [RetroClientBuild.ClientPatch]::Hash([IO.File]::ReadAllBytes($second)) -ceq [RetroClientBuild.ClientPatch]::Hash($secondBefore)) 'A concurrent profile change escaped rollback'
        }
    }
    function Get-LabNetwork { $loopback }
    function Assert-LabCoreStopped { throw 'Simulated owned Core startup' }
    Assert-Rejected { Write-LabNetworkChanges $writes $loopback } 'running Core'
    Assert-Check ([RetroClientBuild.ClientPatch]::Hash([IO.File]::ReadAllBytes($first)) -ceq [RetroClientBuild.ClientPatch]::Hash($firstBefore) -and
        [RetroClientBuild.ClientPatch]::Hash([IO.File]::ReadAllBytes($second)) -ceq [RetroClientBuild.ClientPatch]::Hash($secondBefore)) 'A running Core did not block publication'
    Assert-Check (@(Get-ChildItem -LiteralPath $isolatedBackend -Filter '*.network-*' -Recurse).Count -eq 0) 'Concurrent profile rollback left scratch files'
    Write-Output 'PASS schema/peer-list changes before, between and after writes trigger rollback; running Core blocks publication (mocked checks only).'

    $guardCalls = @($startAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Assert-LabNetworkUnchanged'
    }, $true))
    Assert-Check ($guardCalls.Count -eq 1) 'Core supervision must use the shared complete profile guard'
    $guardAst = $guardCalls[0].Parent.Parent.Parent
    Assert-Check ($guardAst -is [Management.Automation.Language.IfStatementAst] -and
        $guardAst.Parent.Parent -is [Management.Automation.Language.WhileStatementAst]) 'The Core profile guard is not in the supervision loop'
    # Execute only the Core-specific guard with mocked profiles, never the startup script or its process/firewall code.
    $runtimeGuard = [scriptblock]::Create($guardAst.Extent.Text)
    $parts = @('Core')
    function Get-LabNetwork { $observedNetwork }
    foreach ($network in @($loopback,$privateNetwork,$botServerNetwork,$singleBotNetwork,$twoBotNetwork,$sharedNetwork)) {
        $observedNetwork = $network
        & $runtimeGuard
    }
    foreach ($case in @(
        @{ expected=$loopback; changed=$privateNetwork },
        @{ expected=$privateNetwork; changed=$botServerNetwork },
        @{ expected=$privateNetwork; changed=[RetroClientBuild.NetworkProfile]::Create('private','192.168.56.1','192.168.56.1','192.168.56.11') },
        @{ expected=$sharedNetwork; changed=$twoBotNetwork },
        @{ expected=$sharedNetwork; changed=$reorderedNetwork },
        @{ expected=$sharedNetwork; changed=[RetroClientBuild.NetworkProfile]::Parse($sharedJson.Replace('192.168.56.12','192.168.56.13')) },
        @{ expected=$sharedNetwork; changed=[RetroClientBuild.NetworkProfile]::Parse($sharedJson.Replace('"humanAddress":"192.168.56.1"','"humanAddress":"192.168.56.2"')) },
        @{ expected=$botServerNetwork; changed=$singleBotNetwork },
        @{ expected=$singleBotNetwork; changed=$botServerNetwork }
    )) {
        $network = $case.expected
        $observedNetwork = $case.changed
        $message = $null
        try { & $runtimeGuard } catch { $message = $_.Exception.Message }
        Assert-Check ($message -ceq 'network.json changed while Core was running. Stop Core before switching profiles.') 'Running Core missed a schema/peer/legacy change or changed its error context'
        $message = $null
        try { Assert-LabNetworkUnchanged $network } catch { $message = $_.Exception.Message }
        Assert-Check ($message -ceq 'network.json changed during preparation.') 'Preparation profile-guard error changed'
    }
    foreach ($parts in @(@('Database'), @('Buddy'))) { & $runtimeGuard }
    Write-Output 'PASS actual Core supervision guard: v1 behavior/context preserved; v2 schema and full peer changes detected; Database/Buddy unchanged (mocked profiles only).'

    $compiler = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    & $compiler /nologo /platform:x86 /target:exe /optimize+ "/out:$work\check-native.exe" "$PSScriptRoot\ClientPatch.cs" "$PSScriptRoot\CheckNative.cs" "$PSScriptRoot\CheckWrapper.cs"
    if ($LASTEXITCODE) { throw 'Isolated native checker compilation failed.' }
    & "$work\check-native.exe" $source
    if ($LASTEXITCODE) { throw 'Isolated native checker failed.' }
    & $compiler /nologo /platform:x86 /target:exe /optimize+ /r:System.Drawing.dll /r:System.Web.Extensions.dll "/out:$work\lab-client.exe" "$lab\lab-client.cs" "$PSScriptRoot\ClientPatch.cs"
    if ($LASTEXITCODE) { throw 'Isolated launcher compilation failed.' }
    & "$work\lab-client.exe" self-check
    if ($LASTEXITCODE) { throw 'Isolated launcher self-check failed.' }
    $defaultJson = & "$work\lab-client.exe" check-network
    if ($LASTEXITCODE) { throw 'Isolated default profile check failed.' }
    Assert-Check ($defaultJson -ceq '{"schemaVersion":1,"mode":"loopback","serverAddress":"127.0.0.1","humanAddress":"127.0.0.1","botAddress":"127.0.0.2"}') 'Legacy profile inspection output changed'
    [IO.File]::WriteAllText("$work\network.json", $sharedJson)
    $inspected = & "$work\lab-client.exe" check-network | ConvertFrom-Json
    if ($LASTEXITCODE) { throw 'Isolated v2 profile check failed.' }
    Assert-Check ($inspected.schemaVersion -eq 2 -and $inspected.botAddress -ceq $sharedNetwork.BotAddress -and
        ($inspected.botAddresses -join ';') -ceq ($sharedNetwork.BotAddresses -join ';')) 'Profile inspection dropped schema/peer information'
    Assert-Check ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $sourceHash) 'Original client changed'
    Write-Output 'PASS: no shared executable builds, active profiles, native configuration, live processes or private/public test sockets changed.'
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    Remove-Item -LiteralPath $work -Recurse -Force
}
