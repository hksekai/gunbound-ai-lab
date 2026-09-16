#requires -Version 7.0
[CmdletBinding()]
param([uint32]$ArenaBase = 0x01000000)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$source = "$root\client-image\GunBound.gme"
$original = [IO.File]::ReadAllBytes($source)
$work = "$PSScriptRoot\work"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:TEMP = $work
$env:TMP = $work
Add-Type -Path "$PSScriptRoot\ClientPatch.cs"
$variants = @()
foreach ($role in @('human','bot')) {
    $plan = [RetroClientBuild.ClientPatch]::Build($original, $role, $ArenaBase)
    $directory = "$PSScriptRoot\$role"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [IO.File]::WriteAllBytes("$directory\GunBound.image.bin", $plan.ImageModel)
    [IO.File]::WriteAllBytes("$directory\network-code.bin", $plan.Arena)
    if ($plan.InitialTrace) { [IO.File]::WriteAllBytes("$directory\startup-data.bin", $plan.InitialTrace) }
    $patches = @($plan.Edits | ForEach-Object {
        [ordered]@{
            rva=('0x{0:x8}' -f $_.Rva); va=('0x{0:x8}' -f (0x400000 + $_.Rva)); fileOffset=$_.Rva
            expected=([BitConverter]::ToString($_.Expected).Replace('-','').ToLowerInvariant())
            replacement=([BitConverter]::ToString($_.Replacement).Replace('-','').ToLowerInvariant())
            purpose=$_.Purpose
        }
    })
    $entries = [ordered]@{}
    foreach ($entry in @('ensure','bind','connect','sendto','udp_init','mutex_trace','bot_mutex_name')) {
        if ($plan.Entries.ContainsKey($entry)) { $entries[$entry] = [ordered]@{ offset=$plan.Entries[$entry]; va=('0x{0:x8}' -f ($ArenaBase + $plan.Entries[$entry])) } }
    }
    $record = [ordered]@{
        role=$role; address=$plan.Address; mutex=$plan.MutexName; sourceSha256=[RetroClientBuild.ClientPatch]::SourceHash
        imageBase='0x00400000'; imageSize='0x004fe000'; arenaBase=('0x{0:x8}' -f $ArenaBase); arenaReservationBytes=$plan.ReservationBytes
        imageModelSha256=[RetroClientBuild.ClientPatch]::Hash($plan.ImageModel)
        codeSha256=[RetroClientBuild.ClientPatch]::Hash($plan.Arena); codeBytes=$plan.Arena.Length
        initialTraceSha256=if($plan.InitialTrace){[RetroClientBuild.ClientPatch]::Hash($plan.InitialTrace)}else{$null}
        modelWarning='Not an executable to launch: arena allocation is required. Use the original shared asset image with the guarded suspended-child interface.'
        entries=$entries; patches=$patches
        iatOperands=@($plan.IatReferences|ForEach-Object{[ordered]@{offset=$_.Offset;dll=$_.Dll;api=$_.Api;expectedVa=('0x{0:x8}' -f $_.Address)}})
        diagnosticAddressOperands=@($plan.AddressReferences|ForEach-Object{[ordered]@{offset=$_.Offset;target=$_.Target;expectedVa=('0x{0:x8}' -f $_.Address)}})
    }
    ConvertTo-Json -InputObject $record -Depth 8 | Set-Content -LiteralPath "$directory\patches.json" -Encoding utf8
    $variants += [ordered]@{role=$role;imageModelSha256=$record.imageModelSha256;codeSha256=$record.codeSha256;patchCount=$patches.Count}
}
$compiler = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if (!(Test-Path -LiteralPath $compiler)) { throw 'The existing Windows .NET Framework compiler is missing; no dependency will be installed automatically.' }
& $compiler /nologo /target:library /platform:anycpu /optimize+ "/out:$PSScriptRoot\RetroClientPatch.dll" "$PSScriptRoot\ClientPatch.cs"
if ($LASTEXITCODE) { throw 'Failed to compile the staged parent integration helper.' }
& $compiler /nologo /target:exe /platform:x86 /optimize+ "/out:$PSScriptRoot\check-native.exe" "$PSScriptRoot\ClientPatch.cs" "$PSScriptRoot\CheckNative.cs" "$PSScriptRoot\CheckWrapper.cs"
if ($LASTEXITCODE) { throw 'Failed to compile the isolated x86 checker.' }
$manifest = [ordered]@{
    schemaVersion=1
    source='client-image\GunBound.gme'
    sourceSha256=[RetroClientBuild.ClientPatch]::SourceHash
    generatedUtc=[DateTime]::UtcNow.ToString('o')
}
$manifest.referenceArena = '0x{0:x8}' -f $ArenaBase
$manifest['variants'] = $variants
$manifest['integrationDllSha256'] = (Get-FileHash -LiteralPath "$PSScriptRoot\RetroClientPatch.dll" -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest['checkerSha256'] = (Get-FileHash -LiteralPath "$PSScriptRoot\check-native.exe" -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest.validationStatus = 'Built; run verify.ps1. No live client or backend was changed.'
ConvertTo-Json -InputObject $manifest -Depth 8 | Set-Content -LiteralPath "$PSScriptRoot\manifest.json" -Encoding utf8
Write-Output 'Staged deterministic image models, network code, guarded patch plans, and integration helper under client-build only.'
