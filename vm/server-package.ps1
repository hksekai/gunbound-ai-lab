#requires -Version 7.0
[CmdletBinding()]
param([switch]$Resume)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\host-io.ps1"
$root = Split-Path $PSScriptRoot
$config = Read-VmConfig $root
$snapshot = Get-Content -LiteralPath "$PSScriptRoot\server-snapshot.json" -Raw | ConvertFrom-Json
$network = Get-Content -LiteralPath "$root\network.json" -Raw | ConvertFrom-Json
if ($network.serverAddress -ne $config.botAddress -or $network.humanAddress -ne $config.hostAddress -or
    !$snapshot.originalPreserved -or $snapshot.ownerId -ine $config.machineId -or
    !$snapshot.snapshot.StartsWith("$root\private\vm\server-snapshots\",[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The selected guest-server topology or protected snapshot is invalid.'
}
Assert-VmBackendStopped $root
$null = Assert-VmPath $snapshot.snapshot "$root\private\vm\server-snapshots"
Assert-VmTreeManifest $snapshot.snapshot $snapshot.files
$canonical = @(Get-Content -LiteralPath "$root\private\backend\accounts.json" -Raw | ConvertFrom-Json)
Assert-VmAccounts $canonical 'Server'
if ((Get-FileHash -LiteralPath "$root\private\backend\accounts.json" -Algorithm SHA256).Hash -cne $snapshot.accountsSha256) {
    throw 'Canonical accounts no longer match the offline snapshot; no credentials or SQL data were reset.'
}
$receipt = Join-Path $PSScriptRoot 'server-package.json'
if (Test-Path -LiteralPath $receipt) {
    if (!$Resume) { throw 'A server package already exists; only an unchanged interrupted setup may resume it.' }
    $previous = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    $null = Assert-VmPath $previous.archive "$root\private\vm\server-packages"
    if ($previous.ownerId -ine $config.machineId -or $previous.snapshotId -cne $snapshot.snapshotId -or
        (Get-FileHash -LiteralPath $previous.archive -Algorithm SHA256).Hash -cne $previous.sha256) {
        throw 'The recorded server package/snapshot changed.'
    }
    foreach ($file in $previous.sourceFiles) {
        $path = Assert-VmPath (Join-Path $root $file.path) $root
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $file.sha256) { throw 'Server source/credential inputs changed after packaging; resume cannot silently update them.' }
    }
    Write-Output 'Verified the unchanged protected server package and original offline snapshot.'
    return
}
& "$root\backend\network-config.ps1" -Check
foreach ($path in @("$root\backend\native","$root\runtime\mariadb\mariadb-11.4.13-winx64",$PSHOME)) {
    $null = Assert-VmPath $path
    if (@(Get-ChildItem -LiteralPath $path -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        throw 'Server package input contains redirected files/directories.'
    }
}
$id = [Guid]::NewGuid().ToString('N')
$directory = Join-Path $root ('private\vm\server-packages\' + $id)
$stage = Join-Path $directory 'GunBoundServer'
Protect-VmDirectory $directory
New-Item -ItemType Directory -Path "$stage\backend\native","$stage\private\backend","$stage\runtime\mariadb\work","$stage\logs","$stage\client-build" -Force | Out-Null
Copy-Item -LiteralPath "$root\client-build\ClientPatch.cs" -Destination "$stage\client-build\ClientPatch.cs"
$files = @('start.ps1','stop.ps1','health.ps1','mysql-compat.ps1','network-config.ps1','bind-loopback.ps1',
    'manifest.json','loopback-patches.json','schema-static.sql')
foreach ($file in $files) { Copy-Item -LiteralPath "$root\backend\$file" -Destination "$stage\backend\$file" }
foreach ($folder in @('Central','Server8360','BuddyCenter','BuddyServ')) {
    $source = "$root\backend\native\$folder"
    New-Item -ItemType Directory -Path "$stage\backend\native\$folder" -Force | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $source -File) {
        if ($file.Name -match '(?i)(\.log$|\.dmp$|\.network-.*\.backup$)') { continue }
        Copy-Item -LiteralPath $file.FullName -Destination "$stage\backend\native\$folder\$($file.Name)"
    }
}
Copy-Item -LiteralPath "$root\network.json" -Destination "$stage\network.json"
Copy-Item -LiteralPath "$root\private\backend\accounts.json" -Destination "$stage\private\accounts.json"
Copy-Item -LiteralPath "$root\private\backend\accounts.json" -Destination "$stage\private\backend\accounts.json"
foreach ($file in @('admin.ini','my.ini','credentials.json','legacy-agent.json')) {
    Copy-Item -LiteralPath "$root\private\backend\$file" -Destination "$stage\private\backend\$file"
}
foreach ($file in @('admin.ini','my.ini')) {
    $path = "$stage\private\backend\$file"
    $text = [IO.File]::ReadAllText($path)
    $text = $text.Replace($root.Replace('\','\\'),'C:\\GunBoundServer').Replace($root,'C:\GunBoundServer')
    [IO.File]::WriteAllText($path,$text)
}
Copy-Item -LiteralPath "$root\runtime\mariadb\mariadb-11.4.13-winx64" -Destination "$stage\runtime\mariadb" -Recurse
Copy-Item -LiteralPath $snapshot.snapshot -Destination "$stage\runtime\mariadb\data" -Recurse
Assert-VmTreeManifest "$stage\runtime\mariadb\data" $snapshot.files
Copy-Item -LiteralPath $PSHOME -Destination "$stage\runtime\pwsh" -Recurse
[ordered]@{schemaVersion=1;ownerId=$config.machineId;packageId=$id;root='C:\GunBoundServer';sourceSnapshot=$snapshot.snapshot;
    snapshotId=$snapshot.snapshotId;accountsSha256=$snapshot.accountsSha256
    originalHostDataPreserved=$true;databaseVersion='11.4.13';createdUtc=[DateTime]::UtcNow.ToString('o')} |
    ConvertTo-Json | Set-Content -LiteralPath "$stage\server-owner.json" -Encoding utf8
Copy-Item -LiteralPath "$PSScriptRoot\server-snapshot.json" -Destination "$stage\private\backend\source-snapshot.json"
$hashes = @(Get-VmTreeManifest $stage)
[ordered]@{schemaVersion=1;ownerId=$config.machineId;packageId=$id;files=$hashes} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$stage\package-manifest.json" -Encoding utf8
$archive = Join-Path $directory 'server-package.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$archive,[IO.Compression.CompressionLevel]::Fastest,$false)
[ordered]@{schemaVersion=1;ownerId=$config.machineId;packageId=$id;snapshotId=$snapshot.snapshotId;archive=$archive
    sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash;bytes=(Get-Item -LiteralPath $archive).Length
    originalHostDataPreserved=$true;uploadedToAzure=$false
    sourceFiles=@(foreach ($file in @($files | ForEach-Object { "backend\$_" }) + @(
        'client-build\ClientPatch.cs','network.json','private\backend\accounts.json','private\backend\admin.ini',
        'private\backend\my.ini','private\backend\credentials.json','private\backend\legacy-agent.json'
    ) + @(Get-ChildItem -LiteralPath "$root\backend\native" -File -Recurse |
        Where-Object { $_.Name -notmatch '(?i)(\.log$|\.dmp$|\.network-.*\.backup$)' } | ForEach-Object { $_.FullName.Substring($root.Length + 1) })) {
        [ordered]@{path=$file;sha256=(Get-FileHash -LiteralPath (Join-Path $root $file) -Algorithm SHA256).Hash}
    })} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receipt -Encoding utf8
Write-Output 'Protected server package created from the verified offline snapshot. Original host database remains unchanged.'
