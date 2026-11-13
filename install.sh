#!/usr/bin/env bash

: "${LSU_BRANCH:="master"}"
: "${LSU_REPO:="srounce/linux-simracing-utils"}"

# Installers from before var/lsu.conf kept the Wine settings baked in here, and
# an update run by one of them still bakes them in. load_settings moves them
# into var/lsu.conf and empties these lines again.
: "${LSU_WINE_REPO:=""}"
: "${LSU_WINE_VERSION:=""}"

# Run from a pipe (curl ... | bash) there is no script file to work from and
# stdin is the script itself, so fetch a copy, point stdin back at the
# terminal and continue from that file. The copy step below then lands it in
# the install directory.
if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  bootstrap_dir=$(mktemp -d)
  if ! curl -sL --fail \
    "https://raw.githubusercontent.com/${LSU_REPO}/${LSU_BRANCH}/install.sh" \
    -o "${bootstrap_dir}/install.sh"
  then
    echo "Unable to download the installer from branch ${LSU_BRANCH}." >&2
    exit 1
  fi
  { exec < /dev/tty; } 2> /dev/null || true
  exec env LSU_SKIP_UPDATE=1 LSU_BRANCH="$LSU_BRANCH" LSU_REPO="$LSU_REPO" \
    TARGET_DIR="${TARGET_DIR:-$HOME/linux-simracing-utils}" \
    bash "${bootstrap_dir}/install.sh" "$@"
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

: "${DEBUG:="0"}"
: "${UNATTENDED:="0"}"
: "${TARGET_DIR:="$SCRIPT_DIR"}"
# Every path in the prefix's launchers is built from this, and they are told
# apart from other prefixes' by plain text matching, so a trailing slash or a
# relative path must not change it. Symlinks are kept as given.
TARGET_DIR="$(realpath -ms -- "$TARGET_DIR")"

LSU_ARGS=("$@")

set -euo pipefail

usage() {
  cat << EOF
usage: install.sh [--modules <id>[,<id>...] | --modules none]

Installs or updates Wine, the Wine prefix and Winecarte, then the programs
(modules) you pick from a menu.

  --modules <ids>   install or update these modules instead of asking,
                    e.g. --modules simhub,crewchief
  --modules none    only the base install, no modules

With UNATTENDED=1 and no --modules, the modules already installed are updated.
See README.md for the environment variables that pin versions and channels.
EOF
}

MODULES_ARG=""
MODULES_ARG_SET=0

