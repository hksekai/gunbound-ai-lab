#requires -Version 7.4
<#
Synthetic backend bootstrap checks only. No database, archive extraction, private-data
read/write, network, ACL change, process launch or legacy-maintenance entry point is used.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. "$root\backend\prepare.ps1"
. "$root\setup\prepare-backend.ps1"

function Require([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw "BackendCheck: $Message" }
}
function Reject([scriptblock]$Code) {
    $failed=$false
    try { & $Code | Out-Null } catch { $failed=$true }
    Require $failed "An unsafe synthetic input was accepted at check line $($MyInvocation.ScriptLineNumber)."
}
function Load-BackendCheckFunctions([string]$Path, [string[]]$Names) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Require (!$errors.Count) 'A bootstrap source script has a parser error.'
    foreach ($name in $Names) {
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false)
        Require ($null -ne $definition) 'An expected pure validator is missing.'
        $definition.Extent.Text
    }
}

foreach ($file in @('backend\prepare.ps1','setup\prepare-backend.ps1','backend\health.ps1',
    'backend\start.ps1','backend\stop.ps1','accounts\provision-room-bots.ps1','setup\check-backend.ps1')) {
    Load-BackendCheckFunctions "$root\$file" @() | Out-Null
    Require ([IO.File]::ReadAllText("$root\$file") -notmatch '(?i)[A-Z]:\\Users\\') 'A personal absolute installation path remains in backend source.'
}
$layout=Get-BackendSourceLayout "$root\synthetic source folder"
Require ($layout.sql -ceq "$root\synthetic source folder\Database\gunbound.sql" -and
    $layout.native -ceq "$root\synthetic source folder\Server Binaries\GunBoundXP") 'Source layout did not preserve spaces/canonical bundle paths.'
