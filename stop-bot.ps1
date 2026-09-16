$ErrorActionPreference = 'Stop'
$recordPath = Join-Path $PSScriptRoot 'bot-process.json'
if (-not (Test-Path -LiteralPath $recordPath)) {
    Write-Output 'No BotOne controller has been started.'
    return
}
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$process = Get-Process -Id $record.ProcessId -ErrorAction SilentlyContinue
if (-not $process) {
    Write-Output 'BotOne controller is already stopped.'
    return
}
try {
    $expected = Join-Path $PSScriptRoot 'bot-controller.exe'
    if ($process.StartTime.ToUniversalTime().Ticks -ne $record.StartedUtcTicks -or
        -not [string]::Equals($process.Path, $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The recorded PID no longer identifies this lab controller; it will not be touched.'
    }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'bot.stop'), 'stop')
    if (-not $process.WaitForExit(8000)) {
        throw 'BotOne did not stop promptly. Use Ctrl+C in its console; it has not been forcibly killed.'
    }
    Write-Output 'BotOne stopped gracefully; both game clients were left open.'
} finally {
    $process.Dispose()
}
