#requires -Version 7.0
[CmdletBinding()]
param([switch]$Resume)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\host-io.ps1"
$root = Split-Path $PSScriptRoot
$config = Read-VmConfig $root
$receipt = Join-Path $PSScriptRoot 'package.json'
if (Test-Path -LiteralPath $receipt) {
    if (!$Resume) { throw 'An application package already exists; only an unchanged interrupted setup may resume it.' }
    $previous = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    $null = Assert-VmPath $previous.archive (Join-Path $root 'private\vm\packages')
    if ($previous.ownerId -ine $config.machineId -or
        (Get-FileHash -LiteralPath $previous.archive -Algorithm SHA256).Hash -cne $previous.sha256) { throw 'The recorded bot package changed.' }
    foreach ($file in $previous.sourceFiles) {
        $path = Assert-VmPath (Join-Path $root $file.path) $root
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $file.sha256) { throw 'Application inputs changed after packaging; resume cannot silently update guest code.' }
    }
    Write-Output 'Verified the unchanged private bot-only package for this interrupted installation.'
    return
}
if ($config.phase -ne 'installing') { throw 'Build the first bot-only package after preparing Windows media, before deployment.' }
$network = Get-Content -LiteralPath "$root\network.json" -Raw | ConvertFrom-Json
$roomFill = $config.PSObject.Properties.Name -contains 'roomFill' -and $config.roomFill -eq $true
if ($network.mode -ne 'private' -or $network.serverAddress -notin @($config.hostAddress,$config.botAddress) -or
    $network.humanAddress -ne $config.hostAddress -or $network.botAddress -ne $config.botAddress) {
    throw 'The guest package must use the explicitly approved private game network.'
}
$files = @('lab-client.exe','lab-tools.exe','bot-controller.exe','stop-bot.ps1','network.json',
    'profiles\difficulty.json','vm\guest-bootstrap.ps1','vm\guest-idle.ps1','vm\guest-session.ps1','vm\guest-server.ps1','vm\shared-io.ps1',
    'vm\configure-room-bots.ps1')