while (( $# )); do
  case "$1" in
    --modules)
      if (( $# < 2 )); then
        usage >&2
        exit 2
      fi
      MODULES_ARG="$2"
      MODULES_ARG_SET=1
      shift 2
      ;;
    --modules=*)
      MODULES_ARG="${1#*=}"
      MODULES_ARG_SET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

LSU_RAW_URL="https://raw.githubusercontent.com/${LSU_REPO}/${LSU_BRANCH}"

# Everything below needs the shared library. A copy that has none yet, from a
# bootstrap or from before the library existed, fetches it.
if [[ ! -f "${SCRIPT_DIR}/lib/lsu-common.sh" ]]; then
  mkdir -p "${SCRIPT_DIR}/lib"
  if ! curl -sL --fail "${LSU_RAW_URL}/lib/lsu-common.sh" \
    -o "${SCRIPT_DIR}/lib/lsu-common.sh.part"
  then
    rm -f "${SCRIPT_DIR}/lib/lsu-common.sh.part"
    echo "Unable to download lib/lsu-common.sh from branch ${LSU_BRANCH}." >&2
    exit 1
  fi
  mv -f "${SCRIPT_DIR}/lib/lsu-common.sh.part" "${SCRIPT_DIR}/lib/lsu-common.sh"
fi

# shellcheck source=lib/lsu-common.sh
source "${SCRIPT_DIR}/lib/lsu-common.sh"

LSU_LOGDIR="${TARGET_DIR}/log"
mkdir -p "${LSU_LOGDIR}"
echo "" > "${LSU_LOGDIR}/prefix_setup.log"
echo "" > "${LSU_LOGDIR}/install.log"

if [[ $DEBUG == "1" ]]; then
  set -x
  export WINEDEBUG=${WINEDEBUG:-+seh,+loaddll,+module}
else
  export WINEDEBUG=${WINEDEBUG:--all}
fi

lsu_init_runtime

bake_default() {
  local name="$1" value="$2" file="$3"
  value=${value//&/\\&}
  value=${value//|/\\|}
  sed -i "s|^: \"\${${name}:=\"[^\"]*\"}\"\$|: \"\${${name}:=\"${value}\"}\"|" "$file"
}

# Standalone installers keep where they update from as baked defaults. Git
# clones are skipped, since a modified file blocks pull.
bake_defaults() {
  bake_default LSU_BRANCH "$LSU_BRANCH" "$1"
  bake_default LSU_REPO "$LSU_REPO" "$1"
}

# Any clone counts, forks included, but only at its top level and only while
# it tracks install.sh, so an install directory that happens to sit inside an
# unrelated repository (a dotfiles home, say) is not mistaken for one.
is_lsu_clone() {
  [[ "$(git -C "$1" rev-parse --show-toplevel 2> /dev/null)" -ef "$1" ]] \
    && git -C "$1" ls-files --error-unmatch install.sh > /dev/null 2>&1
}

restart_installer() {
  lsu_cleanup_runtime
  exec env LSU_SKIP_UPDATE=1 LSU_BRANCH="$LSU_BRANCH" LSU_REPO="$LSU_REPO" \
    DEBUG="$DEBUG" UNATTENDED="$UNATTENDED" TARGET_DIR="$TARGET_DIR" \
    bash "$1" "${LSU_ARGS[@]}"
}

INSTALLER_OUTDATED=0

# install.sh and the library it sources update together, so a run never
# mixes one version of each.
check_self_update() {
  if [[ "${LSU_SKIP_UPDATE:-0}" == "1" ]]; then
    return
  fi

  local script_path="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
  local lib_path="${SCRIPT_DIR}/lib/lsu-common.sh"
  local remote_dir="${LSU_TMP}/self-update"

  mkdir -p "$remote_dir"

  if ! curl -sL --fail "${LSU_RAW_URL}/install.sh" -o "${remote_dir}/install.sh" \
    || ! curl -sL --fail "${LSU_RAW_URL}/lib/lsu-common.sh" -o "${remote_dir}/lsu-common.sh"
  then
    echo -e "${YELLOW}Unable to check for installer updates, continuing with the current version.${NC}"
    return
  fi

  if ! is_lsu_clone "$SCRIPT_DIR"; then
    bake_defaults "${remote_dir}/install.sh"
  fi

  if cmp -s "$script_path" "${remote_dir}/install.sh" \
    && cmp -s "$lib_path" "${remote_dir}/lsu-common.sh"
  then
    return
  fi

  if [[ "$UNATTENDED" == "1" ]] \
    || confirm "A new version of the installer is available, do you want to update?" Y
  then
    if is_lsu_clone "$SCRIPT_DIR"; then
      echo -e "${CYAN}Updating installer repository...${NC}"
      if ! run git -C "$SCRIPT_DIR" pull --ff-only origin "$LSU_BRANCH"; then
        echo -e "${YELLOW}Failed to update the installer repository (see ${LSU_LOGDIR}/install.log), continuing with the current version.${NC}"
        return
      fi
    else
      echo -e "${CYAN}Updating installer...${NC}"
      cp "${remote_dir}/install.sh" "$script_path"
      chmod +x "$script_path"
      cp "${remote_dir}/lsu-common.sh" "$lib_path"
    fi
    echo -e "${GREEN}Installer updated, restarting...${NC}"
    restart_installer "$script_path"
  fi

  echo -e "${YELLOW}Skipping installer update.${NC}"
  INSTALLER_OUTDATED=1
}

# Settings that outlive a run, kept in var/lsu.conf as KEY=value lines. It is
# read line by line rather than sourced, so it can never run anything.
conf_get() {
  [[ -f "$LSU_CONF" ]] || return 0
  sed -n "s/^$1=//p" "$LSU_CONF" | tail -n1
}

conf_set() {
  mkdir -p "$(dirname "$LSU_CONF")"
  if [[ -f "$LSU_CONF" ]]; then
    grep -v "^$1=" "$LSU_CONF" > "${LSU_CONF}.tmp" || true
  else
    : > "${LSU_CONF}.tmp"
  fi
  echo "$1=$2" >> "${LSU_CONF}.tmp"
  mv -f "${LSU_CONF}.tmp" "$LSU_CONF"
}

# KEY=default for each setting kept in var/lsu.conf.
LSU_SETTINGS=(
  LSU_WINE_REPO=srounce/wine
  LSU_WINE_VERSION=latest
  LSU_WINE_CHANNEL=prerelease
)

WINE_CHANNEL_EXPLICIT=0

# A setting given for this run, in the environment or baked in by an older
# installer, wins and is saved for later runs. Anything else comes from
# var/lsu.conf, then the default.
load_settings() {
  local setting key value

  LSU_CONF="${vardir}/lsu.conf"

  for setting in "${LSU_SETTINGS[@]}"; do
    key="${setting%%=*}"
    if [[ -n "${!key:-}" ]]; then
      conf_set "$key" "${!key}"
      [[ "$key" == "LSU_WINE_CHANNEL" ]] && WINE_CHANNEL_EXPLICIT=1
    else
      value="$(conf_get "$key")"
      printf -v "$key" '%s' "${value:-${setting#*=}}"
    fi
  done

  case "$LSU_WINE_CHANNEL" in
    release|prerelease) ;;
    *)
      echo -e "${RED}LSU_WINE_CHANNEL must be release or prerelease (found: ${LSU_WINE_CHANNEL}).${NC}"
      exit 1
      ;;
  esac

  if ! is_lsu_clone "$TARGET_DIR"; then
    bake_default LSU_WINE_REPO "" "${TARGET_DIR}/install.sh"
    bake_default LSU_WINE_VERSION "" "${TARGET_DIR}/install.sh"
  fi
}

# Stops a pin naming no release from being baked in. Offline runs still pass.
check_wine_pin() {
  [[ "$LSU_WINE_VERSION" == "latest" ]] && return

  local tag="$LSU_WINE_VERSION"
  local status
  status=$(curl -sI -o /dev/null -w '%{http_code}' \
    "https://github.com/${LSU_WINE_REPO}/releases/download/${tag}/wine-${tag}-amd64.tar.xz" \
    || true)

  if [[ "$status" == "404" ]]; then
    echo -e "${RED}Wine release ${tag} was not found in ${LSU_WINE_REPO}. Check LSU_WINE_VERSION, or set it to \"latest\" to follow the newest release.${NC}"
    exit 1
  fi
}

check_self_update

if [[ "$UNATTENDED" == "1" ]]; then
  printf "${CYAN}Install directory:${NC} %s\n" "${TARGET_DIR}"
else
  printf "${CYAN}Install directory: ${NC}"
  read -e -rp "" -i "$TARGET_DIR" TARGET_DIR
fi

WINEPREFIX="${TARGET_DIR}/pfx"
export WINEPREFIX

# Logging starts before the install directory is known, so move what has been
# written so far to the chosen directory and log there from now on.
mkdir -p "${TARGET_DIR}/log"
if [[ ! "${TARGET_DIR}/log" -ef "$LSU_LOGDIR" ]]; then
  mv -f "${LSU_LOGDIR}/install.log" "${LSU_LOGDIR}/prefix_setup.log" "${TARGET_DIR}/log/"
  LSU_LOGDIR="${TARGET_DIR}/log"
fi

if [[ "$TARGET_DIR" != "$SCRIPT_DIR" ]]; then
  mkdir -p "${TARGET_DIR}/lib"
  cp "${SCRIPT_DIR}/install.sh" "${TARGET_DIR}/install.sh"
  cp "${SCRIPT_DIR}/lib/lsu-common.sh" "${TARGET_DIR}/lib/lsu-common.sh"
  bake_defaults "${TARGET_DIR}/install.sh"
  chmod +x "${TARGET_DIR}/install.sh"
  echo -e "${GREEN}Installer copied to ${TARGET_DIR}/install.sh${NC}"
fi

bindir="${TARGET_DIR}/bin"
vardir="${TARGET_DIR}/var"
mkdir -p "${bindir}" "${vardir}"
# The names the library uses for them.
LSU_TARGET_DIR="$TARGET_DIR"
LSU_BINDIR="$bindir"
LSU_VARDIR="$vardir"

export PATH="${bindir}:$PATH"

load_settings
check_wine_pin

# Oldest winetricks verified against the sangria Wine builds.
MIN_WINETRICKS_VERSION=20260125

# Everything runs on the bundled Wine. A system Wine further down PATH would
# upgrade the prefix behind its back, so it is not accepted as a stand-in.
check_tools() {
  if [[ "$(command -v wine)" != "${bindir}/wine" ]]; then
    echo -e "${RED}The bundled Wine is missing from ${bindir}, re-run this script to install it.${NC}"
    exit 1
  fi

  local wine_version=$(wine --version 2> /dev/null)
  local wine_major=$(echo "$wine_version" | grep -oE '[0-9]+' | head -1)
  if [[ -z "$wine_major" ]] || (( wine_major < 11 )); then
    echo -e "${RED}Wine 11 or newer is required (found: ${wine_version:-unknown}). Re-run this script to reinstall the bundled Wine.${NC}"
    exit 1
  fi

  if ! run command -v winetricks; then
    echo -e "${RED}Winetricks is not installed, please install it with your package manager and re-run this script to proceed.${NC}"
    exit 1
  fi

  # Releases are tagged YYYYMMDD, and git builds append "-next".
  local winetricks_version
  winetricks_version=$(winetricks --version 2> /dev/null | grep -Eo '^[0-9]{8}' || true)
  run echo "winetricks version: ${winetricks_version:-unknown}"
  if [[ -z "$winetricks_version" ]] || (( winetricks_version < MIN_WINETRICKS_VERSION )); then
    echo -e "${RED}Winetricks ${MIN_WINETRICKS_VERSION} or newer is required (found: ${winetricks_version:-unknown} at $(command -v winetricks)). Update it with your package manager or run 'winetricks --self-update', then re-run this script to proceed.${NC}"
    exit 1
  fi

  pin_winetricks_wine_arch
}

install_winetricks() {
  local workdir=$(mktemp -d)

  mkdir "${vardir}/winetricks"

  curl -sL --fail "https://api.github.com/repos/winetricks/winetricks/releases/latest" \
    | grep "tarball_url" \
    | cut -d : -f 2,3 \
    | sed 's/[",]//g' \
    | xargs curl -sL --fail > "${workdir}/winetricks.tar.gz"
  tar -xzf "${workdir}/winetricks.tar.gz" -C "${vardir}/winetricks" --strip-components=1

  rm -rf "${workdir}"

  ln -s "${vardir}/winetricks/src/winetricks" "${bindir}/winetricks"
}

setup_prefix() {
  echo -e "${CYAN}Setting up prefix at $WINEPREFIX...${NC}"

  mkdir -p $WINEPREFIX

  # winemenubuilder as lsu_disable_menubuilder explains, until it has run.
  WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" wine wineboot.exe --init >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1
  # wineboot returns before the wineserver has written the registry to disk.
  wineserver -w

  echo -e "${GREEN}Prefix successfully created at $WINEPREFIX${NC}"
}

set_registry_entries() {
  echo -e "${CYAN}Updating registry${NC}"

  wine reg add 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  wine reg add 'HKLM\System\CurrentControlSet\Services\winebus' /v "Enable SDL"       /t REG_DWORD /d 0 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1
  wine reg add 'HKLM\System\CurrentControlSet\Services\winebus' /v "Map Controllers"  /t REG_DWORD /d 0 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1
  wine reg add 'HKLM\System\CurrentControlSet\Services\winebus' /v "DisableInput"     /t REG_DWORD /d 1 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\edgeupdate" /v Start /t REG_DWORD /d 4 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1
  wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\edgeupdatem" /v Start /t REG_DWORD /d 4 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  # Some distributions export where the Linux .Net lives for every session
  # (Arch's dotnet packages do). Wine passes that on, and Windows .Net then
  # looks for its runtime there and asks for .Net to be installed. Values set
  # here win over the Linux ones; they are where .Net installs itself anyway.
  wine reg add 'HKCU\Environment' /v DOTNET_ROOT     /t REG_SZ /d 'C:\Program Files\dotnet'       /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1
  wine reg add 'HKCU\Environment' /v DOTNET_ROOT_X64 /t REG_SZ /d 'C:\Program Files\dotnet'       /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1
  wine reg add 'HKCU\Environment' /v DOTNET_ROOT_X86 /t REG_SZ /d 'C:\Program Files (x86)\dotnet' /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  lsu_disable_menubuilder

  # Flush the registry to disk before winetricks reads the prefix.
  wineserver -w

  echo -e "${CYAN}Registry entries updated successfully${NC}"
}

check_prefix() {
  if [[ ! -d "$WINEPREFIX" ]] || [[ ! -d "$WINEPREFIX/drive_c" ]]; then
    setup_prefix
  fi

  set_registry_entries

  lsu_require_corefonts
}

WINECARTE_REPO="srounce/winecarte"

# The release tarball carries no version of its own, so the tag it came from is
# recorded next to the binaries it unpacks.
winecarte_installed_version() {
  local marker="${bindir}/.winecarte-version"

  [[ -f "${bindir}/winecarte-run" ]] || return 0

  if [[ -f "$marker" ]]; then
    cat "$marker"
  else
    echo "(unknown version)"
  fi
}

# Stable releases only by default. LSU_WINECARTE_VERSION pins an exact tag and
# LSU_WINECARTE_PRERELEASE takes the newest release of any kind, so testers can
# follow the alphas without editing the installer.
winecarte_target_version() {
  if [[ -n "${LSU_WINECARTE_VERSION:-}" ]]; then
    echo "${LSU_WINECARTE_VERSION}"
  elif [[ "${LSU_WINECARTE_PRERELEASE:-0}" == "1" ]]; then
    github_newest_tag "$WINECARTE_REPO"
  else
    github_latest_tag "$WINECARTE_REPO"
  fi
}

check_winecarte() {
  echo -e "${CYAN}Checking for existing Winecarte installation...${NC}"

  local installed target
  installed="$(winecarte_installed_version)"
  target="$(winecarte_target_version)"

  if [[ -n "$installed" ]] && [[ "$installed" == "$target" ]]; then
    echo -e "${GREEN}Winecarte ${installed} is installed and up to date.${NC}"
    return
  fi

  if [[ -n "$installed" ]] && [[ -z "$target" ]]; then
    echo -e "${YELLOW}Unable to determine the latest Winecarte release, keeping ${installed}.${NC}"
    return
  fi

  install_winecarte "$installed" "$target"
}

install_winecarte() {
  local installed="$1"
  local target="$2"
  local workdir=$(mktemp -d)
  local asset_url

  mkdir -p "${bindir}"

  if [[ -n "$installed" ]]; then
    echo -e "${CYAN}Updating Winecarte...${NC}"
  else
    echo -e "${CYAN}Installing Winecarte...${NC}"
  fi

  if [[ -z "$target" ]]; then
    echo -e "${RED}Unable to determine which Winecarte release to install, skipping.${NC}"
    rm -rf ${workdir}
    return
  fi

  asset_url="$(github_release_asset_url "$WINECARTE_REPO" "$target")"
  if [[ -z "$asset_url" ]]; then
    echo -e "${RED}No Winecarte release found for ${target}, skipping.${NC}"
    rm -rf ${workdir}
    return
  fi

  curl -sL --fail "$asset_url" > "${workdir}/winecarte.tar.gz"
  tar -xzf "${workdir}/winecarte.tar.gz" -C "${bindir}" --strip-components=1

  rm -rf ${workdir}

  echo "$target" > "${bindir}/.winecarte-version"

  if [[ -n "$installed" ]]; then
    echo -e "${GREEN}Winecarte ${target} successfully updated.${NC}"
  else
    echo -e "${GREEN}Winecarte ${target} successfully installed.${NC}"
  fi
}

WINE_DIR="${vardir}/wine"

# The tarball carries no version of its own, so the tag it came from is
# recorded next to the binaries it unpacks.
wine_installed_version() {
  local marker="${WINE_DIR}/.wine-version"

  [[ -f "${WINE_DIR}/bin/wine" ]] || return 0

  if [[ -f "$marker" ]]; then
    cat "$marker"
  else
    echo "(unknown version)"
  fi
}

# The newest tag on each channel, looked up once per run. The release channel
# takes full releases only; the prerelease channel takes the newest tag of any
# kind, so it moves onto a full release whenever that is the newest.
WINE_RELEASE_TAG=""
WINE_PRERELEASE_TAG=""
WINE_TAGS_LOOKED_UP=0

lookup_wine_tags() {
  (( WINE_TAGS_LOOKED_UP )) && return
  WINE_RELEASE_TAG="$(github_latest_tag "$LSU_WINE_REPO")"
  WINE_PRERELEASE_TAG="$(github_newest_tag "$LSU_WINE_REPO")"
  WINE_TAGS_LOOKED_UP=1
}

# LSU_WINE_VERSION pins an exact tag over either channel. Call
# lookup_wine_tags first; this runs in a subshell and cannot fill the cache.
wine_target_version() {
  if [[ "$LSU_WINE_VERSION" != "latest" ]]; then
    echo "${LSU_WINE_VERSION}"
  elif [[ "$LSU_WINE_CHANNEL" == "release" ]]; then
    echo "$WINE_RELEASE_TAG"
  else
    echo "$WINE_PRERELEASE_TAG"
  fi
}

# Asked on every interactive run, with the saved channel as the default, so a
# plain Enter keeps things as they are. A pin, or a channel given for this
# run, already answers it.
choose_wine_channel() {
  local installed default reply

  if [[ "$UNATTENDED" == "1" ]] || [[ "$WINE_CHANNEL_EXPLICIT" == "1" ]] \
    || [[ "$LSU_WINE_VERSION" != "latest" ]]
  then
    return
  fi

  lookup_wine_tags
  installed="$(wine_installed_version)"
  default=2
  [[ "$LSU_WINE_CHANNEL" == "release" ]] && default=1

  echo -e "${CYAN}Wine (sangria) channel${installed:+, ${installed} is installed}:${NC}"
  printf '  1) release      %s\n' "${WINE_RELEASE_TAG:-(unavailable)}"
  printf '  2) prerelease   %s\n' "${WINE_PRERELEASE_TAG:-(unavailable)}"

  while true; do
    printf "${CYAN}"
    read -rp "Choose a channel [${default}] " reply
    printf "${NC}"
    case "${reply:-$default}" in
      1) LSU_WINE_CHANNEL=release; break ;;
      2) LSU_WINE_CHANNEL=prerelease; break ;;
      *) echo "Please enter 1 or 2." ;;
    esac
  done

  conf_set LSU_WINE_CHANNEL "$LSU_WINE_CHANNEL"
}

