#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ClientDirectory,
    [string]$ServerSourceDirectory,
    [string]$MariaDbArchive,
    [string]$WindowsIso,
    [string]$VirtualBoxPath = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe',
    [ValidateRange(4096,32768)][int]$MemoryMiB = 6144,
    [ValidateRange(2,16)][int]$Cpus = 4,
    [switch]$Resume,
    [switch]$NoLaunch,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (!$IsWindows) { throw 'This lab requires a Windows host.' }
if ($Check) { & "$root\setup.ps1" -Check; return }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try { $elevated = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
finally { $identity.Dispose() }
if ($elevated -and !$NoLaunch) { throw 'Run start.ps1 in a normal PowerShell 7 window. Player is not launched as administrator.' }
$configPath = Join-Path $root 'vm\config.json'
$configured = $false
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $setupStatePath = Join-Path $root 'private\setup\state.json'
    $setupState = if (Test-Path -LiteralPath $setupStatePath -PathType Leaf) {
        Get-Content -LiteralPath $setupStatePath -Raw | ConvertFrom-Json
    } else { $null }
    $configured = $config.phase -eq 'ready' -and $config.enabled -and
        $setupState -and $setupState.schemaVersion -eq 1 -and
        $setupState.root -eq $root -and $setupState.phase -eq 'ready'
}
if (!$configured) {
    foreach ($value in @($ClientDirectory,$ServerSourceDirectory,$MariaDbArchive,$WindowsIso)) {
        if ([String]::IsNullOrWhiteSpace($value)) {
            throw 'First run requires -ClientDirectory, -ServerSourceDirectory, -MariaDbArchive and -WindowsIso. See README.md.'
        }
    }
    $arguments = @{
        ClientDirectory=$ClientDirectory;ServerSourceDirectory=$ServerSourceDirectory
        MariaDbArchive=$MariaDbArchive;WindowsIso=$WindowsIso;VirtualBoxPath=$VirtualBoxPath
        MemoryMiB=$MemoryMiB;Cpus=$Cpus;Resume=[bool]$Resume
    }
    foreach ($name in @('ClientDirectory','ServerSourceDirectory','MariaDbArchive','WindowsIso','VirtualBoxPath')) {
        $arguments[$name] = (Resolve-Path -LiteralPath ([string]$arguments[$name]) -ErrorAction Stop).ProviderPath
    }
    if ($elevated) { & "$root\setup.ps1" @arguments }
    else {
        $parts = @('& ' + ("'" + (Join-Path $root 'setup.ps1').Replace("'","''") + "'"))
        foreach ($name in @('ClientDirectory','ServerSourceDirectory','MariaDbArchive','WindowsIso','VirtualBoxPath')) {
            $parts += '-' + $name
            $parts += "'" + ([string]$arguments[$name]).Replace("'","''") + "'"
        }
        $parts += @('-MemoryMiB',[string]$MemoryMiB,'-Cpus',[string]$Cpus)
        if ($Resume) { $parts += '-Resume' }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($parts -join ' ')))
        $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
        $installer = Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-NoProfile','-EncodedCommand',$encoded) -PassThru
        try { $null = $installer.Handle; $installer.WaitForExit(); $exitCode = $installer.ExitCode }
        finally { $installer.Dispose() }
        if ($exitCode) { throw "Setup did not complete (exit $exitCode). Player was not launched." }
    }
}
if ($NoLaunch) { Write-Output 'Installation prepared; no Player session was launched.'; return }
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($config.phase -ne 'ready' -or !$config.enabled -or !(Test-Path -LiteralPath "$root\lab-client.exe" -PathType Leaf)) {
    throw 'Setup did not produce a ready installation.'
}
& "$root\play.ps1"
if (!$?) { throw 'The managed game session ended with an error; inspect its local session logs.' }
