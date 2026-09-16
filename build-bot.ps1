$ErrorActionPreference = 'Stop'
& (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe') /nologo /platform:x86 /target:exe /optimize+ `
    /main:BotController /r:System.Drawing.dll /r:System.Web.Extensions.dll `
    "/out:$PSScriptRoot\bot-controller.exe" "$PSScriptRoot\bot.cs" "$PSScriptRoot\aim.cs" `
    "$PSScriptRoot\lab-client.cs" "$PSScriptRoot\client-build\ClientPatch.cs"
if ($LASTEXITCODE -ne 0) { throw "Bot controller build failed ($LASTEXITCODE)." }
& "$PSScriptRoot\bot-controller.exe" --self-check
if ($LASTEXITCODE -ne 0) { throw "Bot controller self-check failed ($LASTEXITCODE)." }
