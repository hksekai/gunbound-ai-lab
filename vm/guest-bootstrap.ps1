#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\shared-io.ps1"
$root = Split-Path $PSScriptRoot
$marker = Get-Content -LiteralPath "$PSScriptRoot\guest.json" -Raw | ConvertFrom-Json
if ($root -ne 'C:\GunBoundAI' -or $marker.schemaVersion -ne 1 -or $marker.root -ne $root -or
    $marker.computerName -ne $env:COMPUTERNAME -or $marker.provider -ne 'virtualbox') {
    throw 'This setup may run only inside the identified local lab guest.'
}
Assert-GuestIdentity -OwnerId $marker.ownerId
$network = Get-Content -LiteralPath "$root\network.json" -Raw | ConvertFrom-Json
if ($network.mode -ne 'private' -or $network.serverAddress -notin @('192.168.56.1','192.168.56.10') -or
    $network.humanAddress -ne '192.168.56.1' -or $network.botAddress -ne '192.168.56.10') {
    throw 'The approved local guest network profile changed.'
}
$control = 'C:\ProgramData\GunBoundAIControl'
$userFile = Join-Path $control 'bot-user.json'
$userDescription = 'GBVM ' + $marker.ownerId
$user = Get-LocalUser -Name LabBot -ErrorAction SilentlyContinue
if ($user) {
    if (!(Test-Path -LiteralPath $userFile)) {
        if ($user.Description -cne $userDescription -or (Test-Path -LiteralPath "$PSScriptRoot\bootstrap-receipt.json")) {
            throw 'A preexisting LabBot account has no first-bootstrap ownership receipt; it was not changed.'
        }
        @{schemaVersion=1;ownerId=$marker.ownerId;sid=$user.SID.Value} |
            ConvertTo-Json | Set-Content -LiteralPath $userFile -Encoding utf8
    }
    $userOwner = Get-Content -LiteralPath $userFile -Raw | ConvertFrom-Json
    if ($userOwner.ownerId -ine $marker.ownerId -or $userOwner.sid -cne $user.SID.Value) { throw 'The guest bot account belongs to another bootstrap.' }
} else {
    if (Test-Path -LiteralPath $userFile) { throw 'The recorded bot account is missing; it will not be recreated/reset.' }
    $secret = ConvertTo-SecureString ([IO.File]::ReadAllText((Join-Path $control 'setup-user-password.txt'))) -AsPlainText -Force
    try { $user = New-LocalUser -Name LabBot -Description $userDescription -Password $secret -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword }
    finally { $secret.Dispose() }
    @{schemaVersion=1;ownerId=$marker.ownerId;sid=$user.SID.Value} |
        ConvertTo-Json | Set-Content -LiteralPath $userFile -Encoding utf8
}
if (!(Get-LocalGroupMember -SID 'S-1-5-32-545' | Where-Object SID -eq $user.SID)) {
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user
}
if (Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object SID -eq $user.SID) {
    throw 'LabBot must never be an administrator. Its unexpected privileges were not silently adopted.'
}
$admin = Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' }
if (!$admin -or $admin.Name -ne 'Administrator') { throw 'The prepared guest administrator identity changed.' }
Enable-LocalUser -InputObject $admin

if ($marker.guestPrivateMac -cnotmatch '^080027[0-9A-F]{6}$') { throw 'The protected private NIC identity is invalid.' }
$adapter = @(Get-NetAdapter | Where-Object { $_.MacAddress.Replace('-','') -ceq $marker.guestPrivateMac })
if ($adapter.Count -ne 1) { throw 'The dedicated private guest adapter was not identified.' }
$addresses = @(Get-NetIPAddress -InterfaceIndex $adapter[0].ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object IPAddress -notlike '169.254.*')
$allowedAddresses = if ($marker.PSObject.Properties.Name -contains 'roomFill' -and $marker.roomFill -eq $true) {
    @('192.168.56.10','192.168.56.11','192.168.56.12')
} else { @($network.botAddress) }
$freshDhcp = $addresses.Count -eq 1 -and [uint32]$addresses[0].PrefixOrigin -eq 3 -and
    $addresses[0].IPAddress.StartsWith('192.168.56.') -and $addresses[0].PrefixLength -eq 24