# Everything else runs on this Wine, so it is always installed or updated.
check_wine() {
  echo -e "${CYAN}Checking for existing Wine installation...${NC}"

  local installed target

  [[ "$LSU_WINE_VERSION" == "latest" ]] && lookup_wine_tags
  installed="$(wine_installed_version)"
  target="$(wine_target_version)"

  install_wine "$installed" "$target"
}

# The release is a generic FHS build, so on NixOS it cannot run as-is: the
# ELF interpreter /lib64/ld-linux-x86-64.so.2 does not exist, and the
# unix-side modules cannot resolve system libraries (libX11, pulse, freetype,
# ...), which kills prefix boot with a kernel32 c0000135. The executables get
# their interpreter patched to the pinned glibc's loader, and the wrappers
# bake the needed lib dirs into LD_LIBRARY_PATH. Containers (steam-run) are
# not an option: they give every invocation a private /tmp, so each wine call
# spawns its own wineserver and they race each other over the shared prefix.
WINE_NIXPKGS_REV="dc5d91f840324650bac8c379428c7037a416959a"

# One entry per soname the release binaries reference (DT_NEEDED plus dlopen
# strings), resolved against the pinned revision above. Resolving from
# whatever wine the running system happens to have installed would track a lib
# set the release was never built against.
WINE_NIX_LIBS=(
  alsa-lib "cups^lib" "dbus^lib" "fontconfig^lib" freetype "glib^out"
  "gnutls^out" "gst_all_1.gstreamer^out" gst_all_1.gst-plugins-base
  "krb5^lib" libglvnd libgphoto2 "libpcap^lib" libpulseaudio libusb1 libv4l
  libxkbcommon ocl-icd "pcsclite^lib" SDL2 systemdLibs unixODBC vulkan-loader
  wayland xorg.libX11 xorg.libXcomposite xorg.libXcursor xorg.libXext
  xorg.libXfixes xorg.libXi xorg.libXinerama xorg.libXrandr xorg.libXrender
  xorg.libXxf86vm
)

