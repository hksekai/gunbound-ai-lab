#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\host-io.ps1"
function Assert([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Reject([scriptblock]$Check, [string]$Message) {
    $rejected = $false
    try { & $Check | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
function Clone($Value) { ConvertTo-Json -InputObject $Value -Depth 12 | ConvertFrom-Json }
$root = Split-Path $PSScriptRoot
$id = '11111111-2222-3333-4444-555555555555'
$adapterId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$config = [pscustomobject]@{
    schemaVersion=1;provider='virtualbox';machineName='GunBound-BotOne';machineId=$id
    machineFile="$root\runtime\vm\GunBound-BotOne\GunBound-BotOne.vbox";virtualBox='C:\Tools\VirtualBox\VBoxManage.exe'
    guestRoot='C:\GunBoundAI';guestUser='LabBot';leaseSeconds=120;phase='installing';enabled=$false
    hostAddress='192.168.56.1';botAddress='192.168.56.10';guestPrivateMac='080027123456'
    hostAdapter='VirtualBox Host-Only Ethernet Adapter #7';hostAdapterId=$adapterId;roomFill=$true
    botInstances=@(
        [pscustomobject]@{name='BotOne';address='192.168.56.10'}
        [pscustomobject]@{name='BotTwo';address='192.168.56.11'}
        [pscustomobject]@{name='BotThree';address='192.168.56.12'}
    )
}
$owner = [pscustomobject]@{schemaVersion=1;root=$root;machineId=$id;machineFile=$config.machineFile
    virtualBox=$config.virtualBox;guestPrivateMac=$config.guestPrivateMac;hostAdapter=$config.hostAdapter;hostAdapterId=$adapterId}
$info = Convert-VBoxInfo @(
    'UUID="' + $id + '"'
    'CfgFile=' + ($config.machineFile | ConvertTo-Json -Compress)
    'VMState="poweroff"'
    'nic1="nat"'
    'nic2="hostonly"'
    'hostonlyadapter2="' + $config.hostAdapter + '"'
    'macaddress2="' + $config.guestPrivateMac + '"'
    '"SATA-0-0"="C:\\Portable Lab\\system.vdi"'
    'GuestProperty="metadata" @123'
    'GuestProperty="different metadata" @124'
)
Assert ($info['SATA-0-0'] -ceq 'C:\Portable Lab\system.vdi') 'Quoted VBox disk/path decoding changed.'
Assert-VmIdentity $config $owner $root $info
foreach ($field in @('machineId','machineFile','virtualBox','hostAdapterId')) {
    $bad = Clone $config
    $bad.$field = if ($field -eq 'machineId' -or $field -eq 'hostAdapterId') { [Guid]::NewGuid().ToString('D') } else { 'C:\Other\VBoxManage.exe' }
    Reject { Assert-VmIdentity $bad $owner $root $info } "A changed $field was accepted."
}
$badInfo = $info.Clone(); $badInfo.UUID = [Guid]::NewGuid().ToString('D')
Reject { Assert-VmIdentity $config $owner $root $badInfo } 'Name-only registration was accepted.'
$badInfo = $info.Clone(); $badInfo.CfgFile = "$root-other\vm.vbox"
Reject { Assert-VmIdentity $config $owner $root $badInfo } 'A relocated/unowned CfgFile was accepted.'
Reject { Convert-VBoxInfo @('UUID="one"','UUID="two"') } 'Duplicate VM identity keys were accepted.'
Reject { Assert-VmPath "$root\..\other\machine.vbox" $root } 'A lexical-root/path traversal was accepted.'
$registrations = @(Convert-VBoxRegistrations @('"Synthetic unrelated VM" {aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}'))
Assert ($registrations.Count -eq 1 -and $registrations[0].id -ceq $adapterId) 'Registration UUID parsing changed.'
Reject { Convert-VBoxRegistrations @('"Name alone"') } 'A registration without a UUID was accepted.'
Assert ((Get-VmCreatedDiskId "Medium created. UUID: $id`n") -ceq $id) 'The protected created-disk receipt was not decoded.'
Reject { Get-VmCreatedDiskId "Existing arbitrary disk: $id" } 'An arbitrary existing disk was adopted without a creation receipt.'
Reject { Get-VmCreatedDiskId "Medium created. UUID: $id`nMedium created. UUID: $adapterId" } 'An ambiguous created-medium receipt was accepted.'

$adapters = @(Convert-VBoxBlocks @(
    "Name: $($config.hostAdapter)", "GUID: $adapterId", 'DHCP: Disabled',
    'IPAddress: 192.168.56.1', 'NetworkMask: 255.255.255.0', ''
))
$addresses = @([pscustomobject]@{IPAddress='192.168.56.1';PrefixLength=24;InterfaceGuid=$adapterId})
$routes = @(
    [pscustomobject]@{DestinationPrefix='192.168.56.0/24';NextHop='0.0.0.0';InterfaceGuid=$adapterId}
    [pscustomobject]@{DestinationPrefix='0.0.0.0/0';NextHop='192.168.1.1';InterfaceGuid='unrelated'}
)
$dhcp = @(Convert-VBoxBlocks @(
    "NetworkName: HostInterfaceNetworking-$($config.hostAdapter)", 'Dhcpd IP: 192.168.56.100',
    'LowerIPAddress: 192.168.56.101', 'UpperIPAddress: 192.168.56.254', 'NetworkMask: 255.255.255.0', 'Enabled: Yes'
))
$plan = Select-VmHostAdapter $adapters $addresses $routes $dhcp @() $id
Assert ($plan.action -ceq 'reuse' -and $plan.id -ceq $adapterId -and $plan.name -ceq $config.hostAdapter) 'A compatible existing adapter was not reused read-only.'
$plan = Select-VmHostAdapter @() @() @() @() @() $id
Assert ($plan.action -ceq 'create' -and !$plan.id -and !$plan.name) 'A fresh network plan invented an adapter identity.'
$conflict = [pscustomobject]@{IPAddress='192.168.56.10';PrefixLength=24;InterfaceGuid='unrelated'}
Reject { Select-VmHostAdapter $adapters ($addresses + $conflict) $routes @() @() $id } 'A conflicting host/private address was accepted.'
$conflict = [pscustomobject]@{DestinationPrefix='192.168.0.0/16';NextHop='10.0.0.1';InterfaceGuid='vpn'}
Reject { Select-VmHostAdapter $adapters $addresses ($routes + $conflict) @() @() $id } 'An overlapping VPN route was accepted.'
$badDhcp = Clone $dhcp[0]; $badDhcp.LowerIPAddress = '192.168.56.2'
Reject { Select-VmHostAdapter $adapters $addresses $routes @($badDhcp) @() $id } 'A DHCP pool that leases bot addresses was accepted.'
$otherVm = $info.Clone(); $otherVm.UUID = $adapterId
Reject { Select-VmHostAdapter $adapters $addresses $routes @() @($otherVm) $id } 'An adapter attached to another registered VM was adopted.'
Assert-VmRuntimeInfo $config $info $adapters[0]
$badAdapter = Clone $adapters[0]; $badAdapter.GUID = $id
Reject { Assert-VmRuntimeInfo $config $info $badAdapter } 'An adapter replacement with the same name was accepted.'
$badInfo = $info.Clone(); $badInfo.nic2 = 'bridged'
Reject { Assert-VmRuntimeInfo $config $badInfo $adapters[0] } 'A public/bridged guest NIC was accepted.'
$badInfo = $info.Clone(); $badInfo['Forwarding(0)'] = 'public'
Reject { Assert-VmRuntimeInfo $config $badInfo $adapters[0] } 'NAT public forwarding was accepted.'
Assert (Test-VmSubnetOverlap '192.168.56.10' 32) 'A conflicting host route was missed.'
Assert (!(Test-VmSubnetOverlap '192.168.57.10' 24)) 'An unrelated subnet was treated as overlapping.'

$commands = @('CPU','RAM','SecureBoot','Storage','TPM') | ForEach-Object {
    "<RunAsynchronousCommand><Path>reg.exe ADD HKLM\SYSTEM\Setup\LabConfig /v Bypass$($_)Check /t REG_DWORD /d 1 /f</Path></RunAsynchronousCommand>"
}
$template = @'
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <ProtectYourPC>3</ProtectYourPC><NetworkLocation>Home</NetworkLocation>
  <LocalAccounts><LocalAccount><Group>administrators;users</Group></LocalAccount></LocalAccounts>
  <ImageIndex>@@VBOX_INSERT_IMAGE_INDEX_ELEMENT@@</ImageIndex><Password>@@VBOX_INSERT_USER_PASSWORD_ELEMENT@@</Password>
  <UserData><ProductKey><Key>vendor-placeholder</Key></ProductKey></UserData>
  <RunAsynchronous>__COMMANDS__</RunAsynchronous>
</unattend>
'@
$template = $template.Replace('__COMMANDS__', ($commands -join ''))
$safe = Convert-VmUnattendedTemplate $template
Assert ($safe.OuterXml -notmatch 'Bypass.+Check|ProductKey|administrators' -and
    $safe.OuterXml.Contains('<ProtectYourPC>1</ProtectYourPC>') -and $safe.OuterXml.Contains('<NetworkLocation>Other</NetworkLocation>')) 'Vendor safety transformation changed.'
Reject { Convert-VmUnattendedTemplate ($template.Replace('/v BypassCPUCheck', '/v UnreviewedCommand')) } 'An unfamiliar vendor command was removed without review.'
Reject { Convert-VmUnattendedTemplate ('<!DOCTYPE x SYSTEM "file:///not-read">' + $template) } 'An external XML declaration was accepted.'
$images = @(
    [pscustomobject]@{ImageIndex=1;ImageName='Windows Server 2022 Standard';Version='10.0.20348.1';Architecture=9;Languages=@('en-US (Default)')}
    [pscustomobject]@{ImageIndex=2;ImageName='Windows Server 2022 Standard (Desktop Experience)';Version='10.0.20348.1';Architecture=9;Languages=@('en-US (Default)')}
    [pscustomobject]@{ImageIndex=4;ImageName='Windows Server 2022 Datacenter Evaluation (Desktop Experience)';Version='10.0.20348.1';Architecture=9;Languages=@('en-US (Default)')}
)
Assert ((Select-VmWindowsImage $images).ImageIndex -eq 2) 'Desktop image selection still blindly assumes index 4.'
Reject { Select-VmWindowsImage @($images[0]) } 'Server Core was accepted.'
foreach ($change in @('version','architecture','language')) {
    $image = Clone $images[1]
    switch ($change) { version { $image.Version = '10.0.17763.1' }; architecture { $image.Architecture = 0 }; language { $image.Languages = @('de-DE') } }
    Reject { Select-VmWindowsImage @($image) } "An unsupported media $change was accepted."
}
Reject { Resolve-VmPrerequisites (Join-Path $root 'not-supplied.iso') 'C:\NotInstalled\VBoxManage.exe' } 'Missing Microsoft media was accepted.'
& {
    function Test-Path { param($LiteralPath, $PathType) $LiteralPath -ceq 'C:\Synthetic\windows.iso' }
    function Assert-VmPath { param($Path, $Below) $Path }
    Reject { Resolve-VmPrerequisites 'C:\Synthetic\windows.iso' 'C:\Synthetic\missing\VBoxManage.exe' } 'Missing VirtualBox was accepted.'
}
Reject { Assert-VmSourceInputs $root (Join-Path $root 'not-supplied-server-bundle') } 'Missing source/provisioned backend was accepted.'

$accounts = @(foreach ($name in @('Player','BotOne','BotTwo','BotThree')) {
    [pscustomobject]@{role=$(if ($name -eq 'Player') {'human'} else {'bot'});username=$name;id=$name;nickname=$name;password='CheckOnly123'}
})
Assert-VmAccounts $accounts 'Server'
Assert-VmAccounts @($accounts[1..3]) 'Bots'
Assert-VmAccounts @($accounts[0..1]) 'Client'
Reject { Assert-VmAccounts @($accounts[0..1]) 'Server' } 'Two client accounts were mistaken for the canonical four-account server seed.'
Reject { Assert-VmAccounts @($accounts[0..2]) 'Bots' } 'Player credentials were accepted in the bot package.'
$badAccounts = @(Clone $accounts); $badAccounts[2].username = 'BotOne'
Reject { Assert-VmAccounts $badAccounts 'Server' } 'Duplicate canonical identities were accepted.'
$package = [pscustomobject]@{ownerId=$id;packageId='0123456789abcdef0123456789abcdef';sha256=('A' * 64)}
foreach ($kind in @('app','server')) {
    $script = Get-VmGuestPackageScript $kind $package $true
    $tokens = $null; $issues = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$issues)
    Assert (!$issues.Count -and $script -notmatch '__OWNER__|__PACKAGE__|__HASH__|__KIND__|__RESUME__') 'Generated guest package code is invalid/unexpanded.'
    Assert ($script.Contains("Move-Item -LiteralPath `$stage -Destination `$destination") -and
        $script.Contains('it will not be overwritten')) 'First-install staging/non-overwrite protection changed.'
}
Assert-VmResume $null $false @('installing')
Assert-VmResume $config $true @('installing')
Reject { Assert-VmResume $null $true @('installing') } 'Resume adopted missing ownership metadata.'
Reject { Assert-VmResume $config $false @('installing') } 'An existing VM was accepted without explicit interrupted-phase recovery.'
$ready = Clone $config; $ready.phase = 'ready'; $ready.enabled = $true
Reject { Assert-VmResume $ready $true @('installing','provisioned') } 'Resume became a ready-VM overwrite switch.'
$now = [DateTime]::UtcNow
$lease = @{schemaVersion=2;sessionId=$id;issuedUtc=$now.ToString('o');expiresUtc=$now.AddSeconds(120).ToString('o')
    playerOnline=$false;roomReady=$false;roomId=$null;roomCapacity=0}
Convert-PlayerLease $lease $now | Out-Null
$lease.expiresUtc = $now.AddSeconds(121).ToString('o')
Reject { Convert-PlayerLease $lease $now } 'An overlong offline maintenance lease was accepted.'
Assert ((Get-VmUtcTicks $now.ToString('o')) -eq (Get-VmUtcTicks ((@{utc=$now.ToString('o')} | ConvertTo-Json | ConvertFrom-Json).utc))) 'PowerShell JSON timestamp decoding changed watchdog time bounds.'
$watch = [pscustomobject]@{schemaVersion=1;sessionId=$id;status='active';startedUtc=$now.ToString('o');deadlineUtc=$now.AddHours(2).ToString('o')}
Assert ((Get-VmWatchAction $watch $id $now $true $false) -ceq 'renew') 'A live bounded owner lost offline maintenance.'
Assert ((Get-VmWatchAction $watch $id $now $false $false) -ceq 'stop') 'A crashed installer left an orphan renewal authority.'
Assert ((Get-VmWatchAction $watch $id $now.AddHours(2) $true $false) -ceq 'stop') 'The installation deadline was not enforced.'
Assert ((Get-VmWatchAction $watch $id $now.AddHours(2) $false $true) -ceq 'yield') 'Maintenance fought a new Player owner.'
Assert ((Get-VmWatchAction $watch $adapterId $now $false $false) -ceq 'retire') 'A superseded watchdog retained power authority.'
$watch.deadlineUtc = $now.AddSeconds(7201).ToString('o')
Reject { Get-VmWatchAction $watch $id $now $true $false } 'An unbounded maintenance intent was accepted.'
& {
    $computer = $env:COMPUTERNAME
    $hardwareId = $id
    $attribute = [IO.FileAttributes]::Normal
    $marker = [pscustomobject]@{schemaVersion=1;provider='virtualbox';root='C:\GunBoundAI';computerName='GUNBOUND-BOT'
        ownerId=$id;leaseSeconds=120;serverRoot='C:\GunBoundServer'}
    $serverMarker = [pscustomobject]@{ownerId=$id;root='C:\GunBoundServer';originalHostDataPreserved=$true}
    $access = [Security.AccessControl.DirectorySecurity]::new()
    $access.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $access.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),'FullControl','Allow'))
    function Get-CimInstance { param($ClassName, $OperationTimeoutSec) [pscustomobject]@{UUID=$hardwareId} }
    function Get-Item { param($LiteralPath, [switch]$Force) [pscustomobject]@{Attributes=$attribute} }
    function Get-Acl { param($LiteralPath) $access }
    function Get-Content {
        param($LiteralPath, [switch]$Raw)
        if ($LiteralPath.EndsWith('\guest.json')) { $marker | ConvertTo-Json }
        elseif ($LiteralPath.EndsWith('\server-owner.json')) { $serverMarker | ConvertTo-Json }
        else { @{schemaVersion=1;ownerId=$id} | ConvertTo-Json }
    }
    try {
        $env:COMPUTERNAME = 'GUNBOUND-BOT'
        Assert-GuestIdentity -OwnerId $id -Server
        $marker.PSObject.Properties.Remove('serverRoot')
        Reject { Assert-GuestIdentity -OwnerId $id -Server } 'An unlinked server could start through the normal lifecycle guard.'
        Assert-GuestIdentity -OwnerId $id -Server -AllowUnlinkedServer
        $hardwareId = $adapterId
        Reject { Assert-GuestIdentity -OwnerId $id -HardwareOnly } 'Guest name alone replaced actual SMBIOS UUID verification.'
        $hardwareId = $id; $marker.ownerId = $adapterId
        Reject { Assert-GuestIdentity -OwnerId $id } 'A guest/package owner mismatch was accepted.'
        $marker.ownerId = $id; $attribute = [IO.FileAttributes]::ReparsePoint
        Reject { Assert-GuestIdentity -OwnerId $id } 'A redirected protected marker was accepted.'
        $attribute = [IO.FileAttributes]::Normal
        $access.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Write','Allow'))
        Reject { Assert-GuestIdentity -OwnerId $id } 'An unprivileged-writable guest/package ACL was accepted.'
    } finally { $env:COMPUTERNAME = $computer }
}

