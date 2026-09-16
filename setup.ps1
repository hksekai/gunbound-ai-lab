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
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (!$IsWindows) { throw 'GunBound AI Lab requires a Windows host with an interactive desktop.' }

function Get-SetupRoute($ExistingVm, [bool]$ResumeRequested) {
    if (!$ExistingVm) { return 'prepare' }
    if (!$ResumeRequested) { throw 'Owned VM setup already exists. Use -Resume for unfinished setup or host finalization.' }
    if ($ExistingVm.phase -eq 'ready') { return 'finalize' }
    if ($ExistingVm.phase -notin @('preparing','installing','deploying','app-provisioned','migrating','provisioned')) {
        throw 'The existing VM has an unsupported provisioning phase.'
    }
    'resume-vm'
}

foreach ($file in @('setup\prepare-client.ps1','setup\prepare-backend.ps1','setup\prepare-vm.ps1')) {
    if (!(Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) { throw "Setup component is missing: $file" }
}
if ($Check) {
    if ((Get-SetupRoute $null $false) -ne 'prepare' -or
        (Get-SetupRoute ([pscustomobject]@{phase='installing'}) $true) -ne 'resume-vm' -or
        (Get-SetupRoute ([pscustomobject]@{phase='ready'}) $true) -ne 'finalize') {
        throw 'The setup resume routing changed.'
    }
    $rejected = $false
    try { Get-SetupRoute ([pscustomobject]@{phase='installing'}) $false | Out-Null }
    catch { $rejected = $true }
    if (!$rejected) { throw 'An existing VM was accepted as a new installation.' }
    & "$root\setup\prepare-client.ps1" -Check
    & "$root\setup\prepare-backend.ps1" -Check
    & "$root\setup\prepare-vm.ps1" -Check
    Write-Output 'PASS: source-only setup contracts. No VM, database, registry, adapter or Player action was performed.'
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if (!([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'One-time setup needs administrator consent. Run start.ps1 normally to request UAC, or run setup.ps1 in an elevated PowerShell 7 window.'
    }
} finally { $identity.Dispose() }
if (![Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows host is required.' }
foreach ($entry in @(
    @{Name='ClientDirectory';Path=$ClientDirectory;Type='Container'},
    @{Name='ServerSourceDirectory';Path=$ServerSourceDirectory;Type='Container'},
    @{Name='MariaDbArchive';Path=$MariaDbArchive;Type='Leaf'},
    @{Name='WindowsIso';Path=$WindowsIso;Type='Leaf'},
    @{Name='VirtualBoxPath';Path=$VirtualBoxPath;Type='Leaf'}
)) {
    if (!$entry.Path -or !(Test-Path -LiteralPath $entry.Path -PathType $entry.Type)) {
        throw "Supply a valid -$($entry.Name). See README.md for required external files and prerequisites."
    }
}
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if (!(Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The Windows .NET Framework x86 compiler is missing.' }
if (@(Get-CimInstance Win32_Process -Filter "Name='GunBound.gme' OR Name='bot-controller.exe' OR Name='lab-client.exe'" |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase) }).Count) {
    throw 'An owned game/controller is running. Stop it before setup or rebuilding.'
}
$stateFile = Join-Path $root 'private\setup\state.json'
$previous = $null
$existingVm = $null
if (Test-Path -LiteralPath "$root\vm\config.json") {
    . "$root\vm\host-io.ps1"
    $existingVm = Read-VmConfig $root
}
if (Test-Path -LiteralPath $stateFile) {
    $previous = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($previous.schemaVersion -ne 1 -or $previous.root -ne $root) { throw 'Setup metadata belongs to another installation.' }
    if ($previous.phase -eq 'ready') {
        if (!$existingVm -or $existingVm.phase -ne 'ready' -or !$existingVm.enabled -or
            !(Test-Path -LiteralPath "$root\lab-client.exe" -PathType Leaf)) { throw 'Ready setup metadata is inconsistent; no reset was attempted.' }
        Write-Output 'This installation is already prepared. Run start.ps1 without elevation to play.'
        return
    }
    if (!$Resume) { throw 'An incomplete setup exists. Inspect its retained records, then use -Resume; no data was reset.' }
}

$route = Get-SetupRoute $existingVm ([bool]$Resume)
if ($route -eq 'prepare') {
    & "$root\setup\prepare-client.ps1" -ClientDirectory $ClientDirectory -Resume:$Resume
} elseif (!(Test-Path -LiteralPath $stateFile -PathType Leaf)) {
    throw 'The owned VM lacks its root setup record; no package or binary was rebuilt.'
}
$state = [ordered]@{schemaVersion=1;root=$root;phase=$route;stage=$route;updatedUtc=[DateTime]::UtcNow.ToString('o')}
[IO.File]::WriteAllText($stateFile,($state | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
try {
    if ($route -eq 'prepare') {
        $state.stage = 'building'
        & "$root\build-client.ps1"
        & "$root\build-client.ps1" -Tools
        & "$root\build-client.ps1" -Control
        & "$root\build-bot.ps1"
        & "$root\client-build\build.ps1"
        & "$root\client-build\verify.ps1"
        $state.stage = 'backend'; $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
        [IO.File]::WriteAllText($stateFile,($state | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        & "$root\setup\prepare-backend.ps1" -ServerSourceDirectory $ServerSourceDirectory -MariaDbArchive $MariaDbArchive
    }
    if ($route -ne 'finalize') {
        $state.stage = 'vm'; $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
        [IO.File]::WriteAllText($stateFile,($state | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        & "$root\setup\prepare-vm.ps1" -WindowsIso $WindowsIso -ServerSourceDirectory $ServerSourceDirectory `
            -VirtualBoxPath $VirtualBoxPath -MemoryMiB $MemoryMiB -Cpus $Cpus -Resume:($route -eq 'resume-vm')
    }
    $state.stage = 'host-finalization'
    & "$root\lab-tools.exe" setup-machine 0
    if ($LASTEXITCODE) { throw 'The host lab-owned registry configuration did not complete.' }
    & "$root\vm\control.ps1" -Action Stop
    $config = Get-Content -LiteralPath "$root\vm\config.json" -Raw | ConvertFrom-Json
    if ($config.phase -ne 'ready' -or !$config.enabled -or !$config.roomFill -or $config.playerSetup -ne 'manual') {
        throw 'The VM did not publish the expected ready/manual room-fill configuration.'
    }
    $state.phase = 'ready'; $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($stateFile,($state | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Write-Output 'Setup completed with the VM off. Run start.ps1 without elevation to open Player and its managed server/bots.'
} catch {
    $state.phase = 'failed'; $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($stateFile,($state | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    throw
}