# Resolves the pinned lib set plus glibc and patchelf, patches the release
# executables' interpreter to the pinned glibc's loader, and leaves the lib
# search path in WINE_NIX_LIB_PATH for the wrappers.
WINE_NIX_LIB_PATH=""

setup_wine_nix_runtime() {
  local flakeref="github:NixOS/nixpkgs/${WINE_NIXPKGS_REV}"
  local rootdir="${vardir}/.wine-libs"
  local installables=() a link root p f libpath="" loader="" patchelf=""

  command -v nix > /dev/null || return 1

  for a in "${WINE_NIX_LIBS[@]}" "glibc^out" patchelf; do
    installables+=("${flakeref}#${a}")
  done

  rm -rf "$rootdir"
  mkdir -p "${rootdir}/compat"

  # The out-links double as GC roots, so the store paths survive collection.
  nix --extra-experimental-features 'nix-command flakes' build \
    --out-link "${rootdir}/dep" "${installables[@]}" \
    >> "${LSU_LOGDIR}/install.log" 2>&1 || return 1

  for link in "${rootdir}"/dep*; do
    root="$(readlink -f "$link")"

    # glibc stays out of LD_LIBRARY_PATH: the patched loader finds its own
    # libc, and host programs spawned by wine keep the host's.
    if [[ -e "${root}/lib/ld-linux-x86-64.so.2" ]]; then
      loader="${root}/lib/ld-linux-x86-64.so.2"
      continue
    fi

    if [[ -x "${root}/bin/patchelf" ]]; then
      patchelf="${root}/bin/patchelf"
      continue
    fi

    p="${root}/lib"
    [[ -d "$p" ]] || continue
    libpath="${libpath:+$libpath:}$p"

    # The release links against Debian's libpcap soname, which nixpkgs does
    # not provide.
    if [[ -e "$p/libpcap.so.1" ]]; then
      ln -sf "$p/libpcap.so.1" "${rootdir}/compat/libpcap.so.0.8"
    fi
  done

  [[ -n "$libpath" && -n "$loader" && -n "$patchelf" ]] || return 1

  for f in "${WINE_DIR}/bin/"*; do
    [[ -f "$f" && "$(head -c 4 "$f")" == $'\x7fELF' ]] || continue
    run "$patchelf" --set-interpreter "$loader" "$f" || return 1
  done

  WINE_NIX_LIB_PATH="${rootdir}/compat:${libpath}"
}

install_wine_bin_entries() {
  local lib_path="" tool

  if [[ -e /etc/NIXOS ]]; then
    if ! setup_wine_nix_runtime; then
      echo -e "${RED}Failed to set up Wine's nix runtime (see ${LSU_LOGDIR}/install.log). Check that nix is available and you are online, then re-run this script.${NC}"
      exit 1
    fi
    lib_path="$WINE_NIX_LIB_PATH"
  fi

  for tool in wine wineserver wineboot winecfg msiexec regedit regsvr32 winepath winedbg; do
    # An earlier install may have left a symlink here; writing through it would
    # clobber the real binary.
    rm -f "${bindir}/${tool}"

    if [[ -z "$lib_path" ]]; then
      ln -s "${WINE_DIR}/bin/${tool}" "${bindir}/${tool}"
      continue
    fi

    cat > "${bindir}/${tool}" << EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH:+\$LD_LIBRARY_PATH:}${lib_path}"
exec "${WINE_DIR}/bin/${tool}" "\$@"
EOF
    chmod +x "${bindir}/${tool}"
  done
}

install_wine() {
  local installed="$1"
  local target="$2"
  local workdir=$(mktemp -d)
  local base_url tarball tool

  if [[ "$installed" == "$target" ]] && [[ -n "$installed" ]]; then
    echo -e "${GREEN}Wine ${installed} is already installed.${NC}"
    install_wine_bin_entries
    rm -rf ${workdir}
    return
  fi

  # An older Wine on a prefix a newer one has already upgraded can break the
  # programs in it, so going back takes an explicit yes.
  if [[ -n "$installed" ]] && [[ -n "$target" ]] \
    && [[ "$(lsu_wine_cmp "$installed" "$target" || true)" == "gt" ]]
  then
    echo -e "${YELLOW}Wine ${installed} is installed, which is newer than ${target}. Going back to an older Wine can break programs in a prefix the newer one has already upgraded.${NC}"
    if [[ "$UNATTENDED" == "1" ]] || ! confirm "Downgrade Wine to ${target}?" N; then
      echo -e "${YELLOW}Keeping Wine ${installed}.${NC}"
      install_wine_bin_entries
      rm -rf ${workdir}
      return
    fi
  fi

  if [[ -n "$installed" ]]; then
    echo -e "${CYAN}Updating Wine...${NC}"
  else
    echo -e "${CYAN}Installing Wine...${NC}"
  fi

  # Without wine nothing downstream can run, so an unresolved release is only
  # survivable when a previous install is already in place.
  if [[ -z "$target" ]]; then
    if [[ -n "$installed" ]]; then
      echo -e "${YELLOW}Unable to determine which Wine release to install, keeping ${installed}.${NC}"
      rm -rf ${workdir}
      return
    fi
    echo -e "${RED}Unable to determine which Wine release to install.${NC}"
    rm -rf ${workdir}
    exit 1
  fi

  tarball="wine-${target}-amd64.tar.xz"
  base_url="https://github.com/${LSU_WINE_REPO}/releases/download/${target}"

  if ! curl -sL --fail "${base_url}/${tarball}" -o "${workdir}/${tarball}" \
    || ! curl -sL --fail "${base_url}/SHA256SUMS" -o "${workdir}/SHA256SUMS"
  then
    echo -e "${RED}Failed to download Wine ${target} from ${base_url}${NC}"
    rm -rf ${workdir}
    exit 1
  fi

  if ! (cd "$workdir" && grep " ${tarball}\$" SHA256SUMS | run sha256sum -c); then
    echo -e "${RED}Checksum verification failed for Wine ${target}.${NC}"
    rm -rf ${workdir}
    exit 1
  fi

  rm -rf "${WINE_DIR}"
  mkdir -p "${WINE_DIR}"
  tar -xJf "${workdir}/${tarball}" -C "${WINE_DIR}" --strip-components=1

  rm -rf ${workdir}

  install_wine_bin_entries

  echo "$target" > "${WINE_DIR}/.wine-version"

  if [[ -n "$installed" ]]; then
    echo -e "${GREEN}Wine ${target} successfully updated.${NC}"
  else
    echo -e "${GREEN}Wine ${target} successfully installed.${NC}"
  fi
}

