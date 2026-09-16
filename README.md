# GunBound AI Lab

A **private, source-only, bring-your-own-assets** setup project for a local
GunBound WC Retro v7 server and up to three real-client AI opponents.

The human client runs on the Windows host. One Windows Desktop Experience VM
contains the legacy server, MariaDB, and BotOne/BotTwo/BotThree. The controllers
use native game-state observations, bounded tactical movement, numerical aiming,
model robustness estimates and match-scoped shot memory.

**This is an experimental research prototype, not a turnkey public game service.**
The current bot behavior and known limitations are described in
[the contributor overview](docs/OVERVIEW.md). Shot 2 remains deliberately disabled
pending exact-client runtime calibration.

## What is and is not included

Included: custom C#/PowerShell source, build and setup scripts, safe configuration
generation, tests, and documentation.

**Not included:** game/server binaries, artwork, original SQL/static game data,
Windows media, compatibility DLLs, VM disks, existing accounts, credentials,
database snapshots, logs, or private deployment archives.

Setup generates new local-game passwords, database credentials and VM ownership
identities. Host paths are derived from the chosen repository/installation root
and input parameters. The fixed guest paths `C:\GunBoundAI` and
`C:\GunBoundServer` are part of the supported guest layout, not personal paths.

See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) before redistributing any
external files. A private repository does not grant redistribution rights.

## Prerequisites and required files

Use a 64-bit Windows host with hardware virtualization available, PowerShell 7.4+,
the Windows .NET Framework x86 compiler, and Oracle VirtualBox. Default VM
allocation is **6144 MiB RAM, four vCPUs and a 64 GiB dynamically allocated disk**.
Allow at least 80 GiB of free installation space and sufficient host RAM
headroom; these are prototype settings, not a validated minimum specification.

One-time setup needs administrator consent for VM/network preparation and the
lab-owned registry configuration. Normal gameplay must run without elevation.
No script disables Windows security/virtualization requirements or the host
firewall to make installation succeed.