Require ((Resolve-BackendLocalPath "$root\setup\..\backend") -ceq "$root\backend") 'Local path normalization changed.'
Require ((Resolve-BackendLocalPath '.') -ceq $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path.TrimEnd('\')) 'Relative inputs did not use the PowerShell working directory.'
Assert-BackendPath "$root\backend\prepare.ps1" $root
foreach ($path in @('\\server\share','\\?\C:\escape','C:\data:stream','C:\NUL.txt','C:\folder.\file','C:\bad"name')) {
    Reject { Resolve-BackendLocalPath $path }
}
Reject { Assert-BackendPath ($root+'-other\backend') $root }
Reject { Get-BackendSourcePlan "$root\setup" }
Reject { Invoke-FreshBackendSetup $root '' '' -CheckOnly }

$savedGuard=${function:Assert-BackendPath}
try {
    $existing=@()
    function Assert-BackendPath([string]$Path,[string]$Root) {}
    function Test-Path([string]$LiteralPath) { $LiteralPath -in $existing }
    Assert-BackendFresh $root
    foreach ($relative in @('private\backend','private\accounts.json','private\vm\bot-accounts.json','backend\native',
        'backend\schema-static.sql','backend\manifest.json','backend\loopback-patches.json','backend\database-processes.json',
        'runtime\mariadb\data','runtime\mariadb\work','runtime\mariadb\mariadb-11.4.13-winx64')) {
        $existing=@("$root\$relative")
        Reject { Assert-BackendFresh $root }
    }
    $existing=@("$root\runtime\mariadb\mariadb-11.4.13-winx64")
    Assert-BackendFresh $root -DistributionInstalled
} finally {
    Set-Item -LiteralPath 'Function:\Assert-BackendPath' -Value $savedGuard
    Remove-Item -LiteralPath 'Function:\Test-Path'
}

$ddl=@'
CREATE TABLE `Item` (
  `No` int(11) NOT NULL AUTO_INCREMENT,
  `Name` varchar(50) COLLATE latin1_swedish_ci NOT NULL DEFAULT '',
  PRIMARY KEY (`No`)
) ENGINE=MyISAM AUTO_INCREMENT=999999 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci ROW_FORMAT=FIXED;
'@
$historical='SOURCE_ROW_' + [Guid]::NewGuid().ToString('N')
$dump="-- discarded dump controls`n/*!40101 SET NAMES latin1 */;`nDROP TABLE IF EXISTS ``Item``;`n" + $ddl + "`n" +
    "INSERT INTO ``Item`` VALUES (1,'literal; -- comment /* inside */ escaped \' quote');`n" +
    "INSERT INTO ``Menu`` VALUES (1,NULL,-2,0x0102);`nINSERT INTO ``MenuDat`` VALUES (1,'menu');`nINSERT INTO ``Ranks`` VALUES (1,2);`n" +
    "INSERT INTO ``User`` VALUES ('$historical','a;`nCREATE TABLE ``Never`` (not schema);');`n" +
    "INSERT INTO ``Chest`` VALUES ('$historical');`nUPDATE ``Item`` SET ``Name``='$historical';`n"
$schema=Get-BackendSchemaPlan $dump
Require ($schema.tables.Count -eq 1 -and $schema.staticTables.Count -eq 4 -and $schema.staticCount -eq 4) 'Schema/static statement extraction count changed.'
Require (!$schema.sql.Contains($historical) -and !$schema.sql.Contains('Never') -and
    !$schema.sql.Contains('AUTO_INCREMENT=999999') -and $schema.sql.Contains('AUTO_INCREMENT,') -and
    $schema.sql.Contains("literal; -- comment /* inside */ escaped \' quote")) 'Historical data, counters or quote/comment handling escaped the extraction boundary.'
Require ((Get-BackendSchemaPlan ([string][char]0xFEFF+$dump)).sql -ceq $schema.sql) 'UTF-8 BOM handling changed source extraction.'
Reject { Assert-BackendSchema $schema }
Reject { Get-BackendSchemaPlan ($ddl + "`n" + $ddl) }
Reject { Get-BackendSchemaPlan $ddl.Replace('ENGINE=MyISAM','ENGINE=InnoDB') }
Reject { Get-BackendSchemaPlan $ddl.Replace(' ROW_FORMAT=FIXED',' DATA DIRECTORY=''C:\\outside''') }
Reject { Get-BackendSchemaPlan $ddl.Replace("DEFAULT ''","DEFAULT (SELECT 1)") }
Reject { Get-BackendSchemaPlan $ddl.Replace('ENGINE=MyISAM','/*!50000 ENGINE=MyISAM */ ENGINE=MyISAM') }
Reject { Get-BackendSchemaPlan 'CREATE TABLE `Partial` (' }
Reject { Get-BackendSchemaPlan ($ddl+"`nCREATE VIEW ``unexpected`` AS SELECT * FROM ``Item``;") }
Reject { Get-BackendSchemaPlan ($ddl+"`nALTER TABLE ``Item`` ADD ``extra`` int;") }
Reject { Get-BackendSchemaPlan "INSERT INTO ``User`` VALUES ('unclosed);" }
foreach ($insert in @(
    'INSERT INTO `Item` VALUES (1,LOAD_FILE(''secret''));',
    'INSERT INTO `Menu` SELECT * FROM `User`;',
    'INSERT INTO `MenuDat` VALUES (1) ON DUPLICATE KEY UPDATE No=1;',
    'INSERT INTO `Ranks` VALUES (@private);'
)) { Reject { Get-BackendSchemaPlan ($ddl+"`n"+$insert) } }

$accounts=New-BackendAccounts
Assert-BackendAccounts $accounts
Require ($accounts.Count -eq 4 -and @($accounts[0..1] | Where-Object role -CEQ 'bot').Count -eq 1 -and
    @($accounts[1..3] | Where-Object role -CNE 'bot').Count -eq 0 -and $accounts[1..3].username -cnotcontains 'Player') 'Client/server/bot-only account scope changed.'
Require (@($accounts.password | Select-Object -Unique).Count -eq 4) 'Generated account passwords are not distinct.'
Assert-BackendAccountScopes $accounts $accounts[0..1] $accounts[1..3]
Reject { Assert-BackendAccountScopes $accounts $accounts $accounts[1..3] }
Reject { Assert-BackendAccountScopes $accounts $accounts[0..1] $accounts[0..2] }
Reject { ConvertFrom-BackendJson '{"root":"first","ROOT":"second"}' }
Reject { ConvertFrom-BackendJson '{"files":{"same":"first","sa\u006de":"second"}}' }
Reject { ConvertFrom-BackendJson '{"password":"unterminated' }
$decoded=ConvertFrom-BackendJson (ConvertTo-Json -InputObject $accounts)
Assert-BackendAccounts $decoded
foreach ($field in @('username','id','nickname','role','password')) {
    $bad=ConvertFrom-Json (ConvertTo-Json -InputObject $accounts)
    $bad[2].$field="bad`n"
    Reject { Assert-BackendAccounts $bad }
}
$bad=ConvertFrom-Json (ConvertTo-Json -InputObject $accounts)
$bad[2].password=$bad[1].password
Reject { Assert-BackendAccounts $bad }
Reject { Assert-BackendAccounts $accounts[0..1] }
Reject { Assert-BackendAccounts @($accounts[0],$accounts[1],$accounts[2],$accounts[2]) }
Reject { New-BackendPassword 8 }
Assert-BackendFreshDatabase "1`r`n1`r`n1`r`n1"
foreach ($result in @("0`n1`n1`n1","1`n0`n1`n1","1`n1`n0`n1","1`n1`n1`n0",'', "1`n1`n1`n1`n1")) {
    Reject { Assert-BackendFreshDatabase $result }
}
$sql=@(New-BackendAccountSql $accounts) -join "`n"
Require ([regex]::Matches($sql,'(?m)^INSERT INTO ').Count -eq 19 -and
    $sql -notmatch '(?im)^\s*(UPDATE|DELETE|DROP|REPLACE)|ON DUPLICATE|INSERT IGNORE') 'Fresh provisioning stopped being strictly insert-only.'
foreach ($name in @('BotOne','BotTwo','BotThree')) {
    foreach ($id in @(98345,32807,163847,229381)) {
        Require ($sql.Contains("($id,1,'T',NULL,1,0,0,'$name','I')")) 'A hard-gear native Chest field changed.'
    }
}
Require (!$sql.Contains("0,0,'Player','I'") -and [regex]::Matches($sql,'100000000').Count -eq 8) 'Fresh local gear/balance defaults changed.'
$credentials=[pscustomobject]@{rootPassword=(New-BackendPassword 40);nativeUser='gb_local';nativePassword=(New-BackendPassword 20)}
$agent=[pscustomobject]@{username='FixtureAgent';password=(New-BackendPassword 12)}
$grants=@(New-BackendGrantSql $credentials $agent) -join "`n"
Require ([regex]::Matches($grants,'GRANT SELECT, INSERT, UPDATE, DELETE, LOCK TABLES ON gunbound\.\*').Count -eq 4 -and
    $grants.Contains('old_passwords=1') -and $grants -notmatch 'IF NOT EXISTS|GRANT OPTION|ALL PRIVILEGES|ON \*\.\*') 'Native legacy authentication privileges widened.'
$badAgent=[pscustomobject]@{username='root';password=$agent.password}
Reject { New-BackendGrantSql $credentials $badAgent }
$diagnostic=Convert-BackendDiagnostic ("ERROR 1064 (42000) at line 2: " + $accounts[0].password.Substring(0,6) + "`n" + $credentials.rootPassword)
Require ($diagnostic.Contains('ERROR 1064 (42000) at line 2') -and !$diagnostic.Contains($accounts[0].password.Substring(0,6)) -and
    !$diagnostic.Contains($credentials.rootPassword)) 'Diagnostics leaked a complete or partial secret.'
$config=New-BackendConfiguration "$root\synthetic installation" $credentials
Require ($config.admin.Contains("password=$($credentials.rootPassword)") -and $config.admin.Contains('host=127.0.0.1') -and
    $config.server.Contains('bind-address=127.0.0.1') -and $config.server.Contains('port=3307') -and
    $config.server.Contains('secure-auth=OFF') -and $config.server.Contains('local-infile=0') -and
    $config.server.Contains('event-scheduler=DISABLED') -and $config.server.Contains('skip-log-bin') -and
    $config.server.Contains(("$root\synthetic installation").Replace('\','\\'))) 'Private portable paths or database safety defaults changed.'

$settings=@"
Port=8360
Accept=*;
GameDB_Host=192.0.2.1
GameDB_Port=3306
GameDB_User=FixtureUser
GameDB_Pwd=$($agent.password)
GameDB_DB=fixture
PartnerAgentDB_Host=192.0.2.2
PartnerAgentDB_Port=3306
PartnerAgentDB_User=$($agent.username)
PartnerAgentDB_Pwd=$($agent.password)
PartnerAgentDB_DB=fixture
"@
$local=Convert-BackendSettings $settings 'Server8360' $credentials
Require ($local.Contains('Accept=127.0.0.1;') -and [regex]::Matches($local,'_Host=127\.0\.0\.1').Count -eq 2 -and
    [regex]::Matches($local,'_Port=3308').Count -eq 2 -and !$local.Contains($agent.password) -and
    !$local.Contains($agent.username) -and !$local.Contains('192.0.2.')) 'Source Agent credentials/endpoints leaked into native settings.'
Reject { Convert-BackendSettings ($settings+"`nPort=8360") 'Server8360' $credentials }
Reject { Convert-BackendSettings $settings.Replace('Port=8360','Port=8372') 'Server8360' $credentials }
Reject { Convert-BackendSettings ($settings -replace '(?m)^GameDB_Pwd=.*\r?\n','') 'Server8360' $credentials }
Reject { Convert-BackendSettings $settings 'Unowned' $credentials }
foreach ($definition in Load-BackendCheckFunctions "$root\backend\bind-loopback.ps1" @('Get-LabNativeHashes')) {
    . ([scriptblock]::Create($definition))
}
$native=Get-LabNativeHashes
Require ($native.Count -eq 2 -and
    $native['Server8360\Gunboundserv3.exe'].original -ceq 'd82513950d4db08be664d538e09e5b00a07c795d76a0a7ed0eede8a8553fa511' -and
    $native['Central\GunBoundBroker3.exe'].original -ceq 'db6f6765aef74c702ceb6ae035fa022f3d309670d804e4679a681781fb448a63') 'Pinned original native core fingerprints changed.'
$started=[DateTime]::UtcNow
$supervisor=[pscustomobject]@{Id=1234;Path='C:\Synthetic\pwsh.exe';StartTime=$started}
$record=[pscustomobject]@{name='mariadb';pid=1235;path="$root\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe"
    group='Database';port=3307;bindAddress='127.0.0.1';startedUtcTicks=$started.Ticks
    supervisorPid=1234;supervisorPath=$supervisor.Path;supervisorStartedUtcTicks=$started.Ticks}
Assert-BackendProcessRecord $record $root $supervisor
$record.supervisorPid=5678
Reject { Assert-BackendProcessRecord $record $root $supervisor }
$record.supervisorPid=1234; $record.path="$root-other\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe"
Reject { Assert-BackendProcessRecord $record $root }
$record.path="$root\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe"; $record.bindAddress='0.0.0.0'
Reject { Assert-BackendProcessRecord $record $root }

function New-BackendFixtureImage {
    $bytes=[byte[]]::new(1024)
    function Put16([int]$At,[uint16]$Value) { [Array]::Copy([BitConverter]::GetBytes($Value),0,$bytes,$At,2) }
    function Put32([int]$At,[uint32]$Value) { [Array]::Copy([BitConverter]::GetBytes($Value),0,$bytes,$At,4) }
    $bytes[0]=0x4d; $bytes[1]=0x5a
    Put32 0x3c 0x80; Put32 0x80 0x4550
    Put16 0x84 0x8664; Put16 0x86 1; Put16 0x94 240; Put16 0x96 0x22
    Put16 0x98 0x20b; Put32 (0x98+32) 0x1000; Put32 (0x98+36) 0x200
    Put32 (0x98+56) 0x2000; Put32 (0x98+60) 0x200; Put16 (0x98+68) 3
    Put32 (0x98+108) 16; Put32 (0x98+128) 0x1000; Put32 (0x98+132) 0x200
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('.rsrc'),0,$bytes,0x188,5)
    Put32 (0x188+8) 0x200; Put32 (0x188+12) 0x1000; Put32 (0x188+16) 0x200; Put32 (0x188+20) 0x200
    Put16 (0x200+14) 1; Put32 (0x200+16) 16; Put32 (0x200+20) 0x80000020L
    Put16 (0x220+14) 1; Put32 (0x220+16) 1; Put32 (0x220+20) 0x80000040L
    Put16 (0x240+14) 1; Put32 (0x240+16) 1033; Put32 (0x240+20) 0x60
    Put32 0x260 0x1080; Put32 0x264 92
    Put16 0x280 92; Put16 0x282 52
    [Array]::Copy([Text.Encoding]::Unicode.GetBytes("VS_VERSION_INFO`0"),0,$bytes,0x286,32)
    Put32 (0x280+40) 0xfeef04bdL; Put32 (0x280+44) 0x10000
    Put32 (0x280+48) 0x000b0004; Put32 (0x280+52) 0x000d0000
    Put32 (0x280+56) 0x000b0004; Put32 (0x280+60) 0x000d0000
    ,$bytes
}
function Test-BackendFixtureArchive([string[]]$Extra = @(), [string]$Link = '', [byte[]]$Image = $script:fixtureImage, [switch]$FalseLength) {
    $memory=[IO.MemoryStream]::new()
    try {
        $zip=[IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Create,$true)
        try {
            foreach ($name in @('mariadbd.exe','mariadb.exe','mariadb-admin.exe','mariadb-install-db.exe')) {
                $entry=$zip.CreateEntry("mariadb-11.4.13-winx64\bin\$name".Replace('\','/'))
                $stream=$entry.Open()
                try { $stream.Write($Image,0,$Image.Length) } finally { $stream.Dispose() }
            }
            foreach ($name in $Extra) { $null=$zip.CreateEntry($name.Replace('\','/')) }
            if ($Link) {
                $entry=$zip.CreateEntry($Link.Replace('\','/'))
                $entry.ExternalAttributes=[BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]0xa1ff0000L),0)
            }
        } finally { $zip.Dispose() }
        if ($FalseLength) {
            $contents=$memory.ToArray()
            for ($i=0; $i -lt $contents.Length-46; $i++) {
                if ([BitConverter]::ToUInt32($contents,$i) -eq 0x02014b50) {
                    $memory.Position=$i+24
                    $memory.Write([BitConverter]::GetBytes([uint32]512),0,4)
                    break
                }
            }
        }
        $memory.Position=0
        $zip=[IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Read,$true)
        try { $plan=Get-BackendArchivePlan $zip "$root\runtime\mariadb"; $plan.Count }
        finally { $zip.Dispose() }
    } finally { $memory.Dispose() }
}
$fixtureImage=New-BackendFixtureImage
Assert-BackendMariaDbImage $fixtureImage
Require ((Test-BackendFixtureArchive) -eq 4) 'A canonical synthetic MariaDB ZIP did not validate.'
foreach ($name in @('..\escaped','C:\escaped','\absolute','mariadb-11.4.13-winx64\..\escaped',
    'mariadb-11.4.13-winx64\NUL.txt','mariadb-11.4.13-winx64\trailing.','mariadb-11.4.13-winx64\bin\mariadbd.exe',
    'mariadb-11.4.13-winx64\bin\MARIADBD.EXE','mariadb-11.4.13-winx64\bin','mariadb-11.4.12-winx64\wrong',
    'mariadb-11.4.13-winx64\extra:stream')) { Reject { Test-BackendFixtureArchive -Extra @($name) } }
Reject { Test-BackendFixtureArchive -Link 'mariadb-11.4.13-winx64\redirect' }
Reject { Test-BackendFixtureArchive -FalseLength }
$badImage=[byte[]]$fixtureImage.Clone(); $badImage[0x84]=0x4c
Reject { Assert-BackendMariaDbImage $badImage }
$badImage=[byte[]]$fixtureImage.Clone(); $badImage[0x280+54]=14
Reject { Test-BackendFixtureArchive -Image $badImage }
Reject { Assert-BackendMariaDbImage ([byte[]]::new(256)) }

foreach ($definition in Load-BackendCheckFunctions "$root\backend\network-config.ps1" @('Convert-LabNetworkSettingBytes','Convert-LabWorldListBytes')) {
    . ([scriptblock]::Create($definition))
}
$worldRelative='backend\native\Server8360\setting.txt'
$initialSettings=$local.Replace('Accept=127.0.0.1;','Accept=127.0.0.1;127.0.0.2;')
$initialBytes=[Text.Encoding]::Latin1.GetBytes($initialSettings)
$initialHash=Get-BackendHash $initialBytes
Require ((Get-BackendInitialNetworkHash $worldRelative $initialBytes) -ceq $initialHash) 'Initial native network settings did not round-trip.'
$changedAcl=[Text.Encoding]::Latin1.GetBytes($initialSettings.Replace('Accept=127.0.0.1;127.0.0.2;','Accept=127.0.0.2;'))
Require ((Get-BackendInitialNetworkHash $worldRelative $changedAcl) -ceq $initialHash) 'Only an allowlist change should normalize to its initial digest.'
$changedCredential=[Text.Encoding]::Latin1.GetBytes($initialSettings.Replace($credentials.nativePassword,(New-BackendPassword 20)))
Require ((Get-BackendInitialNetworkHash $worldRelative $changedCredential) -cne $initialHash) 'Credential drift was mistaken for a network-only change.'
Reject { Get-BackendInitialNetworkHash 'private\backend\admin.ini' $initialBytes }
Assert-BackendStoppedProcesses @([pscustomobject]@{ExecutablePath='C:\AnotherLab\mariadbd.exe';CommandLine=''}) $root
foreach ($process in @(
    [pscustomobject]@{ExecutablePath="$root\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe";CommandLine=''},
    [pscustomobject]@{ExecutablePath="$root\backend\native\Central\GunBoundBroker3.exe";CommandLine=''},
    [pscustomobject]@{ExecutablePath='C:\Synthetic\pwsh.exe';CommandLine="-NoProfile -File `"$root\backend\start.ps1`" -Part Database"}
)) { Reject { Assert-BackendStoppedProcesses @($process) $root } }

$preparedNames=@(Get-BackendPreparedFileNames)
Require ($preparedNames.Count -eq 27 -and @($preparedNames | Select-Object -Unique).Count -eq 27) 'The sealed backend artifact inventory changed unexpectedly.'
$fixtureFiles=@{}
foreach ($relative in $preparedNames) { $fixtureFiles["$root\$relative"]=[Text.Encoding]::UTF8.GetBytes('fixture bytes') }
$fixtureFiles["$root\private\backend\accounts.json"]=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $accounts))
$fixtureFiles["$root\private\accounts.json"]=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $accounts[0..1]))
$fixtureFiles["$root\private\vm\bot-accounts.json"]=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $accounts[1..3]))
$fixtureFiles["$root\private\backend\credentials.json"]=[Text.Encoding]::UTF8.GetBytes(($credentials | ConvertTo-Json))
$fixtureFiles["$root\private\backend\legacy-agent.json"]=[Text.Encoding]::UTF8.GetBytes(($agent | ConvertTo-Json))
$fixtureConfiguration=New-BackendConfiguration $root $credentials
$fixtureFiles["$root\private\backend\admin.ini"]=[Text.Encoding]::UTF8.GetBytes($fixtureConfiguration.admin)
$fixtureFiles["$root\private\backend\my.ini"]=[Text.Encoding]::UTF8.GetBytes($fixtureConfiguration.server)
$savedSource=[pscustomobject]@{schemaVersion=1;serverSourceDirectory="$root\offline source";mariaDbArchive="$root\offline database.zip"
    mariaDbArchiveSha256=('a'*64);sourceSqlSha256=('b'*64)}
$fixtureFiles["$root\private\backend\source.json"]=[Text.Encoding]::UTF8.GetBytes(($savedSource | ConvertTo-Json))
$sealed=[ordered]@{}
foreach ($relative in $preparedNames) { $sealed[$relative]=Get-BackendHash $fixtureFiles["$root\$relative"] }
$receipt=[pscustomobject]@{schemaVersion=1;installationId=[Guid]::NewGuid().ToString('D');root=$root;phase='complete-stopped'
    createdUtc=[DateTime]::UtcNow.ToString('o');files=[pscustomobject]$sealed}
Assert-BackendSavedState $receipt $root 'complete-stopped'
foreach ($phase in @('initializing','initialized','provisioning','provisioned','unknown')) {
    $receipt.phase=$phase
    Reject { Assert-BackendSavedState $receipt $root 'complete-stopped' }
}
$receipt.phase='complete-stopped'
Reject { Assert-BackendSavedState $receipt ($root+'-other') 'complete-stopped' }
$badReceipt=ConvertFrom-BackendJson ($receipt | ConvertTo-Json -Depth 5)
$badReceipt.files.PSObject.Properties.Remove('private\backend\accounts.json')
Reject { Assert-BackendSavedState $badReceipt $root 'complete-stopped' }
foreach ($name in @('mariadbd.exe','mariadb.exe','mariadb-admin.exe','mariadb-install-db.exe')) {
    $fixtureFiles["$root\runtime\mariadb\mariadb-11.4.13-winx64\bin\$name"]=$fixtureImage
}
foreach ($extension in @('frm','MYD','MYI')) { $fixtureFiles["$root\runtime\mariadb\data\gunbound\Fixture.$extension"]=[byte[]]@(1) }
$fixtureDirectories=@("$root\runtime\mariadb\data\mysql","$root\runtime\mariadb\data\gunbound")
$receiptPath="$root\private\backend\setup-state.json"
$fixtureFiles[$receiptPath]=[Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 5))
$savedFunctions=@{}
foreach ($name in @('Assert-BackendPath','Read-BackendBytes','Assert-BackendStopped','Assert-BackendCompletedNetwork',
    'Get-BackendSchemaPlan','Assert-BackendSchema','Write-BackendPrivate','Invoke-BackendCommand','Initialize-Backend',
    'Invoke-BackendProvision','Expand-BackendArchive')) { $savedFunctions[$name]=(Get-Item -LiteralPath "Function:\$name").ScriptBlock }
$calls=[pscustomobject]@{stopped=0;network=0;mutations=0;active=$false}
try {
    function Assert-BackendPath([string]$Path,[string]$Root) {}
    function Read-BackendBytes([string]$Path,[long]$Maximum=134217728) {
        if (!$fixtureFiles.ContainsKey($Path)) { throw 'Missing synthetic artifact.' }
        ,$fixtureFiles[$Path]
    }
    function Test-Path([string]$LiteralPath,[string]$PathType) {
        if ($PathType -eq 'Container') { return $LiteralPath -in $fixtureDirectories }
        $fixtureFiles.ContainsKey($LiteralPath)
    }
    function Assert-BackendStopped([string]$Root) { $calls.stopped++; if ($calls.active) { throw 'Synthetic backend is active.' } }
    function Assert-BackendCompletedNetwork([string]$Root,$State) { $calls.network++ }
    function Get-BackendSchemaPlan([string]$Text) { [pscustomobject]@{tables=@([pscustomobject]@{name='Fixture'})} }
    function Assert-BackendSchema($Plan) { Require ($Plan.tables[0].name -ceq 'Fixture') 'Unexpected synthetic schema.' }
    foreach ($name in @('Write-BackendPrivate','Invoke-BackendCommand','Initialize-Backend','Invoke-BackendProvision','Expand-BackendArchive')) {
        Set-Item -LiteralPath "Function:\$name" -Value { $calls.mutations++; throw 'An idempotent rerun attempted mutation.' }
    }
    $output=@(Invoke-FreshBackendSetup $root $savedSource.serverSourceDirectory $savedSource.mariaDbArchive) -join "`n"
    Require ($output.Contains('completed backend verified on disk and STOPPED') -and $calls.stopped -eq 2 -and
        $calls.network -eq 1 -and $calls.mutations -eq 0) 'A completed backend was not reused read-only.'
    foreach ($secret in @($credentials.rootPassword,$credentials.nativePassword,$agent.password)+@($accounts.password)) {
        Require (!$output.Contains($secret)) 'Idempotent diagnostics exposed a credential.'
    }
    $reorderedBots=@($accounts[1..3] | ForEach-Object {
        [pscustomobject][ordered]@{nickname=$_.nickname;id=$_.id;password=$_.password;username=$_.username;role=$_.role}
    })
    $fixtureFiles["$root\private\vm\bot-accounts.json"]=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $reorderedBots -Compress)+"`r`n")
    Invoke-FreshBackendSetup $root '' '' | Out-Null
    Require ($calls.mutations -eq 0) 'Equivalent account JSON formatting caused a mutation.'
    Reject { Invoke-FreshBackendSetup $root ($savedSource.serverSourceDirectory+'-other') $savedSource.mariaDbArchive }
    $calls.active=$true
    Reject { Invoke-FreshBackendSetup $root '' '' }
    $calls.active=$false
    $receipt.phase='provisioned'
    $fixtureFiles[$receiptPath]=[Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 5))
    Reject { Invoke-FreshBackendSetup $root '' '' }
    $receipt.phase='complete-stopped'
    $fixtureFiles[$receiptPath]=[Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 5))
    $fixtureFiles["$root\private\backend\admin.ini"]=[Text.Encoding]::UTF8.GetBytes('changed configuration')
    Reject { Invoke-FreshBackendSetup $root '' '' }
    $fixtureFiles["$root\private\backend\admin.ini"]=[Text.Encoding]::UTF8.GetBytes($fixtureConfiguration.admin)
    $fixtureFiles.Remove("$root\runtime\mariadb\data\gunbound\Fixture.MYD")
    Reject { Invoke-FreshBackendSetup $root '' '' }
    Require ($calls.mutations -eq 0) 'A rejected rerun performed a backend mutation.'
} finally {
    foreach ($name in $savedFunctions.Keys) { Set-Item -LiteralPath "Function:\$name" -Value $savedFunctions[$name] }
    Remove-Item -LiteralPath 'Function:\Test-Path'
}

# Only these pure definitions are loaded; the guest-maintenance script itself is never executed.
foreach ($definition in Load-BackendCheckFunctions "$root\accounts\provision-room-bots.ps1" @('Assert','Integer','Assert-ServerOwnership')) {
    . ([scriptblock]::Create($definition))
}
$guestRoot='C:\GunBoundAI'
$owner=[pscustomobject]@{schemaVersion=1;ownerId=[Guid]::NewGuid().ToString('D');root="$root\guest fixture"
    databaseVersion='11.4.13';originalHostDataPreserved=$true}
$marker=[pscustomobject]@{schemaVersion=1;ownerId=$owner.ownerId;root=$guestRoot;serverRoot=$owner.root
    computerName='SYNTHETIC-BOT';provider='virtualbox';leaseSeconds=120}
Require ((Assert-ServerOwnership $owner $marker $owner.root 'SYNTHETIC-BOT') -ceq $owner.ownerId) 'Fresh marked server ownership failed.'
Reject { Assert-ServerOwnership $owner $marker ($owner.root+'-other') 'SYNTHETIC-BOT' }
Reject { Assert-ServerOwnership $owner $marker $owner.root 'OTHER-COMPUTER' }
$marker.ownerId=[Guid]::NewGuid().ToString('D')
Reject { Assert-ServerOwnership $owner $marker $owner.root 'SYNTHETIC-BOT' }
$marker.ownerId=$owner.ownerId; $owner.ownerId=[Guid]::Empty.ToString('D')
Reject { Assert-ServerOwnership $owner $marker $owner.root 'SYNTHETIC-BOT' }
foreach ($definition in Load-BackendCheckFunctions "$root\backend\health.ps1" @('Assert-HealthAccounts','New-HealthSql','Assert-HealthCounts')) {
    . ([scriptblock]::Create($definition))
}
foreach ($count in @(2,4)) {
    Assert-HealthAccounts $accounts[0..($count-1)]
    $results=@('57') + @([string]$count)*4 + @('1200','1200') + @('1')*$count
    Assert-HealthCounts $results $count
    $results[0]='56'
    Reject { Assert-HealthCounts $results $count }
}
Write-Output 'PASS: synthetic portable layout/fresh-only guards; completed-state read-only idempotency and incomplete/active/drift refusal; strict JSON/schema/static extraction; four unique accounts and scoped metadata; insert-only hard gear and minimal legacy grants; redacted diagnostics; native/config/process/guest ownership; safe ZIP paths and exact x64 PE versions. No DB/VM/process/private-data or legacy maintenance action.'
