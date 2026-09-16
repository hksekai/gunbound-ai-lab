#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
$full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
if (!$full.StartsWith($PSScriptRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Read only a staged client-build startup trace.' }
$stream = [IO.FileStream]::new($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
try {
    if ($stream.Length -ne 128) { throw 'Incomplete startup trace.' }
    $data = [byte[]]::new(128)
    $stream.ReadExactly($data,0,$data.Length)
} finally { $stream.Dispose() }
if ($data.Length -ne 128 -or [Text.Encoding]::ASCII.GetString($data,0,4) -ne 'GBC2' -or [BitConverter]::ToUInt32($data,4) -ne 2) {
    throw 'Incomplete or unsupported startup trace.'
}
function Read-Name([int]$Offset) {
    $end = $Offset
    while ($end -lt $Offset + 32 -and $data[$end]) { $end++ }
    [Text.Encoding]::ASCII.GetString($data,$Offset,$end-$Offset)
}
$phase = [BitConverter]::ToUInt32($data,8)
$before = Read-Name 16
$during = Read-Name 48
$argument = Read-Name 80
$lastError = [BitConverter]::ToUInt32($data,116)
$interpretation = if ($phase -ne 2) {
    'No completed startup CreateMutex call was recorded. Do not infer which earlier stage or guard caused an exit.'
} elseif ($lastError -eq 183) {
    'CreateMutex reported ERROR_ALREADY_EXISTS; the original single-instance rejection remains active.'
} elseif ([BitConverter]::ToUInt32($data,112) -ne 0) {
    'The startup mutex call succeeded without ERROR_ALREADY_EXISTS. A subsequent normal exit needs later-stage evidence, not another blanket guard bypass.'
} else {
    'CreateMutex failed with the recorded Windows error.'
}
[ordered]@{
    phase=$phase
    nameVerifiedBeforeResume=$before
    originalImageNameAtGuard=if($phase -eq 2){$during}else{$null}
    originalBufferChanged=if($phase -eq 2){$before -cne $during}else{$null}
    actualCreateMutexArgument=if($phase -eq 2){$argument}else{$null}
    createMutexTargetVa=('0x{0:x8}' -f [BitConverter]::ToUInt32($data,12))
    returnedHandle=('0x{0:x8}' -f [BitConverter]::ToUInt32($data,112))
    lastError=if($phase -eq 2){$lastError}else{$null}
    argumentPointer=('0x{0:x8}' -f [BitConverter]::ToUInt32($data,124))
    interpretation=$interpretation
    note='Only mutex names/API results are recorded; no account credentials or network payloads.'
} | ConvertTo-Json -Depth 4
