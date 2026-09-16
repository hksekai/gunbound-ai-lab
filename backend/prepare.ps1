#requires -Version 7.4
<#
Fresh-only backend preparation. Normally invoked by setup\prepare-backend.ps1.
-Provision accepts only this installation's initialized, supervised database.
Dot-sourcing loads validators only; it does not read private data or start processes.
#>
[CmdletBinding()]
param([string]$ServerSourceDirectory, [switch]$Provision)
$ErrorActionPreference = 'Stop'

function Get-BackendHash([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Resolve-BackendLocalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('"') -or $Path -match '[\x00-\x1f]') {
        throw 'A nonempty local Windows path without quotes/control characters is required.'
    }
    if ($Path.Contains('/') -or $Path -match '\A[A-Za-z]:(?!\\)') { throw 'Use a local Windows path, not a drive-relative path.' }
    foreach ($segment in $Path.Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment -notin @('.','..') -and ($segment.EndsWith('.') -or $segment.EndsWith(' '))) {
            throw 'Trailing dots/spaces must not be normalized into a different input path.'
        }
    }
    $full = [IO.Path]::GetFullPath($Path, $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path)
    if ($full -notmatch '\A[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) {
        throw 'UNC, device, provider and alternate-stream paths are not supported.'
    }
    foreach ($segment in $full.Substring(3).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment -match '[<>|?*]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[0-9¹²³]|LPT[0-9¹²³])(?:\.|$)') {
            throw 'The path contains an ambiguous or reserved Windows filename.'
        }
    }
    if ($full -eq [IO.Path]::GetPathRoot($full)) { throw 'A backend input/output must name a directory below a drive root.' }
    $full.TrimEnd('\')
}

function Assert-BackendPath([string]$Path, [string]$Root = '') {
    $full = Resolve-BackendLocalPath $Path
    if ($Root) {
        $base = Resolve-BackendLocalPath $Root
        if ($full -ine $base -and !$full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A backend path escaped the installation root.'
        }
    }
    for ($at = $full; $at; $at = Split-Path -Parent $at) {
        if (Test-Path -LiteralPath $at) {
            $item = Get-Item -LiteralPath $at -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Backend inputs and outputs must not traverse reparse points.'
            }
            if ($at -ine $full -and !$item.PSIsContainer) { throw 'A backend path traverses a file.' }
        }
    }
}

function Assert-BackendFresh([string]$Root, [switch]$DistributionInstalled) {
    $reserved = @('private\backend', 'private\accounts.json', 'private\vm\bot-accounts.json',
        'backend\native', 'backend\schema-static.sql', 'backend\manifest.json', 'backend\loopback-patches.json',
        'backend\database-processes.json', 'backend\core-processes.json', 'backend\buddy-processes.json',
        'backend\database.pid', 'backend\database.stop', 'backend\core.stop', 'backend\buddy.stop',
        'runtime\mariadb\data', 'runtime\mariadb\work')
    if (!$DistributionInstalled) { $reserved += 'runtime\mariadb\mariadb-11.4.13-winx64' }
    foreach ($relative in $reserved) {
        Assert-BackendPath "$Root\$relative" $Root
        if (Test-Path -LiteralPath "$Root\$relative") {
            throw "Fresh backend setup refuses existing $relative. No resume, replacement or automatic cleanup is supported."
        }
    }
}

function Protect-BackendPath([string]$Path, [string]$Root) {
    Assert-BackendPath $Path $Root
    $directory = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rights = if ($directory) { '(OI)(CI)F' } else { 'F' }
    & icacls.exe $Path '/grant:r' "*${userSid}:$rights" "*S-1-5-18:$rights" '/inheritance:r' '/Q' | Out-Null
    if ($LASTEXITCODE) { throw 'Cannot restrict a backend artifact to the current user and SYSTEM.' }
    foreach ($rule in (Get-Acl -LiteralPath $Path).Access) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin @($userSid, 'S-1-5-18')) {
            & icacls.exe $Path '/remove' "*$sid" '/Q' | Out-Null
            if ($LASTEXITCODE) { throw 'Cannot remove an extra backend access rule.' }
        }
    }
}

function Write-BackendPrivate([string]$Path, [string]$Text, [string]$Root, [switch]$Replace, [Text.Encoding]$Encoding = [Text.UTF8Encoding]::new($false)) {
    Assert-BackendPath $Path $Root
    $mode = if ($Replace) { [IO.FileMode]::Open } else { [IO.FileMode]::CreateNew }
    $stream = [IO.File]::Open($Path, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        Protect-BackendPath $Path $Root
        $bytes = $Encoding.GetBytes($Text)
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Read-BackendBytes([string]$Path, [long]$Maximum = 134217728) {
    Assert-BackendPath $Path
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'A required backend input file is missing; check the supplied source layout.' }
    $file = Get-Item -LiteralPath $Path -Force
    if ($file.Length -eq 0 -or $file.Length -gt $Maximum) { throw 'A backend input is empty or exceeds its supported size.' }
    ,([IO.File]::ReadAllBytes($Path))
}

function ConvertFrom-BackendJson([string]$Text) {
    $document=$null
    try {
        if (!$Text -or $Text.Length -gt 1048576) { throw 'Invalid metadata size.' }
        $document=[Text.Json.JsonDocument]::Parse($Text.TrimStart([char]0xFEFF),
            [Text.Json.JsonDocumentOptions]@{MaxDepth=16})
        $pending=[Collections.Generic.List[Text.Json.JsonElement]]::new()
        $pending.Add($document.RootElement)
        for ($i=0; $i -lt $pending.Count; $i++) {
            $element=$pending[$i]
            if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $element.EnumerateObject()) {
                    if (!$names.Add($property.Name)) { throw 'Duplicate metadata field.' }
                    $pending.Add($property.Value)
                }
            } elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) { $pending.Add($item) }
            }
        }
        ,($Text.TrimStart([char]0xFEFF) | ConvertFrom-Json -Depth 16)
    } catch { throw 'Saved backend metadata is malformed, duplicated or oversized; private contents were not echoed.' }
    finally { if ($document) { $document.Dispose() } }
}

function Read-BackendJson([string]$Root, [string]$Relative) {
    Assert-BackendPath "$Root\$Relative" $Root
    try {
        $text=[Text.UTF8Encoding]::new($false,$true).GetString((Read-BackendBytes "$Root\$Relative" 1048576))
        ConvertFrom-BackendJson $text
    } catch { throw 'A required saved backend metadata file is missing, unreadable or invalid; private contents were not echoed.' }
}

function Get-BackendNativeFiles {
    [ordered]@{
        BuddyCenter=@('BuddyCenter2.exe'); BuddyServ=@('BuddyServ2.exe'); Central=@('GunBoundBroker3.exe')
        Server8360=@('Gunboundserv3.exe','AllowedGuild.txt','CSAuth.idx','CSAuth.tab','EvsW_stage_pos.txt','Mix_stage_pos.txt','Rand_stage_pos.txt')
    }
}