if ($addresses.Count -eq 0 -or $freshDhcp) {
    & "$env:SystemRoot\System32\netsh.exe" interface ipv4 set address ("name="+$adapter[0].Name) `
        source=static ("address="+$network.botAddress) mask=255.255.255.0 gateway=none
    if ($LASTEXITCODE -ne 0) { throw 'The guest private address could not be configured.' }
} elseif ($network.botAddress -notin $addresses.IPAddress -or
    @($addresses | Where-Object { $_.IPAddress -notin $allowedAddresses -or $_.PrefixLength -ne 24 }).Count) {
    throw 'An unexpected address already exists on the private guest adapter.'
}

foreach ($name in @('AudioEndpointBuilder','Audiosrv')) {
    Set-Service -Name $name -StartupType Automatic
    Start-Service -Name $name
}
if (!(Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ServerManager')) {
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -PropertyType DWord -Force | Out-Null
& "$root\lab-client.exe" setup-machine 0
if ($LASTEXITCODE -ne 0) { throw 'The guest client registry configuration failed.' }

$ruleName = 'GunBoundAI-PrivatePeer'
$rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if ($rule) {
    $application = $rule | Get-NetFirewallApplicationFilter
    $address = $rule | Get-NetFirewallAddressFilter
    $port = $rule | Get-NetFirewallPortFilter
    if ($application.Program -ne "$root\client-image\GunBound.gme" -or $rule.Action -ne 'Allow' -or
        $rule.Direction -ne 'Inbound' -or $address.LocalAddress -ne $network.botAddress -or
        $address.RemoteAddress -ne $network.humanAddress -or $port.LocalPort -ne '8363' -or $port.Protocol -ne 'UDP') {
        throw 'An existing firewall rule with this lab name has different ownership or scope.'
    }
} else {
    New-NetFirewallRule -Name $ruleName -DisplayName 'GunBound AI private peer only' -Direction Inbound `
        -Action Allow -Protocol UDP -LocalPort 8363 -LocalAddress $network.botAddress `
        -RemoteAddress $network.humanAddress -Program "$root\client-image\GunBound.gme" -Profile Any | Out-Null
}
$fw = New-Object -ComObject HNetCfg.FwPolicy2
foreach ($profile in @(1,2,4)) {
    if (!$fw.FirewallEnabled($profile) -or $fw.DefaultInboundAction($profile) -ne 0) {
        throw 'The guest firewall is not enabled/default-inbound-block. No security profile was disabled.'
    }
}

function Directory-Access([string]$Path, [bool]$UserWrites) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    $access = if ($UserWrites) { 'FullControl' } else { 'ReadAndExecute' }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $user.SID,$access,'ContainerInherit,ObjectInherit','None','Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
Directory-Access $root $false
$rootAcl = Get-Acl -LiteralPath $root
$rootAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
    $user.SID,'CreateFiles','None','None','Allow')))
$rootAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
    (New-Object Security.Principal.SecurityIdentifier('S-1-3-0')),'Modify','ObjectInherit','InheritOnly','Allow')))
Set-Acl -LiteralPath $root -AclObject $rootAcl
foreach ($name in @('logs','session','client-image','client-build\startup')) { Directory-Access (Join-Path $root $name) $true }
foreach ($name in @('vm','private','profiles')) { Directory-Access (Join-Path $root $name) $false }
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -File) {
    $acl = Get-Acl -LiteralPath $file.FullName
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $file.FullName -AclObject $acl
}
foreach ($name in @('bot.stop','bot-process.json')) {
    $file = Join-Path $root $name
    if (!(Test-Path -LiteralPath $file)) { continue }
    $acl = Get-Acl -LiteralPath $file
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($user.SID,'Modify','Allow')))
    Set-Acl -LiteralPath $file -AclObject $acl
}
Directory-Access $control $false

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class GunBoundGuestLogon {
    [StructLayout(LayoutKind.Sequential)]
    struct Attributes {
        public uint Length; public IntPtr Root, Name; public uint Flags;
        public IntPtr Descriptor, Quality;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Text { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr name, ref Attributes attributes, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr policy, ref Text key, ref Text value);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
    static Text Make(string value) {
        return new Text { Length=checked((ushort)(value.Length*2)), MaximumLength=checked((ushort)(value.Length*2+2)),
            Buffer=Marshal.StringToHGlobalUni(value) };
    }
    public static void Store(string password) {
        if (String.IsNullOrEmpty(password)) throw new ArgumentException("Missing guest logon password.");
        var attributes = new Attributes { Length=(uint)Marshal.SizeOf(typeof(Attributes)) };
        IntPtr policy=IntPtr.Zero;
        Text key=Make("DefaultPassword"), value=Make(password);
        try {
            uint status=LsaOpenPolicy(IntPtr.Zero,ref attributes,0x20,out policy);
            if (status!=0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
            status=LsaStorePrivateData(policy,ref key,ref value);
            if (status!=0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
        } finally {
            if (policy!=IntPtr.Zero) LsaClose(policy);
            Marshal.ZeroFreeGlobalAllocUnicode(key.Buffer);
            Marshal.ZeroFreeGlobalAllocUnicode(value.Buffer);
        }
    }
}
'@
$passwordFile = Join-Path $control 'setup-user-password.txt'
[GunBoundGuestLogon]::Store([IO.File]::ReadAllText($passwordFile))
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
foreach ($entry in @{AutoAdminLogon='1';DefaultUserName='LabBot';DefaultDomainName=$env:COMPUTERNAME}.GetEnumerator()) {
    New-ItemProperty -Path $winlogon -Name $entry.Key -Value $entry.Value -PropertyType String -Force | Out-Null
}
if ((Get-ItemProperty -LiteralPath $winlogon).PSObject.Properties.Name -contains 'DefaultPassword') {
    Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword
}

$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
foreach ($taskName in @('GunBoundAI-BotSession','GunBoundAI-IdleShutdown')) {
    $old = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($old -and $old.Description -ne ('GunBound AI Lab guest ' + $marker.ownerId)) {
        throw "An unowned scheduled task already uses $taskName."
    }
}
$action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File `"$PSScriptRoot\guest-session.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\LabBot" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'GunBoundAI-BotSession' -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn -User 'LabBot') `
    -Principal $principal -Settings $settings -Description ('GunBound AI Lab guest ' + $marker.ownerId) -Force | Out-Null
$action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File `"$PSScriptRoot\guest-idle.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes(1))
Register-ScheduledTask -TaskName 'GunBoundAI-IdleShutdown' -Action $action -Trigger $trigger `
    -User SYSTEM -RunLevel Highest -Settings $settings -Description ('GunBound AI Lab guest ' + $marker.ownerId) -Force | Out-Null
Disable-ScheduledTask -TaskName 'GunBoundAI-BotSession' | Out-Null
if ($marker.PSObject.Properties.Name -contains 'roomFill' -and $marker.roomFill -eq $true) {
    & "$PSScriptRoot\configure-room-bots.ps1" -FirstDeployment
}
Remove-Item -LiteralPath $passwordFile
[ordered]@{timeUtc=[DateTime]::UtcNow.ToString('o');ownerId=$marker.ownerId;status='provisioned-needs-relogon'
    clientAddress=$network.botAddress;serverAddress=$network.serverAddress;leaseSeconds=120
    autoLogon='LSA private secret';gameUser='LabBot (non-administrator)'
    azureResourcesCreated=$false} | ConvertTo-Json | Set-Content -LiteralPath "$PSScriptRoot\bootstrap-receipt.json" -Encoding utf8
Write-Output 'Guest prerequisites and Player-lease shutdown are configured. Relogon and actual game behavior still require verification.'
