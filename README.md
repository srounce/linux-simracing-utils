# linux-simracing-utils

An all-in-one installer that gets [SimHub](https://www.simhubdash.com/) and [CrewChief](https://thecrewchief.org/) running on Linux, including telemetry bridging via [Winecarte](https://github.com/srounce/winecarte) so they can read data from Linux-native and Proton-based sim titles.

Supported games include: Assetto Corsa, Assetto Corsa Competizione, Assetto Corsa Evo, Assetto Corsa Rally, rFactor 2, Automobilista 2, Project Cars 2, Le Mans Ultimate, and American/Euro Truck Simulator 2.

---

## Background

SimHub and CrewChief are Windows applications. On Linux, Windows software is run using a compatibility layer called [Wine](https://www.winehq.org/). The catch is that sim racing games write their telemetry data (speed, gear, lap times, etc.) to a region of memory that Wine-hosted apps can't normally see.

This installer sets up everything needed to bridge that gap using **[Winecarte](https://github.com/srounce/winecarte)**. Winecarte has three components:

- **Wine2Linux** runs in a Wine prefix and maps shared memory in either direction between the prefix and the Linux system. Multiple instances can be run in different prefixes to replicate shared memory across prefixes.
- **Winehub**, which runs against a 'target' (non-game, eg. SimHub/CrewChief/etc.) prefix and works by detecting games running in their own separate prefixes. Upon detection it starts an instance of Wine2Linux in the target prefix to map shared memory files from Linux into the Wine environment.
- **winecarte-run**, wraps the execution of a Proton game and starts a Wine2Linux instance in the game's prefix to export data from the game to the Linux environment.

---

## Prerequisites

Before running the installer, make sure the following are installed on your system. If you're not sure how to install them, search for instructions for your specific Linux distribution (e.g. Ubuntu, Fedora, Arch).

- **Wine** — runs Windows applications on Linux
- **curl** — for downloading files (usually pre-installed)
- **unzip** — for extracting downloaded archives (usually pre-installed)

---

## Installation

> **Important:** Choose where you want to keep this folder before running the installer. The install location gets baked into the desktop launchers for SimHub and CrewChief. If you move the folder later, just re-run `install.sh` from the new location to fix everything up.

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

4. Follow the prompts. The installer will ask whether you want to install or skip each component — SimHub, CrewChief, and Winecarte. You can safely press Enter to accept the defaults.

The installer will download and set everything up, including a dedicated Wine environment so SimHub and CrewChief don't interfere with any other Wine applications you might have.

---

## Setting up your games

For SimHub and CrewChief to receive telemetry, each game needs to be launched via `winecarte-run`. This tells Winecarte to expose the game's shared memory to Wine so the apps can read it.

For each game in Steam:

1. Right-click the game in your Steam library and select **Properties**
2. In the **General** tab, find the **Launch Options** field
3. Enter the following, replacing the path with the actual location of your `linux-simracing-utils` folder:

   ```
   /path/to/linux-simracing-utils/bin/winecarte-run %command%
   ```

   For example, if you cloned the repo to your home folder:

   ```
   ~/linux-simracing-utils/bin/winecarte-run %command%
   ```

The `%command%` part is important — it tells Steam to run the game itself after `winecarte-run`.

---

## Using SimHub and CrewChief

Once installation is complete, SimHub and CrewChief will appear in your application menu (the same place you launch other apps). Launch them from there as normal.

Winehub starts automatically in the background when you open either app, bridging the game's shared memory into Wine so SimHub and CrewChief can read the telemetry. It shuts down cleanly when you close the apps. You don't need to do anything special to make it work.

---

## Updating SimHub or CrewChief

Re-run the installer at any time to update to the latest versions:

```bash
bash install.sh
```

It checks the installed version of each component against the latest release and only offers an update when there actually is one. Anything already up to date is offered as a reinstall/repair instead, and pressing Enter skips it, so a re-run costs nothing if you only need the launchers fixing up.

To follow Winecarte prereleases, or to pin a specific release:

```bash
LSU_WINECARTE_PRERELEASE=1 bash install.sh
LSU_WINECARTE_VERSION=v0.4.0 bash install.sh
```

---

## If you move the folder

Re-run the installer from the new location:

```bash
bash install.sh
```

This will also fix up the desktop launchers for SimHub and CrewChief to point to the new location.

---

## Directory layout

```
install.sh       # the installer
bin/             # helper scripts and tools (created by the installer)
pfx/             # the Wine environment (created by the installer)
log/             # install and runtime logs (created by the installer)
```

---

## Troubleshooting

Install logs are saved to the `log/` folder inside the project directory. If something goes wrong during installation, check the relevant log file there for details.

If you need to debug runtime issues, you can enable verbose output by setting `DEBUG=1` before running any of the scripts:

```bash
DEBUG=1 bash install.sh
```

---

## Related projects

- **[SimHub_on_Linux](https://github.com/srlemke/SimHub_on_Linux)** by [@srlemke](https://github.com/srlemke) — Provided initial inspiration for this project and was a helpful reference for various aspects of the processes involved. Big shoutout to @srlemke for his work on this.