function Get-BackendPreparedFileNames {
    @('private\backend\credentials.json','private\backend\accounts.json','private\backend\legacy-agent.json',
        'private\backend\admin.ini','private\backend\my.ini','private\accounts.json','private\vm\bot-accounts.json',
        'backend\schema-static.sql','backend\manifest.json','backend\loopback-patches.json',
        'backend\native\Central\GameServerList.txt','backend\native\Server8360\channel_ment.txt','backend\native\Server8360\room_ment.txt')
    $files=Get-BackendNativeFiles
    foreach ($component in $files.Keys) {
        foreach ($file in @($files[$component])+@('setting.txt')) { "backend\native\$component\$file" }
    }
}

function Assert-BackendSavedState($State, [string]$Root, [string]$Phase) {
    $id=[Guid]::Empty
    if ($Phase -cnotin @('initialized','complete-stopped') -or $State -isnot [pscustomobject] -or
        ($State.schemaVersion -isnot [int] -and $State.schemaVersion -isnot [long]) -or $State.schemaVersion -ne 1 -or
        $State.root -isnot [string] -or $State.root -ine $Root -or $State.phase -cne $Phase -or
        $State.installationId -isnot [string] -or ![Guid]::TryParseExact($State.installationId,'D',[ref]$id) -or $id -eq [Guid]::Empty -or
        $State.files -isnot [pscustomobject]) {
        throw "Incomplete or incompatible backend setup state; expected this installation's $Phase receipt. Automatic resume, database replacement and credential regeneration are not supported."
    }
    $expected=@(Get-BackendPreparedFileNames)
    $fields=@($State.files.PSObject.Properties)
    if ($fields.Count -ne $expected.Count -or
        @($fields | Where-Object { $_.Name -cnotin $expected -or $_.Value -isnot [string] -or $_.Value -cnotmatch '\A[0-9a-f]{64}\z' }).Count) {
        throw 'The backend preparation receipt has an incomplete or unrecognized artifact inventory.'
    }
}

function ConvertTo-BackendAccountsJson($Accounts) {
    $fields=@('role','username','password','id','nickname')
    $records=@(foreach ($account in $Accounts) {
        if ($account -isnot [pscustomobject] -or @($account.PSObject.Properties).Count -ne 5 -or
            @($fields | Where-Object { $account.PSObject.Properties.Name -cnotcontains $_ -or $account.$_ -isnot [string] }).Count) {
            throw 'Account metadata must contain only the five supported string fields.'
        }
        [pscustomobject][ordered]@{role=$account.role;username=$account.username;password=$account.password;id=$account.id;nickname=$account.nickname}
    })
    ConvertTo-Json -InputObject $records
}

function Assert-BackendAccountScopes($Canonical, $Client, $Bots) {
    Assert-BackendAccounts $Canonical
    if ($Client -isnot [array] -or $Client.Count -ne 2 -or $Bots -isnot [array] -or $Bots.Count -ne 3 -or
        (ConvertTo-BackendAccountsJson $Client) -cne (ConvertTo-BackendAccountsJson $Canonical[0..1]) -or
        (ConvertTo-BackendAccountsJson $Bots) -cne (ConvertTo-BackendAccountsJson $Canonical[1..3])) {
        throw 'Saved account scopes must match the canonical four, Player/BotOne client pair and three bot-only records exactly.'
    }
}

function Get-BackendSqlStatements([string]$Text) {
    if (!$Text -or $Text.Length -gt 134217728 -or $Text.Contains([char]0)) { throw 'The source SQL dump is empty, oversized or contains NUL bytes.' }
    $Text=$Text.TrimStart([char]0xFEFF)
    $buffer = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -in @([char]39, [char]34, [char]96)) {
            $start = $i
            $closed = $false
            for ($i++; $i -lt $Text.Length; $i++) {
                if ($Text[$i] -eq '\' -and $c -ne [char]96) { $i++; continue }
                if ($Text[$i] -eq $c) {
                    if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq $c) { $i++; continue }
                    $closed = $true
                    break
                }
            }
            if (!$closed) { throw 'The source SQL contains an unterminated quoted value.' }
            $null = $buffer.Append($Text, $start, $i - $start + 1)
        } elseif ($c -eq '#' -or ($c -eq '-' -and $i + 2 -lt $Text.Length -and
                $Text[$i + 1] -eq '-' -and [char]::IsWhiteSpace($Text[$i + 2]))) {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            $null = $buffer.Append(' ')
        } elseif ($c -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '*') {
            $end = $Text.IndexOf('*/', $i + 2, [StringComparison]::Ordinal)
            if ($end -lt 0) { throw 'The source SQL contains an unterminated comment.' }
            if ($i + 2 -lt $Text.Length -and $Text[$i + 2] -eq '!' -and $buffer.ToString().Trim()) {
                throw 'Executable comments embedded in source SQL statements are not supported.'
            }
            $i = $end + 1
            $null = $buffer.Append(' ')
        } elseif ($c -eq ';') {
            $statement = $buffer.ToString().Trim().TrimStart([char]0xFEFF).Trim()
            if ($statement) { $statement }
            $null = $buffer.Clear()
        } else { $null = $buffer.Append($c) }
    }
    if ($buffer.ToString().Trim()) { throw 'The source SQL ends with an incomplete statement.' }
}

