# 🧳 PC Migration Kit

**Move a Windows PC to a new drive or a fresh Windows install without losing your setup.** It brings over your programs, their settings, automations, Windows settings, files on every drive, and even a self-hosted media server. You get a scan and backup on the old system, a restore on the new one, and a verify step that finds anything that didn't come back.

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D6)
![.NET Framework](https://img.shields.io/badge/.NET%20Framework-4.8%20(built%20in)-512BD4)
![PowerShell](https://img.shields.io/badge/engine-PowerShell-5391FE)
![License](https://img.shields.io/badge/license-MIT-green)

**Nothing to install:** download one `.exe` and run it on any Windows 10 or 11. It starts with normal rights and asks for administrator rights only for the steps that need them.

---

## What it does

| Page | What it does |
|---|---|
| **Scan & back up** | Scans the whole PC: every drive and folder, plus programs, services, scheduled tasks, startup items, environment variables, WSL, Docker, drivers, fonts, Wi-Fi profiles, game saves (including games that keep saves in their own folder or in emulator save folders), code projects, virtual-machine disks and the media server. Everything is grouped with sizes, and what belongs to your setup is **pre-ticked**. The ticked items are copied to another drive **from a shadow-copy snapshot**, so open databases are copied cleanly. |
| **Restore** | On the new Windows: pick the backup, untick what you don't want, and it runs the steps. Those are drive letters, Windows features, programs (via **winget**), files and profile, app data, registry settings, environment variables, services, scheduled tasks, startup items, WSL, drivers, Wi-Fi / hosts / power plan / fonts, taskbar pins, the media server and folders from other drives. **Finished steps are remembered**, so running it again is safe, and a **practice run** shows what would happen without changing anything. |
| **Verify & fix** | Compares the PC with a backup and lists anything that isn't back, or went missing later. Tick what to put back and click **Fix**. Worth running after every big Windows update: one Windows 10 → 11 upgrade silently removed a scheduled task and a service and reset the power plan. |
| **Media server** | Checks a self-hosted media stack (Jellyfin, Radarr, Sonarr, Prowlarr, Jackett, qBittorrent, Caddy, DuckDNS, Docker, Seerr, Jellystat, a Home Assistant VM and the network profile) and **sets up whatever is down**. |

The program travels with each backup. Open `PC Migration Kit.exe` from inside a backup folder on the new PC, and the Restore page already knows which backup to use.

### Smart details

- **Account name can change:** every `C:\Users\<old>\...` path in app settings, shortcuts, the registry, services, tasks, startup items and the scripts they run is rewritten to the new account.
- **Drive letters come back first**, matched by partition, so automations that depend on `D:\...` keep working.
- **Language runtimes keep their version**: Node.js, Python, Java and Go are reinstalled at the version the old PC had, so native modules keep loading.
- **Programs that move during reinstall are found again** (e.g. from `Program Files (x86)` to `Program Files`, or versioned folders), and startup items, tasks and services are pointed at the new place.
- **A restart mid-restore doesn't break it**: Windows Update is held off while it runs, and if the PC restarts anyway the restore reopens after sign-in.
- **Registry settings are imported key by key** when Windows refuses one. Integrity-protected browser keys are skipped.

---

## Download & use

1. Download **`PC-Migration-Kit.zip`** from the [latest release](../../releases/latest) and extract it, ideally onto the drive that will hold the backup.
2. **On the old PC:** run `PC Migration Kit.exe` → **Scan & back up**.
3. **On the new Windows:** open the program *from inside the backup folder* → **Restore**.
4. Afterwards: **Verify & fix**.

### Moving to a new SSD

- **Plan A, clone:** copy the whole Windows drive to the new SSD with an imaging tool (e.g. Hasleo Backup Suite Free: System Backup, then System Restore from its boot USB). Nothing is reinstalled. Make a backup with this kit first anyway.
- **Plan B, fresh Windows + this kit:** install a clean Windows, then run Restore. It reinstalls your programs and puts back files, settings and automations. Then run Verify & fix.

Tips: use a current Windows installer (Microsoft's Media Creation Tool), since old images have no winget and WSL2/Docker won't run. If your EFI boot partition lives on another disk, a clone must include it; for a fresh install, unplug the other drives so Setup puts the boot files on the new SSD. Turn on browser sync before switching, because saved passwords are encrypted per Windows installation.

### Console version

The numbered `.bat` files run the same engine in a console window: `1 - SCAN`, `2 - BACKUP`, `3 - RESTORE`, `4 - MEDIA SERVER`, `5 - VERIFY`. The PowerShell scripts in `Engine\` can also be run directly:

```powershell
.\Engine\Restore.ps1 -DryRun      # show what a restore would do
.\Engine\Restore.ps1 -Steps 3,9   # run only chosen steps
.\Engine\Verify.ps1               # compare the PC with the newest backup
.\Engine\Verify.ps1 -FixAll       # put back everything that is missing (admin window)
```

---

## Adapting the media-server part

The **Media server** page is built around the author's home server. Its catalog of parts, with install type, folders, ports, health checks and launchers, is a table at the top of [`Engine/MediaServer.ps1`](Engine/MediaServer.ps1). It expects, for example, Jellyfin and Prowlarr as portable installs on `G:`, Caddy on `D:\Caddy`, a Docker compose project in `D:\Docker` and a VirtualBox VM named `HomeAssistant`. Edit that table to match your setup, or simply don't use that page. Everything else in the kit is generic.

## Honest limits

- No tool can transplant an installed program into a different Windows. A fresh Windows gets programs **reinstalled**, then their data and settings back. For most apps that's indistinguishable from before; a few ask you to sign in again.
- **Not carried over:** browser passwords and cookies that aren't synced, Windows Credential Manager entries, hardware-locked licences, other user accounts' programs and settings (their files can be ticked), and programs with no installer anywhere (listed as "by hand").
- Taskbar pins only come back between the same Windows version (10 → 10, 11 → 11).

## Safety

- The scan and the backup don't change your PC. The backup takes temporary snapshots of the drives it copies from (removed afterwards) and briefly stops the WSL distro so its disk is copied cleanly.
- The restore **adds and overwrites but never deletes**. Later runs keep files that are newer on the PC, and it refuses to run on the same Windows the backup came from.
- ⚠️ **A backup contains Wi-Fi passwords, API tokens and app databases. Keep it private.**

---

## Building from source

The app is WPF on **.NET Framework 4.8**, which is built into Windows 10/11, compiled with the Roslyn C# compiler from Visual Studio Build Tools:

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools
.\Source\build.ps1          # builds and copies "PC Migration Kit.exe" next to the launchers
.\Source\build.ps1 -NoCopy  # build only -> Source\build\PCMigrationKit.exe
```

The screens (`Source\xaml`), the engine scripts (`Engine\`) and the icon are embedded, so the exe also works on its own. If there's an `Engine` folder next to it, it uses that one instead.

| Path | Purpose |
|---|---|
| `Engine\Backup.ps1`, `Inventory.ps1`, `Catalog.ps1` | Scan and backup |
| `Engine\Restore.ps1`, `RestoreSteps.ps1` | Restore steps |
| `Engine\Verify.ps1` | Compare and fix |
| `Engine\MediaServer.ps1`, `ServerSetup.ps1` | Media server check and repair |
| `Engine\Common.ps1` | Shared helpers (path rewriting, logging, snapshots…) |
| `Source\src\*.cs`, `Source\xaml\*.xaml` | The WPF app, which drives the engine and shows its progress |

## License

[MIT](LICENSE) © Denis Kostadinov
