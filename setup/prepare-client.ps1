#requires -Version 7.0
[CmdletBinding()]
param([string]$ClientDirectory, [switch]$Resume, [switch]$Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$required = @('GunBound.gme','ddraw.dll','dxwnd.dll','avatar.xfs','graphics.xfs','sound.xfs')
$pinned = @{
    'GunBound.gme' = '683CB237147C8DE28C2A5EA3343E9A6B6082EC5D1851F5D20DFBF8BA81A530A8'
    'ddraw.dll' = 'AA29719572FC6842ACF85302BEE94AB889AEC49C7E456C83C0770ABB0BD8D6C4'
    'dxwnd.dll' = '909349FF70190FE962BDC55748C740B9E4137126B2AC4A4CEBB7E63C3DF55898'
}

function Assert-PlainPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Redirected asset path refused: $current"
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        $current = if ($parent) { $parent.FullName } else { $null }
    }
}

function Assert-ClientReceipt($Marker, [string]$Root, $Hashes, [bool]$ResumeRequested, [bool]$DirectoryExists) {
    if (!$Marker -or $Marker.schemaVersion -ne 1 -or $Marker.root -ne $Root -or
        $Marker.phase -notin @('copying','ready') -or
        ($Marker.phase -eq 'copying' -and !$ResumeRequested) -or
        ($Marker.phase -eq 'ready' -and !$DirectoryExists)) {
        throw 'The client setup receipt is incomplete, belongs to another installation, or requires explicit resume.'
    }
    foreach ($name in $Hashes.Keys) {
        if ($Marker.hashes.$name -ne $Hashes[$name]) { throw 'Supplied client assets differ from their protected setup receipt.' }
    }
}

function New-WrapperProfile([string]$Directory) {
    $image = Join-Path $Directory 'GunBound.gme'
    @"
[target]
title0=GunBound AI Lab
path0=$image
launchpath0=$image
startfolder0=
module0=
opengllib0=
notes0=
registry0=
ver0=0
monitorid0=-1
filterid0=0
renderer0=3
coord0=0
flag0=673186353
flagg0=1275346944
flagh0=22
flagi0=4194308
flagj0=4224
flagk0=268500992
flagl0=1048576
flagm0=0
flagn0=17825793
flago0=536870912
tflag0=0
dflag0=0
posx0=100
posy0=100
sizx0=800
sizy0=600
maxfps0=0
initts0=0
winver0=0
maxres0=-1
swapeffect0=0
maxddinterface0=7
slowratio0=2
scanline0=0
initresw0=800
initresh0=600
fakehddrive0=C:
fakecddrive0=D:
cdvol0=100
"@
}

if ($Check) {
    $profile = New-WrapperProfile 'D:\Example Lab\client-image'
    if ($required.Count -ne 6 -or $required -contains 'GunBound.exe' -or
        $required -contains 'GunBound.ini' -or $required -contains 'MuteList.txt' -or
        $required -contains 'dxwnd.log' -or $required -contains 'dxwnd.reg' -or
        $pinned.Count -ne 3 -or $profile -notmatch 'path0=D:\\Example Lab\\client-image\\GunBound.gme' -or
        $profile -notmatch 'sizx0=800' -or $profile -match 'icon0=|HKEY_') {
        throw 'The source-only client import/profile contract changed.'
    }
    $hashes = [ordered]@{}
    foreach ($name in $required) { $hashes[$name] = 'A' * 64 }
    $marker = [pscustomobject]@{schemaVersion=1;root='D:\Example Lab';phase='copying';hashes=$hashes}
    Assert-ClientReceipt $marker $marker.root $hashes $true $false
    $rejected = $false
    try { Assert-ClientReceipt $marker $marker.root $hashes $false $true } catch { $rejected = $true }
    if (!$rejected) { throw 'An incomplete client copy was resumed without consent.' }
    $marker.phase = 'ready'
    Assert-ClientReceipt $marker $marker.root $hashes $false $true
    $rejected = $false
    try { Assert-ClientReceipt $marker $marker.root $hashes $true $false } catch { $rejected = $true }
    if (!$rejected) { throw 'A missing ready client directory was silently recreated.' }
    $changed = [ordered]@{}
    foreach ($name in $required) { $changed[$name] = $hashes[$name] }
    $changed['GunBound.gme'] = 'B' * 64
    $rejected = $false
    try { Assert-ClientReceipt $marker $marker.root $changed $true $true } catch { $rejected = $true }
    if (!$rejected) { throw 'A changed client was adopted by resume.' }
    Write-Output 'PASS: six required assets, exact binary fingerprints, generated local wrapper paths, and no imported user settings. No assets were copied.'
    return
}