postinstall_winecarte() {
  echo -e "

---------------------------------------------

${YELLOW}Winecarte injection is now automatic!${NC}

The winecarte-run tool is now optional, you can remove it from your launch options.

---------------------------------------------

${YELLOW}Not receiving telemetry after an update?${NC}

Re-run this script in future to repair all desktop launcher entries in the prefix.

"
}

install_launch_wrapper() {
  mkdir -p "${bindir}"

  cat > "${bindir}/lsu-launch-wrapper" << EOF
#!/usr/bin/env bash

export WINEDEBUG=-all
export WINEPREFIX="${WINEPREFIX}"
export PATH="${bindir}:\$PATH"

WINEHUB_PIDFILE="${WINEPREFIX}/winehub.pid"

cleanup_stale_pids() {
  if [ -f "\$WINEHUB_PIDFILE" ] && ! kill -0 "\$(cat \$WINEHUB_PIDFILE)" 2>/dev/null; then
    rm -f "\$WINEHUB_PIDFILE"
  fi
}

cleanup_stale_pids

# The app is backgrounded only so the winehub manager can start alongside it;
# the wrapper still waits so stdout/stderr and the exit status behave as if wine
# were run directly.
if [ ! -f "\$WINEHUB_PIDFILE" ] || ! kill -0 "\$(cat \$WINEHUB_PIDFILE)" 2>/dev/null; then
  "${bindir}/wine" "\$@" &
  wine_pid=\$!
  "${bindir}/lsu-winehub-manager" &
  wait "\$wine_pid"
else
  exec "${bindir}/wine" "\$@"
fi
EOF
  chmod +x "${bindir}/lsu-launch-wrapper"

  cat > "${bindir}/lsu-winehub-manager" << EOF
#!/usr/bin/env bash

export WINEPREFIX="${WINEPREFIX}"
export PATH="${bindir}:\$PATH"

WINEHUB_PIDFILE="${WINEPREFIX}/winehub.pid"

export WINECARTE_WINE2LINUX_EXE="${TARGET_DIR}/bin/wine2linux.exe"
"${TARGET_DIR}/bin/winehub" > "${LSU_LOGDIR}/winehub.log" 2>&1 &
echo \$! > "\$WINEHUB_PIDFILE"

sleep 2
"${bindir}/wineserver" -w

kill "\$(cat \$WINEHUB_PIDFILE)" 2>/dev/null
rm -f "\$WINEHUB_PIDFILE"

# Launchers for any shortcuts the session's programs saved, updates included.
"${bindir}/lsu-update-launchers" >> "${LSU_LOGDIR}/launchers.log" 2>&1
EOF
  chmod +x "${bindir}/lsu-winehub-manager"

  cat > "${bindir}/lsu-update-launchers" << EOF
#!/usr/bin/env bash
# Writes launchers for the shortcuts programs in the prefix saved since the
# last run, pointed at the bundled Wine. Run when a wrapped session ends, and
# safe to run by hand; install.sh does the same on every run.

set -uo pipefail

export WINEPREFIX="${WINEPREFIX}"
export WINEDEBUG=-all
export PATH="${bindir}:\$PATH"

LSU_TARGET_DIR="${TARGET_DIR}"
LSU_BINDIR="${bindir}"
LSU_VARDIR="${vardir}"
LSU_LOGDIR="${LSU_LOGDIR}"

source "${TARGET_DIR}/lib/lsu-common.sh"

date
lsu_update_launchers --new
EOF
  chmod +x "${bindir}/lsu-update-launchers"
}

