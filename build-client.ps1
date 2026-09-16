param([switch]$Control, [switch]$Tools)

$ErrorActionPreference = 'Stop'
$work = Join-Path $PSScriptRoot 'session\build-work'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:TEMP = $work
$env:TMP = $work
if ($Control -and $Tools) { throw 'Choose either -Control or -Tools, not both.' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
$outputName = if ($Tools) { 'lab-tools.exe' } elseif ($Control) { 'lab-control.exe' } else { 'lab-client.exe' }
& $compiler /nologo /platform:x86 /target:exe /optimize+ `
    /r:System.Drawing.dll /r:System.Web.Extensions.dll `
    "/out:$PSScriptRoot\$outputName" "$PSScriptRoot\lab-client.cs" "$PSScriptRoot\client-build\ClientPatch.cs"
if ($LASTEXITCODE -ne 0) { throw "Client helper compilation failed ($LASTEXITCODE)." }
& "$PSScriptRoot\$outputName" self-check
if ($LASTEXITCODE -ne 0) { throw "Client helper self-check failed ($LASTEXITCODE)." }
