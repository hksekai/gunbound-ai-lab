#requires -Version 7.4
<#
Usage: .\setup\prepare-backend.ps1 -ServerSourceDirectory <folder> -MariaDbArchive <zip> [-Check]
The supplied official ZIP is never downloaded or executed by -Check. Obtain/verify its
authenticity with MariaDB before use; ZIP layout, x64 PE resources and version 11.4.13.0
are checked locally. -Check alone runs asset-free synthetic checks; with both inputs it
also validates their shape and target freshness without starting services.
Normal setup briefly supervises only its new loopback database, provisions fresh accounts,
and gracefully stops it before reporting success. A completed, stopped installation is
validated read-only and reused, including guarded later network-profile changes. Interrupted
or incompatible installations are not resumed, reset, reseeded or silently repaired.
#>
[CmdletBinding()]
param([string]$ServerSourceDirectory, [string]$MariaDbArchive, [switch]$Check)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\backend\prepare.ps1" -ServerSourceDirectory $ServerSourceDirectory

function Assert-BackendMariaDbImage([byte[]]$Bytes) {
    $stream=[IO.MemoryStream]::new($Bytes,$false)
    $pe=$null
    try {
        $pe=[Reflection.PortableExecutable.PEReader]::new($stream)
        if ($pe.PEHeaders.CoffHeader.Machine -ne [Reflection.PortableExecutable.Machine]::Amd64 -or
            $pe.PEHeaders.PEHeader.Magic -ne [Reflection.PortableExecutable.PEMagic]::PE32Plus) {
            throw 'The MariaDB ZIP must contain x64 PE32+ executables.'
        }
        $directory=$pe.PEHeaders.PEHeader.ResourceTableDirectory
        if ($directory.RelativeVirtualAddress -le 0 -or $directory.Size -lt 16 -or $directory.Size -gt 16777216) {
            throw 'A MariaDB image has no bounded version resource.'
        }
        $resources=[byte[]]$pe.GetSectionData($directory.RelativeVirtualAddress).GetContent(0,$directory.Size)
        function Read-VersionDirectory([int]$Offset) {
            if ($Offset -lt 0 -or $Offset -gt $resources.Length-16) { throw 'Invalid PE version directory bounds.' }
            $count=[int][BitConverter]::ToUInt16($resources,$Offset+12)+[int][BitConverter]::ToUInt16($resources,$Offset+14)
            if ($count -lt 1 -or $count -gt 1024 -or $Offset+16+8*$count -gt $resources.Length) {
                throw 'Invalid PE version directory count.'
            }
            for ($i=0; $i -lt $count; $i++) {
                $at=$Offset+16+8*$i
                $value=[BitConverter]::ToUInt32($resources,$at+4)
                [pscustomobject]@{id=[BitConverter]::ToUInt32($resources,$at); offset=[int]($value -band 0x7fffffff); directory=[bool]($value -band 0x80000000L)}
            }
        }
        $types=@(Read-VersionDirectory 0 | Where-Object id -EQ 16)
        if ($types.Count -ne 1 -or !$types[0].directory) { throw 'Exactly one PE version-resource type is required.' }
        $names=@(Read-VersionDirectory $types[0].offset)
        if ($names.Count -ne 1 -or !$names[0].directory) { throw 'Exactly one PE version-resource identity is required.' }
        foreach ($language in @(Read-VersionDirectory $names[0].offset)) {
            if ($language.directory -or $language.offset -gt $resources.Length-16) { throw 'Invalid PE version-resource leaf.' }
            $rva=[BitConverter]::ToInt32($resources,$language.offset)
            $size=[BitConverter]::ToInt32($resources,$language.offset+4)
            if ($size -lt 92 -or $size -gt 65536) { throw 'Invalid PE fixed version size.' }
            $version=[byte[]]$pe.GetSectionData($rva).GetContent(0,$size)
            if ([BitConverter]::ToUInt16($version,0) -lt 92 -or [BitConverter]::ToUInt16($version,0) -gt $size -or
                [BitConverter]::ToUInt16($version,2) -ne 52 -or [BitConverter]::ToUInt16($version,4) -ne 0 -or
                [Text.Encoding]::Unicode.GetString($version,6,32) -cne "VS_VERSION_INFO`0" -or
                [BitConverter]::ToUInt32($version,40) -ne 0xfeef04bdL -or [BitConverter]::ToUInt32($version,44) -ne 0x00010000 -or
                [BitConverter]::ToUInt32($version,48) -ne 0x000b0004 -or [BitConverter]::ToUInt32($version,52) -ne 0x000d0000 -or
                [BitConverter]::ToUInt32($version,56) -ne 0x000b0004 -or [BitConverter]::ToUInt32($version,60) -ne 0x000d0000) {
                throw 'MariaDB executable file/product versions must both be exactly 11.4.13.0.'
            }
        }
    } catch {
        throw 'The archive contains an unsupported or malformed MariaDB PE image; expected x64 file/product version 11.4.13.0.'
    } finally {
        if ($pe) { $pe.Dispose() }
        $stream.Dispose()
    }
}

