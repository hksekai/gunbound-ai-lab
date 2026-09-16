#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$source = "$root\client-image\GunBound.gme"
$manifest = Get-Content -LiteralPath "$PSScriptRoot\manifest.json" -Raw | ConvertFrom-Json
$hashBefore = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hashBefore -ne $manifest.sourceSha256) { throw 'The live source image is not the expected original.' }
Add-Type -Path "$PSScriptRoot\ClientPatch.cs"
$original = [IO.File]::ReadAllBytes($source)
foreach ($role in @('human','bot')) {
    $record = Get-Content -LiteralPath "$PSScriptRoot\$role\patches.json" -Raw | ConvertFrom-Json
    $arenaBase = [Convert]::ToUInt32($record.arenaBase.Substring(2), 16)
    $plan = [RetroClientBuild.ClientPatch]::Build($original, $role, $arenaBase)
    if ((Get-FileHash -LiteralPath "$PSScriptRoot\$role\GunBound.image.bin" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.imageModelSha256 -or
        [RetroClientBuild.ClientPatch]::Hash($plan.ImageModel) -ne $record.imageModelSha256 -or
        (Get-FileHash -LiteralPath "$PSScriptRoot\$role\network-code.bin" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.codeSha256 -or
        [RetroClientBuild.ClientPatch]::Hash($plan.Arena) -ne $record.codeSha256) { throw "The $role artifacts differ from the guarded transformation." }
    if ($plan.ImageModel.Length -ne $original.Length) { throw 'Image layout changed.' }
    $beforeHeader = [byte[]]$original[0..4095]
    [RetroClientBuild.ClientPatch]::RequireBytes($plan.ImageModel, 0, $beforeHeader)
    [RetroClientBuild.ClientPatch]::RequireBytes($plan.ImageModel, 0xc3ea, [RetroClientBuild.ClientPatch]::ParseHex('84 db 0f 85 ef 0a 00 00'))
    [RetroClientBuild.ClientPatch]::RequireBytes($plan.ImageModel, 0x47053c, [byte[]]$original[0x47053c..0x47054b])
    if ($role -eq 'bot') {
        if ((Get-FileHash -LiteralPath "$PSScriptRoot\bot\startup-data.bin" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.initialTraceSha256) { throw 'Bot initial trace template changed.' }
        $privateName = $arenaBase + $plan.Entries['bot_mutex_name']
        foreach ($site in @(0xc3c1,0x1344d)) {
            if ($plan.ImageModel[$site] -ne 0x68 -or [BitConverter]::ToUInt32($plan.ImageModel,$site+1) -ne $privateName) { throw 'Bot mutex argument is not pinned to the private arena.' }
        }
        [RetroClientBuild.ClientPatch]::RequireBytes($plan.Arena, $plan.Entries['bot_mutex_name'], [Text.Encoding]::ASCII.GetBytes("SoftnyxGunBound.bot`0"))
        $restored = [byte[]]$plan.ImageModel.Clone()
        [Array]::Copy($original,0x17283c,$restored,0x17283c,20)
        if ([BitConverter]::ToUInt32($restored,0xc3c2) -ne $privateName) { throw 'Restoring original string data affected the pinned argument.' }
        Write-Output 'PASS bot: restoring the original image mutex buffer cannot change the pinned API argument.'
    }
    Write-Output "PASS ${role}: hashes, exact patch bytes, original headers/guard logic, and mode/global offsets preserved."
}
foreach ($artifact in @(@('RetroClientPatch.dll','integrationDllSha256'),@('check-native.exe','checkerSha256'))) {
    if ((Get-FileHash -LiteralPath "$PSScriptRoot\$($artifact[0])" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.($artifact[1])) { throw 'A compiled staging tool changed.' }
}
$changedSource = [byte[]]$original.Clone()
$changedSource[0x2000] = $changedSource[0x2000] -bxor 1
$rejected = $false
try { [RetroClientBuild.ClientPatch]::Build($changedSource, 'bot', 0x01000000) | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'A mismatched source image was not rejected.' }
$rejected = $false
try { [RetroClientBuild.ClientPatch]::Build($original, 'bot', 0x00400000) | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'An arena overlapping the original image was not rejected.' }
$env:TEMP = "$PSScriptRoot\work"
$env:TMP = $env:TEMP
& "$PSScriptRoot\check-native.exe" $source "$root\client-image\dxwnd.dll" "$PSScriptRoot\wrapper-config\dxwnd.ini"
if ($LASTEXITCODE) { throw 'The isolated x86 socket regression check failed.' }
if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashBefore) { throw 'The original source image changed.' }
[ordered]@{
    verifiedAt=(Get-Date).ToString('o')
    sourceSha256=$hashBefore
    status='PASS'
    checks=@('Exact source and staged hashes','Original image layout/global offsets','Original singleton branch/result preserved; bot argument pinned privately','Mismatched source and overlapping arena rejected','Actual x86 Winsock wrappers and thiscall/error paths','Isolated loopback source identities','Guard-time trace detects a simulated rewrite and preserves ERROR_ALREADY_EXISTS','Exact supplied DxWnd single-process decision and native multiprocesshook INI opt-in')
    liveClientsLaunched=$false
    liveClientsModified=$false
    backendAllowanceChangedByThisCheck=$false
    realClientMutexOverwriteProven=$false
    wrapperConfigurationAppliedByThisCheck=$false
    gameplayVerified=$false
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$PSScriptRoot\verification.json" -Encoding utf8
$manifest.validationStatus = 'PASS: verify.ps1 checked exact staged hashes/layout and actual x86 socket/error behavior. Live clients/gameplay remain unverified.'
ConvertTo-Json -InputObject $manifest -Depth 8 | Set-Content -LiteralPath "$PSScriptRoot\manifest.json" -Encoding utf8
Write-Output 'PASS: only isolated loopback test sockets were used; no live clients, backend, accounts, assets, firewall or networking configuration changed.'
