#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$WindowsIso, [string]$VirtualBoxPath,
    [ValidateRange(4096,65536)][int]$MemoryMiB = 6144,
    [ValidateRange(2,32)][int]$Cpus = 4,
    [switch]$Check, [switch]$Resume
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\host-io.ps1"
$root = Split-Path $PSScriptRoot
if ($Check) {
    & "$PSScriptRoot\check-provision.ps1"
    if ($WindowsIso -or $VirtualBoxPath) { & "$PSScriptRoot\install-platform.ps1" -WindowsIso $WindowsIso -VirtualBoxPath $VirtualBoxPath -Check }
    return
}
$private = Join-Path $root 'private\vm'
$configPath = Join-Path $PSScriptRoot 'config.json'
$ownerPath = Join-Path $private 'owner.json'
$config = if (Test-Path -LiteralPath $configPath) { Read-VmConfig $root } else { $null }
Assert-VmResume $config ([bool]$Resume) @('preparing','installing','deploying','app-provisioned','migrating','provisioned')
if (Test-VmPlayerOwner $root) { throw 'A Player session owns this workspace. Provisioning did not take over its VM or lease.' }
if (!$config -and (Test-Path -LiteralPath $ownerPath)) {
    throw 'An incomplete protected VM ownership record exists without config.json. It was not replaced or adopted.'
}
$platform = & "$PSScriptRoot\install-platform.ps1" -WindowsIso $WindowsIso -VirtualBoxPath $VirtualBoxPath
$computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15
$processors = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 15)
if (![Environment]::Is64BitOperatingSystem -or $computer.TotalPhysicalMemory -lt ($MemoryMiB + 2048) * 1MB -or
    ($processors | Measure-Object NumberOfLogicalProcessors -Sum).Sum -lt $Cpus) {
    throw "Use an x64 Windows host with at least $($MemoryMiB + 2048) MiB RAM and $Cpus logical processors; no VM resources were changed."
}
if (!$computer.HypervisorPresent -and !@($processors | Where-Object VirtualizationFirmwareEnabled).Count) {
    throw 'Hardware virtualization is unavailable. Enable VT-x/AMD-V in firmware or use a supported VirtualBox host; do not disable Windows security features.'
}
if (!$config -and (Get-PSDrive -Name $root.Substring(0,1)).Free -lt 80GB) {
    throw 'Keep at least 80 GiB free on the workspace drive for the owned 64-GiB dynamic VM disk, protected snapshots and packages.'
}
if ($config) {
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    if ($config.virtualBox -ine $platform.virtualBox -or $config.windowsIso -ine $platform.windowsIso -or
        $config.windowsSha256 -cne $platform.windowsSha256 -or $config.windowsImageIndex -ne $platform.imageIndex -or
        $config.memoryMiB -ne $MemoryMiB -or $config.cpus -ne $Cpus) {
        throw 'Resume requires the same VM, inspected Windows media, memory and CPU request. It cannot reconfigure an existing installation.'
    }
    if ($config.phase -ne 'preparing') { Get-OwnedVmInfo $root $config | Out-Null; $config; return }
} else {
    $machineFile = Join-Path $root 'runtime\vm\GunBound-BotOne\GunBound-BotOne.vbox'
    if (Test-Path -LiteralPath (Split-Path $machineFile)) { throw 'An existing VM directory has no protected ownership record; no file was replaced.' }
    foreach ($name in @('guest-user.txt','guest-admin.txt','provision-session.json','disk-create.log')) {
        if (Test-Path -LiteralPath (Join-Path $private $name)) { throw 'Unowned VM credentials/artifacts exist; setup will not overwrite them.' }
    }
    foreach ($name in @('package.json','server-package.json','server-snapshot.json')) {
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name)) { throw 'A VM package/snapshot exists without its protected VM owner; no new VM was created.' }
    }
    $registered = @(Convert-VBoxRegistrations @(Invoke-VBox $platform.virtualBox @('list','vms')))
    if (@($registered | Where-Object name -ceq 'GunBound-BotOne').Count) { throw 'An unowned registered VM already uses GunBound-BotOne; it was not changed.' }
    $id = [Guid]::NewGuid().ToString('D')
    $mac = '080027' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(3))
    $config = [pscustomobject][ordered]@{
        schemaVersion=1; enabled=$false; provider='virtualbox'; machineName='GunBound-BotOne'
        machineId=$id; machineFile=$machineFile; virtualBox=$platform.virtualBox; phase='preparing'; preparationStep='adapter'
        guestRoot='C:\GunBoundAI'; guestUser='LabBot'; playerSetup='manual'; roomFill=$true
        botInstances=@(
            [pscustomobject]@{name='BotOne';address='192.168.56.10'}
            [pscustomobject]@{name='BotTwo';address='192.168.56.11'}
            [pscustomobject]@{name='BotThree';address='192.168.56.12'}
        )
        hostAdapter=$null; hostAdapterId=$null; adapterCreated=$false
        hostAddress='192.168.56.1'; botAddress='192.168.56.10'; guestPrivateMac=$mac
        memoryMiB=$MemoryMiB; cpus=$Cpus; graphicsAcceleration=$false; leaseSeconds=120
        windowsIso=$platform.windowsIso; windowsSha256=$platform.windowsSha256; windowsImage=$platform.imageName
        windowsImageIndex=$platform.imageIndex; additionsIso=$platform.additionsIso
        diskFile=(Join-Path (Split-Path $machineFile) 'system.vdi'); diskId=$null; azureResourcesCreated=$false
    }
    $owner = [pscustomobject][ordered]@{
        schemaVersion=1; root=$root; machineId=$id; machineFile=$machineFile; virtualBox=$platform.virtualBox
        guestPrivateMac=$mac; hostAdapter=$null; hostAdapterId=$null; adapterCreated=$false
        createdUtc=[DateTime]::UtcNow.ToString('o')
    }
    Protect-VmDirectory $private
    Protect-VmDirectory (Join-Path $root 'runtime\vm')
    Write-VmJson $ownerPath $owner
    Write-VmJson $configPath $config
}
function Save-Preparation([string]$Step) {
    $config.preparationStep = $Step
    Write-VmJson $ownerPath $owner
    Write-VmJson $configPath $config
}
function Network-State {
    $interfaces = @(Convert-VBoxBlocks @(Invoke-VBox $config.virtualBox @('list','hostonlyifs')))
    $adapters = @(Get-NetAdapter -IncludeHidden)
    $addresses = @(foreach ($row in Get-NetIPAddress -AddressFamily IPv4) {
        $adapter = @($adapters | Where-Object ifIndex -eq $row.InterfaceIndex)
        [pscustomobject]@{IPAddress=$row.IPAddress;PrefixLength=$row.PrefixLength
            Disabled=($adapter.Count -eq 1 -and $adapter[0].Status -eq 'Disabled')
            InterfaceGuid=$(if ($adapter.Count -eq 1) { ([Guid]$adapter[0].InterfaceGuid).ToString('D') } else { '' })}
    })
    $routes = @(foreach ($row in Get-NetRoute -AddressFamily IPv4) {
        $adapter = @($adapters | Where-Object ifIndex -eq $row.InterfaceIndex)
        [pscustomobject]@{DestinationPrefix=$row.DestinationPrefix;NextHop=$row.NextHop
            InterfaceGuid=$(if ($adapter.Count -eq 1) { ([Guid]$adapter[0].InterfaceGuid).ToString('D') } else { '' })}
    })
    $registrations = @(Convert-VBoxRegistrations @(Invoke-VBox $config.virtualBox @('list','vms')))
    $infos = @(foreach ($vm in $registrations) {
        $info = Convert-VBoxInfo @(Invoke-VBox $config.virtualBox @('showvminfo', $vm.id, '--machinereadable'))
        if ($info.UUID -ine $vm.id -or ($info.CfgFile -ieq $config.machineFile -and $info.UUID -ine $config.machineId)) {
            throw 'Registered VM UUID/path conflict; no VM was changed.'
        }
        $info
    })
    [pscustomobject]@{ interfaces=$interfaces; addresses=$addresses; routes=$routes; infos=$infos
        dhcp=@(Convert-VBoxBlocks @(Invoke-VBox $config.virtualBox @('list','dhcpservers'))) }
}
Write-VmJson (Join-Path $PSScriptRoot 'platform-install.json') $platform
foreach ($role in @('user','admin')) {
    $file = Join-Path $private "guest-$role.txt"
    if (!(Test-Path -LiteralPath $file)) {
        if ($config.preparationStep -ne 'adapter') { throw 'A recorded installation passwordfile is missing; credentials will not be reset.' }
        $bytes = [Text.Encoding]::UTF8.GetBytes([Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)) + 'a!')
        $stream = [IO.File]::Open($file, 'CreateNew', 'Write', 'None')
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose(); [Array]::Clear($bytes) }
    }
    Assert-VmPrivateFile $file
}
if ($config.preparationStep -eq 'adapter') {
    $state = Network-State
    $plan = Select-VmHostAdapter $state.interfaces $state.addresses $state.routes $state.dhcp $state.infos $config.machineId
    $intentPath = Join-Path $private 'adapter-intent.json'
    if ($config.hostAdapter) {
        $recorded = @($state.interfaces | Where-Object GUID -ieq $config.hostAdapterId)
        if ($recorded.Count -ne 1 -or $recorded[0].Name -cne $config.hostAdapter) { throw 'The recorded host-only adapter disappeared or was renamed.' }
        if ($plan.action -ne 'reuse' -and $config.adapterCreated -and $owner.adapterCreated) {
            $intent = Get-Content -LiteralPath $intentPath -Raw | ConvertFrom-Json
            if ($intent.ownerId -ine $config.machineId -or $intent.id -ine $config.hostAdapterId -or
                $intent.name -cne $config.hostAdapter -or $intent.status -cne 'created') { throw 'The dedicated adapter configuration intent is incomplete.' }
            $null = Select-VmHostAdapter @($state.interfaces | Where-Object GUID -ine $config.hostAdapterId) `
                @($state.addresses | Where-Object InterfaceGuid -ine $config.hostAdapterId) `
                @($state.routes | Where-Object InterfaceGuid -ine $config.hostAdapterId) $state.dhcp $state.infos $config.machineId
            Invoke-VBox $config.virtualBox @('hostonlyif','ipconfig',$config.hostAdapter,'--ip=192.168.56.1','--netmask=255.255.255.0') | Out-Null
            $state = Network-State
            $plan = Select-VmHostAdapter $state.interfaces $state.addresses $state.routes $state.dhcp $state.infos $config.machineId
        }
        if ($plan.action -ne 'reuse' -or $plan.name -cne $config.hostAdapter -or $plan.id -ine $config.hostAdapterId) {
            throw 'The recorded adapter is no longer compatible; no unrelated adapter was changed.'
        }
    } elseif ($plan.action -eq 'reuse') {
        if (Test-Path -LiteralPath $intentPath) { throw 'An interrupted adapter creation needs explicit inspection; an unrecorded adapter will not be adopted.' }
        $owner.hostAdapter = $config.hostAdapter = $plan.name
        $owner.hostAdapterId = $config.hostAdapterId = $plan.id
        Save-Preparation 'adapter'
    } else {
        if (Test-Path -LiteralPath $intentPath) { throw 'An unfinished adapter creation intent exists. Inspect it before retrying; setup will not create another or claim an unrelated adapter.' }
        Write-VmJson $intentPath ([ordered]@{schemaVersion=1;ownerId=$config.machineId;beforeIds=@($state.interfaces.GUID);status='creating'})
        Invoke-VBox -VirtualBoxPath $config.virtualBox -Arguments @('hostonlyif','create') -TimeoutSeconds 120 `
            -PrivateLog (Join-Path $private 'adapter-create.log') | Out-Null
        $after = @(Convert-VBoxBlocks @(Invoke-VBox $config.virtualBox @('list','hostonlyifs')))
        $created = @($after | Where-Object GUID -notin @($state.interfaces.GUID))
        if ($created.Count -ne 1) { throw 'The newly created adapter is ambiguous; no address was changed.' }
        $owner.hostAdapter = $config.hostAdapter = $created[0].Name
        $owner.hostAdapterId = $config.hostAdapterId = ([Guid]$created[0].GUID).ToString('D')
        $owner.adapterCreated = $config.adapterCreated = $true
        Write-VmJson $intentPath ([ordered]@{schemaVersion=1;ownerId=$config.machineId;name=$config.hostAdapter;id=$config.hostAdapterId;status='created'})
        Save-Preparation 'adapter'
        if ($created[0].IPAddress -cne '192.168.56.1' -or $created[0].NetworkMask -cne '255.255.255.0') {
            $current = Network-State
            $null = Select-VmHostAdapter @($current.interfaces | Where-Object GUID -ine $config.hostAdapterId) `
                @($current.addresses | Where-Object InterfaceGuid -ine $config.hostAdapterId) `
                @($current.routes | Where-Object InterfaceGuid -ine $config.hostAdapterId) $current.dhcp $current.infos $config.machineId
            Invoke-VBox $config.virtualBox @('hostonlyif','ipconfig',$config.hostAdapter,'--ip=192.168.56.1','--netmask=255.255.255.0') | Out-Null
        }
    }
    $state = Network-State
    $verified = Select-VmHostAdapter $state.interfaces $state.addresses $state.routes $state.dhcp $state.infos $config.machineId
    if ($verified.id -ine $config.hostAdapterId -or $verified.name -cne $config.hostAdapter) { throw 'Adapter read-back did not match its recorded real name/GUID.' }
    Save-Preparation 'vm'
}
$registered = @(Convert-VBoxRegistrations @(Invoke-VBox $config.virtualBox @('list','vms')))
if ($config.preparationStep -eq 'vm') {
    if (@($registered | Where-Object { $_.name -ceq $config.machineName -and $_.id -ine $config.machineId }).Count) {
        throw 'An unowned VM claimed the requested name; nothing was replaced.'
    }
    if ($config.machineId -notin $registered.id) {
        if (Test-Path -LiteralPath (Split-Path $config.machineFile)) { throw 'An unregistered VM directory already exists; resume cannot adopt or overwrite it.' }
        Invoke-VBox $config.virtualBox @('createvm', "--name=$($config.machineName)", '--ostype=Windows2022_64',
            "--uuid=$($config.machineId)", "--basefolder=$root\runtime\vm", '--register') | Out-Null
    }
    Get-OwnedVmInfo $root $config | Out-Null
    Save-Preparation 'hardware'
}
$info = Get-OwnedVmInfo $root $config
if ($info.VMState -cne 'poweroff') { throw 'An unfinished preparation must be powered off. It was not reset or reinstalled.' }
if ($config.preparationStep -eq 'hardware') {
    Invoke-VBox $config.virtualBox @('modifyvm',$config.machineId,"--memory=$MemoryMiB","--cpus=$Cpus",
        "--hardware-uuid=$($config.machineId)",'--system-uuid-le=on','--rtc-use-utc=on','--ioapic=on','--firmware=efi',
        '--graphicscontroller=vboxsvga','--vram=128','--accelerate-3d=off','--paravirt-provider=hyperv',
        '--nic1=nat','--nic-type1=82540EM','--nat-localhostreachable1=off','--nic2=hostonly',
        "--host-only-adapter2=$($config.hostAdapter)",'--nic-type2=82540EM',"--mac-address2=$($config.guestPrivateMac)",
        '--clipboard-mode=disabled','--drag-and-drop=disabled','--vrde=off',
        '--audio-enabled=on','--audio-driver=null','--audio-controller=hda',
        '--mouse=ps2','--keyboard=ps2','--boot1=dvd','--boot2=disk','--boot3=none','--boot4=none') | Out-Null
    Save-Preparation 'disk'
}
if ($config.preparationStep -eq 'disk') {
    if (!(Test-Path -LiteralPath $config.diskFile)) {
        Invoke-VBox -VirtualBoxPath $config.virtualBox -TimeoutSeconds 300 -Arguments @('createmedium','disk',
            "--filename=$($config.diskFile)",'--size=65536','--format=VDI','--variant=Standard') `
            -PrivateLog (Join-Path $private 'disk-create.log') | Out-Null
    }
    Assert-VmPrivateFile (Join-Path $private 'disk-create.log')
    $createdId = Get-VmCreatedDiskId ([IO.File]::ReadAllText((Join-Path $private 'disk-create.log')))
    $disk = Convert-VBoxInfo @(Invoke-VBox $config.virtualBox @('showmediuminfo','disk',$config.diskFile,'--machinereadable'))
    $diskId = [Guid]::Empty
    if ($disk.Location -ine $config.diskFile -or ![Guid]::TryParseExact([string]$disk.UUID,'D',[ref]$diskId) -or
        $diskId -eq [Guid]::Empty -or $disk.UUID -ine $createdId -or ($config.diskId -and $config.diskId -ine $disk.UUID)) {
        throw 'The existing disk does not match the recorded creation intent. No disk was overwritten.'
    }
    $config.diskId = $diskId.ToString('D')
    Save-Preparation 'storage'
}
if ($config.preparationStep -eq 'storage') {
    $info = Get-OwnedVmInfo $root $config
    if ('SATA' -notin @($info.Keys | Where-Object { $_ -match '^storagecontrollername\d+$' } | ForEach-Object { $info[$_] })) {
        Invoke-VBox $config.virtualBox @('storagectl',$config.machineId,'--name=SATA','--add=sata','--controller=IntelAhci','--portcount=4','--bootable=on') | Out-Null
    }
    if ($info['SATA-0-0'] -and $info['SATA-0-0'] -ine $config.diskFile) { throw 'The owned system-disk port contains a different medium.' }
    Invoke-VBox $config.virtualBox @('storageattach',$config.machineId,'--storagectl=SATA','--port=0','--device=0','--type=hdd',"--medium=$($config.diskFile)") | Out-Null
    if (!$info['SATA-1-0']) {
        Invoke-VBox $config.virtualBox @('storageattach',$config.machineId,'--storagectl=SATA','--port=1','--device=0','--type=dvddrive','--medium=emptydrive') | Out-Null
    }
    Save-Preparation 'unattended'
}
if ($config.preparationStep -eq 'unattended') {
    Disconnect-VmInstallMedia $root $config
    $directory = Join-Path $private ('unattended\' + [Guid]::NewGuid().ToString('N'))
    Protect-VmDirectory $directory
    $template = Convert-VmUnattendedTemplate ([IO.File]::ReadAllText($platform.template))
    $template.Save((Join-Path $directory 'windows-template.xml'))
    Invoke-VBox -VirtualBoxPath $config.virtualBox -TimeoutSeconds 300 -PrivateLog (Join-Path $directory 'prepare.log') -Arguments @(
        'unattended','install',$config.machineId,"--iso=$($platform.windowsIso)","--image-index=$($platform.imageIndex)",
        '--user=Administrator',"--user-password-file=$private\guest-admin.txt","--admin-password-file=$private\guest-admin.txt",
        '--full-user-name=Guest Setup Administrator','--hostname=gunbound-bot.lab.invalid','--locale=en_US',
        '--language=en-US','--country=US','--time-zone=UTC','--install-additions',"--additions-iso=$($platform.additionsIso)",
        '--no-install-txs',"--script-template=$directory\windows-template.xml","--auxiliary-base-path=$directory\unattended-", '--start-vm=none') | Out-Null
    $config.phase = 'installing'
    Save-Preparation 'complete'
}
Get-OwnedVmInfo $root $config | Out-Null
$config