if (!$ClientDirectory -or !(Test-Path -LiteralPath $ClientDirectory -PathType Container)) {
    throw 'Supply -ClientDirectory pointing to trusted, legally obtained extracted Retro v7 client files.'
}
$source = (Resolve-Path -LiteralPath $ClientDirectory).ProviderPath
$destination = Join-Path $root 'client-image'
Assert-PlainPath $source
Assert-PlainPath $destination
if ([String]::Equals($source.TrimEnd('\'), $destination.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The supplied client directory must be outside the generated client-image directory.'
}
$hashes = [ordered]@{}
foreach ($name in $required) {
    $file = Join-Path $source $name
    Assert-PlainPath $file
    if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
        throw "Required supplied client file is missing or empty: $name"
    }
    $hashes[$name] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if ($pinned.ContainsKey($name) -and $hashes[$name] -ne $pinned[$name]) {
        throw "Unsupported $name fingerprint. Do not substitute a different client or wrapper build."
    }
}
$markerPath = Join-Path $root 'private\setup\client.json'
Assert-PlainPath $markerPath
$marker = $null
if (Test-Path -LiteralPath $markerPath) {
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    Assert-ClientReceipt $marker $root $hashes ([bool]$Resume) (Test-Path -LiteralPath $destination -PathType Container)
    if (!(Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination | Out-Null }
}
if (Test-Path -LiteralPath $destination) {
    if (!$marker) {
        throw 'An existing client-image directory has no setup receipt; it was not overwritten.'
    }
    foreach ($name in $required) {
        $target = Join-Path $destination $name
        if ((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $hashes[$name]) {
            throw 'Supplied or installed client assets changed after preparation.'
        }
        if (!(Test-Path -LiteralPath $target)) {
            if ($marker.phase -eq 'ready') { throw 'An owned ready client asset is missing; no repair was guessed.' }
            Copy-Item -LiteralPath (Join-Path $source $name) -Destination $target
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $hashes[$name]) { throw 'Resumed client copy did not verify.' }
        }
    }
    if ($marker.phase -eq 'copying') {
        $configuration = @{
            'dxwnd.dxw' = New-WrapperProfile $destination
            'dxwnd.ini' = "[window]`r`nmultiprocesshook=1`r`n"
        }
        foreach ($name in $configuration.Keys) {
            $target = Join-Path $destination $name
            if ((Test-Path -LiteralPath $target) -and [IO.File]::ReadAllText($target) -cne $configuration[$name]) {
                throw 'Partial client configuration changed; it was not overwritten.'
            }
            [IO.File]::WriteAllText($target,$configuration[$name],[Text.UTF8Encoding]::new($false))
        }
        $marker.phase = 'ready'
        [IO.File]::WriteAllText($markerPath,($marker | ConvertTo-Json -Depth 4))
    }
    Write-Output 'The owned client assets are already prepared; no files were replaced.'
    return
}

$private = Join-Path $root 'private\setup'
Assert-PlainPath $private
New-Item -ItemType Directory -Path $private -Force | Out-Null
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
    [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $private -AclObject $acl
$marker = [ordered]@{schemaVersion=1;root=$root;phase='copying';hashes=$hashes}
[IO.File]::WriteAllText($markerPath,($marker | ConvertTo-Json -Depth 4))
New-Item -ItemType Directory -Path $destination | Out-Null
foreach ($name in $required) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $destination $name)
    if ((Get-FileHash -LiteralPath (Join-Path $destination $name) -Algorithm SHA256).Hash -ne $hashes[$name]) {
        throw 'Client asset copy verification failed; inspect the retained incomplete setup receipt.'
    }
}
[IO.File]::WriteAllText((Join-Path $destination 'dxwnd.dxw'),(New-WrapperProfile $destination),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $destination 'dxwnd.ini'),"[window]`r`nmultiprocesshook=1`r`n",[Text.UTF8Encoding]::new($false))
$marker.phase = 'ready'
[IO.File]::WriteAllText($markerPath,($marker | ConvertTo-Json -Depth 4))
Write-Output 'Prepared only the six required supplied assets and fresh wrapper configuration. Personal launcher settings and logs were not imported.'
