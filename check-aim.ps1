$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath $PSScriptRoot
$checkRoot = '.controller-check-' + [Guid]::NewGuid().ToString('N')
try {
    # Verify the supplied unpacked native profile, not a guessed field or a live input experiment.
    $signatures = @(
        @(0x004CBA1E, '88 90 EC 40 02 00'), # capacity from room-join packet
        @(0x004CBA2C, '88 88 ED 40 02 00'), # independent occupancy byte
        @(0x004268D3, '88 81 EC 40 02 00'), # native capacity update
        @(0x005170B2, '8A 43 18 04 FE 3C 01 88 43 18 B1 08'), # capacity -2, wraps to 8
        @(0x00517117, '8A 53 18 B0 02 02 D0'), # capacity +2
        @(0x00510A6A, '0F B6 88 EC 40 02 00 6A 00 8D 95 C2 00 00 00 52 D1 E9'), # displayed capacity /2
        @(0x004F0A0E, '8B D3 C1 EA 12 88 88 EE 40 02 00 83 E2 03'), # native game type = options >>18 &3
        @(0x005102B5, '8B 35 58 05 87 00 68 10 32 00 00'), # Team button BF -> native 3210
        @(0x005102D5, '80 FB 01 0F 95 C1'), # 1-selfTeam, not an arbitrary team write
        @(0x004E9CD3, '68 DC 51 57 00 8B CF FF 52 04'), # native "dead" transition
        @(0x005751DC, '64 65 61 64 00'),
        @(0x004E9D17, '81 C7 D4 02 00 00 32 C0 E8 9C CD F2 FF'), # clears decoded alive flag +2D4
        @(0x004693D5, '8D 8F 1C 02 00 00 E8 F0 2B FC FF 6B C0 4C 99 F7 FE'), # native healthbar current HP +21C
        @(0x004244ED, '81 C5 38 71 07 00 68 A1 86 01 00'), # mobile registry/type
        @(0x00526AD0, '8B 41 04 8B 40 1C 8B 48 04') # native type-list lookup
    )
    foreach ($role in @('bot', 'human')) {
        $image = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot "client-build\$role\GunBound.image.bin"))
        foreach ($entry in $signatures) {
            $expected = @($entry[1].Split(' ') | ForEach-Object { [Convert]::ToByte($_, 16) })
            $offset = [int]$entry[0] - 0x00400000
            for ($index = 0; $index -lt $expected.Count; $index++) {
                if ($offset + $index -ge $image.Length -or $image[$offset + $index] -ne $expected[$index]) {
                    throw ('Unsupported {0} native profile at {1:X8}; do not use unchecked room/life fields.' -f $role, $entry[0])
                }
            }
        }
    }
    Write-Output 'PASS: supplied host/bot native capacity, game type, team action, alive/health and mobile-registry signatures.'
    New-Item -ItemType Directory -Path "$checkRoot\profiles" -Force | Out-Null
    Copy-Item -LiteralPath '.\profiles\difficulty.json' -Destination "$checkRoot\profiles\difficulty.json"
    & 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' /nologo /platform:x86 /target:exe /optimize+ `
        /main:BotController /r:System.Drawing.dll /r:System.Web.Extensions.dll `
        "/out:$checkRoot\bot-controller-check.exe" '.\bot.cs' '.\aim.cs' '.\lab-client.cs' '.\client-build\ClientPatch.cs'
    if ($LASTEXITCODE -ne 0) { throw "Isolated controller compilation failed ($LASTEXITCODE)." }
    & ".\$checkRoot\bot-controller-check.exe" --self-check
    if ($LASTEXITCODE -ne 0) { throw "Controller/aim self-check failed ($LASTEXITCODE)." }
} finally {
    if (Test-Path -LiteralPath $checkRoot) { Remove-Item -LiteralPath $checkRoot -Recurse -Force }
    Pop-Location
}
