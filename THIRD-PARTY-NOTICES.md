# Third-party material and distribution boundaries

This private repository contains the lab's custom integration, orchestration,
controller source and configuration templates. It does not grant rights to
redistribute the game, artwork, original server programs, Windows, VirtualBox,
MariaDB, or compatibility libraries.

- The compatible GunBound WC Retro v7 client, assets and native Serv3/Broker3
  server bundle must be supplied separately by the operator. The original
  distribution/licensing chain of that community bundle has not been
  independently established. Obtain any required permission before sharing it.
- Protocol references include [jglim/gunbound-server](https://github.com/jglim/gunbound-server),
  whose source is MIT-licensed. This repository is not that Python server
  emulator running unchanged.
- Initial numerical aiming references came from
  [SanjoSolutions/gunbound-aimbot](https://github.com/SanjoSolutions/gunbound-aimbot),
  released under the Unlicense. Existing inline attribution is retained.
- DxWnd and any supplied proxy/compatibility DLLs keep their own upstream
  licenses. They are not included here.
- Microsoft Windows installation media and licensing must be supplied
  separately. An evaluation installation is not a perpetual production license.
- VirtualBox and MariaDB are external prerequisites with their own licenses.
  Download them from their official distributors and retain applicable notices.

No public distribution license for the custom lab source is selected by this
packaging step. A future public release should explicitly choose its license
and review all upstream obligations.

Never commit local credentials, VM disks, database snapshots, generated SQL/static
game data, game binaries, private deployment archives or unsanitized logs.
