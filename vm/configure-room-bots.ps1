#requires -Version 5.1
[CmdletBinding()]
param([switch]$Check, [switch]$FirstDeployment)
$ErrorActionPreference = 'Stop'

function Room-Instances($Marker, $Network) {
    $names = @('BotOne','BotTwo','BotThree')
    $addresses = @('192.168.56.10','192.168.56.11','192.168.56.12')
    if ($Marker.roomFill -ne $true -or $Marker.roomFill -isnot [bool] -or
        $Network.schemaVersion -ne 2 -or $Network.mode -cne 'private' -or
        $Network.serverAddress -cne '192.168.56.10' -or $Network.humanAddress -cne '192.168.56.1' -or
        $Network.botAddress -cne $addresses[0] -or
        (@($Network.botAddresses) -join ',') -cne ($addresses -join ',') -or
        @($Marker.botInstances).Count -ne 3) {
        throw 'Room filling requires the approved three-bot private network and marker.'
    }
    for ($i = 0; $i -lt 3; $i++) {
        $entry = $Marker.botInstances[$i]
        if (@($entry.PSObject.Properties).Count -ne 2 -or
            $entry.name -cne $names[$i] -or $entry.address -cne $addresses[$i]) {
            throw 'Unexpected, reordered, or duplicate room-bot configuration.'
        }
        [pscustomobject]@{name=$names[$i];address=$addresses[$i];root=('C:\GunBoundAI\instances\' + $names[$i])}
    }
}

function Test-RoomAddressState($Rows, [string[]]$Expected) {
    $observed = @($Rows | ForEach-Object { $_.IPAddress })
    if (@($Rows | Where-Object { $_.IPAddress -notin $Expected -or $_.PrefixLength -ne 24 }).Count -ne 0 -or
        $Expected[0] -notin $observed -or @($observed | Sort-Object -Unique).Count -ne $observed.Count) {
        throw 'Unexpected addresses or missing primary address on the guest-only adapter.'
    }
    if (@($Rows | Where-Object { [int]$_.AddressState -eq 2 }).Count) { throw 'A room-bot guest address conflicts with another peer.' }
    # NetTCPIP CIM uses numeric NL_DAD_STATE values: Preferred=4, Duplicate=2.
    @($Rows | Where-Object { [int]$_.AddressState -eq 4 }).Count -eq $Expected.Count
}

if ($Check) {
    $marker = [pscustomobject]@{roomFill=$true;botInstances=@(
        [pscustomobject]@{name='BotOne';address='192.168.56.10'}
        [pscustomobject]@{name='BotTwo';address='192.168.56.11'}
        [pscustomobject]@{name='BotThree';address='192.168.56.12'}
    )}
    $network = [pscustomobject]@{schemaVersion=2;mode='private';serverAddress='192.168.56.10'
        humanAddress='192.168.56.1';botAddress='192.168.56.10';botAddresses=@('192.168.56.10','192.168.56.11','192.168.56.12')}
    $instances = @(Room-Instances $marker $network)
    if ($instances.Count -ne 3 -or $instances[1].root -cne 'C:\GunBoundAI\instances\BotTwo') {
        throw 'The isolated instance mapping changed.'
    }
    $expectedAddresses = @($instances | ForEach-Object { $_.address })
    $rows = @([pscustomobject]@{IPAddress='192.168.56.10';PrefixLength=24;AddressState=[uint32]4})
    if (Test-RoomAddressState $rows $expectedAddresses) { throw 'A single primary address was presented as three ready peers.' }
    $rows += [pscustomobject]@{IPAddress='192.168.56.11';PrefixLength=24;AddressState=[uint32]4}
    $rows += [pscustomobject]@{IPAddress='192.168.56.12';PrefixLength=24;AddressState=[uint32]4}
    if (!(Test-RoomAddressState $rows $expectedAddresses)) { throw 'Three preferred CIM peer addresses were rejected.' }
    $rows[2].AddressState = [uint32]1
    if (Test-RoomAddressState $rows $expectedAddresses) { throw 'Tentative address detection was skipped.' }
    $rows[2].AddressState = [uint32]2
    $rejected = $false
    try { Test-RoomAddressState $rows $expectedAddresses | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'A duplicate network address was accepted.' }
    $marker.botInstances[1].address = '192.168.56.10'
    $rejected = $false
    try { Room-Instances $marker $network | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'A duplicate instance address was accepted.' }
    $marker.botInstances[1].address = '192.168.56.11'
    $network.botAddresses = @('192.168.56.10','192.168.56.11','8.8.8.8')
    $rejected = $false
    try { Room-Instances $marker $network | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'An unapproved peer was accepted.' }
    Write-Output 'PASS: bounded named instance roots and exact private peer configuration. No files, accounts, adapters or firewall rules changed.'
    return
}

$root = Split-Path $PSScriptRoot
$marker = Get-Content -LiteralPath "$PSScriptRoot\guest.json" -Raw | ConvertFrom-Json
if ($root -cne 'C:\GunBoundAI' -or $env:COMPUTERNAME -cne 'GUNBOUND-BOT' -or
    $marker.root -cne $root -or $marker.computerName -cne $env:COMPUTERNAME -or
    $marker.provider -cne 'virtualbox') {
    throw 'Room-bot configuration is restricted to the identified local guest.'
}
. "$PSScriptRoot\shared-io.ps1"
Assert-GuestIdentity -OwnerId $marker.ownerId
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if (!([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Room-bot configuration requires the guest administrator or SYSTEM.'
    }
} finally { $identity.Dispose() }
if ($FirstDeployment) {
    if ((Test-Path -LiteralPath "$PSScriptRoot\bootstrap-receipt.json") -or
        $marker.PSObject.Properties.Name -contains 'serverRoot' -or
        !(Test-Path -LiteralPath 'C:\ProgramData\GunBoundAIControl\setup-user-password.txt')) {
        throw 'First-deployment mode requires the original, unfinished guest bootstrap.'
    }
} else {
    . "$PSScriptRoot\shared-io.ps1"
    $reader = Open-SharedReader 'C:\ProgramData\GunBoundAIControl\lease.json'
    try { $leaseText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($leaseText.Length -gt 4096) { throw 'Oversized maintenance lease.' }
    $lease = Convert-PlayerLease ($leaseText | ConvertFrom-Json) ([DateTime]::UtcNow)
    if ($lease.playerOnline -or $lease.expiresUtcTicks -le [DateTime]::UtcNow.Ticks) {
        throw 'Room-bot maintenance requires a current offline Player lease.'
    }
}
$running = @(Get-CimInstance Win32_Process -Filter "Name='GunBound.gme' OR Name='GunBound.exe' OR Name='bot-controller.exe' OR Name='lab-client.exe' OR Name='lab-tools.exe' OR Name='GunBoundBroker3.exe' OR Name='Gunboundserv3.exe'")
if ($running.Count) { throw 'Stop the guest clients/controllers and native core before configuring room bots.' }
$network = Get-Content -LiteralPath "$root\network.json" -Raw | ConvertFrom-Json
$instances = @(Room-Instances $marker $network)
$accounts = @(foreach ($entry in (Get-Content -LiteralPath "$root\private\bot-accounts.json" -Raw | ConvertFrom-Json)) { $entry })
if ($accounts.Count -ne 3 -or (($accounts.username | Sort-Object) -join ',') -cne 'BotOne,BotThree,BotTwo' -or
    @($accounts | Where-Object { @($_.PSObject.Properties).Count -ne 5 -or
        $_.role -cne 'bot' -or $_.password -cnotmatch '^[A-Za-z0-9]{12}$' -or
        $_.id -cne $_.username -or $_.nickname -cne $_.username }).Count) {
    throw 'The bot-only credential package must contain exactly the three approved bot identities.'
}
$user = Get-LocalUser -Name LabBot
if (Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object SID -eq $user.SID) {
    throw 'The bot user must remain non-administrator.'
}

function Directory-Access([string]$Path, [bool]$UserWrites, [switch]$InstanceRoot) {
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Instance preparation refuses redirected directories.'
        }
    } else { New-Item -ItemType Directory -Path $Path | Out-Null }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    $rights = if ($UserWrites) { 'FullControl' } else { 'ReadAndExecute' }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $user.SID,$rights,'ContainerInherit,ObjectInherit','None','Allow')))
    if ($InstanceRoot) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($user.SID,'CreateFiles','None','None','Allow')))
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-3-0')),'Modify','ObjectInherit','InheritOnly','Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$code = @('lab-client.exe','lab-tools.exe','bot-controller.exe')
foreach ($file in $code) {
    if (!(Test-Path -LiteralPath "$root\$file" -PathType Leaf)) { throw "Missing prepared client code: $file." }
}
if ((Get-FileHash -LiteralPath "$root\client-image\GunBound.gme" -Algorithm SHA256).Hash -ne
    '683CB237147C8DE28C2A5EA3343E9A6B6082EC5D1851F5D20DFBF8BA81A530A8' -or
    @(Get-ChildItem -LiteralPath "$root\client-image" -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
    throw 'The supplied client assets changed or contain redirected paths.'
}
Directory-Access "$root\instances" $false
foreach ($instance in $instances) {
    $destination = $instance.root
    $receiptPath = "$destination\private\instance.json"
    $previous = $null
    if (Test-Path -LiteralPath $destination) {
        if (!(Test-Path -LiteralPath $receiptPath)) { throw "Existing instance $($instance.name) has no ownership receipt." }
        $previous = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        if ($previous.ownerId -cne $marker.ownerId -or $previous.name -cne $instance.name -or
            $previous.root -cne $destination -or $previous.address -cne $instance.address) {
            throw 'An existing instance belongs to another configuration.'
        }
    }
    Directory-Access $destination $false -InstanceRoot
    foreach ($folder in @('private','profiles')) { Directory-Access "$destination\$folder" $false }
    foreach ($folder in @('logs','session','client-build')) { Directory-Access "$destination\$folder" $true }
    Directory-Access "$destination\client-build\startup" $true
    if (!$previous) {
        $intentHashes = [ordered]@{}
        foreach ($file in $code) { $intentHashes[$file] = (Get-FileHash -LiteralPath "$root\$file" -Algorithm SHA256).Hash }
        $previous = [pscustomobject]@{schemaVersion=1;ownerId=$marker.ownerId;name=$instance.name;root=$destination
            address=$instance.address;hashes=$intentHashes;status='preparing'}
        [IO.File]::WriteAllText($receiptPath,($previous | ConvertTo-Json -Depth 5))
    }
    if ((Test-Path -LiteralPath "$destination\client-image") -and
        @(Get-ChildItem -LiteralPath "$destination\client-image" -Recurse -Force |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        throw 'An instance asset directory contains a redirected path.'
    }
    if (!(Test-Path -LiteralPath "$destination\client-image")) {
        Copy-Item -LiteralPath "$root\client-image" -Destination "$destination\client-image" -Recurse
    } elseif ($previous.status -eq 'preparing') {
        foreach ($asset in Get-ChildItem -LiteralPath "$root\client-image" -Force) {
            Copy-Item -LiteralPath $asset.FullName -Destination "$destination\client-image" -Recurse -Force
        }
    }
    Directory-Access "$destination\client-image" $true
    if ((Get-FileHash -LiteralPath "$destination\client-image\GunBound.gme" -Algorithm SHA256).Hash -ne
        '683CB237147C8DE28C2A5EA3343E9A6B6082EC5D1851F5D20DFBF8BA81A530A8') {
        throw 'An instance contains an unsupported client image.'
    }
    $hashes = [ordered]@{}
    foreach ($file in $code) {
        $hashes[$file] = (Get-FileHash -LiteralPath "$root\$file" -Algorithm SHA256).Hash
        $target = "$destination\$file"
        if (Test-Path -LiteralPath $target) {
            $current = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if (!$previous -or $current -notin @($previous.hashes.$file,$hashes[$file])) {
                throw 'An instance executable changed outside its recorded update.'
            }
            if ($current -eq $hashes[$file]) { continue }
            $acl = Get-Acl -LiteralPath $target
            $next = $target + '.room-' + [Guid]::NewGuid().ToString('N') + '.new'
            [IO.File]::Copy("$root\$file",$next,$false)
            [IO.File]::Replace($next,$target,[NullString]::Value)
            Set-Acl -LiteralPath $target -AclObject $acl
        } else { Copy-Item -LiteralPath "$root\$file" -Destination $target }
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $hashes[$file]) { throw 'Instance code readback failed.' }
    }
    $peer = Get-Content -LiteralPath "$root\network.json" -Raw | ConvertFrom-Json
    $peer.botAddress = $instance.address
    $account = @($accounts | Where-Object username -ceq $instance.name)
    if ($account.Count -ne 1) { throw 'The instance credential is ambiguous.' }
    [IO.File]::WriteAllText("$destination\network.json",($peer | ConvertTo-Json -Depth 5))
    [IO.File]::WriteAllText("$destination\private\accounts.json",(ConvertTo-Json -InputObject $account -Depth 5))
    Copy-Item -LiteralPath "$root\profiles\difficulty.json" -Destination "$destination\profiles\difficulty.json" -Force
    $receipt = [ordered]@{schemaVersion=1;ownerId=$marker.ownerId;name=$instance.name;root=$destination
        address=$instance.address;hashes=$hashes;status='ready';updatedUtc=[DateTime]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($receiptPath,($receipt | ConvertTo-Json -Depth 5))
}

if ($marker.guestPrivateMac -cnotmatch '^080027[0-9A-F]{6}$') { throw 'The protected private NIC identity is invalid.' }
$adapter = @(Get-NetAdapter | Where-Object { $_.MacAddress.Replace('-','') -ceq $marker.guestPrivateMac })
if ($adapter.Count -ne 1) { throw 'The dedicated private guest adapter is not uniquely identified.' }
$addresses = @(Get-NetIPAddress -InterfaceIndex $adapter[0].ifIndex -AddressFamily IPv4)
$botAddresses = @($instances | ForEach-Object { $_.address })
Test-RoomAddressState $addresses $botAddresses | Out-Null
foreach ($instance in $instances | Select-Object -Skip 1) {
    if ($instance.address -notin $addresses.IPAddress) {
        New-NetIPAddress -InterfaceIndex $adapter[0].ifIndex -IPAddress $instance.address -PrefixLength 24 -SkipAsSource $true | Out-Null
    }
}
$watch = [Diagnostics.Stopwatch]::StartNew()
do {
    $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter[0].ifIndex -AddressFamily IPv4)
    $ready = Test-RoomAddressState $addresses $botAddresses
    if ($ready) { break }
    if ($watch.Elapsed.TotalSeconds -ge 15) { throw 'The configured guest aliases did not become usable.' }
    Start-Sleep -Milliseconds 250
} while ($true)
$persistent = @(Get-NetIPAddress -InterfaceIndex $adapter[0].ifIndex -AddressFamily IPv4 -PolicyStore PersistentStore)
foreach ($address in $botAddresses) {
    if ($address -notin $persistent.IPAddress) { throw 'A room-bot address was not persisted for the next guest boot.' }
}

$peers = @($network.humanAddress) + $botAddresses
$rules = @(foreach ($instance in $instances) {
    @{name=('GunBoundAI-Peer-' + $instance.name);program=($instance.root + '\client-image\GunBound.gme')
        protocol='UDP';port=8363;local=$instance.address}
})
if ($marker.PSObject.Properties.Name -contains 'serverRoot') {
    if ($marker.serverRoot -cne 'C:\GunBoundServer') { throw 'Unexpected protected server root.' }
    $rules += @(
        @{name='GunBoundAI-GuestBroker';program='C:\GunBoundServer\backend\native\Central\GunBoundBroker3.exe';protocol='TCP';port=8372;local='192.168.56.10'}
        @{name='GunBoundAI-GuestWorldTcp';program='C:\GunBoundServer\backend\native\Server8360\Gunboundserv3.exe';protocol='TCP';port=8360;local='192.168.56.10'}
        @{name='GunBoundAI-GuestWorldUdp';program='C:\GunBoundServer\backend\native\Server8360\Gunboundserv3.exe';protocol='UDP';port=8360;local='192.168.56.10'}
    )
}
foreach ($spec in $rules) {
    $rule = Get-NetFirewallRule -Name $spec.name -ErrorAction SilentlyContinue
    if ($rule) {
        $app = $rule | Get-NetFirewallApplicationFilter
        $address = $rule | Get-NetFirewallAddressFilter
        $port = $rule | Get-NetFirewallPortFilter
        if ($rule.Action -ne 'Allow' -or $rule.Direction -ne 'Inbound' -or $app.Program -cne $spec.program -or
            $address.LocalAddress -ne $spec.local -or $port.Protocol -ne $spec.protocol -or $port.LocalPort -ne [string]$spec.port -or
            @($address.RemoteAddress | Where-Object { $_ -notin $peers }).Count) {
            throw 'A preexisting guest game rule has unexpected ownership or scope.'
        }
        Set-NetFirewallRule -Name $spec.name -RemoteAddress $peers | Out-Null
    } else {
        New-NetFirewallRule -Name $spec.name -DisplayName $spec.name -Direction Inbound -Action Allow `
            -Program $spec.program -Protocol $spec.protocol -LocalPort $spec.port `
            -LocalAddress $spec.local -RemoteAddress $peers -Profile Any | Out-Null
    }
}
$firewall = New-Object -ComObject HNetCfg.FwPolicy2
foreach ($profile in @(1,2,4)) {
    if (!$firewall.FirewallEnabled($profile) -or $firewall.DefaultInboundAction($profile) -ne 0) {
        throw 'The guest firewall must stay enabled and default-inbound-block.'
    }
}
Write-Output 'Three isolated bot roots and persistent guest-only peer addresses are configured. Player/database credentials, host firewall, SQL binding and VM power policy were not changed.'