function Convert-BackendSchemaSql([string]$Statement) {
    $match = [regex]::Match($Statement, '(?s)\ACREATE TABLE `(?<name>[A-Za-z0-9_]+)`\s*\(\s*\r?\n(?<body>.*?)\r?\n\)\s*(?<options>[^\r\n]+)\z')
    if (!$match.Success) { throw 'Unexpected CREATE TABLE layout; refusing a partial or executable schema.' }
    # ponytail: only the reviewed dump grammar is accepted; new schemas need new fingerprints and checks.
    $quoted = "'(?:[^'\\]|\\.|'')*'"
    $type = '(?:tinyint|smallint|mediumint|int|bigint|decimal|float|double|char|varchar|binary|varbinary|tinytext|text|mediumtext|longtext|tinyblob|blob|mediumblob|longblob|date|datetime|timestamp|time|year|bit)(?:\([0-9]+(?:,[0-9]+)?\))?'
    $type += '|(?:enum|set)\(' + $quoted + '(?:,' + $quoted + ')*\)'
    $attribute = '(?: UNSIGNED| ZEROFILL| CHARACTER SET (?:latin1|utf8|utf8mb3)| COLLATE (?:latin1_swedish_ci|utf8_general_ci|utf8mb3_general_ci)| NOT NULL| NULL| DEFAULT (?:' +
        $quoted + '|NULL|-?[0-9]+(?:\.[0-9]+)?|CURRENT_TIMESTAMP(?:\(\))?)| AUTO_INCREMENT| ON UPDATE CURRENT_TIMESTAMP(?:\(\))?)'
    $column = '^\s*`[A-Za-z0-9_]+`\s+(?:' + $type + ')(?:' + $attribute + ')*,?\s*$'
    $index = '^\s*(?:PRIMARY KEY|(?:UNIQUE )?KEY `[A-Za-z0-9_]+`)\s*\(`[A-Za-z0-9_]+`(?:\([0-9]+\))?(?:,\s*`[A-Za-z0-9_]+`(?:\([0-9]+\))?)*\)(?: USING BTREE)?,?\s*$'
    $columns = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $match.Groups['body'].Value -split '\r?\n') {
        if ($line -match $column) {
            $name = [regex]::Match($line, '`([^`]+)`').Groups[1].Value
            if (!$columns.Add($name)) { throw 'The source schema contains duplicate columns.' }
        } elseif ($line -notmatch $index) { throw 'The source schema has an unsupported column, index or executable clause.' }
    }
    if (!$columns.Count) { throw 'The source schema has no columns.' }
    $options = $match.Groups['options'].Value
    if ($options -cnotmatch '\AENGINE=MyISAM(?: AUTO_INCREMENT=[0-9]+)? DEFAULT CHARSET=(?:latin1|utf8|utf8mb3)(?: COLLATE=(?:latin1_swedish_ci|utf8_general_ci|utf8mb3_general_ci))?(?: ROW_FORMAT=(?:FIXED|DYNAMIC|COMPACT|Fixed|Dynamic|Compact))?\z') {
        throw 'Only the supplied MyISAM table options are supported; external data paths and executable schema clauses are refused.'
    }
    # No historical auto-increment position is carried into the fresh database.
    $clean = 'CREATE TABLE `' + $match.Groups['name'].Value + '` (' + "`n" + $match.Groups['body'].Value +
        "`n) " + ($options -creplace ' AUTO_INCREMENT=[0-9]+', '')
    [pscustomobject]@{ name=$match.Groups['name'].Value; columns=$columns.Count; sql=$clean + ';' }
}

function Get-BackendSchemaPlan([string]$Text) {
    $tables = [Collections.Generic.List[object]]::new()
    $static = [Collections.Generic.List[string]]::new()
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $staticNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $staticRows = @{}
    $staticWidths = @{}
    $literal = "(?:NULL|[-+]?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?|0x[0-9A-Fa-f]+|'(?:[^'\\]|\\.|'')*')"
    $tuple = '\(\s*(?<value>' + $literal + ')(?:\s*,\s*(?<value>' + $literal + '))*\s*\)'
    foreach ($statement in Get-BackendSqlStatements $Text) {
        if ($statement -match '^CREATE\s+(?:TEMPORARY\s+)?TABLE\b') {
            $table = Convert-BackendSchemaSql $statement
            if (!$names.Add($table.name)) { throw 'Duplicate source tables are not supported.' }
            $tables.Add($table)
        } elseif ($statement -match '^(?:ALTER|DELIMITER)\b|^CREATE\s+(?!DATABASE\b)') {
            throw 'Unreviewed schema objects or separate ALTER definitions are not supported.'
        } elseif ($statement -match '^INSERT\s+INTO\s+`(Item|Menu|MenuDat|Ranks)`') {
            $name = $Matches[1]
            $pattern = '\AINSERT INTO `' + $name + '`\s+VALUES\s*' + $tuple + '(?:\s*,\s*' + $tuple + ')*\s*\z'
            if ($name -cnotin @('Item','Menu','MenuDat','Ranks') -or
                ![regex]::IsMatch($statement, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline, [TimeSpan]::FromSeconds(5))) {
                throw 'Allowlisted static INSERTs must contain literal VALUES only, without expressions, modifiers or trailing SQL.'
            }
            $null = $staticNames.Add($name)
            if (!$staticRows.ContainsKey($name)) { $staticRows[$name]=0; $staticWidths[$name]=[Collections.Generic.HashSet[int]]::new() }
            foreach ($row in [regex]::Matches($statement,$tuple,[Text.RegularExpressions.RegexOptions]::Singleline,[TimeSpan]::FromSeconds(5))) {
                $staticRows[$name]++
                $null=$staticWidths[$name].Add($row.Groups['value'].Captures.Count)
            }
            $static.Add($statement + ';')
        }
    }
    [pscustomobject]@{
        tables=$tables.ToArray(); staticTables=@($staticNames); staticCount=$static.Count; staticRows=$staticRows; staticWidths=$staticWidths
        sql="SET NAMES utf8;`nSET SESSION sql_mode='NO_ENGINE_SUBSTITUTION';`n" +
            (($tables | ForEach-Object sql) -join "`n") + "`n" + ($static -join "`n") + "`n"
    }
}