function Get-BackendArchivePlan([IO.Compression.ZipArchive]$Archive, [string]$DestinationRoot) {
    $root=Resolve-BackendLocalPath $DestinationRoot
    $top='mariadb-11.4.13-winx64'
    $entries=[Collections.Generic.List[object]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $total=0L
    if ($Archive.Entries.Count -lt 4 -or $Archive.Entries.Count -gt 20000) { throw 'Unsupported or empty MariaDB archive entry count.' }
    foreach ($entry in $Archive.Entries) {
        $name=$entry.FullName.Replace('/','\')
        $directory=$name.EndsWith('\')
        $relative=$name.TrimEnd('\')
        $segments=$relative.Split('\')
        if (!$relative -or $segments[0] -cne $top -or
            @($segments | Where-Object { !$_ -or $_ -in @('.','..') }).Count -or
            $name -match '[\x00-\x1f<>:"|?*]' -or $name.StartsWith('\') -or
            ($segments.Count -eq 1 -and !$directory)) { throw 'The archive must contain only canonical paths below mariadb-11.4.13-winx64.' }
        $destination=Resolve-BackendLocalPath "$root\$relative"
        if (!$destination.StartsWith("$root\$top\",[StringComparison]::OrdinalIgnoreCase) -and $destination -ine "$root\$top") {
            throw 'A MariaDB archive entry escaped the destination.'
        }
        if ($destination.Length -gt 240 -or !$seen.Add($relative)) { throw 'Archive paths are too long, duplicated or case-conflicting.' }
        $attributes=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes),0)
        $kind=($attributes -shr 16) -band 0xf000
        if (($attributes -band 0x400) -or $kind -notin @(0,0x8000,0x4000) -or
            ($kind -eq 0x4000 -and !$directory) -or ($kind -eq 0x8000 -and $directory)) {
            throw 'Archive links, reparse points and special files are forbidden.'
        }
        $total+=$entry.Length
        if ($entry.Length -lt 0 -or $entry.Length -gt 536870912 -or $total -gt 4294967296L -or
            ($directory -and $entry.Length -ne 0)) { throw 'The MariaDB archive exceeds safe expanded-size limits.' }
        if (!$directory) { $null=$files.Add($relative) }
        $entries.Add([pscustomobject]@{entry=$entry;relative=$relative;path=$destination;directory=$directory})
    }
    foreach ($entry in $entries) {
        for ($parent=Split-Path -Parent $entry.relative; $parent; $parent=Split-Path -Parent $parent) {
            if ($files.Contains($parent)) { throw 'Archive file/directory paths overlap.' }
        }
    }
    foreach ($file in @('mariadbd.exe','mariadb.exe','mariadb-admin.exe','mariadb-install-db.exe')) {
        $required=@($entries | Where-Object { $_.relative -ceq "$top\bin\$file" -and !$_.directory })
        if ($required.Count -ne 1 -or $required[0].entry.Length -lt 256 -or $required[0].entry.Length -gt 134217728) {
            throw 'The exact portable MariaDB server, client, admin and offline initializer are required.'
        }
        $input=$required[0].entry.Open()
        try {
            $bytes=[byte[]]::new([int]$required[0].entry.Length)
            $input.ReadExactly($bytes,0,$bytes.Length)
            if ($input.ReadByte() -ne -1) { throw 'An archive entry exceeds its declared expanded length.' }
            Assert-BackendMariaDbImage $bytes
        } finally { $input.Dispose() }
    }
    ,$entries.ToArray()
}

function Expand-BackendArchive($Plan, [string]$Root) {
    $destination="$Root\runtime\mariadb\mariadb-11.4.13-winx64"
    if (Test-Path -LiteralPath $destination) { throw 'The portable MariaDB destination already exists; extraction never merges or overwrites.' }
    Assert-BackendPath $destination $Root
    $null=New-Item -ItemType Directory -Path $destination
    Protect-BackendPath $destination $Root
    $buffer=[byte[]]::new(65536)
    foreach ($item in $Plan) {
        Assert-BackendPath $item.path $destination
        if ($item.directory) { $null=New-Item -ItemType Directory -Path $item.path -Force; continue }
        $null=New-Item -ItemType Directory -Path (Split-Path $item.path) -Force
        $input=$item.entry.Open()
        $output=[IO.File]::Open($item.path,'CreateNew','Write','None')
        try {
            $remaining=$item.entry.Length
            while ($remaining -gt 0) {
                $read=$input.Read($buffer,0,[int][Math]::Min($buffer.Length,$remaining))
                if (!$read) { throw 'A MariaDB archive entry is truncated.' }
                $output.Write($buffer,0,$read)
                $remaining-=$read
            }
            if ($input.ReadByte() -ne -1) { throw 'A MariaDB archive entry exceeds its declared expanded length.' }
            $output.Flush($true)
        } finally { $output.Dispose(); $input.Dispose() }
    }
}

function Get-BackendNetworkFileNames {
    @('backend\native\Server8360\Gunboundserv3.exe','backend\native\Central\GunBoundBroker3.exe',
        'backend\native\Server8360\setting.txt','backend\native\Central\setting.txt',
        'backend\native\Central\GameServerList.txt','backend\loopback-patches.json')
}

function Assert-BackendStoppedProcesses([object[]]$Processes, [string]$Root) {
    foreach ($process in $Processes) {
        $path=[string]$process.ExecutablePath
        $command=[string]$process.CommandLine
        if ($path.StartsWith("$Root\backend\native\",[StringComparison]::OrdinalIgnoreCase) -or
            $path.StartsWith("$Root\runtime\mariadb\",[StringComparison]::OrdinalIgnoreCase) -or
            $command.IndexOf("$Root\backend\start.ps1",[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $command.IndexOf("$Root\backend\mysql-compat.ps1",[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw 'The prepared backend is active or starting. Stop its owned services with the lifecycle helpers before rerunning setup; no process was stopped.'
        }
    }
}

function Assert-BackendStopped([string]$Root) {
    foreach ($relative in @('backend\bootstrap.lock','backend\database.pid','backend\database-processes.json',
        'backend\core-processes.json','backend\buddy-processes.json','backend\database.stop','backend\core.stop','backend\buddy.stop')) {
        Assert-BackendPath "$Root\$relative" $Root
        if (Test-Path -LiteralPath "$Root\$relative") {
            throw 'Backend lifecycle/operation state is still present. Finish owned lifecycle cleanup before rerunning setup; no state was removed.'
        }
    }
    Assert-BackendStoppedProcesses @(Get-CimInstance Win32_Process -ErrorAction Stop) $Root
}

function Get-BackendInitialNetworkHash([string]$Relative, [byte[]]$Bytes) {
    $initial=switch -CaseSensitive ($Relative) {
        'backend\native\Server8360\setting.txt' {
            Convert-LabNetworkSettingBytes $Bytes 'Accept' '127.0.0.1;127.0.0.2;' 8360
        }
        'backend\native\Central\setting.txt' {
            Convert-LabNetworkSettingBytes $Bytes 'Accept' '127.0.0.1;' 8372
        }
        'backend\native\Central\GameServerList.txt' {
            Convert-LabWorldListBytes $Bytes '127.0.0.1'
        }
        default { throw 'Only the three guarded native network settings may be normalized.' }
    }
    Get-BackendHash $initial
}

function Assert-BackendCompletedNetwork([string]$Root, $State) {
    . "$Root\backend\network-config.ps1"
    $network=Get-LabNetwork
    # This re-proves the patched core images from pinned originals, not the old loopback hashes.
    Assert-LabNetworkPrepared $network
    foreach ($relative in @('backend\native\Server8360\setting.txt','backend\native\Central\setting.txt','backend\native\Central\GameServerList.txt')) {
        $hash=Get-BackendInitialNetworkHash $relative (Read-BackendBytes "$Root\$relative")
        if ($hash -cne $State.files.$relative) {
            throw 'A prepared native setting changed beyond its permitted network address/allowlist; existing credentials and configuration were not replaced.'
        }
    }
    Assert-LabNetworkUnchanged $network
}

function Assert-BackendCompleted([string]$Root, [string]$RequestedSource = '', [string]$RequestedArchive = '') {
    $state=Read-BackendJson $Root 'private\backend\setup-state.json'
    Assert-BackendSavedState $state $Root 'complete-stopped'
    Assert-BackendStopped $Root
    $source=Read-BackendJson $Root 'private\backend\source.json'
    if (($source.schemaVersion -isnot [int] -and $source.schemaVersion -isnot [long]) -or $source.schemaVersion -ne 1 -or
        $source.serverSourceDirectory -isnot [string] -or $source.mariaDbArchive -isnot [string] -or
        $source.mariaDbArchiveSha256 -isnot [string] -or $source.sourceSqlSha256 -isnot [string] -or
        $source.mariaDbArchiveSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $source.sourceSqlSha256 -cnotmatch '\A[0-9a-f]{64}\z') {
        throw 'Saved backend source provenance is incomplete or incompatible.'
    }
    $savedSource=Resolve-BackendLocalPath $source.serverSourceDirectory
    $savedArchive=Resolve-BackendLocalPath $source.mariaDbArchive
    if (($RequestedSource -and (Resolve-BackendLocalPath $RequestedSource) -ine $savedSource) -or
        ($RequestedArchive -and (Resolve-BackendLocalPath $RequestedArchive) -ine $savedArchive)) {
        throw 'The completed backend was prepared from different input paths. Reruns do not replace its source configuration, database or accounts.'
    }
    if ($RequestedArchive -and (Test-Path -LiteralPath $savedArchive -PathType Leaf)) {
        Assert-BackendPath $savedArchive
        if ((Get-FileHash -LiteralPath $savedArchive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $source.mariaDbArchiveSha256) {
            throw 'The supplied MariaDB archive differs from the recorded completed installation.'
        }
    }
    if ($RequestedSource -and (Test-Path -LiteralPath "$savedSource\Database\gunbound.sql" -PathType Leaf) -and
        (Get-BackendHash (Read-BackendBytes "$savedSource\Database\gunbound.sql")) -cne $source.sourceSqlSha256) {
        throw 'The supplied source SQL differs from the recorded completed installation.'
    }
    $networkFiles=@(Get-BackendNetworkFileNames)
    foreach ($field in $state.files.PSObject.Properties) {
        $path="$Root\$($field.Name)"
        Assert-BackendPath $path $Root
        if ($field.Name -cin $networkFiles) { continue }
        $hash=if ($field.Name -cin @('private\backend\accounts.json','private\accounts.json','private\vm\bot-accounts.json')) {
            $records=Read-BackendJson $Root $field.Name
            Get-BackendHash ([Text.Encoding]::UTF8.GetBytes((ConvertTo-BackendAccountsJson $records)))
        } else { Get-BackendHash (Read-BackendBytes $path) }
        if ($hash -cne $field.Value) {
            throw 'A prepared backend artifact differs from its completed receipt; no existing data or credentials were repaired or replaced.'
        }
    }
    $accounts=Read-BackendJson $Root 'private\backend\accounts.json'
    $client=Read-BackendJson $Root 'private\accounts.json'
    $bots=Read-BackendJson $Root 'private\vm\bot-accounts.json'
    Assert-BackendAccountScopes $accounts $client $bots
    $credentials=Read-BackendJson $Root 'private\backend\credentials.json'
    $agent=Read-BackendJson $Root 'private\backend\legacy-agent.json'
    $null=@(New-BackendGrantSql $credentials $agent)
    $configuration=New-BackendConfiguration $state.root $credentials
    if ([Text.Encoding]::UTF8.GetString((Read-BackendBytes "$Root\private\backend\admin.ini")) -cne $configuration.admin -or
        [Text.Encoding]::UTF8.GetString((Read-BackendBytes "$Root\private\backend\my.ini")) -cne $configuration.server) {
        throw 'Saved database configuration does not match this installation and its protected credentials.'
    }
    foreach ($name in @('mariadbd.exe','mariadb.exe','mariadb-admin.exe','mariadb-install-db.exe')) {
        Assert-BackendMariaDbImage (Read-BackendBytes "$Root\runtime\mariadb\mariadb-11.4.13-winx64\bin\$name")
    }
    $schema=Get-BackendSchemaPlan ([Text.Encoding]::UTF8.GetString((Read-BackendBytes "$Root\backend\schema-static.sql")))
    Assert-BackendSchema $schema
    foreach ($relative in @('runtime\mariadb\data\mysql','runtime\mariadb\data\gunbound')) {
        Assert-BackendPath "$Root\$relative" $Root
        if (!(Test-Path -LiteralPath "$Root\$relative" -PathType Container)) { throw 'The completed backend database directories are missing; initialization will not be repeated.' }
    }
    foreach ($table in $schema.tables.name) {
        foreach ($extension in @('frm','MYD','MYI')) {
            $path="$Root\runtime\mariadb\data\gunbound\$table.$extension"
            Assert-BackendPath $path $Root
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The completed MyISAM database is incomplete; missing tables will not be recreated.' }
        }
    }
    Assert-BackendCompletedNetwork $Root $state
    Assert-BackendStopped $Root
}

function Invoke-FreshBackendSetup([string]$Root, [string]$SourceDirectory, [string]$ArchivePath, [switch]$CheckOnly) {
    $rootPath=Resolve-BackendLocalPath $Root
    Assert-BackendPath $rootPath
    if (!$CheckOnly -and (Test-Path -LiteralPath "$rootPath\private\backend\setup-state.json")) {
        Assert-BackendCompleted $rootPath $SourceDirectory $ArchivePath
        Write-Output 'PASS: completed backend verified on disk and STOPPED; canonical four/client two/bot-only three metadata retained. No database session, process, credential, account or file was created or changed.'
        return
    }
    Assert-BackendFresh $rootPath
    if (!$SourceDirectory -or !$ArchivePath) { throw '-ServerSourceDirectory <folder> and -MariaDbArchive <official 11.4.13 x64 zip> are required for a new installation.' }
    $archivePath=Resolve-BackendLocalPath $ArchivePath
    Assert-BackendPath $archivePath
    if (!(Test-Path -LiteralPath $archivePath -PathType Leaf) -or [IO.Path]::GetExtension($archivePath) -ine '.zip') {
        throw '-MariaDbArchive must identify an existing official MariaDB 11.4.13 Windows x64 ZIP.'
    }
    if ((Get-Item -LiteralPath $archivePath).Length -gt 1073741824) { throw 'The MariaDB ZIP exceeds the supported 1 GiB compressed input limit.' }
    if (Test-Path -LiteralPath "$rootPath\network.json") { throw 'Run fresh backend setup before generating network.json.' }
    if (!$CheckOnly) {
        foreach ($command in @('pwsh','icacls.exe','Get-NetTCPConnection','Get-NetUDPEndpoint','Get-CimInstance')) {
            if (!(Get-Command $command -ErrorAction SilentlyContinue)) {
                throw "Missing prerequisite: $command. Use supported Windows with PowerShell 7.4 or newer; setup does not install host tools."
            }
        }
    }
    if (!(Test-Path -LiteralPath "$rootPath\client-build\ClientPatch.cs" -PathType Leaf)) {
        throw 'The client-build\ClientPatch.cs host helper source is missing.'
    }
    $source=Get-BackendSourcePlan $SourceDirectory
    $archiveStream=[IO.File]::Open($archivePath,'Open','Read','Read')
    $archive=$null; $lock=$null; $supervisor=$null; $supervisorIdentity=$null; $databaseProcess=$null; $owned=$null; $complete=$false
    try {
        $archive=[IO.Compression.ZipArchive]::new($archiveStream,[IO.Compression.ZipArchiveMode]::Read,$true)
        $plan=Get-BackendArchivePlan $archive "$rootPath\runtime\mariadb"
        if ($CheckOnly) {
            Write-Output 'PASS: fresh target, source layout/pinned native core, reviewed schema/static-only SQL, and MariaDB 11.4.13 x64 archive shape. No files, credentials, services or processes changed.'
            return
        }
        $firewall=New-Object -ComObject HNetCfg.FwPolicy2
        foreach ($profile in @(1,2,4)) {
            if (!$firewall.FirewallEnabled($profile) -or $firewall.DefaultInboundAction($profile) -ne 0) {
                throw 'Enabled, default-inbound-block firewall profiles are required. No firewall settings were changed.'
            }
        }
        if (Get-NetTCPConnection -State Listen -LocalPort 3307 -ErrorAction SilentlyContinue) {
            throw 'Loopback database port 3307 is already in use; no existing process was stopped.'
        }
        $lock=[IO.File]::Open("$rootPath\backend\bootstrap.lock",'CreateNew','Write','None')
        Assert-BackendFresh $rootPath
        $archiveStream.Position=0
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $archiveHash=[Convert]::ToHexString($sha.ComputeHash($archiveStream)).ToLowerInvariant() } finally { $sha.Dispose() }
        Expand-BackendArchive $plan $rootPath
        Initialize-Backend $rootPath $source $archivePath $archiveHash
        $pwsh=(Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
        $arguments='-NoProfile -File "' + "$rootPath\backend\start.ps1" + '" -Part Database'
        $supervisor=Start-Process -FilePath $pwsh -ArgumentList $arguments -WorkingDirectory $rootPath -NoNewWindow -PassThru `
            -RedirectStandardOutput "$rootPath\logs\backend-setup-supervisor-stdout.log" `
            -RedirectStandardError "$rootPath\logs\backend-setup-supervisor-stderr.log"
        $null=$supervisor.Handle
        $supervisorIdentity=[pscustomobject]@{Id=$supervisor.Id;Path=$pwsh;StartTime=$supervisor.StartTime}
        $watch=[Diagnostics.Stopwatch]::StartNew()
        . "$rootPath\backend\network-config.ps1"
        $network=Get-LabNetwork
        do {
            $supervisor.Refresh()
            if ($supervisor.HasExited) { throw 'The retained database supervisor exited before readiness; inspect protected backend setup logs.' }
            if (Test-Path -LiteralPath "$rootPath\backend\database-processes.json") {
                $owned=Get-BackendOwnedDatabase $rootPath $supervisorIdentity
                if (!$databaseProcess) {
                    $databaseProcess=Get-Process -Id $owned.pid -ErrorAction Stop
                    $null=$databaseProcess.Handle
                    if ($databaseProcess.Path -ine $owned.path -or $databaseProcess.StartTime.ToUniversalTime().Ticks -ne $owned.startedUtcTicks) {
                        throw 'The database identity changed before its process handle could be retained.'
                    }
                }
                if (@(Assert-LabServiceEndpoints $owned $network -AllowStarting).Count -eq 1) { break }
            }
            Start-Sleep -Milliseconds 250
        } until ($watch.Elapsed.TotalSeconds -ge 40)
        if (!$owned -or @(Assert-LabServiceEndpoints $owned $network -AllowStarting).Count -ne 1) {
            throw 'The owned loopback database did not become ready within 40 seconds.'
        }
        Invoke-BackendProvision $rootPath
        & "$rootPath\backend\health.ps1" -DatabaseOnly | Out-Null
        $complete=$true
    } finally {
        try {
            if ($supervisor) {
                if (Test-Path -LiteralPath "$rootPath\backend\database-processes.json") {
                    $record=@(Get-Content -LiteralPath "$rootPath\backend\database-processes.json" -Raw | ConvertFrom-Json)
                    if ($record.Count -ne 1) { throw 'Shutdown refused an ambiguous database identity; setup did not complete.' }
                    Assert-BackendProcessRecord $record[0] $rootPath $supervisorIdentity
                    & "$rootPath\backend\stop.ps1" -Part Database | Out-Null
                } elseif (!$supervisor.HasExited) {
                    [IO.File]::WriteAllText("$rootPath\backend\database.stop",'stop')
                }
                if (!$supervisor.WaitForExit(45000)) {
                    throw 'Graceful setup shutdown is still pending; retain the protected state and supervisor, and do not proceed with VM packaging.'
                }
                if ($databaseProcess -and !$databaseProcess.HasExited) {
                    throw 'The owned database is still running; setup did NOT complete and it was not forcibly killed.'
                }
                if ($supervisor.ExitCode -ne 0) { throw 'The backend supervisor reported a startup/shutdown failure; inspect protected setup logs.' }
            }
        } finally {
            if ($archive) { $archive.Dispose() }
            $archiveStream.Dispose()
            if ($lock) { $lock.Dispose(); [IO.File]::Delete("$rootPath\backend\bootstrap.lock") }
            if ($databaseProcess -and $databaseProcess.HasExited) { $databaseProcess.Dispose() }
            if ($supervisor -and $supervisor.HasExited) { $supervisor.Dispose() }
        }
    }
    if ($complete) {
        . "$rootPath\backend\network-config.ps1"
        Assert-LabCoreStopped
        if (Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -ieq "$rootPath\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe" }) {
            throw 'An installation-owned database image remains active; setup did not finish stopped.'
        }
        $path="$rootPath\private\backend\setup-state.json"
        $state=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($state.phase -cne 'provisioned') { throw 'The verified provisioning receipt is missing; setup did not complete.' }
        $state.phase='complete-stopped'
        Write-BackendPrivate $path ($state | ConvertTo-Json -Depth 5) $rootPath -Replace
        Write-Output 'PASS: fresh backend verified and STOPPED. Canonical server accounts: Player/BotOne/BotTwo/BotThree; client metadata: Player/BotOne; VM metadata: three bots only. Credentials and source paths remain private.'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Check) {
        if ([bool]$ServerSourceDirectory -ne [bool]$MariaDbArchive) { throw '-Check accepts either no assets or both -ServerSourceDirectory and -MariaDbArchive.' }
        & "$PSScriptRoot\check-backend.ps1"
        if ($ServerSourceDirectory) {
            Invoke-FreshBackendSetup (Split-Path $PSScriptRoot) $ServerSourceDirectory $MariaDbArchive -CheckOnly
        }
    } else {
        Invoke-FreshBackendSetup (Split-Path $PSScriptRoot) $ServerSourceDirectory $MariaDbArchive
    }
}
