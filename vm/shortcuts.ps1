#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$shell = New-Object -ComObject WScript.Shell
$powershell = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
foreach ($action in @('On','Off','Status')) {
    $shortcut = $shell.CreateShortcut((Join-Path $root "Bot $action.lnk"))
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = "-NoLogo -NoProfile -NoExit -File `"$PSScriptRoot\control.ps1`" -Action $action"
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = "GunBound AI Lab: $action for the owned BotOne VM"
    $shortcut.Save()
}
Write-Output 'Created Bot On, Bot Off and Bot Status shortcuts in the lab folder; no host startup entry was added.'