foreach ($file in $files) {
    if (!(Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) { throw "Package input is missing: $file" }
}
$newestSource = @(Get-Item -LiteralPath "$root\bot.cs","$root\aim.cs","$root\lab-client.cs","$root\client-build\ClientPatch.cs" |
    Sort-Object LastWriteTimeUtc -Descending)[0].LastWriteTimeUtc
if ((Get-Item -LiteralPath "$root\bot-controller.exe").LastWriteTimeUtc -lt $newestSource -or
    (Get-Item -LiteralPath "$root\lab-client.exe").LastWriteTimeUtc -lt (Get-Item "$root\lab-client.cs").LastWriteTimeUtc) {
    throw 'Rebuild the shared client/tools/controller before packaging.'
}
if ((Get-FileHash -LiteralPath "$root\client-image\GunBound.gme" -Algorithm SHA256).Hash -ne
    '683CB237147C8DE28C2A5EA3343E9A6B6082EC5D1851F5D20DFBF8BA81A530A8') {
    throw 'The client source no longer matches the supplied Retro build.'
}
if (@(Get-ChildItem -LiteralPath "$root\client-image" -Recurse -Force |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
    throw 'The client package must not follow links outside its approved source.'
}
$accountFile = if ($roomFill) { "$root\private\vm\bot-accounts.json" } else { "$root\private\accounts.json" }
$sourceAccounts = @(Get-Content -LiteralPath $accountFile -Raw | ConvertFrom-Json)
$accounts = if ($roomFill) { $sourceAccounts } else {
    @($sourceAccounts | Where-Object { $_.role -ceq 'bot' -and $_.username -ceq 'BotOne' })
}
$required = if ($roomFill) { @('BotOne','BotTwo','BotThree') } else { @('BotOne') }
if ($accounts.Count -ne $required.Count -or
    (($accounts.username | Sort-Object) -join ',') -cne (($required | Sort-Object) -join ',') -or
    @($accounts | Where-Object { $_.role -cne 'bot' -or $_.password -cnotmatch '^[A-Za-z0-9]{12}$' -or
        $_.id -cne $_.username -or $_.nickname -cne $_.username }).Count) {
    throw 'The package must contain exactly the requested bot identities, never Player/database credentials.'
}
if ($roomFill -and ($config.roomFill -isnot [bool] -or $network.schemaVersion -ne 2 -or
    ($network.botAddresses -join ',') -cne '192.168.56.10,192.168.56.11,192.168.56.12' -or
    ($config.botInstances.name -join ',') -cne 'BotOne,BotTwo,BotThree' -or
    (($config.botInstances | ForEach-Object { $_.address }) -join ',') -cne ($network.botAddresses -join ','))) {
    throw 'The room-fill instance list and versioned private peer profile differ.'
}
Assert-VmAccounts $accounts 'Bots'
$canonical = @(Get-Content -LiteralPath "$root\private\backend\accounts.json" -Raw | ConvertFrom-Json)
Assert-VmAccounts $canonical 'Server'
foreach ($account in $accounts) {
    if ($account.password -cne @($canonical | Where-Object username -ceq $account.username)[0].password) {
        throw 'Bot package credentials differ from the canonical seeded accounts; no account was reset.'
    }
}

$id = [Guid]::NewGuid().ToString('N')
$directory = Join-Path $root "private\vm\packages\$id"
$stage = Join-Path $directory 'GunBoundAI'
Protect-VmDirectory $directory
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($file in $files) {
    $target = Join-Path $stage $file
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $target
}
Copy-Item -LiteralPath "$root\client-image" -Destination $stage -Recurse
New-Item -ItemType Directory -Path "$stage\private","$stage\logs","$stage\session" -Force | Out-Null
ConvertTo-Json -InputObject @($accounts | Where-Object username -ceq 'BotOne') -Depth 5 |
    Set-Content -LiteralPath "$stage\private\accounts.json" -Encoding utf8
$guestMarker = [ordered]@{schemaVersion=1;root='C:\GunBoundAI';computerName='GUNBOUND-BOT';provider='virtualbox'
    ownerId=$config.machineId;leaseSeconds=120;guestPrivateMac=$config.guestPrivateMac;packageId=$id}
if ($roomFill) {
    ConvertTo-Json -InputObject $accounts -Depth 5 | Set-Content -LiteralPath "$stage\private\bot-accounts.json" -Encoding utf8
    $guestMarker.roomFill = $true
    $guestMarker.botInstances = $config.botInstances
}
$guestMarker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$stage\vm\guest.json" -Encoding utf8
$hashes = @(
    foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse -Force) {
        [ordered]@{path=$file.FullName.Substring($stage.Length+1);sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
    }
)
[ordered]@{schemaVersion=1;createdUtc=[DateTime]::UtcNow.ToString('o');ownerId=$config.machineId;files=$hashes} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$stage\vm\package-manifest.json" -Encoding utf8
$archive = Join-Path $directory 'bot-package.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$archive,[IO.Compression.CompressionLevel]::Fastest,$false)
[ordered]@{schemaVersion=1;createdUtc=[DateTime]::UtcNow.ToString('o');ownerId=$config.machineId
    packageId=$id;archive=$archive;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    bytes=(Get-Item -LiteralPath $archive).Length;fileCount=$hashes.Count;includesPlayerCredentials=$false
    includesDatabase=$false;uploadedToAzure=$false
    sourceFiles=@(foreach ($file in @($files) + @('client-image\GunBound.gme','private\vm\bot-accounts.json','private\backend\accounts.json')) {
        [ordered]@{path=$file;sha256=(Get-FileHash -LiteralPath (Join-Path $root $file) -Algorithm SHA256).Hash}
    })} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receipt -Encoding utf8
Write-Output "Created the private bot-only guest package ($($accounts.Count) bots, $($hashes.Count) files). No Player/database credentials or Azure upload."
