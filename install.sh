#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

: "${DEBUG:="0"}"
: "${UNATTENDED:="0"}"
: "${TARGET_DIR:="$SCRIPT_DIR"}"

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

LSU_LOGDIR="${TARGET_DIR}/log"
mkdir -p ${LSU_LOGDIR}
echo "" > "${LSU_LOGDIR}/prefix_setup.log"
echo "" > "${LSU_LOGDIR}/install.log"

run() {
  {
    echo "---"
    printf '%q ' "$@"
    echo
    "$@"
  } >> "${LSU_LOGDIR}/install.log" 2>&1
}

if [[ $DEBUG == "1" ]]; then
  set -x
else
  export WINEDEBUG="-all"
fi

# $2 is the answer a bare Enter gives, and picks which letter the hint
# capitalises. Returns 0 for yes.
confirm() {
  local message="$1"
  local default="${2:-Y}"
  local hint="[Y/n]"
  local reply

  [[ "$default" == "N" ]] && hint="[y/N]"

  while true; do
    printf "${CYAN}"
    read -rp "${message} ${hint} " reply
    printf "${NC}"
    reply="${reply:-$default}"
    case "$reply" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

# Upstream version lookups. Each echoes an empty string when the release data
# cannot be fetched, which callers treat as "version unknown" rather than fatal.
github_latest_tag() {
  curl -sL --fail "https://api.github.com/repos/$1/releases/latest" 2> /dev/null \
    | grep -m1 '"tag_name"' \
    | cut -d '"' -f 4 \
    || true
}

# Unlike /releases/latest this includes prereleases, since /releases is ordered
# newest-first regardless of the prerelease flag.
github_newest_tag() {
  curl -sL --fail "https://api.github.com/repos/$1/releases" 2> /dev/null \
    | grep -m1 '"tag_name"' \
    | cut -d '"' -f 4 \
    || true
}

gitlab_latest_tag() {
  curl -sL --fail "https://gitlab.com/api/v4/projects/$1/repository/tags?per_page=1" 2> /dev/null \
    | grep -m1 '"name"' \
    | cut -d '"' -f 4 \
    || true
}

github_release_asset_url() {
  curl -sL --fail "https://api.github.com/repos/$1/releases/tags/$2" 2> /dev/null \
    | grep -m1 "browser_download_url" \
    | cut -d '"' -f 4 \
    || true
}

# Picks the wording and the safe default from what is installed against what is
# available upstream. An unknown upstream version degrades to repair wording
# rather than claiming the install is current.
confirm_component() {
  local name="$1" installed="$2" target="$3"

  if [[ -z "$installed" ]]; then
    echo -e "${CYAN}${name} is not installed.${NC}"
    confirm "Install ${name}?" Y
  elif [[ -z "$target" ]]; then
    echo -e "${CYAN}${name} ${installed} is installed.${NC}"
    confirm "Reinstall/repair ${name}?" N
  elif [[ "$installed" == "$target" ]]; then
    echo -e "${CYAN}${name} ${installed} is installed and up to date.${NC}"
    confirm "Reinstall/repair ${name}?" N
  else
    echo -e "${CYAN}${name} ${installed} is installed, ${target} is available.${NC}"
    confirm "Update ${name}?" Y
  fi
}

check_self_update() {
  if [[ "${LSU_SKIP_UPDATE:-0}" == "1" ]]; then
    return
  fi

  local script_path="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
  local remote_script=$(mktemp)

  if ! curl -sL --fail \
    "https://raw.githubusercontent.com/srounce/linux-simracing-utils/master/install.sh" \
    -o "$remote_script"
  then
    echo -e "${YELLOW}Unable to check for installer updates, continuing with the current version.${NC}"
    rm -f "$remote_script"
    return
  fi

  if cmp -s "$script_path" "$remote_script"; then
    rm -f "$remote_script"
    return
  fi

  if [[ "$UNATTENDED" == "1" ]] \
    || confirm "A new version of the installer is available, do you want to update?" Y
  then
    if [[ "$(git -C "$SCRIPT_DIR" remote get-url origin 2> /dev/null)" == *srounce/linux-simracing-utils* ]]; then
      echo -e "${CYAN}Updating installer repository...${NC}"
      if ! run git -C "$SCRIPT_DIR" pull --ff-only; then
        echo -e "${YELLOW}Failed to update the installer repository (see ${LSU_LOGDIR}/install.log), continuing with the current version.${NC}"
        rm -f "$remote_script"
        return
      fi
    else
      echo -e "${CYAN}Updating installer...${NC}"
      cp "$remote_script" "$script_path"
      chmod +x "$script_path"
    fi
    rm -f "$remote_script"
    echo -e "${GREEN}Installer updated, restarting...${NC}"
    exec env LSU_SKIP_UPDATE=1 \
      DEBUG="$DEBUG" UNATTENDED="$UNATTENDED" TARGET_DIR="$TARGET_DIR" \
      bash "$script_path"
  fi

  echo -e "${YELLOW}Skipping installer update.${NC}"
  rm -f "$remote_script"
}

check_self_update

if [[ "$UNATTENDED" == "1" ]]; then
  printf "${CYAN}Install directory:${NC} ${TARGET_DIR}"
else
  printf "${CYAN}Install directory: ${NC}"
  read -e -rp "" -i "$TARGET_DIR" TARGET_DIR
fi

WINEPREFIX="${TARGET_DIR}/pfx"
export WINEPREFIX

if [[ "$TARGET_DIR" != "$SCRIPT_DIR" ]]; then
  cp "${SCRIPT_DIR}/install.sh" "${TARGET_DIR}/install.sh"
  chmod +x "${TARGET_DIR}/install.sh"
  echo -e "${GREEN}Installer copied to ${TARGET_DIR}/install.sh${NC}"
fi

bindir="${TARGET_DIR}/bin"
vardir="${TARGET_DIR}/var"
mkdir -p "${bindir}" "${vardir}"

export PATH="${bindir}:$PATH"

setup_silentwine() {
  export SILENT_WINE=$(mktemp)
  cat > $SILENT_WINE << 'EOF'
#!/usr/bin/env bash
export WINEDEBUG=-all
exec wine "$@"
EOF
  chmod +x $SILENT_WINE
}

setup_silentwine

trap cleanup_tools SIGINT
trap cleanup_tools SIGTERM
trap cleanup_tools EXIT

cleanup_tools() {
  [ -e "$SILENT_WINE" ] && rm -r "$SILENT_WINE"
}

check_tools() {
  if ! run command -v wine; then
    echo -e "${RED}Wine is not installed, please install it with your package manager and re-run this script to proceed.${NC}"
    exit 1
  fi

  if ! run command -v winetricks; then
    echo -e "${RED}Winetricks is not installed, please install it with your package manager and re-run this script to proceed.${NC}"
    exit 1
  else
    if ! winetricks --version 2> /dev/null | run grep -E '^(2026|2025)'; then
      winetricks_version=$(winetricks --version 2> /dev/null | grep -Eo '^[0-9]+')
      echo -e "${RED}Winetricks version is out of date, please update it and re-run this script to proceed.${NC}"
      exit 1
    fi
  fi

  pin_winetricks_wine_arch
}

# Winetricks decides a 64-bit prefix is in new-wow64 mode by comparing the ELF
# class of the wine and wineserver binaries. Where wine ships as a wrapper
# script the read yields nothing, so it looks for the wine64 that wine 11 no
# longer has, ends up with an empty WINE_ARCH and dies on "cmd.exe /c echo
# '%AppData%' returned empty string". WINE64 is checked before any of that.
pin_winetricks_wine_arch() {
  [[ -n "${WINE64:-}" ]] && return

  if command -v wine64 > /dev/null 2>&1; then
    export WINE64="$(command -v wine64)"
  else
    export WINE64="$SILENT_WINE"
  fi
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

  WINEDLLOVERRIDES="mscoree,mshtml=" wine wineboot.exe --init >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  echo -e "${GREEN}Prefix successfully created at $WINEPREFIX${NC}"
}

set_registry_entries() {
  echo -e "${CYAN}Updating registry${NC}"

  wine reg add 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  wine reg add 'HKLM\System\CurrentControlSet\Services\winebus' /v "Enable SDL"       /t REG_DWORD /d 0 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1
  wine reg add 'HKLM\System\CurrentControlSet\Services\winebus' /v "Map Controllers"  /t REG_DWORD /d 0 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\edgeupdate" /v Start /t REG_DWORD /d 4 /f
  wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\edgeupdatem" /v Start /t REG_DWORD /d 4 /f

  wine reg delete "HKLM\System\CurrentControlSet\Services\winebus" /v "DisableInput"  /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1 || true
  wine reg delete "HKLM\System\CurrentControlSet\Services\winebus" /v "EnableHidraw"  /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1 || true
  wine reg delete "HKLM\System\CurrentControlSet\Services\winebus" /v "DisableHidraw" /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1 || true

  echo -e "${CYAN}Registry entries updated successfully${NC}"
}

check_dotnet() {
  echo -e "${CYAN}Checking for existing .Net 4.8 install...${NC}"

  DOTNET_DIR="$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319"

  if [[ ! -d "$DOTNET_DIR" ]] || \
    [[ ! -f "$DOTNET_DIR/mscorlib.dll" ]] || \
    [[ $(stat -c%s "$DOTNET_DIR/mscorlib.dll" 2> /dev/null) -lt 1000000 ]]
  then
    echo -e "${CYAN}Installing .Net 4.8...${NC}"
    if ! WINE=$SILENT_WINE winetricks -q dotnet48 > "${LSU_LOGDIR}/dotnet_install.log" 2>&1; then
      echo -e "${RED}Installation failed for .Net 4.8:"
      tail -n 50 "${LSU_LOGDIR}/dotnet_install.log"
      echo -e "Full log: ${LSU_LOGDIR}/dotnet_install.log${NC}"
      exit 1
    else
      echo -e "${GREEN}Successfully installed .Net 4.8${NC}"
    fi
  else
    echo -e "${GREEN}Found existing .Net 4.8 install.${NC}"
  fi
}

# Every dotnet runtime verb drops the same dotnet.exe, so only the shared
# framework directory and its version tell them apart. On a 64-bit prefix
# winetricks installs the x86 build alongside, under Program Files (x86);
# either build landing in Program Files is enough to call the verb done.
check_dotnet_runtime() {
  local verb="$1" framework="$2" version="$3" label="$4"

  if compgen -G "${WINEPREFIX}/drive_c/Program Files/dotnet/shared/${framework}/${version}.*" > /dev/null; then
    echo -e "${GREEN}Found existing ${label} install.${NC}"
    return
  fi

  echo -e "${CYAN}Installing ${label}...${NC}"
  if ! WINE=$SILENT_WINE winetricks -q "${verb}" > "${LSU_LOGDIR}/${verb}_install.log" 2>&1; then
    echo -e "${RED}Installation failed for ${label}:"
    tail -n 50 "${LSU_LOGDIR}/${verb}_install.log"
    echo -e "Full log: ${LSU_LOGDIR}/${verb}_install.log${NC}"
    exit 1
  fi
  echo -e "${GREEN}Successfully installed ${label}${NC}"
}

# Winetricks has no aspnetcore verb, so this runtime is fetched straight from
# Microsoft's release index. Apps built against 8.0.0 roll forward onto whatever
# 8.0 patch this resolves to.
aspnetcore8_target_version() {
  curl -sL --fail "https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json" 2> /dev/null \
    | grep -m1 '"latest-runtime"' \
    | cut -d '"' -f 4 \
    || true
}

check_aspnetcore8() {
  local label="ASP.Net Core Runtime 8.0"

  if compgen -G "${WINEPREFIX}/drive_c/Program Files/dotnet/shared/Microsoft.AspNetCore.App/8.0.*" > /dev/null; then
    echo -e "${GREEN}Found existing ${label} install.${NC}"
    return
  fi

  local version workdir arch installer url
  version="$(aspnetcore8_target_version)"

  if [[ -z "$version" ]]; then
    echo -e "${RED}Unable to determine which ${label} release to install.${NC}"
    exit 1
  fi

  workdir=$(mktemp -d)

  echo -e "${CYAN}Installing ${label} (${version})...${NC}"
  echo "" > "${LSU_LOGDIR}/aspnetcore8_install.log"

  # x86 first so the x64 build lands last and owns the shared install state on a
  # 64-bit prefix, which is the order the winetricks dotnet verbs use.
  for arch in x86 x64; do
    installer="aspnetcore-runtime-${version}-win-${arch}.exe"
    url="https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/${version}/${installer}"

    if ! curl -sL --fail -o "${workdir}/${installer}" "$url"; then
      echo -e "${RED}Failed to download ${label} (${arch}) from ${url}${NC}"
      rm -rf "$workdir"
      exit 1
    fi

    if ! wine "${workdir}/${installer}" /quiet >> "${LSU_LOGDIR}/aspnetcore8_install.log" 2>&1; then
      echo -e "${RED}Installation failed for ${label} (${arch}):"
      tail -n 50 "${LSU_LOGDIR}/aspnetcore8_install.log"
      echo -e "Full log: ${LSU_LOGDIR}/aspnetcore8_install.log${NC}"
      rm -rf "$workdir"
      exit 1
    fi
  done

  rm -rf "$workdir"
  echo -e "${GREEN}Successfully installed ${label} (${version})${NC}"
}

check_corefonts() {
  if [[ -f "${WINEPREFIX}/drive_c/windows/Fonts/corefonts.installed" ]]; then
    echo -e "${GREEN}Found existing corefonts install.${NC}"
    return
  fi

  echo -e "${CYAN}Updating prefix corefonts installation...${NC}"
  if ! WINE=$SILENT_WINE winetricks -q corefonts > "${LSU_LOGDIR}/corefonts_install.log" 2>&1; then
    echo -e "${RED}Installation failed for corefonts:"
    tail -n 50 "${LSU_LOGDIR}/corefonts_install.log"
    echo -e "Full log: ${LSU_LOGDIR}/corefonts_install.log${NC}"
    exit 1
  fi
  echo -e "${GREEN}Installation of corefonts is up to date.${NC}"
}

check_prefix() {
  if [[ ! -d "$WINEPREFIX" ]] || [[ ! -d "$WINEPREFIX/drive_c" ]]; then
    setup_prefix
  fi

  set_registry_entries
  
  check_dotnet

  check_dotnet_runtime dotnetcore3 Microsoft.NETCore.App 3.1 ".Net Core Runtime 3.1"

  check_dotnet_runtime dotnetcoredesktop3 Microsoft.WindowsDesktop.App 3.1 ".Net Core Desktop Runtime 3.1"

  check_dotnet_runtime dotnetdesktop8 Microsoft.WindowsDesktop.App 8.0 ".Net Desktop Runtime 8.0"

  check_aspnetcore8

  check_corefonts
}

# SimHub maintains this itself and it is verbatim the upstream release tag, so
# it stays accurate even for installs this script did not perform. reg query
# reports CRLF, and the stray carriage return would defeat the version compare.
simhub_installed_version() {
  wine reg query 'HKCU\Software\SimHub' /v LastInstalledVersion 2> /dev/null \
    | tr -d '\r' \
    | awk '/LastInstalledVersion/ { print $NF }' \
    || true
}

check_simhub() {
  echo -e "${CYAN}Checking for existing SimHub installation...${NC}"

  local installed target
  installed="$(simhub_installed_version)"
  target="$(github_latest_tag SHWotever/simhub)"

  if [[ "$UNATTENDED" == "1" ]]; then
    install_simhub "$installed"
    return
  fi

  if confirm_component "SimHub" "$installed" "$target"; then
    install_simhub "$installed"
  else
    echo -e "${YELLOW}Skipping SimHub installation${NC}"
  fi
}

install_simhub() {
  local workdir=$(mktemp -d)

  if [[ -n "$1" ]]; then
    echo -e "${CYAN}Updating SimHub...${NC}"
  else
    echo -e "${CYAN}Installing SimHub...${NC}"
  fi

  curl -sL --fail "https://api.github.com/repos/SHWotever/simhub/releases/latest" \
    | grep "browser_download_url" \
    | cut -d : -f 2,3 \
    | tr -d \" \
    | xargs curl -sL --fail > "${workdir}/simhub.zip"
  unzip -q -d "${workdir}/simhub" "${workdir}/simhub.zip"
  wine ${workdir}/simhub/SimHubSetup*.exe /TASKS="desktopicon,enablemotion,dashsandoverlays" /RESTARTAPPLICATIONS /VERYSILENT \
    >> "${LSU_LOGDIR}/simhub_setup.log" 2>&1
  rm -rf ${workdir}

  if [[ -n "$1" ]]; then
    echo -e "${GREEN}SimHub successfully updated.${NC}"
  else
    echo -e "${GREEN}SimHub successfully installed.${NC}"
  fi
}

CREWCHIEF_DIR="drive_c/CrewChiefV4"
CREWCHIEF_GITLAB_PROJECT="mr_belowski%2FCrewChiefV4"

# The msi is served unversioned, so the tag that was current at install time is
# recorded alongside the install rather than read back out of it.
crewchief_installed_version() {
  local marker="${WINEPREFIX}/${CREWCHIEF_DIR}/.crewchief-version"

  [[ -f "${WINEPREFIX}/${CREWCHIEF_DIR}/CrewChiefV4.exe" ]] || return 0

  if [[ -f "$marker" ]]; then
    cat "$marker"
  else
    echo "(unknown version)"
  fi
}

check_crewchief() {
  echo -e "${CYAN}Checking for existing CrewChief installation...${NC}"

  local installed target
  installed="$(crewchief_installed_version)"
  target="$(gitlab_latest_tag "$CREWCHIEF_GITLAB_PROJECT")"

  if [[ "$UNATTENDED" == "1" ]]; then
    install_crewchief "$installed" "$target"
    return
  fi

  if confirm_component "CrewChief" "$installed" "$target"; then
    install_crewchief "$installed" "$target"
  else
    echo -e "${YELLOW}Skipping CrewChief installation${NC}"
  fi
}

install_crewchief() {
  local workdir=$(mktemp -d)

  if [[ -n "$1" ]]; then
    echo -e "${CYAN}Updating CrewChief...${NC}"
  else
    echo -e "${CYAN}Installing CrewChief...${NC}"
  fi

  if [[ -f "$SCRIPT_DIR/CrewChiefV4.msi" ]]; then
    cp "${SCRIPT_DIR}/CrewChiefV4.msi" "${workdir}/CrewChiefV4.msi"
  fi

  if [[ ! -f "${workdir}/CrewChiefV4.msi" ]]; then
    curl -sL --fail \
      -o "${workdir}/CrewChiefV4.msi" \
      -H 'Referer: https://thecrewchief.org' \
      "https://thecrewchief.org/downloads/CrewChiefV4.msi"
  fi

  wine msiexec /i "${workdir}/CrewChiefV4.msi" /qn /l*v "$LSU_LOGDIR/cc_install.log" \
    INSTALLFOLDER='C:\CrewChiefV4'

  rm -rf ${workdir}

  if [[ ! -f "${WINEPREFIX}/${CREWCHIEF_DIR}/CrewChiefV4.exe" ]]; then
    echo -e "${RED}Installation failed for CrewChief, see ${LSU_LOGDIR}/cc_install.log${NC}"
    exit 1
  fi

  # Without a known tag the marker would keep asserting a version this install
  # can no longer vouch for.
  if [[ -n "$2" ]]; then
    echo "$2" > "${WINEPREFIX}/${CREWCHIEF_DIR}/.crewchief-version"
  else
    rm -f "${WINEPREFIX}/${CREWCHIEF_DIR}/.crewchief-version"
  fi

  if [[ -n "$1" ]]; then
    echo -e "${GREEN}CrewChief successfully updated.${NC}"
  else
    echo -e "${GREEN}CrewChief successfully installed.${NC}"
  fi
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

  if [[ "$UNATTENDED" == "1" ]]; then
    install_winecarte "$installed" "$target"
    return
  fi

  if confirm_component "Winecarte" "$installed" "$target"; then
    install_winecarte "$installed" "$target"
  else
    echo -e "${YELLOW}Skipping Winecarte installation${NC}"
  fi
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

postinstall_winecarte() {
  echo -e "
${CYAN}Winecarte setup${NC}

To receive telemetry in SimHub and CrewChief, each game needs to be launched
via winecarte-run. This is done through Steam launch options.

For each supported game:

  1. Right-click the game in your Steam library and select ${CYAN}Properties${NC}
  2. Go to the ${CYAN}General${NC} tab and find the ${CYAN}Launch Options${NC} field
  3. Enter the following:

     ${GREEN}${TARGET_DIR}/bin/winecarte-run %command%${NC}

  The %command% part is required -- it tells Steam to launch the game itself
  after winecarte-run has set up the shared memory bridge.
"
}

install_launch_wrapper() {
  mkdir -p "${bindir}"

  cat > "${bindir}/lsu-launch-wrapper" << EOF
#!/usr/bin/env bash

export WINEDEBUG=-all
export WINEPREFIX="${WINEPREFIX}"

WINEHUB_PIDFILE="${WINEPREFIX}/winehub.pid"

cleanup_stale_pids() {
  if [ -f "\$WINEHUB_PIDFILE" ] && ! kill -0 "\$(cat \$WINEHUB_PIDFILE)" 2>/dev/null; then
    rm -f "\$WINEHUB_PIDFILE"
  fi
}

cleanup_stale_pids

if [ ! -f "\$WINEHUB_PIDFILE" ] || ! kill -0 "\$(cat \$WINEHUB_PIDFILE)" 2>/dev/null; then
  wine "\$@" &
  "${bindir}/lsu-winehub-manager" &
else
  wine "\$@"
fi
EOF
  chmod +x "${bindir}/lsu-launch-wrapper"

  cat > "${bindir}/lsu-winehub-manager" << EOF
#!/usr/bin/env bash

export WINEPREFIX="${WINEPREFIX}"

WINEHUB_PIDFILE="${WINEPREFIX}/winehub.pid"

export WINECARTE_WINE2LINUX_EXE="${TARGET_DIR}/bin/wine2linux.exe"
"${TARGET_DIR}/bin/winehub" &
echo \$! > "\$WINEHUB_PIDFILE"

sleep 2
wineserver -w

kill "\$(cat \$WINEHUB_PIDFILE)" 2>/dev/null
rm -f "\$WINEHUB_PIDFILE"
EOF
  chmod +x "${bindir}/lsu-winehub-manager"
}

fix_desktop_launchers() {
  echo -e "${CYAN}Patching desktop launchers...${NC}"

  patch_desktop_launchers_in "$HOME/.local/share/applications/wine/Programs"
  patch_desktop_launchers_in "$(xdg_desktop_dir)"

  local has_run="0"

  if run command -v update-desktop-database; then
    run update-desktop-database ~/.local/share/applications 2>/dev/null
    has_run="1"
  fi
  if run command -v kbuildsycoca6; then
    run kbuildsycoca6 --noincremental 2>/dev/null
    has_run="1"
  fi
  if run command -v kbuildsycoca5; then
    run kbuildsycoca5 --noincremental 2>/dev/null
    has_run="1"
  fi
  if run command -v xdg-desktop-menu; then
    run xdg-desktop-menu forceupdate 2>/dev/null
    has_run="1"
  fi

  if [[ $has_run == "0" ]]; then
    echo -e "${YELLOW}WARNING: Unsure how to refresh your desktop launcher entry cache, please do it manually.${NC}"
  fi
  
  echo -e "${CYAN}Desktop launchers successfully patched.${NC}"
}

xdg_desktop_dir() {
  local desktop_dir
  desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  if [[ -z "$desktop_dir" || "$desktop_dir" == "$HOME" ]]; then
    desktop_dir="$HOME/Desktop"
  fi
  printf '%s' "$desktop_dir"
}

# A launcher is ours if wine generated it against our prefix, or if an earlier
# install already wrapped it. Matching wrapped entries as well means a reinstall
# to a different TARGET_DIR repoints them.
is_lsu_launcher() {
  local launcher_path="$1"

  grep -qE "^Exec=.*(${WINEPREFIX}|lsu-launch-wrapper)" "$launcher_path"
}

# Wine writes Exec lines of the form:
#   Exec=env "WINEPREFIX=<prefix>" wine "C:\\Program Files\\App\\App.exe"
# Everything ahead of the Windows path is replaced by the launch wrapper so the
# app runs under winehub.
patch_desktop_launcher() {
  local launcher_path="$1"

  sed -i "s|^Exec=.* \\(\"\\)\\?C:|Exec=${bindir}/lsu-launch-wrapper \"C:|" "$launcher_path"
}

# Launchers are discovered by scanning rather than named individually, so every
# entry the wine installers generate is covered.
patch_desktop_launchers_in() {
  local root="$1"
  local launcher_path

  [[ -d "$root" ]] || return 0

  shopt -s globstar

  for launcher_path in "$root"/**/*.desktop; do
    [[ -f "$launcher_path" ]] || continue

    if is_lsu_launcher "$launcher_path"; then
      patch_desktop_launcher "$launcher_path"
    fi
  done
}

check_tools

check_prefix

check_simhub

check_crewchief

check_winecarte

postinstall_winecarte

install_launch_wrapper

fix_desktop_launchers