function Assert-BackendSchema($Plan) {
    $names = [string[]]@($Plan.tables | ForEach-Object { $_.name.ToLowerInvariant() })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    if ($names.Count -ne 57 -or (Get-BackendHash ([Text.Encoding]::UTF8.GetBytes($names -join "`n"))) -cne
        '320b0eab6b4d87f2e73b9989f46459aa249c74fb32604d8986e0086ff0f22e07' -or
        $Plan.staticTables.Count -ne 4) { throw 'Expected the reviewed 57-table schema and all four static tables; no partial schema will be imported.' }
    foreach ($name in @('Item','Menu','MenuDat','Ranks')) {
        $columns=@($Plan.tables | Where-Object name -IEQ $name)[0].columns
        $minimum=if ($name -in @('Item','Menu')) { 1000 } else { 1 }
        if ($Plan.staticRows[$name] -lt $minimum -or $Plan.staticWidths[$name].Count -ne 1 -or
            !$Plan.staticWidths[$name].Contains($columns)) { throw 'Allowlisted catalog rows are incomplete or do not match their table column counts.' }
    }
    $hashes = @{
        cash='aa53e1556396b34a76fb779a61bc47371fe610fe2bb3d43c512afc33bfc435e2'
        chest='241b1e8b713304ec28a04bfe1628e25bc9bcb2d7988dbe648fa12067b243884c'
        game='2ee55540391ddbff5e41c6b8dcdb09006b8fd8d5e0bb31c4203037579bc7f247'
        gunwcuser='1e7139a616986b27f635a23e2e9a7bbc06e60b38fc004c741a9e453e386decbb'
        item='8a28f2cc49e0db8ebc8fc44c29db64697e4bb68d87e5b13252364a26add42468'
        menu='79a73e77521d459e19dcce0f9db251b23fa61e5ad9cd99821cea7239a2f0dd1a'
        menudat='bd26a6bdd795b9ec699f8a373baa16b9b1e017d56b5befa601af67635a822a59'
        user='82c2c5c6a6f823f9f46e6c8d5672cbc166a7a5e2aa5367ca7ee9664f12cd2404'
    }
    $indexes = @{
        cash=@('primarykey(id)'); chest=@('primarykey(no)'); game=@('keyguild(guild)','primarykey(id)')
        gunwcuser=@(); item=@('primarykey(no)'); menu=@('primarykey(no)'); menudat=@('primarykey(id)'); user=@('primarykey(id)')
    }
    foreach ($table in $hashes.Keys) {
        $definition = @($Plan.tables | Where-Object name -IEQ $table)[0].sql
        $actualIndexes=@($definition -split '\r?\n' | Where-Object { $_ -match '^\s*(?:PRIMARY KEY|(?:UNIQUE )?KEY )' } |
            ForEach-Object { ($_.Trim().TrimEnd(',').ToLowerInvariant() -replace '[\s`]', '') -replace 'usingbtree$','' } | Sort-Object)
        if (($actualIndexes -join '|') -cne ($indexes[$table] -join '|')) { throw "Unreviewed $table indexes or account uniqueness constraints." }
        $rows = @(foreach ($line in $definition -split '\r?\n') {
            if ($line -match '^\s*`(\w+)`\s+(\w+(?:\(\d+(?:,\d+)?\))?(?: UNSIGNED)?)(.*)') {
                $name=$Matches[1].ToLowerInvariant(); $type=$Matches[2].ToLowerInvariant(); $tail=$Matches[3]
                $default = if ($tail -match " DEFAULT ('[^']*'|[^,\s]+)") { $Matches[1].Trim("'") } else { '<null>' }
                if ($default -ceq 'NULL') { $default='<null>' }
                $collation = if ($tail -match ' COLLATE (\w+)') { $Matches[1].ToLowerInvariant() } else { '' }
                $nullable = if ($tail.Contains('NOT NULL')) { 'NO' } else { 'YES' }
                $extra = if ($tail.Contains('AUTO_INCREMENT')) { 'auto_increment' } else { '' }
                @($table,$name,$type,$nullable,$default,$collation,$extra,'') -join '|'
            }
        })
        if ((Get-BackendHash ([Text.Encoding]::UTF8.GetBytes($rows -join "`n"))) -cne $hashes[$table]) {
            throw "Unreviewed $table columns/defaults; the supplied schema was not adopted."
        }
    }
}

function New-BackendPassword([int]$Length) {
    if ($Length -notin @(12,20,40)) { throw 'Unsupported backend password length.' }
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    -join (1..$Length | ForEach-Object { $alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)] })
}

function Assert-BackendAccounts($Accounts) {
    $names = @('Player','BotOne','BotTwo','BotThree')
    $fields = @('role','username','password','id','nickname')
    $passwords = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($Accounts -isnot [array] -or $Accounts.Count -ne 4) { throw 'Fresh backend accounts must contain exactly Player/BotOne/BotTwo/BotThree.' }
    for ($i=0; $i -lt 4; $i++) {
        $a=$Accounts[$i]
        if ($a -isnot [pscustomobject] -or @($a.PSObject.Properties).Count -ne 5 -or
            @($fields | Where-Object { $a.PSObject.Properties.Name -cnotcontains $_ -or $a.$_ -isnot [string] }).Count -or
            $a.role -cne $(if ($i -eq 0) { 'human' } else { 'bot' }) -or $a.username -cne $names[$i] -or
            $a.id -cne $names[$i] -or $a.nickname -cne $names[$i] -or $a.password -cnotmatch '\A[A-Za-z0-9]{12}\z' -or
            !$passwords.Add($a.password)) { throw 'Invalid fresh account fields, identities, roles or distinct 12-character credentials.' }
    }
}

function New-BackendAccounts {
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $accounts = @(foreach ($name in @('Player','BotOne','BotTwo','BotThree')) {
        do { $password = New-BackendPassword 12 } until ($used.Add($password))
        [pscustomobject][ordered]@{ role=$(if ($name -ceq 'Player') { 'human' } else { 'bot' })
            username=$name; password=$password; id=$name; nickname=$name }
    })
    Assert-BackendAccounts $accounts
    ,$accounts
}

function Get-BackendSettings([string]$Text, [string]$Component) {
    $ports = @{Server8360=8360; Central=8372; BuddyCenter=8339; BuddyServ=8352}
    if (!$ports.ContainsKey($Component) -or $Text.Length -gt 65536 -or $Text -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') {
        throw 'Unsupported native component/configuration size or control characters.'
    }
    $settings = [ordered]@{}
    foreach ($line in $Text -split '\r?\n') {
        if (!$line.Trim() -or $line -match '^\s*[#;]') { continue }
        if ($line -cnotmatch '^([A-Za-z][A-Za-z0-9_]*)=([^\r\n]*)$' -or $settings.Contains($Matches[1])) {
            throw 'Unsupported or duplicate native setting; no source settings were copied.'
        }
        $settings[$Matches[1]] = $Matches[2]
    }
    $accept = if ($Component -ceq 'BuddyServ') { 'StarAccept' } else { 'Accept' }
    if ($settings['Port'] -cne [string]$ports[$Component] -or !$settings.Contains($accept) -or
        ($settings.Contains('Accept') -and $settings.Contains('StarAccept'))) { throw 'Native port/allowlist ownership does not match the selected component.' }
    $prefixes = @{}
    foreach ($key in $settings.Keys) {
        if ($key -cmatch '^(\w*DB\w*_)(Host|Port|User|Pwd|Password|DB)$') {
            $prefix=$Matches[1]; $kind=$Matches[2]
            if (!$prefixes.ContainsKey($prefix)) { $prefixes[$prefix]=@() }
            $prefixes[$prefix] += $kind
        } elseif ($key -match 'DB.*_(Host|Port|User|Pwd|Password|DB)$') { throw 'Unexpected native SQL setting spelling.' }
    }
    if (!$prefixes.Count) { throw 'Native SQL endpoint fields are missing.' }
    foreach ($fields in $prefixes.Values) {
        if ($fields.Count -ne 5 -or @('Host','Port','User','DB' | Where-Object { $_ -cnotin $fields }).Count -or
            @($fields | Where-Object { $_ -cin @('Pwd','Password') }).Count -ne 1) {
            throw 'A native SQL credential/endpoint group is incomplete or ambiguous.'
        }
    }
    $settings
}

