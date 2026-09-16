#requires -Version 7.0
[CmdletBinding()]
param([switch]$Resume)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\host-io.ps1"
$root = Split-Path $PSScriptRoot
$config = Read-VmConfig $root
$package = Get-Content -LiteralPath "$PSScriptRoot\package.json" -Raw | ConvertFrom-Json
$private = Join-Path $root 'private\vm'
$null = Assert-VmPath $package.archive "$private\packages"
if ($package.ownerId -ine $config.machineId -or !$package.includesPlayerCredentials.Equals($false) -or
    !$package.includesDatabase.Equals($false) -or
    (Get-FileHash -LiteralPath $package.archive -Algorithm SHA256).Hash -cne $package.sha256) { throw 'The protected bot-only package/VM ownership does not match.' }
if (($Resume -and ($config.phase -cne 'deploying' -or $config.appPackageSha256 -cne $package.sha256)) -or
    (!$Resume -and $config.phase -cne 'installing')) {
    throw 'Resume is only for the recorded interrupted first application deployment, not an update of a provisioned guest.'
}
if (Test-VmPlayerOwner $root) { throw 'A Player session owns this workspace; first deployment did not take over.' }
if ((Get-OwnedVmInfo $root $config).VMState -cne 'running') { throw 'The owned installation VM must be running.' }
$prepare = @'
if (Get-Process -Name 'GunBound.gme','bot-controller','mariadbd' -ErrorAction SilentlyContinue) { throw 'Guest clients/database must be stopped.' }
foreach ($path in @('C:\ProgramData\GunBoundAIProvision','C:\ProgramData\GunBoundAIControl')) {
    if (Test-Path -LiteralPath $path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected provisioning directory.' }
        $owner = Get-Content -LiteralPath "$path\owner.json" -Raw | ConvertFrom-Json
        if ($owner.ownerId -ine '__OWNER__' -or $owner.root -cne $path) { throw 'A provisioning/control directory belongs to another VM.' }
    } else {
        New-Item -ItemType Directory -Path $path | Out-Null
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                (New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
        }
        Set-Acl -LiteralPath $path -AclObject $acl
        @{schemaVersion=1;ownerId='__OWNER__';root=$path} | ConvertTo-Json | Set-Content -LiteralPath "$path\owner.json" -Encoding utf8
    }
}
if (Test-Path -LiteralPath 'C:\GunBoundAI') {
    if ('__RESUME__' -cne 'yes') { throw 'An existing application root requires explicit first-deployment recovery.' }
    Assert-GuestIdentity -OwnerId '__OWNER__'
    $marker = Get-Content -LiteralPath 'C:\GunBoundAI\vm\guest.json' -Raw | ConvertFrom-Json
    if ($marker.PSObject.Properties.Name -contains 'serverRoot') { throw 'A server-provisioned guest cannot be redeployed as a first installation.' }
}
'@
$config.phase = 'deploying'
$config | Add-Member -NotePropertyName appPackageSha256 -NotePropertyValue $package.sha256 -Force
Write-VmJson "$PSScriptRoot\config.json" $config
Invoke-VmGuest $root $config ($prepare.Replace('__OWNER__',$config.machineId).Replace('__RESUME__',$(if($Resume){'yes'}else{'no'}))) `
    -HardwareOnly -LogName 'deploy-prepare.log' | Out-Null
foreach ($copy in @(
    @{source=$package.archive;target='C:\ProgramData\GunBoundAIProvision\'}
    @{source="$private\guest-user.txt";target='C:\ProgramData\GunBoundAIControl\'}
)) {
    Assert-VmPrivateFile $copy.source
    Invoke-VBox -VirtualBoxPath $config.virtualBox -TimeoutSeconds 900 -PrivateLog "$private\deploy-copy.log" -Arguments @(
        'guestcontrol',$config.machineId,'copyto','--quiet','--username=Administrator',
        "--passwordfile=$private\guest-admin.txt","--target-directory=$($copy.target)",$copy.source) | Out-Null
}
$install = Get-VmGuestPackageScript 'app' $package ([bool]$Resume)
$install += @'

Assert-GuestIdentity -OwnerId '__OWNER__'
$receipt = 'C:\GunBoundAI\vm\bootstrap-receipt.json'
if (Test-Path -LiteralPath $receipt) {
    $provisioned = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    if ($provisioned.ownerId -ine '__OWNER__' -or $provisioned.status -cne 'provisioned-needs-relogon') { throw 'Unexpected bootstrap receipt.' }
} else {
    [IO.File]::Copy('C:\ProgramData\GunBoundAIControl\guest-user.txt','C:\ProgramData\GunBoundAIControl\setup-user-password.txt',$true)
    & 'C:\GunBoundAI\vm\guest-bootstrap.ps1'
    if (!$?) { throw 'Guest bootstrap did not complete.' }
}
Remove-Item -LiteralPath 'C:\ProgramData\GunBoundAIControl\guest-user.txt'
Write-Output 'Guest payload verified and bootstrapped with a non-administrator bot user; no Player login or gameplay was attempted.'
'@
Invoke-VmGuest $root $config ($install.Replace('__OWNER__',$config.machineId)) -HardwareOnly -TimeoutSeconds 900 -LogName 'deploy-install.log'
$config.phase = 'app-provisioned'
$config.enabled = $false
Write-VmJson "$PSScriptRoot\config.json" $config
