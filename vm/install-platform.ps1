#requires -Version 7.0
[CmdletBinding()]
param([string]$WindowsIso, [string]$VirtualBoxPath, [switch]$Check)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\host-io.ps1"
$platform = Resolve-VmPrerequisites $WindowsIso $VirtualBoxPath
if ($Check) {
    Write-Output 'PASS: prerequisite files and safe vendor template are present. No VBox command, ISO mount, adapter, VM, credential, or host-tool change was performed. Image/signature inspection is deferred to installation.'
    return
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if (!([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run setup once in an elevated PowerShell 7 window as the SAME Windows user. ISO inspection/host-only adapter creation need elevation; normal play does not.'
    }
} finally { $identity.Dispose() }
$signature = Get-AuthenticodeSignature -LiteralPath $platform.virtualBox
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Oracle (America|Corporation)') {
    throw 'The installed VBoxManage executable does not have a valid Oracle publisher signature.'
}
$version = (Invoke-VBox $platform.virtualBox @('--version')) -join ''
if ($version -notmatch '^7\.2\.\d+r\d+$') { throw 'This installer supports VirtualBox 7.2.x. Install that vendor version separately; no existing installation was replaced.' }
$help = (Invoke-VBox $platform.virtualBox @('unattended', 'install', '--help')) -join "`n"
foreach ($option in @('--user-password-file','--admin-password-file','--script-template','--image-index')) {
    if (!$help.Contains($option)) { throw 'The installed VBoxManage lacks safe unattended passwordfile/image selection support.' }
}
$hash = (Get-FileHash -LiteralPath $platform.windowsIso -Algorithm SHA256).Hash
$diskImage = Get-DiskImage -ImagePath $platform.windowsIso
$mountedHere = !$diskImage.Attached
if ($mountedHere) { $diskImage = Mount-DiskImage -ImagePath $platform.windowsIso -Access ReadOnly -PassThru }
try {
    $volumes = @($diskImage | Get-Volume | Where-Object DriveLetter)
    if ($volumes.Count -ne 1) { throw 'The supplied Windows ISO has no unique readable volume.' }
    $drive = "$($volumes[0].DriveLetter):"
    $setup = Get-AuthenticodeSignature -LiteralPath "$drive\setup.exe"
    if ($setup.Status -ne 'Valid' -or $setup.SignerCertificate.Subject -notmatch 'Microsoft') {
        throw 'Microsoft Windows setup publisher/signature verification failed.'
    }
    $imagePaths = @("$drive\sources\install.wim", "$drive\sources\install.esd" | Where-Object { Test-Path -LiteralPath $_ })
    if ($imagePaths.Count -ne 1) { throw 'The ISO must contain one supported install.wim or install.esd; split/unrecognized media was refused.' }
    $images = @(foreach ($image in Get-WindowsImage -ImagePath $imagePaths[0]) {
        Get-WindowsImage -ImagePath $imagePaths[0] -Index $image.ImageIndex |
            Select-Object ImageIndex, ImageName, Version, Architecture, Languages
    })
    $selected = Select-VmWindowsImage $images
} finally {
    if ($mountedHere) { Dismount-DiskImage -ImagePath $platform.windowsIso | Out-Null }
}
if ((Get-FileHash -LiteralPath $platform.windowsIso -Algorithm SHA256).Hash -cne $hash) { throw 'Windows media changed during image inspection.' }
[pscustomobject]@{
    schemaVersion=1; verifiedUtc=[DateTime]::UtcNow.ToString('o'); virtualBox=$platform.virtualBox; version=$version
    windowsIso=$platform.windowsIso; windowsSha256=$hash; template=$platform.template; additionsIso=$platform.additionsIso
    templateSha256=(Get-FileHash -LiteralPath $platform.template -Algorithm SHA256).Hash
    imageIndex=[int]$selected.ImageIndex; imageName=$selected.ImageName; imageVersion=[string]$selected.Version
    windowsSetupSignature='Valid Microsoft publisher'; windowsImages=$images
}