function Convert-BackendSettings([string]$Text, [string]$Component, $Credentials) {
    if ($Credentials.nativeUser -cne 'gb_local' -or $Credentials.nativePassword -cnotmatch '\A[A-Za-z0-9]{20}\z') {
        throw 'Invalid generated native database credentials.'
    }
    $settings = Get-BackendSettings $Text $Component
    foreach ($key in @($settings.Keys)) {
        if ($key -cmatch '^\w*DB\w*_(Host|Port|User|Pwd|Password|DB)$') {
            $settings[$key] = switch -CaseSensitive ($Matches[1]) {
                Host { '127.0.0.1' }; Port { '3308' }; User { $Credentials.nativeUser }
                Pwd { $Credentials.nativePassword }; Password { $Credentials.nativePassword }; DB { 'gunbound' }
            }
        } elseif ($key -cin @('Accept','StarAccept')) { $settings[$key]='127.0.0.1;' }
        elseif ($key -cin @('MaxConnection','MaxConnectionPerSource')) { $settings[$key]='16' }
    }
    $settings['Log']='1'
    (@($settings.Keys | ForEach-Object { "$_=$($settings[$_])" }) -join "`r`n") + "`r`n"
}

function Get-BackendSourceLayout([string]$Directory) {
    $source = Resolve-BackendLocalPath $Directory
    [pscustomobject]@{root=$source;sql="$source\Database\gunbound.sql";native="$source\Server Binaries\GunBoundXP"}
}

function Get-BackendSourcePlan([string]$Directory) {
    $layout = Get-BackendSourceLayout $Directory
    $source = $layout.root
    Assert-BackendPath $source
    if (!(Test-Path -LiteralPath $layout.sql -PathType Leaf) -or
        !(Test-Path -LiteralPath $layout.native -PathType Container)) {
        throw '-ServerSourceDirectory must contain Database\gunbound.sql and Server Binaries\GunBoundXP.'
    }
    $raw = Read-BackendBytes $layout.sql
    $schema = Get-BackendSchemaPlan ([Text.UTF8Encoding]::new($false,$true).GetString($raw))
    Assert-BackendSchema $schema
    . "$PSScriptRoot\bind-loopback.ps1"
    $known = Get-LabNativeHashes
    $files = Get-BackendNativeFiles
    $assets = [Collections.Generic.List[object]]::new()
    $settings = @{}
    foreach ($component in $files.Keys) {
        $settings[$component] = [Text.Encoding]::Latin1.GetString((Read-BackendBytes "$source\Server Binaries\GunBoundXP\$component\setting.txt" 65536))
        $null = Get-BackendSettings $settings[$component] $component
        foreach ($name in $files[$component]) {
            $relative = "$component\$name"
            $path = "$source\Server Binaries\GunBoundXP\$relative"
            $bytes = Read-BackendBytes $path
            $hash = Get-BackendHash $bytes
            if ($known.ContainsKey($relative) -and $hash -cne $known[$relative].original) {
                throw 'The native world/broker must match the exact pinned, unmodified original images.'
            }
            if ($name.EndsWith('.exe') -and ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a)) {
                throw 'A required native server image is not a PE executable.'
            }
            $assets.Add([pscustomobject]@{ relative=$relative; path=$path; sha256=$hash })
        }
    }
    $world = Get-BackendSettings $settings.Server8360 'Server8360'
    $agent = [pscustomobject]@{username=$world['PartnerAgentDB_User']; password=$world['PartnerAgentDB_Pwd']}
    if ($agent.username -cnotmatch '\A[A-Za-z0-9_]{1,16}\z' -or $agent.username -iin @('root','mariadb.sys','gb_local') -or
        $agent.password -cnotmatch '\A[A-Za-z0-9]{4,32}\z') { throw 'Unexpected compiled Agent credentials; administrator identities are never adopted.' }
    [pscustomobject]@{source=$source; sourceSha256=(Get-BackendHash $raw); schema=$schema; assets=$assets.ToArray(); settings=$settings; agent=$agent}
}