| Input | Required contents/version | Where to obtain it |
|---|---|---|
| PowerShell 7 | Installed PowerShell 7.4 or newer, available as `pwsh` | [Microsoft installation documentation](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) |
| VirtualBox | Installed VirtualBox 7.2.x and matching Guest Additions; the prototype originated on 7.2.16 | [Oracle downloads](https://www.virtualbox.org/wiki/Downloads) |
| `-ClientDirectory` | Trusted, extracted compatible Retro v7 client directory containing the six files below | **Project owner to supply a lawful compatible-client download location.** No game files are hosted here. |
| `-ServerSourceDirectory` | Inner server-bundle folder containing `Database\gunbound.sql` and `Server Binaries\GunBoundXP` | **Project owner to supply a lawful compatible-server download location.** |
| `-MariaDbArchive` | Official `mariadb-11.4.13-winx64.zip` | [MariaDB 11.4.13 Windows archive directory](https://archive.mariadb.org/mariadb-11.4.13/winx64-packages/) |
| `-WindowsIso` | Legally obtained English x64 Windows Server 2022 ISO with a Desktop Experience image | [Microsoft evaluation center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022); obtain appropriate licensing for ongoing use |

The client importer copies only:

```text
GunBound.gme
ddraw.dll
dxwnd.dll
avatar.xfs
graphics.xfs
sound.xfs
```

It generates new `dxwnd.dxw` / `dxwnd.ini` configuration. It does **not** copy the
original launcher, saved launcher settings, registry exports, mute lists or logs.
Supply extracted files from a trusted source; the setup does not execute an
arbitrary client installer or the old network launcher.

A small launcher MSI is not sufficient unless it actually supplies all six
required runtime files. Do not depend on a defunct patch/download server to fill
in missing assets; the importer verifies the complete local input set first.

Critical supported fingerprints:

| File | SHA256 |
|---|---|
| `GunBound.gme` | `683CB237147C8DE28C2A5EA3343E9A6B6082EC5D1851F5D20DFBF8BA81A530A8` |
| `ddraw.dll` | `AA29719572FC6842ACF85302BEE94AB889AEC49C7E456C83C0770ABB0BD8D6C4` |
| `dxwnd.dll` | `909349FF70190FE962BDC55748C740B9E4137126B2AC4A4CEBB7E63C3DF55898` |
| Original `Gunboundserv3.exe` | `D82513950D4DB08BE664D538E09E5B00A07C795D76A0A7ED0EEDE8A8553FA511` |
| Original `GunBoundBroker3.exe` | `DB6F6765AEF74C702CEB6AE035FA022F3D309670D804E4679A681781FB448A63` |

The executable/version names alone are insufficient to establish compatibility.
Do not replace fingerprints to force an unrelated client through the guards.
The original server dump is used only to extract table definitions and reviewed
static-table data; its existing player/account rows must not be imported.

## First run: one entry script

Clone the private repository using your normal GitHub authentication. Never put a
GitHub token into a clone URL, script or configuration file.

In a **normal, non-administrator PowerShell 7** window:

```powershell
git clone https://github.com/hksekai/gunbound-ai-lab.git
Set-Location .\gunbound-ai-lab

.\start.ps1 `
  -ClientDirectory 'D:\GunBoundAssets\Client' `
  -ServerSourceDirectory 'D:\GunBoundAssets\ServerBundle' `
  -MariaDbArchive 'D:\GunBoundAssets\mariadb-11.4.13-winx64.zip' `
  -WindowsIso 'D:\GunBoundAssets\WindowsServer2022.iso'
```

Replace these example paths with your locally supplied files. Relative paths are
resolved before elevation. The first run requests UAC for setup, waits for it,
then returns to the original non-admin process to launch Player.

To prepare the installation but leave Player and the VM off:

```powershell
.\start.ps1 `
  -ClientDirectory 'D:\GunBoundAssets\Client' `
  -ServerSourceDirectory 'D:\GunBoundAssets\ServerBundle' `
  -MariaDbArchive 'D:\GunBoundAssets\mariadb-11.4.13-winx64.zip' `
  -WindowsIso 'D:\GunBoundAssets\WindowsServer2022.iso' `
  -NoLaunch
```

Alternatively, run `setup.ps1` with those inputs in an elevated PowerShell 7
window. Setup deliberately does not launch Player with administrator privileges.

If Windows blocks downloaded scripts, review the source and follow your local
script-signing/unblocking policy. Do not disable security policies globally to
run the project.

### Setup stages

1. Validate supplied paths, supported binary fingerprints and prerequisites.
2. Copy only required client assets and generate fresh local wrapper settings.
3. Build and check the C# helpers/controller and isolated native compatibility tests.
4. Prepare a fresh, restricted portable database and native backend from supplied
   files, generating new accounts and bot-only exports.
5. Create a newly identified VM, install Windows Desktop Experience and Guest
   Additions, provision the isolated bot roots, and migrate only the newly prepared
   offline backend into the protected guest server root.
6. Verify guest code/backend readiness, record the owned installation, and finish
   with the VM off. `start.ps1` then launches the managed game unless `-NoLaunch`
   was selected.

The host client account file contains Player/BotOne only; the protected backend
has all four accounts, and the bot application receives only the three bot
credentials. Guest bots run as non-administrator LabBot.

Setup is fresh-install oriented. It refuses unrelated existing VMs, changed
ownership metadata, occupied/conflicting network resources and existing databases
that would require a reset. An incomplete installation needs inspection and an
explicit `-Resume`; this is not permission to overwrite an unrelated installation.
Once VM ownership/packages exist, resume reuses the checked helper binaries and
immutable packages rather than rebuilding them. If the VM already reached ready,
resume retries only host finalization.
An interrupted database seed is not repaired by blindly replaying SQL. Preserve
its private records and reconcile the partial MyISAM state before retrying; a
verified completed/stopped seed can be reused without resetting accounts.

**Do not test fresh provisioning over an existing development lab.** The default
VM name and private subnet are intentionally constrained. A name/network conflict
is an error to resolve, not something the installer deletes automatically.

## Subsequent play and shutdown

```powershell
.\start.ps1
```

Player opens at 1600x1200. Join **Local Practice**, create a **Solo** room, wait for
the bots to finish setup/Ready, then click Start yourself.

| Native room capacity | Bot population |
|---|---|
| 2 | BotOne |
| 4 | BotOne, BotTwo, BotThree |
| 6 or 8 | Explicitly unsupported |

Bots retain 800x600 rendering for calibrated input/power measurement. They use
actual balanced teams during combat and are restricted to the approved named
roster. Normal launching never automates Player's room creation or Start button.

```powershell
.\vm\control.ps1 -Action Status
.\stop-lab.ps1
```

Closing Player ends its managed bot/server session. Normal shutdown stops the
database before Windows. Force-off is an explicit emergency operation with crash
recovery risk, particularly because the legacy game data uses MyISAM.

The network is host-only/private. SQL remains guest loopback. No public forwarding,
cloud hosting or host-firewall relaxation is part of setup. Preloading/warm standby
and a parallel startup pipeline are not yet implemented.

## Development checks

Host-safe setup contracts, without provisioning:

```powershell
.\setup.ps1 -Check
```

Build source and run the existing controller checks without starting a game:

```powershell
.\build-client.ps1
.\build-client.ps1 -Tools
.\build-client.ps1 -Control
.\build-bot.ps1
```

The separate native wrapper checks require the supplied client assets:

```powershell
.\client-build\build.ps1
.\client-build\verify.ps1
```

Stop the owned game before replacing shared executables. Staged/guest checks do
not prove actual hits or live gameplay. The packaging flow must still be exercised
on a genuinely fresh Windows installation; it is not claimed here as a completed
fresh-machine end-to-end deployment.

## Privacy and repository hygiene

Generated data belongs under ignored local directories. Never commit:

- `private`, `runtime`, `session`, `logs` or `client-image`.
- VM disks/media, client/server binaries, compatibility DLLs, database copies,
  private archives or extracted SQL/static game data.
- Tokens, passwords, signed private download links, personal home-directory paths,
  or per-machine VM/adapter ownership records.

Before staging and again against the exact Git index:

```powershell
.\check-export.ps1 -Check
.\check-export.ps1 -WorkingTree
git add .
.\check-export.ps1
```

The export check prints categories and file/line references, not matched secret
values. It is a guardrail plus an explicit source-file inventory, not a guarantee
that arbitrary future code can never contain a secret. Review staged changes.

Known prototype limitations, observed live results, source origins and contributor
code excerpts are in [docs/OVERVIEW.md](docs/OVERVIEW.md).
