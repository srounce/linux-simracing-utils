# linux-simracing-utils

An all-in-one installer that gets [SimHub](https://www.simhubdash.com/) and [CrewChief](https://thecrewchief.org/) running on Linux, including telemetry bridging via [Winecarte](https://github.com/srounce/winecarte) so they can read data from Linux-native and Proton-based sim titles.

Supported games include: Assetto Corsa, Assetto Corsa Competizione, Assetto Corsa Evo, Assetto Corsa Rally, rFactor 2, Automobilista 2, Project Cars 2, Le Mans Ultimate, and American/Euro Truck Simulator 2.

---

## Background

SimHub and CrewChief are Windows applications. On Linux, Windows software is run using a compatibility layer called [Wine](https://www.winehq.org/). The catch is that sim racing games write their telemetry data (speed, gear, lap times, etc.) to a region of memory that Wine-hosted apps can't normally see.

This installer sets up everything needed to bridge that gap using **[Winecarte](https://github.com/srounce/winecarte)**. Winecarte has three components:

- **Wine2Linux** runs in a Wine prefix and maps shared memory in either direction between the prefix and the Linux system. Multiple instances can be run in different prefixes to replicate shared memory across prefixes.
- **Winehub**, which runs against a 'target' (non-game, eg. SimHub/CrewChief/etc.) prefix and works by detecting games running in their own separate prefixes. Upon detection it starts an instance of Wine2Linux in the target prefix to map shared memory files from Linux into the Wine environment.
- **winecarte-run**, wraps the execution of a Proton game and starts a Wine2Linux instance in the game's prefix to export data from the game to the Linux environment. Optional now that injection is automatic.

---

## Prerequisites

Before running the installer, make sure the following are installed on your system. If you're not sure how to install them, search for instructions for your specific Linux distribution (e.g. Ubuntu, Fedora, Arch).

- **curl** — for downloading files (usually pre-installed)
- **unzip** — for extracting downloaded archives (usually pre-installed)

The installer ships its own Wine build, so you don't need Wine installed. On NixOS its runtime libraries and dynamic loader are fetched from a pinned nixpkgs revision and wired up automatically; no extra system configuration is needed.

---

## Installation

> **Important:** Choose where you want to keep this folder before running the installer. The install location gets baked into the desktop launchers for SimHub and CrewChief. If you move the folder later, just re-run `install.sh` from the new location to fix everything up.

Quickest way, run this in a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/srounce/linux-simracing-utils/master/install.sh | bash
```

It asks where to install (default `~/linux-simracing-utils`) and puts a copy of `install.sh` there for re-runs and updates. Then skip to step 4.

To pick the programs up front instead of from the menu, pass `--modules` through to the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/srounce/linux-simracing-utils/master/install.sh | bash -s -- --modules simhub,crewchief
```

To install from a clone instead:

1. Open a terminal and download the installer:

   ```bash
   git clone https://github.com/srounce/linux-simracing-utils
   ```

   If you don't have `git`, you can also download a ZIP from GitHub and extract it.

2. Move into the folder:

   ```bash
   cd linux-simracing-utils
   ```

3. Run the installer:

   ```bash
   bash install.sh
   ```

4. Follow the prompts. The installer asks which Wine channel to use (press Enter for the default, see [Wine channel](#wine-channel)), then shows a menu of programs to install:

   ```
   Programs to install or update:
      1) [ ] SimHub                   not installed
              Dashboards, overlays, bass shakers and motion
      2) [ ] CrewChief                not installed
              Spotter and virtual race engineer
      3) [ ] MOZA Pit House           not installed
              Settings and firmware for MOZA wheelbases, wheels and pedals
      4) [ ] Richard Burns Rally RSF  not installed
              The RallySimFans build of Richard Burns Rally
   Numbers to toggle (e.g. 1 3), a for all, n for none, Enter to continue:
   ```

   Type the numbers of the programs you want, then press Enter. Programs that are already installed start out ticked.

The installer always sets up its own Wine build, a dedicated Wine environment (so these programs don't interfere with any other Wine applications you might have) and Winecarte. Each program is then installed by its own small script, a *module*, which the installer downloads the first time you pick it.

---

## Setting up your games

Winecarte injection is automatic, so games need no setup. Launch them from Steam as normal.

If you previously added `winecarte-run %command%` to a game's Steam launch options, you can remove it. `winecarte-run` is now optional.

---

## Using SimHub and CrewChief

Once installation is complete, SimHub and CrewChief will appear in your application menu (the same place you launch other apps). Launch them from there as normal.

Winehub starts automatically in the background when you open either app, bridging the game's shared memory into Wine so SimHub and CrewChief can read the telemetry. It shuts down cleanly when you close the apps. You don't need to do anything special to make it work.

The application menu and desktop entries always start this project's Wine by its full path, never whichever `wine` comes first on your `PATH`. Wine's own launcher writer can't do that, so it is switched off in the Wine environment, and the launchers are written by `install.sh` instead. When an app saves a new shortcut while it runs, for example during an update, its launcher appears once every program in the Wine environment has closed, if one of them was started through winehub. You can also write them straight away with `bin/lsu-update-launchers`. After a session it logs to `log/launchers.log`.

---

## MOZA Pit House

Pick **MOZA Pit House** in the installer's menu, or run:

```bash
bash install.sh --modules pithouse
```

It downloads MOZA's online installer and installs the current release without any installer windows. This takes a few minutes. Pit House then appears in your application menu, and it updates itself when it starts.

Pit House needs Wine `sangria-11.18-pre3` or newer. The default prerelease channel has that. If you are on the release channel and it is older, the installer offers to switch channel for you.

Picking Pit House again on an existing install offers a repair. A repair removes the Pit House program folder and installs it again. Your settings and presets in Documents are not touched.

To install from a MOZA channel other than `release`:

```bash
LSU_PITHOUSE_CHANNEL=1.4.1-beta bash install.sh --modules pithouse
```

Logs go to `log/pithouse_install.log`.

---

## Richard Burns Rally (RSF)

Pick **Richard Burns Rally RSF** in the installer's menu, or run:

```bash
bash install.sh --modules rsf
```

rallysimfans.hu does not allow scripted downloads, so download `Rallysimfans_Installer.exe` from the [RSF download page](https://rallysimfans.hu/rbr/download.php?download=rsfrbr) in your browser first. The module looks for it in your Downloads folder and in the install folder, or you can point it at a file with `LSU_RSF_INSTALLER=/path/to/Rallysimfans_Installer.exe`. If it can't find one, it asks for the path.

The RSF installer then opens in its own window and you work through it as you would on Windows. RSF's base game files come from its torrent. If you have already downloaded that, point the installer at the folder. Drive `Z:` in the installer is your Linux file system. When the installer is closed, the module sets the DLL overrides the game needs (`d3d9`, `dinput8` and the old Visual C++ runtimes the game ships with). It also turns off Wine's incomplete ICU DLLs for the RSF launcher, a .Net 10 program that would otherwise quit on start, so that .Net uses Windows' own globalization functions instead. These overrides apply only to the RSF launcher and the Richard Burns Rally executables, not to the rest of the Wine environment. The installer's shortcuts then appear in your application menu, set up like the SimHub and CrewChief ones. RBR is in the same Wine environment as SimHub, so SimHub reads its telemetry directly.

The RSF installer also runs Microsoft's DirectX web setup, which crashes under Wine and may show a crash window or backtrace. The RSF installer carries on regardless. The game itself only uses DirectX DLLs that Wine already provides.

Before the RSF installer runs, the module installs Microsoft's Visual C++ 2015-2022 runtime (x86 and x64) with winetricks. The RSF launcher refuses to start with Wine's own `msvcp140.dll`, and Microsoft's installer won't replace it, so the module puts Microsoft's in place itself where winetricks doesn't.

Picking it again on an existing install opens the RSF installer again, where you can repair the install or change what is installed. Because the installer needs you at the keyboard, `UNATTENDED=1` never runs it.

If you installed RSF into the Wine environment some other way, re-running `install.sh` adds the DLL overrides and the Visual C++ runtime if they are missing. It leaves alone any override you have changed in `winecfg`.

Logs go to `log/rsf_install.log`.

---

## Updating

Re-run the installer at any time to update to the latest versions:

```bash
bash install.sh
```

Wine, the Wine environment and Winecarte are always brought up to date. In the program menu, installed programs start out ticked and show whether an update is available. A ticked program that is already up to date is offered as a reinstall/repair instead, and pressing Enter skips it, so a re-run costs nothing if you only need the launchers fixing up. Untick a program to leave it alone this run. Unticking does not uninstall it.

To run without any prompts, set `UNATTENDED=1`. That installs what `--modules` names, or, without `--modules`, updates the programs that are already installed:

```bash
UNATTENDED=1 bash install.sh
UNATTENDED=1 bash install.sh --modules simhub,crewchief
```

To follow Winecarte prereleases, or to pin a specific release:

```bash
LSU_WINECARTE_PRERELEASE=1 bash install.sh
LSU_WINECARTE_VERSION=v0.4.0 bash install.sh
```

To have the installer, and the modules it downloads, update from a branch other than master:

```bash
LSU_BRANCH=my-feature bash install.sh
```

The installed copy of `install.sh` keeps that branch as its default, so later runs follow it without setting `LSU_BRANCH` again. `LSU_REPO=owner/linux-simracing-utils` does the same for a fork.

### Wine channel

The installer uses its own Wine build, [sangria](https://github.com/srounce/wine). It asks which channel to follow on every interactive run, with your last choice as the default:

- **prerelease** (default): the newest build, prereleases included.
- **release**: full releases only. These change less often, but some programs need a newer Wine than the latest full release (see [MOZA Pit House](#moza-pit-house)).

Switching to an older Wine than the one installed asks before downgrading, because programs in the Wine environment may not work with an older Wine.

To choose without being asked:

```bash
LSU_WINE_CHANNEL=release bash install.sh
```

To pin a specific Wine release instead of following a channel:

```bash
LSU_WINE_VERSION=sangria-11.18-pre3 bash install.sh
```

`LSU_WINE_VERSION=latest` removes the pin and returns to the channel.

`LSU_WINE_REPO=owner/repo` takes Wine releases from another GitHub repository. The default is `srounce/wine`.

These settings are kept in `var/lsu.conf` and apply to later runs too. Pins kept in `install.sh` by older versions of the installer are moved there automatically.

---

## If you move the folder

Re-run the installer from the new location:

```bash
bash install.sh
```

This will also fix up the desktop launchers for the installed programs to point to the new location.

---

## Directory layout

```
install.sh       # the installer
lib/             # code shared by the installer and the modules
modules/         # one install script per program, downloaded when first picked
modules/local/   # your own modules (see below)
bin/             # helper scripts and tools (created by the installer)
pfx/             # the Wine environment (created by the installer)
var/             # Wine, settings (lsu.conf) and other installer state
log/             # install and runtime logs (created by the installer)
```

---

## Writing a module

Each program the installer offers is a module: a bash script in `modules/` that the installer runs as `<id>.sh status`, `<id>.sh install` and so on, and that reports back through its exit status and a few `key=value` results. [`modules/example.sh`](modules/example.sh) is a working template, and its header describes the whole contract.

To add your own:

1. Copy `modules/example.sh` to `modules/local/<id>.sh` in your install folder, where `<id>` is a short lower-case name.
2. Set `LSU_MODULE_ID` to the same `<id>`, give it a name and description, and fill in the `module_status` and `module_install` functions.
3. Re-run `install.sh`. Your module appears in the menu, marked `(local)`.

The installer never touches `modules/local/`, so updates won't overwrite your module. A local module with the same id as a published one replaces it. Modules also run on their own, which is handy while writing one:

```bash
bash modules/local/<id>.sh status
bash modules/local/<id>.sh install
```

To share a module with everyone, open a pull request that adds it to `modules/` and gives it a line in `modules/index`.

---

## Troubleshooting

Not receiving telemetry after an update? Re-run `install.sh` to repair the desktop launcher entries in the prefix.

Install logs are saved to the `log/` folder inside the project directory. The installer ends with a summary of what each program's module did. If something goes wrong during installation, check the relevant log file there for details.

If you need to debug runtime issues, you can enable verbose output by setting `DEBUG=1` before running any of the scripts:

```bash
DEBUG=1 bash install.sh
```

---

## Related projects

- **[SimHub_on_Linux](https://github.com/srlemke/SimHub_on_Linux)** by [@srlemke](https://github.com/srlemke) — Provided initial inspiration for this project and was a helpful reference for various aspects of the processes involved. Big shoutout to @srlemke for his work on this.