function New-BackendConfiguration([string]$Root, $Credentials) {
    if ($Credentials.rootPassword -cnotmatch '\A[A-Za-z0-9]{40}\z' -or
        $Credentials.nativeUser -cne 'gb_local' -or $Credentials.nativePassword -cnotmatch '\A[A-Za-z0-9]{20}\z') {
        throw 'Invalid generated database credentials.'
    }
    $rootPath = Resolve-BackendLocalPath $Root
    $escaped = $rootPath.Replace('\','\\')
    [pscustomobject]@{
        admin = @"
[client]
user=root
password=$($Credentials.rootPassword)
host=127.0.0.1
port=3307
protocol=tcp
default-character-set=latin1
"@
        server = @"
[mysqld]
basedir="$escaped\\runtime\\mariadb\\mariadb-11.4.13-winx64"
datadir="$escaped\\runtime\\mariadb\\data"
tmpdir="$escaped\\runtime\\mariadb\\work"
log-error="$escaped\\logs\\backend-mariadb.log"
pid-file="$escaped\\backend\\database.pid"
port=3307
bind-address=127.0.0.1
skip-name-resolve
skip-log-bin
general-log=OFF
slow-query-log=OFF
event-scheduler=DISABLED
local-infile=0
secure-auth=OFF
character-set-server=latin1
collation-server=latin1_swedish_ci
sql-mode=NO_ENGINE_SUBSTITUTION
max-connections=64
innodb-buffer-pool-size=64M
key-buffer-size=16M
performance-schema=OFF
"@
    }
}

function Convert-BackendDiagnostic([string]$Text) {
    $codes = @([regex]::Matches($Text, '(?m)^ERROR [0-9]{3,5}(?: \([A-Z0-9]{5}\))?(?: at line [0-9]+)?') | ForEach-Object Value)
    if ($Text) { ($codes -join ', ') + "`nProcess/SQL diagnostics: [REDACTED]; private input is never echoed." } else { '' }
}

function Invoke-BackendCommand([string]$Root, [string]$Executable, [string[]]$Arguments, [string]$InputText = '') {
    $path = "$Root\runtime\mariadb\mariadb-11.4.13-winx64\bin\$Executable"
    Assert-BackendPath $path $Root
    if ($Executable -cnotin @('mariadb.exe','mariadb-install-db.exe','mariadbd.exe','mariadb-admin.exe') -or
        !(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A required verified portable MariaDB executable is missing.' }
    $info = [Diagnostics.ProcessStartInfo]::new($path)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.WorkingDirectory=$Root
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    $info.Environment['TEMP']="$Root\runtime\mariadb\work"; $info.Environment['TMP']=$info.Environment['TEMP']
    foreach ($name in @('MYSQL_PWD','MYSQL_DEBUG','MYSQL_HISTFILE')) { $null=$info.Environment.Remove($name) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        try { $process.StandardInput.Write($InputText) } finally { $process.StandardInput.Close() }
        # Offline bootstrap also retains its handle until EOF has closed the instance.
        $process.WaitForExit()
        $output=$stdout.GetAwaiter().GetResult()
        $diagnostic=Convert-BackendDiagnostic ($stderr.GetAwaiter().GetResult())
        $log="$Root\private\backend\last-command-errors.log"
        Write-BackendPrivate $log $diagnostic $Root -Replace:([IO.File]::Exists($log))
        if ($process.ExitCode) { throw "Portable MariaDB command failed (exit $($process.ExitCode)); inspect private\backend\last-command-errors.log." }
        $output.Trim()
    } finally {
        try { $process.StandardInput.Close(); $process.WaitForExit() } finally { $process.Dispose() }
    }
}

function Invoke-BackendSql([string]$Root, [string]$Sql) {
    Invoke-BackendCommand $Root 'mariadb.exe' @("--defaults-file=$Root\private\backend\admin.ini",
        '--batch','--raw','--skip-column-names','--connect-timeout=5','--skip-reconnect','--local-infile=0') $Sql
}

function New-BackendAccountSql($Accounts) {
    Assert-BackendAccounts $Accounts
    foreach ($a in $Accounts) {
        $id=$a.username; $password=$a.password
        # Local fresh test balances, not copied player progress or inventory.
        @"
INSERT INTO User (Id, user, Gender, NickName, Password, Status, MuteTime, RestrictTime, Authority, E_Mail, Country, User_Level, Authority2, RegDate, BirthDate, RegIp) VALUES ('$id','$id',0,'$id','$password','0',FROM_UNIXTIME(0),FROM_UNIXTIME(0),'1','$id@localhost.invalid','1',0,1,NOW(),'2000-01-01 00:00:00','127.0.0.1');
INSERT INTO GunWcUser (Id, user, Gender, NickName, Password, Status, MuteTime, RestrictTime, Authority, E_Mail, Country, User_Level, Authority2, AuthorityBackup) VALUES ('$id','$id',0,'$id','$password','0',FROM_UNIXTIME(0),FROM_UNIXTIME(0),'1','$id@localhost.invalid','999',1,1,'1');
INSERT INTO Game (Id, Nickname, Money, TotalScore, SeasonScore, TotalGrade, SeasonGrade, TotalRank, SeasonRank, SeasonRankHistory, NoRankUpdate, Country, CountryGrade, GiftProhibitTime) VALUES ('$id','$id',100000000,1000,1000,19,19,0,0,0,0,'999','19',FROM_UNIXTIME(0));
INSERT INTO Cash (ID, Cash) VALUES ('$id',100000000);
"@
        if ($a.role -ceq 'bot') {
            $items = (@(98345,32807,163847,229381) | ForEach-Object { "($_,1,'T',NULL,1,0,0,'$id','I')" }) -join ','
            "INSERT INTO Chest (Item,Wearing,Acquisition,Expire,Volume,PlaceOrder,Recovered,Owner,ExpireType) VALUES $items;"
        }
    }
}

function New-BackendGrantSql($Credentials, $Agent) {
    if ($Credentials.nativeUser -cne 'gb_local' -or $Credentials.nativePassword -cnotmatch '\A[A-Za-z0-9]{20}\z' -or
        $Agent.username -cnotmatch '\A[A-Za-z0-9_]{1,16}\z' -or $Agent.username -iin @('root','mariadb.sys','gb_local') -or
        $Agent.password -cnotmatch '\A[A-Za-z0-9]{4,32}\z') { throw 'Unsafe native SQL authentication metadata.' }
    'SET SESSION old_passwords=1;'
    foreach ($account in @([pscustomobject]@{username=$Credentials.nativeUser; password=$Credentials.nativePassword},$Agent)) {
        foreach ($hostName in @('localhost','127.0.0.1')) {
            "CREATE USER '$($account.username)'@'$hostName' IDENTIFIED BY '$($account.password)';"
            "GRANT SELECT, INSERT, UPDATE, DELETE, LOCK TABLES ON gunbound.* TO '$($account.username)'@'$hostName';"
        }
    }
}

function Assert-BackendFreshDatabase([string]$Result) {
    if ((($Result -split '\r?\n') -join ',') -cne '1,1,1,1') {
        throw 'An existing database/account/session or SQL logger was found; no game data was changed.'
    }
}

function Assert-BackendProcessRecord($Entry, [string]$Root, $Supervisor = $null) {
    if ($Entry.name -cne 'mariadb' -or $Entry.path -ine "$Root\runtime\mariadb\mariadb-11.4.13-winx64\bin\mariadbd.exe" -or
        $Entry.group -cne 'Database' -or $Entry.port -ne 3307 -or $Entry.bindAddress -cne '127.0.0.1' -or
        ($Entry.pid -isnot [long] -and $Entry.pid -isnot [int]) -or $Entry.pid -le 0 -or
        ($Entry.startedUtcTicks -isnot [long] -and $Entry.startedUtcTicks -isnot [int]) -or $Entry.startedUtcTicks -le 0) {
        throw 'The database PID/path/start identity is not owned by this installation.'
    }
    if ($Supervisor -and ($Entry.supervisorPid -ne $Supervisor.Id -or $Entry.supervisorPath -ine $Supervisor.Path -or
            $Entry.supervisorStartedUtcTicks -ne $Supervisor.StartTime.ToUniversalTime().Ticks)) {
        throw 'The database was not started by the retained setup supervisor.'
    }
}

function Get-BackendOwnedDatabase([string]$Root, $Supervisor = $null) {
    $path="$Root\backend\database-processes.json"
    Assert-BackendPath $path $Root
    $entries=@(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    if ($entries.Count -ne 1) { throw 'Exactly one owned database process is required.' }
    $entry=$entries[0]
    Assert-BackendProcessRecord $entry $Root $Supervisor
    $p=Get-Process -Id $entry.pid -ErrorAction Stop
    if ($p.Path -ine $entry.path -or $p.StartTime.ToUniversalTime().Ticks -ne $entry.startedUtcTicks) {
        throw 'The recorded database identity is stale; no process was adopted.'
    }
    $command=(Get-CimInstance Win32_Process -Filter "ProcessId=$($entry.pid)" -ErrorAction Stop).CommandLine
    if (!$command -or !$command.Contains("--defaults-file=$Root\private\backend\my.ini")) { throw 'The owned database command does not use this installation configuration.' }
    $entry
}

function Initialize-Backend([string]$Root, $Plan, [string]$ArchivePath, [string]$ArchiveSha256) {
    Assert-BackendFresh $Root -DistributionInstalled
    if (Test-Path -LiteralPath "$Root\network.json") { throw 'Fresh backend initialization must precede private network configuration.' }
    $private="$Root\private\backend"; $data="$Root\runtime\mariadb\data"
    foreach ($directory in @("$Root\private",$private,"$Root\private\vm","$Root\backend\native",$data,"$Root\runtime\mariadb\work","$Root\logs")) {
        Assert-BackendPath $directory $Root
        $null=New-Item -ItemType Directory -Path $directory -Force
    }
    foreach ($directory in @($private,"$Root\private\vm","$Root\backend\native",$data,"$Root\runtime\mariadb\work")) {
        Protect-BackendPath $directory $Root
    }
    $credentials=[pscustomobject][ordered]@{rootPassword=(New-BackendPassword 40); nativeUser='gb_local'; nativePassword=(New-BackendPassword 20)}
    $accounts=New-BackendAccounts
    $configuration=New-BackendConfiguration $Root $credentials
    $state=[pscustomobject][ordered]@{schemaVersion=1; installationId=[Guid]::NewGuid().ToString('D'); root=$Root
        phase='initializing'; createdUtc=[DateTime]::UtcNow.ToString('o'); files=[ordered]@{}}
    Write-BackendPrivate "$private\setup-state.json" ($state | ConvertTo-Json -Depth 5) $Root
    $source=[ordered]@{schemaVersion=1;serverSourceDirectory=$Plan.source;mariaDbArchive=$ArchivePath
        mariaDbArchiveSha256=$ArchiveSha256;sourceSqlSha256=$Plan.sourceSha256}
    Write-BackendPrivate "$private\source.json" ($source | ConvertTo-Json) $Root
    Write-BackendPrivate "$private\credentials.json" ($credentials | ConvertTo-Json) $Root
    Write-BackendPrivate "$private\accounts.json" (ConvertTo-Json -InputObject $accounts) $Root
    Write-BackendPrivate "$Root\private\accounts.json" (ConvertTo-Json -InputObject $accounts[0..1]) $Root
    Write-BackendPrivate "$Root\private\vm\bot-accounts.json" (ConvertTo-Json -InputObject $accounts[1..3]) $Root
    Write-BackendPrivate "$private\legacy-agent.json" ($Plan.agent | ConvertTo-Json) $Root
    Write-BackendPrivate "$private\admin.ini" $configuration.admin $Root
    Write-BackendPrivate "$private\my.ini" $configuration.server $Root
    Write-BackendPrivate "$Root\backend\schema-static.sql" $Plan.schema.sql $Root
    $binaries=[ordered]@{}
    foreach ($asset in $Plan.assets) {
        $bytes=Read-BackendBytes $asset.path
        if ((Get-BackendHash $bytes) -cne $asset.sha256) { throw 'A source native asset changed after validation.' }
        $destination="$Root\backend\native\$($asset.relative)"
        $null=New-Item -ItemType Directory -Path (Split-Path $destination) -Force
        $stream=[IO.File]::Open($destination,'CreateNew','Write','None')
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ($asset.relative.EndsWith('.exe')) { $binaries[(Split-Path $asset.relative -Leaf)]=$asset.sha256 }
    }
    foreach ($component in $Plan.settings.Keys) {
        Write-BackendPrivate "$Root\backend\native\$component\setting.txt" (Convert-BackendSettings $Plan.settings[$component] $component $credentials) $Root -Encoding ([Text.Encoding]::Latin1)
    }
    Write-BackendPrivate "$Root\backend\native\Central\GameServerList.txt" "Local Practice;GunBound AI Lab;127.0.0.1;8360;0;`r`n" $Root
    foreach ($name in @('channel_ment.txt','room_ment.txt')) {
        Write-BackendPrivate "$Root\backend\native\Server8360\$name" "Local GunBound AI Lab`r`n" $Root
    }
    $manifest=[ordered]@{schemaVersion=1;databaseVersion='11.4.13';freshAccounts=@($accounts.username)
        schemaTables=$Plan.schema.tables.Count;staticTables=@('Item','Menu','MenuDat','Ranks');nativeBackend=@{binaries=$binaries}}
    Write-BackendPrivate "$Root\backend\manifest.json" ($manifest | ConvertTo-Json -Depth 5) $Root
    & "$Root\backend\network-config.ps1" -Prepare | Out-Null
    foreach ($name in @('backend-mariadb.log','backend-mariadb-stdout.log','backend-mariadb-stderr.log',
        'backend-shutdown-errors.log','backend-supervisor-errors.log','backend-setup-supervisor-stdout.log','backend-setup-supervisor-stderr.log')) {
        $path="$Root\logs\$name"
        if (Test-Path -LiteralPath $path) { throw 'A setup log already exists; refusing to replace it.' }
        Write-BackendPrivate $path '' $Root
    }
    Invoke-BackendCommand $Root 'mariadb-install-db.exe' @("--datadir=$data",'--port=3307','--skip-networking','--silent') | Out-Null
    $bootstrap=@"
UPDATE mysql.global_priv SET Priv=JSON_SET(Priv, '$.plugin', 'mysql_native_password', '$.authentication_string', PASSWORD('$($credentials.rootPassword)')) WHERE User='root' AND Host='localhost';
INSERT INTO mysql.global_priv (Host,User,Priv) SELECT '127.0.0.1',User,Priv FROM mysql.global_priv WHERE User='root' AND Host='localhost' ON DUPLICATE KEY UPDATE Priv=VALUES(Priv);
DELETE FROM mysql.global_priv WHERE NOT ((User='root' AND Host IN ('localhost','127.0.0.1')) OR (User='mariadb.sys' AND Host='localhost'));
DELETE FROM mysql.proxies_priv;
DROP DATABASE IF EXISTS test;
"@
    Invoke-BackendCommand $Root 'mariadbd.exe' @("--defaults-file=$private\my.ini",'--bootstrap','--skip-networking') $bootstrap | Out-Null
    foreach ($relative in Get-BackendPreparedFileNames) {
        $state.files[$relative]=(Get-FileHash -LiteralPath "$Root\$relative" -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $state.phase='initialized'
    Write-BackendPrivate "$private\setup-state.json" ($state | ConvertTo-Json -Depth 5) $Root -Replace
}

function Invoke-BackendProvision([string]$Root) {
    $private="$Root\private\backend"
    Assert-BackendPath "$private\setup-state.json" $Root
    $state=Read-BackendJson $Root 'private\backend\setup-state.json'
    Assert-BackendSavedState $state $Root 'initialized'
    foreach ($field in $state.files.PSObject.Properties) {
        $path="$Root\$($field.Name)"
        Assert-BackendPath $path $Root
        if ($field.Value -cnotmatch '\A[0-9a-f]{64}\z' -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $field.Value) {
            throw 'A prepared native/config/account artifact changed; fresh provisioning was refused.'
        }
    }
    $credentials=Get-Content -LiteralPath "$private\credentials.json" -Raw | ConvertFrom-Json
    $accounts=@(Get-Content -LiteralPath "$private\accounts.json" -Raw | ConvertFrom-Json)
    Assert-BackendAccounts $accounts
    $configuration=New-BackendConfiguration $Root $credentials
    if ([IO.File]::ReadAllText("$private\admin.ini") -cne $configuration.admin -or
        [IO.File]::ReadAllText("$private\my.ini") -cne $configuration.server) { throw 'Database configuration does not belong to the prepared root/credentials.' }
    $agent=Get-Content -LiteralPath "$private\legacy-agent.json" -Raw | ConvertFrom-Json
    $grants=@(New-BackendGrantSql $credentials $agent) -join "`n"
    . "$PSScriptRoot\network-config.ps1"
    $network=Get-LabNetwork
    if ($network.IsPrivate) { throw 'Fresh provisioning must precede private network configuration.' }
    Assert-LabCoreStopped
    Assert-LabNetworkPrepared $network
    $entry=Get-BackendOwnedDatabase $Root
    Assert-LabServiceEndpoints $entry $network | Out-Null
    $db=Invoke-BackendSql $Root "SELECT JSON_OBJECT('version',VERSION(),'port',@@port,'datadir',@@datadir,'basedir',@@basedir,'bind',@@bind_address);"
    $db=$db | ConvertFrom-Json
    if ($db.version -cnotmatch '\A11\.4\.13-MariaDB(?:[-+].*)?\z' -or $db.port -ne 3307 -or $db.bind -cne '127.0.0.1' -or
        $db.datadir.Replace('/','\').TrimEnd('\') -ine "$Root\runtime\mariadb\data" -or
        $db.basedir.Replace('/','\').TrimEnd('\') -ine "$Root\runtime\mariadb\mariadb-11.4.13-winx64") {
        throw 'The supervised database version, paths or loopback binding differ from this fresh installation.'
    }
    $empty=Invoke-BackendSql $Root @"
SELECT COUNT(*)=0 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='gunbound';
SELECT COUNT(*)=0 FROM mysql.user WHERE User NOT IN ('root','mariadb.sys');
SELECT COUNT(*)=0 FROM information_schema.PROCESSLIST WHERE ID<>CONNECTION_ID();
SELECT @@general_log=0 AND @@slow_query_log=0 AND @@log_bin=0 AND @@performance_schema=0 AND @@event_scheduler='DISABLED';
"@
    Assert-BackendFreshDatabase $empty
    $state.phase='provisioning'
    Write-BackendPrivate "$private\setup-state.json" ($state | ConvertTo-Json -Depth 5) $Root -Replace
    $schema=Get-BackendSchemaPlan ([IO.File]::ReadAllText("$Root\backend\schema-static.sql"))
    Assert-BackendSchema $schema
    $sql="CREATE DATABASE gunbound CHARACTER SET latin1 COLLATE latin1_swedish_ci;`nUSE gunbound;`n" + $schema.sql + "`n" + $grants + "`n"
    $sql+=(@(New-BackendAccountSql $accounts) -join "`n")
    $sql+="`nINSERT INTO ApplicationSetting VALUES (701,'http://127.0.0.1/','http://127.0.0.1/','http://127.0.0.1/',7,7);"
    Invoke-BackendSql $Root $sql | Out-Null
    $checks=[Collections.Generic.List[string]]::new()
    $checks.Add("SELECT COUNT(*)=57 FROM information_schema.TABLES WHERE TABLE_SCHEMA='gunbound' AND TABLE_TYPE='BASE TABLE';")
    foreach ($table in @('User','GunWcUser','Game','Cash')) { $checks.Add("SELECT COUNT(*)=4 FROM gunbound.$table;") }
    foreach ($table in @('Item','Menu')) { $checks.Add("SELECT COUNT(*)>=1000 FROM gunbound.$table;") }
    foreach ($table in @('MenuDat','Ranks','ApplicationSetting')) { $checks.Add("SELECT COUNT(*)>0 FROM gunbound.$table;") }
    foreach ($a in $accounts) {
        $name=$a.username
        $checks.Add("SELECT COUNT(*)=1 FROM gunbound.User u JOIN gunbound.GunWcUser w ON u.Id=w.Id JOIN gunbound.Game g ON u.Id=g.Id JOIN gunbound.Cash c ON u.Id=c.ID WHERE BINARY u.Id='$name' AND BINARY u.Password='$($a.password)' AND BINARY w.Password='$($a.password)' AND g.Money=100000000 AND c.Cash=100000000 AND UNIX_TIMESTAMP(u.MuteTime)=0 AND UNIX_TIMESTAMP(u.RestrictTime)=0 AND UNIX_TIMESTAMP(w.MuteTime)=0 AND UNIX_TIMESTAMP(w.RestrictTime)=0 AND UNIX_TIMESTAMP(g.GiftProhibitTime)=0;")
        if ($a.role -ceq 'bot') {
            $checks.Add("SELECT COUNT(*)=4 AND COUNT(DISTINCT Item)=4 AND MIN(COALESCE(BINARY Owner='$name' AND No>0 AND Item IN (98345,32807,163847,229381) AND Wearing=1 AND BINARY Acquisition='T' AND Expire IS NULL AND Volume=1 AND PlaceOrder=0 AND Recovered=0 AND BINARY ExpireType='I',0))=1 FROM gunbound.Chest WHERE Owner='$name';")
        }
    }
    $checks.Add('SELECT COUNT(*)=12 FROM gunbound.Chest;')
    $checks.Add("SELECT COUNT(*)=4 AND MIN(plugin='mysql_old_password')=1 FROM mysql.user WHERE User IN ('gb_local','$($agent.username)') AND Host IN ('localhost','127.0.0.1');")
    $checks.Add('SELECT COUNT(*)=4 FROM gunbound.Item i JOIN gunbound.Menu m ON i.No=m.No WHERE i.No IN (98345,32807,163847,229381) AND m.Item1=i.No AND m.Item2 IS NULL AND m.Item3 IS NULL AND m.Item4 IS NULL AND m.Item5 IS NULL AND m.Volume1=1;')
    foreach ($table in $schema.tables.name | Where-Object { $_ -inotmatch '^(User|GunWcUser|Game|Cash|Chest|Item|Menu|MenuDat|Ranks|ApplicationSetting)$' }) {
        $checks.Add('SELECT COUNT(*)=0 FROM gunbound.`' + $table + '`;')
    }
    $verified=(Invoke-BackendSql $Root ($checks -join "`n")) -split '\r?\n'
    if ($verified.Count -ne $checks.Count -or @($verified | Where-Object { $_ -cne '1' }).Count) {
        throw 'Fresh schema/account/catalog/gear verification failed; preserve the stopped partial installation for review, not a retry.'
    }
    $state.phase='provisioned'
    Write-BackendPrivate "$private\setup-state.json" ($state | ConvertTo-Json -Depth 5) $Root -Replace
    Write-Output 'Provisioned and verified four fresh local test accounts and three hard-geared bots; no historical player data was imported.'
}

if ($MyInvocation.InvocationName -ne '.') {
    $root=Split-Path $PSScriptRoot
    if ($Provision) {
        if ($ServerSourceDirectory) { throw '-Provision uses the protected initialization record, not a new source directory.' }
        Invoke-BackendProvision $root
    } else {
        throw 'Use setup\prepare-backend.ps1 -ServerSourceDirectory <folder> -MariaDbArchive <zip> for fresh initialization. Resume and credential replacement are intentionally unsupported.'
    }
}
