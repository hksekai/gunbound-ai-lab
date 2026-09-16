param(
    [ValidateSet('human', 'bot')]
    [string]$Role = 'human'
)

$ErrorActionPreference = 'Stop'
$action = if ($Role -eq 'human') { 'play' } else { 'bot-client' }
& "$PSScriptRoot\lab-client.exe" $action

if ($LASTEXITCODE -ne 0) { throw "The $Role client exited with code $LASTEXITCODE." }