install_hidraw_device() {
  cat > "${bindir}/hidraw-device" << 'EOF'
#!/usr/bin/env bash
# Manages winebus's EnableHidraw list in the LSU prefix. See --help.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
WINE="$SCRIPT_DIR/wine"
WINESERVER="$SCRIPT_DIR/wineserver"
export WINEPREFIX="$(dirname "$SCRIPT_DIR")/pfx"
export WINEDEBUG=-all

KEY='HKLM\System\CurrentControlSet\Services\winebus'

die() { echo "error: $*" >&2; exit 1; }
usage() { echo "usage: ${0##*/} add|remove <VID> <PID>  (--help for details)" >&2; exit 2; }

help() {
    cat << HELP
usage: ${0##*/} add|remove <VID> <PID>

Adds or removes a USB device from winebus's EnableHidraw list so Wine
exposes it through hidraw instead of SDL. IDs are 4 hex digits, with or
without a 0x prefix (see lsusb).

Applies to the prefix at $WINEPREFIX
using the wine at $WINE

The change takes effect the next time the wineserver starts. If one is
already running you are asked whether to restart it, which closes every
program in the prefix.

Environment:
  NO_RESTART=1   never restart a running wineserver, and do not ask

Example:
  ${0##*/} add 0x1209 0xffb0
HELP
}

# 0x1234 / 1234 / 0X12AB -> 12ab, must be exactly 4 hex digits
normalise() {
    local v="${1,,}"
    v="${v#0x}"
    [[ "$v" =~ ^[0-9a-f]{4}$ ]] || die "'$1' is not a 4-digit hex ID"
    printf '%s' "$v"
}

case "${1:-}" in -h|--help|help) help; exit 0 ;; esac
[[ $# -eq 3 ]] || usage
ACTION="$1"
[[ "$ACTION" == add || "$ACTION" == remove ]] || usage
# Separate assignments so a bad ID stops the script (set -e only sees the last $(...))
VID="$(normalise "$2")"
PID="$(normalise "$3")"
ENTRY="$VID:$PID"

[[ -x "$WINE" ]] || die "no wine at $WINE"
[[ -f "$WINEPREFIX/system.reg" ]] || die "no Wine prefix at $WINEPREFIX"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# wineserver chdirs into /tmp/.wine-UID/server-<dev>-<inode> of its prefix
prefix_server_running() {
    local dir pid
    dir="$(printf '/tmp/.wine-%u/server-%x-%x' "$(id -u)" $(stat -c '%d %i' "$WINEPREFIX"))"
    for pid in $(pgrep -x wineserver); do
        [[ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" == "$dir" ]] && return 0
    done
    return 1
}

# Checked before this script starts wine itself, which leaves a server of its
# own behind for a few seconds.
server_was_running=0
prefix_server_running && server_was_running=1

# Wine's background processes keep pipes open after 'wine' exits, which makes
# $(wine ...) hang. Writing to a file avoids that; 'timeout' is a backstop.
wine_to_file() {
    local out="$1"; shift
    timeout 120 "$WINE" "$@" >"$out" 2>&1 </dev/null
}

# Prints the current EnableHidraw entries, one per line.
# Returns 1 if the value does not exist.
read_list() {
    local out="$TMP/query.txt" line
    wine_to_file "$out" reg query "$KEY" /v EnableHidraw || return 1
    line="$(grep -a 'REG_MULTI_SZ' "$out" | head -n1 | tr -d '\r')" || return 1
    line="${line#*REG_MULTI_SZ}"
    # reg.exe separates the strings with a literal backslash-zero
    printf '%s\n' "$line" | sed -e 's/\\0/\n/g' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

has_entry() { grep -qixF -- "$ENTRY"; }

entries=()
if list="$(read_list)"; then
    mapfile -t entries <<<"$list"
elif grep -qa '"EnableHidraw"' "$WINEPREFIX/system.reg"; then
    # The value is on disk but the query failed: stop rather than overwrite it.
    die "EnableHidraw exists in system.reg but 'wine reg query' failed; not touching it"
fi

present=0
((${#entries[@]})) && printf '%s\n' "${entries[@]}" | has_entry && present=1

if [[ "$ACTION" == add && $present == 1 ]]; then
    echo "$ENTRY already in EnableHidraw, nothing to do"
    exit 0
elif [[ "$ACTION" == remove && $present == 0 ]]; then
    echo "$ENTRY not in EnableHidraw, nothing to do"
    exit 0
fi

if [[ "$ACTION" == add ]]; then
    entries+=("$ENTRY")
else
    kept=()
    for e in "${entries[@]}"; do
        [[ "${e,,}" == "$ENTRY" ]] || kept+=("$e")
    done
    entries=("${kept[@]}")
fi

# One backup, never overwritten by later runs
[[ -e "$WINEPREFIX/system.reg.bak-hidraw" ]] || cp -p "$WINEPREFIX/system.reg" "$WINEPREFIX/system.reg.bak-hidraw"

if ((${#entries[@]})); then
    # reg.exe takes REG_MULTI_SZ strings joined by a literal backslash-zero
    data="$(printf '%s\\0' "${entries[@]}")"
    data="${data%\\0}"
    wine_to_file "$TMP/write.txt" reg add "$KEY" /v EnableHidraw /t REG_MULTI_SZ /d "$data" /f \
        || die "reg add failed: $(tail -n5 "$TMP/write.txt")"
    # Do not trust the exit code alone: read the value back
    list="$(read_list)" || die "reg add ran but EnableHidraw is unreadable"
    if [[ "$ACTION" == add ]]; then
        printf '%s\n' "$list" | has_entry || die "reg add ran but $ENTRY is not in EnableHidraw"
    else
        printf '%s\n' "$list" | has_entry && die "reg add ran but $ENTRY is still in EnableHidraw"
    fi
else
    # An empty list is the same as no value; delete it so winebus falls back to its default
    wine_to_file "$TMP/write.txt" reg delete "$KEY" /v EnableHidraw /f \
        || die "reg delete failed: $(tail -n5 "$TMP/write.txt")"
    read_list >/dev/null && die "reg delete ran but EnableHidraw still exists"
fi

if [[ "$ACTION" == add ]]; then
    echo "added $ENTRY (list now has ${#entries[@]} entries)"
else
    echo "removed $ENTRY (list now has ${#entries[@]} entries)"
fi

# winebus only reads the list when the server starts. A server this script
# started itself can be killed freely; one that was already there has the
# user's programs in it.
restart=1
if ((server_was_running)); then
    restart=0
    if [[ "${NO_RESTART:-0}" != 1 ]]; then
        echo "The wineserver for $WINEPREFIX is running. Restarting it now will" >&2
        echo "terminate every program running in it." >&2
        read -rp "Restart wineserver? [y/N] " answer
        [[ "${answer,,}" == y || "${answer,,}" == yes ]] && restart=1
    fi
fi

if ((restart)); then
    "$WINESERVER" -k || true
    echo "wineserver stopped, the change applies on next start"
else
    echo "the change will not take effect until wineserver is restarted:"
    echo "  WINEPREFIX=\"$WINEPREFIX\" \"$WINESERVER\" -k"
fi
EOF
  chmod +x "${bindir}/hidraw-device"
}

fix_desktop_launchers() {
  echo -e "${CYAN}Patching desktop launchers...${NC}"

  lsu_update_launchers

  echo -e "${CYAN}Desktop launchers successfully patched.${NC}"
}

# ---------------------------------------------------------------------------
# Modules: one script per program under modules/, listed in modules/index,
# plus any the user drops into modules/local/. modules/example.sh documents
# the contract. They are fetched into the install directory when first picked
# and refreshed on every run after that, like the installer itself.
# ---------------------------------------------------------------------------

MODULES_DIR="${TARGET_DIR}/modules"
LOCAL_MODULES_DIR="${MODULES_DIR}/local"

# What an install from before modules existed could have put in the prefix.
LEGACY_MODULES=(simhub crewchief pithouse)

MOD_IDS=()          # menu order
MOD_ORDER=()        # install order, dependencies first
declare -A MOD_NAME=() MOD_DESC=() MOD_FILE=() MOD_LOCAL=()
declare -A MOD_INSTALLED=() MOD_AVAILABLE=() MOD_DEPENDS=() MOD_MIN_WINE=()
declare -A MOD_SELECTED=() MOD_RESOLVED=() MOD_OK=() MOD_RESULT=()
MOD_FAILED=0
SOURCE_IS_CLONE=0

# Copies a file under modules/ into the install directory, from the clone this
# installer runs from, or else from the repository on GitHub. A failed
# download leaves any existing copy in place.
stage_module_file() {
  local path="$1" dest="${TARGET_DIR}/$1"

  mkdir -p "$(dirname "$dest")"

  if (( SOURCE_IS_CLONE )); then
    [[ -f "${SCRIPT_DIR}/${path}" ]] || return 1
    [[ "${SCRIPT_DIR}/${path}" -ef "$dest" ]] || cp "${SCRIPT_DIR}/${path}" "$dest"
    return 0
  fi

  if curl -sL --fail "${LSU_RAW_URL}/${path}" -o "${dest}.part"; then
    mv -f "${dest}.part" "$dest"
    return 0
  fi

  rm -f "${dest}.part"
  return 1
}

# Runs one verb of a module with the environment the contract promises. The
# results land in MOD_OUT; the module's exit status is returned. Bash itself
# exits 2 on a syntax error, so 2, 3 and 4 only count when the helper that
# exits with them also recorded its status; anything else is a failure.
module_run() {
  local id="$1" verb="$2" rc=0 expected=""

  MOD_OUT="$(mktemp -p "$LSU_TMP" "module-${id}-${verb}.XXXXXX")"

  env LSU_LIB="${TARGET_DIR}/lib/lsu-common.sh" \
    LSU_TARGET_DIR="$TARGET_DIR" LSU_BINDIR="$bindir" LSU_VARDIR="$vardir" \
    LSU_LOGDIR="$LSU_LOGDIR" WINEPREFIX="$WINEPREFIX" \
    LSU_RESULT_FILE="$MOD_OUT" UNATTENDED="$UNATTENDED" DEBUG="$DEBUG" \
    bash "${MOD_FILE[$id]}" "$verb" || rc=$?

  case "$rc" in
    2) expected=skipped ;;
    3) expected=unsupported ;;
    4) expected=unmet ;;
  esac

  if [[ -n "$expected" ]] && [[ "$(lsu_result_get "$MOD_OUT" status)" != "$expected" ]]; then
    rc=1
  fi

  return "$rc"
}

# meta and status are meant to be quiet, so whatever they print goes to the log.
module_query() {
  module_run "$1" "$2" >> "${LSU_LOGDIR}/install.log" 2>&1
}

add_module() {
  local id="$1" name="$2" desc="$3" file="$4" is_local="$5"

  if [[ ! "$id" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo -e "${YELLOW}Ignoring module '${id}': ids are lower case letters, digits, - and _.${NC}"
    return
  fi

  [[ -n "${MOD_NAME[$id]:-}" ]] || MOD_IDS+=("$id")
  MOD_NAME[$id]="${name:-$id}"
  MOD_DESC[$id]="$desc"
  MOD_FILE[$id]="$file"
  MOD_LOCAL[$id]="$is_local"
}

load_module_list() {
  local id name desc file

  if is_lsu_clone "$SCRIPT_DIR"; then
    SOURCE_IS_CLONE=1
  fi

  if ! stage_module_file modules/index; then
    if [[ -f "${MODULES_DIR}/index" ]]; then
      echo -e "${YELLOW}Unable to fetch the module list, using the one from the last run.${NC}"
    else
      echo -e "${YELLOW}Unable to fetch the module list, only local modules are available.${NC}"
    fi
  fi

  if [[ -f "${MODULES_DIR}/index" ]]; then
    while IFS=$'\t' read -r id name desc; do
      [[ -z "$id" || "$id" == \#* ]] && continue
      add_module "$id" "$name" "$desc" "${MODULES_DIR}/${id}.sh" 0
    done < "${MODULES_DIR}/index"
  fi

  for file in "${LOCAL_MODULES_DIR}"/*.sh; do
    [[ -f "$file" ]] || continue
    id="$(basename "$file" .sh)"
    MOD_FILE[$id]="$file"
    if ! module_query "$id" meta; then
      echo -e "${YELLOW}Ignoring local module ${file}: its meta verb failed, see ${LSU_LOGDIR}/install.log${NC}"
      unset 'MOD_FILE[$id]'
      continue
    fi
    add_module "$id" "$(lsu_result_get "$MOD_OUT" name)" \
      "$(lsu_result_get "$MOD_OUT" description)" "$file" 1
  done
}

# Modules fetched on an earlier run are refreshed, unless the installer update
# was declined: newer modules may need the newer library. The first run after
# the switch to modules has none yet, so it fetches the ones the old installer
# handled, keeps those that turn out to be installed, and drops the rest.
refresh_modules() {
  local id have_any=0
  local -a probed=()

  for id in "${MOD_IDS[@]}"; do
    (( MOD_LOCAL[$id] )) && continue
    [[ -f "${MOD_FILE[$id]}" ]] || continue
    have_any=1
    (( INSTALLER_OUTDATED )) && continue
    stage_module_file "modules/${id}.sh" \
      || echo -e "${YELLOW}Unable to update the ${MOD_NAME[$id]} module, using the one from the last run.${NC}"
  done

  if (( ! have_any )) && [[ -d "${WINEPREFIX}/drive_c" ]]; then
    for id in "${LEGACY_MODULES[@]}"; do
      [[ -n "${MOD_NAME[$id]:-}" ]] || continue
      stage_module_file "modules/${id}.sh" && probed+=("$id")
    done
  fi

  query_module_statuses

  for id in "${probed[@]}"; do
    if [[ -z "${MOD_INSTALLED[$id]:-}" ]] \
      && [[ ! "${SCRIPT_DIR}/modules/${id}.sh" -ef "${MOD_FILE[$id]}" ]]
    then
      rm -f "${MOD_FILE[$id]}"
    fi
  done
}

query_module_statuses() {
  local id rc

  echo -e "${CYAN}Checking installed modules...${NC}"

  for id in "${MOD_IDS[@]}"; do
    [[ -f "${MOD_FILE[$id]}" ]] || continue
    rc=0
    module_query "$id" status || rc=$?
    if (( rc != 0 )); then
      echo -e "${YELLOW}Unable to check ${MOD_NAME[$id]} (exit ${rc}), see ${LSU_LOGDIR}/install.log${NC}"
      continue
    fi
    MOD_INSTALLED[$id]="$(lsu_result_get "$MOD_OUT" installed)"
    MOD_AVAILABLE[$id]="$(lsu_result_get "$MOD_OUT" available)"
  done
}

module_status_text() {
  local installed="${MOD_INSTALLED[$1]:-}" available="${MOD_AVAILABLE[$1]:-}"

  if [[ -z "$installed" ]]; then
    echo "not installed"
  elif [[ -z "$available" ]]; then
    echo "${installed} installed"
  elif [[ "$installed" == "$available" ]]; then
    echo "${installed}, up to date"
  else
    echo "${installed} installed, ${available} available"
  fi
}

module_menu() {
  local reply choice id i mark name
  local -a choices

  while true; do
    echo
    echo -e "${CYAN}Programs to install or update:${NC}"
    i=0
    for id in "${MOD_IDS[@]}"; do
      i=$(( i + 1 ))
      mark=" "
      [[ -n "${MOD_SELECTED[$id]:-}" ]] && mark="x"
      name="${MOD_NAME[$id]}"
      (( MOD_LOCAL[$id] )) && name+=" (local)"
      printf "  %2d) [%s] %-24s %s\n" "$i" "$mark" "$name" "$(module_status_text "$id")"
      [[ -n "${MOD_DESC[$id]}" ]] && printf "           %s\n" "${MOD_DESC[$id]}"
    done

    printf "${CYAN}"
    read -rp "Numbers to toggle (e.g. 1 3), a for all, n for none, Enter to continue: " reply
    printf "${NC}"

    case "$reply" in
      "") return ;;
      [Aa]) for id in "${MOD_IDS[@]}"; do MOD_SELECTED[$id]=1; done ;;
      [Nn]) MOD_SELECTED=() ;;
      *)
        read -ra choices <<< "${reply//,/ }"
        for choice in "${choices[@]}"; do
          if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#MOD_IDS[@]} )); then
            id="${MOD_IDS[$(( choice - 1 ))]}"
            if [[ -n "${MOD_SELECTED[$id]:-}" ]]; then
              unset 'MOD_SELECTED[$id]'
            else
              MOD_SELECTED[$id]=1
            fi
          else
            echo -e "${YELLOW}Ignoring '${choice}', pick a number from 1 to ${#MOD_IDS[@]}.${NC}"
          fi
        done
        ;;
    esac
  done
}

# --modules picks exactly what it names. Otherwise what is installed starts
# selected, and an interactive run gets the menu to change that.
select_modules() {
  local id
  local -a ids

  if (( MODULES_ARG_SET )); then
    [[ "$MODULES_ARG" == "none" ]] && return
    read -ra ids <<< "${MODULES_ARG//,/ }"
    for id in "${ids[@]}"; do
      if [[ -z "${MOD_NAME[$id]:-}" ]]; then
        echo -e "${RED}Unknown module '${id}'. Available: ${MOD_IDS[*]:-none}${NC}"
        exit 1
      fi
      MOD_SELECTED[$id]=1
    done
    return
  fi

  for id in "${MOD_IDS[@]}"; do
    [[ -n "${MOD_INSTALLED[$id]:-}" ]] && MOD_SELECTED[$id]=1
  done

  if [[ "$UNATTENDED" != "1" ]] && (( ${#MOD_IDS[@]} )); then
    module_menu
  fi
}

# Fetches a picked module if this is its first run and reads its meta.
prepare_module() {
  local id="$1" api

  if [[ ! -f "${MOD_FILE[$id]}" ]] && ! stage_module_file "modules/${id}.sh"; then
    MOD_RESULT[$id]="failed: unable to download modules/${id}.sh"
    return 1
  fi

  if ! module_query "$id" meta; then
    MOD_RESULT[$id]="failed: its meta verb failed, see ${LSU_LOGDIR}/install.log"
    return 1
  fi

  if [[ "$(lsu_result_get "$MOD_OUT" id)" != "$id" ]]; then
    MOD_RESULT[$id]="failed: ${MOD_FILE[$id]} declares id '$(lsu_result_get "$MOD_OUT" id)'"
    return 1
  fi

  api="$(lsu_result_get "$MOD_OUT" api)"
  if [[ ! "$api" =~ ^[0-9]+$ ]] || (( api > LSU_API )); then
    MOD_RESULT[$id]="skipped: needs a newer install.sh"
    return 1
  fi

  MOD_DEPENDS[$id]="$(lsu_result_get "$MOD_OUT" depends)"
  MOD_MIN_WINE[$id]="$(lsu_result_get "$MOD_OUT" min_wine)"
}

# Depth first, so each module lands in MOD_ORDER after what it depends on.
# Returns 1 when the module cannot be installed, which its dependents inherit.
resolve_module() {
  local id="$1" from="$2" dep
  local -a deps

  case "${MOD_RESOLVED[$id]:-}" in
    ok) return 0 ;;
    failed) return 1 ;;
    visiting)
      echo -e "${RED}Module dependency loop between ${from} and ${id}.${NC}"
      return 1
      ;;
  esac

  if [[ -z "${MOD_NAME[$id]:-}" ]]; then
    echo -e "${RED}${MOD_NAME[$from]} depends on '${id}', which is not a known module.${NC}"
    return 1
  fi

  MOD_RESOLVED[$id]=visiting

  if ! prepare_module "$id"; then
    MOD_RESOLVED[$id]=failed
    return 1
  fi

  read -ra deps <<< "${MOD_DEPENDS[$id]//,/ }"
  for dep in "${deps[@]}"; do
    if ! resolve_module "$dep" "$id"; then
      MOD_RESULT[$id]="${MOD_RESULT[$id]:-skipped: needs ${MOD_NAME[$dep]:-$dep}}"
      MOD_RESOLVED[$id]=failed
      return 1
    fi
  done

  MOD_RESOLVED[$id]=ok
  MOD_SELECTED[$id]=1
  MOD_ORDER+=("$id")
}

resolve_modules() {
  local id

  for id in "${MOD_IDS[@]}"; do
    [[ -n "${MOD_SELECTED[$id]:-}" ]] || continue
    resolve_module "$id" "" || unset 'MOD_SELECTED[$id]'
  done
}

# Checked against the Wine about to be installed, so a module that needs a
# newer one can still have it this run: on the release channel the user is
# offered the prerelease channel when that would do.
check_module_wine_requirements() {
  local id min target rc

  [[ "$LSU_WINE_VERSION" == "latest" ]] && lookup_wine_tags

  for id in "${MOD_ORDER[@]}"; do
    min="${MOD_MIN_WINE[$id]:-}"
    [[ -n "$min" ]] || continue

    target="$(wine_target_version)"
    [[ -n "$target" ]] || target="$(wine_installed_version)"

    rc=0
    lsu_wine_at_least "$target" "$min" || rc=$?
    (( rc == 1 )) || continue

    echo -e "${YELLOW}${MOD_NAME[$id]} needs Wine ${min} or newer, and this run would install ${target}.${NC}"

    if [[ "$UNATTENDED" != "1" ]] && [[ "$LSU_WINE_VERSION" == "latest" ]] \
      && [[ "$LSU_WINE_CHANNEL" == "release" ]] && [[ -n "$WINE_PRERELEASE_TAG" ]] \
      && lsu_wine_at_least "$WINE_PRERELEASE_TAG" "$min" \
      && confirm "Switch to the prerelease channel (${WINE_PRERELEASE_TAG})?" Y
    then
      LSU_WINE_CHANNEL=prerelease
      conf_set LSU_WINE_CHANNEL "$LSU_WINE_CHANNEL"
      continue
    fi

    echo -e "${YELLOW}Skipping ${MOD_NAME[$id]}.${NC}"
    MOD_RESULT[$id]="skipped: needs Wine ${min} or newer"
    unset 'MOD_SELECTED[$id]'
  done
}

# Results go in MOD_RESULT for the summary. A module whose dependency did not
# end up installed is skipped.
run_modules() {
  local id dep rc previous version message blocked
  local -a deps

  for id in "${MOD_ORDER[@]}"; do
    [[ -n "${MOD_SELECTED[$id]:-}" ]] || continue

    blocked=""
    read -ra deps <<< "${MOD_DEPENDS[$id]//,/ }"
    for dep in "${deps[@]}"; do
      if [[ -z "${MOD_OK[$dep]:-}" ]]; then
        blocked="$dep"
        break
      fi
    done
    if [[ -n "$blocked" ]]; then
      MOD_RESULT[$id]="skipped: needs ${MOD_NAME[$blocked]}"
      continue
    fi

    echo
    echo -e "${MAGENTA}== ${MOD_NAME[$id]} ==${NC}"

    rc=0
    module_run "$id" install || rc=$?

    previous="${MOD_INSTALLED[$id]:-}"
    version="$(lsu_result_get "$MOD_OUT" version)"
    message="$(lsu_result_get "$MOD_OUT" message)"

    case "$rc" in
      0)
        MOD_OK[$id]=1
        if [[ -z "$previous" ]]; then
          MOD_RESULT[$id]="installed ${version}"
        elif [[ -n "$version" ]] && [[ "$version" != "$previous" ]]; then
          MOD_RESULT[$id]="updated ${previous} -> ${version}"
        else
          MOD_RESULT[$id]="reinstalled ${version:-$previous}"
        fi
        ;;
      2)
        [[ -n "$previous" ]] && MOD_OK[$id]=1
        MOD_RESULT[$id]="skipped${previous:+, ${previous} installed}"
        ;;
      3)
        MOD_RESULT[$id]="skipped: the module cannot install"
        ;;
      4)
        MOD_RESULT[$id]="skipped: ${message:-a requirement is not met}"
        ;;
      *)
        MOD_RESULT[$id]="failed${message:+: ${message}}"
        MOD_FAILED=1
        ;;
    esac
  done
}

fixup_modules() {
  local id rc

  for id in "${MOD_IDS[@]}"; do
    [[ -f "${MOD_FILE[$id]}" ]] || continue
    rc=0
    module_run "$id" fixup || rc=$?
    case "$rc" in
      0|2|3) ;;
      *) echo -e "${YELLOW}${MOD_NAME[$id]} could not repair its launchers (exit ${rc}), see ${LSU_LOGDIR}/install.log${NC}" ;;
    esac
  done
}

print_summary() {
  local id colour

  echo
  echo -e "${CYAN}Summary:${NC}"
  printf "  %-24s %s\n" "Wine (sangria)" "$(wine_installed_version)"
  printf "  %-24s %s\n" "Winecarte" "$(winecarte_installed_version)"

  for id in "${MOD_IDS[@]}"; do
    [[ -n "${MOD_RESULT[$id]:-}" ]] || continue
    case "${MOD_RESULT[$id]}" in
      failed*) colour="$RED" ;;
      skipped*) colour="$YELLOW" ;;
      *) colour="$GREEN" ;;
    esac
    printf "  %-24s ${colour}%s${NC}\n" "${MOD_NAME[$id]}" "${MOD_RESULT[$id]}"
  done
}

choose_wine_channel

load_module_list
refresh_modules
select_modules
resolve_modules
check_module_wine_requirements

check_wine

check_tools

check_prefix

check_winecarte

install_launch_wrapper

install_hidraw_device

run_modules

fix_desktop_launchers

fixup_modules

postinstall_winecarte

print_summary

exit "$MOD_FAILED"