$paths = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') + @(Get-Item -LiteralPath "$root\setup\prepare-vm.ps1")
foreach ($path in $paths) {
    $tokens = $null; $issues = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$tokens, [ref]$issues)
    Assert (!$issues.Count) "Invalid VM PowerShell syntax: $($path.Name)."
    if ($path.Name -in @('host-io.ps1','shared-io.ps1')) {
        $top = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
        $all = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true))
        Assert ($top.Count -eq $all.Count) "A VM helper was accidentally nested inside another function in $($path.Name)."
        foreach ($function in $top) {
            Assert ([bool](Get-Command -Name $function.Name -CommandType Function -ErrorAction SilentlyContinue)) "VM helper not exported: $($function.Name)."
        }
    }
    foreach ($literal in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.StringConstantType -eq 'SingleQuotedHereString' }, $true)) {
        $innerTokens = $null; $innerIssues = $null
        if ($literal.Value -notmatch '\A\s*(\$|if |Assert-GuestIdentity|& |\.\s)') { continue }
        $null = [Management.Automation.Language.Parser]::ParseInput($literal.Value, [ref]$innerTokens, [ref]$innerIssues)
        Assert (!$innerIssues.Count) "Invalid embedded guest script in $($path.Name)."
    }
}
& "$PSScriptRoot\configure-room-bots.ps1" -Check
& "$PSScriptRoot\guest-idle.ps1" -Check
Write-Output 'PASS: synthetic UUID/CfgFile/protected ownership, real adapter GUID and conflict plans, inspected Desktop image selection, vendor template safety, account/package separation, missing prerequisites, non-overwrite resume guards, bounded leases, and embedded script syntax. No host/VM state changed.'
