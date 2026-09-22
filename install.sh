#!/usr/bin/env bash

: "${LSU_BRANCH:="master"}"

# Run from a pipe (curl ... | bash) there is no script file to work from and
# stdin is the script itself, so fetch a copy, point stdin back at the
# terminal and continue from that file. The copy step below then lands it in
# the install directory.
if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  bootstrap_dir=$(mktemp -d)
  if ! curl -sL --fail \
    "https://raw.githubusercontent.com/srounce/linux-simracing-utils/${LSU_BRANCH}/install.sh" \
    -o "${bootstrap_dir}/install.sh"
  then
    echo "Unable to download the installer from branch ${LSU_BRANCH}." >&2
    exit 1
  fi
  { exec < /dev/tty; } 2> /dev/null || true
  exec env LSU_SKIP_UPDATE=1 LSU_BRANCH="$LSU_BRANCH" \
    TARGET_DIR="${TARGET_DIR:-$HOME/linux-simracing-utils}" \
    bash "${bootstrap_dir}/install.sh"
fi

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
  export WINEDEBUG=${WINEDEBUG:-+seh,+loaddll,+module}
else
  export WINEDEBUG=${WINEDEBUG:--all}
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

# A standalone installer keeps following the branch it was installed from,
# so the branch is written into its LSU_BRANCH default. Git clones are left
# alone: the checkout is the branch record and a modified file blocks pull.
bake_branch() {
  local branch=${LSU_BRANCH//&/\\&}
  branch=${branch//|/\\|}
  sed -i "s|^: \"\${LSU_BRANCH:=\"[^\"]*\"}\"\$|: \"\${LSU_BRANCH:=\"${branch}\"}\"|" "$1"
}

is_lsu_clone() {
  [[ "$(git -C "$1" remote get-url origin 2> /dev/null)" == *srounce/linux-simracing-utils* ]]
}

check_self_update() {
  if [[ "${LSU_SKIP_UPDATE:-0}" == "1" ]]; then
    return
  fi

  local script_path="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
  local remote_script=$(mktemp)

  if ! curl -sL --fail \
    "https://raw.githubusercontent.com/srounce/linux-simracing-utils/${LSU_BRANCH}/install.sh" \
    -o "$remote_script"
  then
    echo -e "${YELLOW}Unable to check for installer updates, continuing with the current version.${NC}"
    rm -f "$remote_script"
    return
  fi

  if ! is_lsu_clone "$SCRIPT_DIR"; then
    bake_branch "$remote_script"
  fi

  if cmp -s "$script_path" "$remote_script"; then
    rm -f "$remote_script"
    return
  fi

  if [[ "$UNATTENDED" == "1" ]] \
    || confirm "A new version of the installer is available, do you want to update?" Y
  then
    if is_lsu_clone "$SCRIPT_DIR"; then
      echo -e "${CYAN}Updating installer repository...${NC}"
      if ! run git -C "$SCRIPT_DIR" pull --ff-only origin "$LSU_BRANCH"; then
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
    exec env LSU_SKIP_UPDATE=1 LSU_BRANCH="$LSU_BRANCH" \
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
  mkdir -p "${TARGET_DIR}"
  cp "${SCRIPT_DIR}/install.sh" "${TARGET_DIR}/install.sh"
  bake_branch "${TARGET_DIR}/install.sh"
  chmod +x "${TARGET_DIR}/install.sh"
  echo -e "${GREEN}Installer copied to ${TARGET_DIR}/install.sh${NC}"
fi

bindir="${TARGET_DIR}/bin"
vardir="${TARGET_DIR}/var"
mkdir -p "${bindir}" "${vardir}"

export PATH="${bindir}:$PATH"

setup_silentwine() {
  export SILENT_WINE=$(mktemp)
  cat > $SILENT_WINE << EOF
#!/usr/bin/env bash
export WINEDEBUG=${WINEDEBUG:--all}
exec wine "\$@"
EOF
  chmod +x $SILENT_WINE
}

setup_silentwine

DOTNET_INDEX_DIR=$(mktemp -d)

trap cleanup_tools SIGINT
trap cleanup_tools SIGTERM
trap cleanup_tools EXIT

cleanup_tools() {
  rm -f "$SILENT_WINE"
  rm -rf "${DOTNET_INDEX_DIR}"
}

check_tools() {
  if ! run command -v wine; then
    echo -e "${RED}Wine is not available. Re-run this script and accept the Wine install step to proceed.${NC}"
    exit 1
  fi

  local wine_version=$(wine --version 2> /dev/null)
  local wine_major=$(echo "$wine_version" | grep -oE '[0-9]+' | head -1)
  if [[ -z "$wine_major" ]] || (( wine_major < 11 )); then
    echo -e "${RED}Wine 11 or newer is required (found: ${wine_version:-unknown}). Re-run this script and accept the Wine install step to proceed.${NC}"
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
  wine reg add 'HKLM\System\CurrentControlSet\Services\winebus' /v "DisableInput"     /t REG_DWORD /d 1 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\edgeupdate" /v Start /t REG_DWORD /d 4 /f
  wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\edgeupdatem" /v Start /t REG_DWORD /d 4 /f

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

# Winetricks pins old patches and has no aspnetcore verb. Apps that ask for an
# exact patch only roll forward onto newer ones, so these runtimes come from
# Microsoft's release index instead.
dotnet_index() {
  local channel="$1"
  local index="${DOTNET_INDEX_DIR}/${channel}.json"

  if [[ ! -f "$index" ]] && ! curl -sL --fail \
    "https://builds.dotnet.microsoft.com/dotnet/release-metadata/${channel}/releases.json" \
    -o "$index"
  then
    echo -e "${RED}Unable to fetch the .Net ${channel} release index.${NC}" >&2
    return 1
  fi

  echo "$index"
}

# Releases are listed newest first, so the first match is the current one.
dotnet_installer_url() {
  local channel="$1" bundle="$2" arch="$3" index

  index="$(dotnet_index "$channel")" || exit 1

  grep -m1 -o "https://[^\"]*/${bundle}-[0-9.]*-win-${arch}\.exe" "$index" || true
}

dotnet_installer_version() {
  local installer="${1##*/}" bundle="$2"

  installer="${installer#"${bundle}"-}"
  echo "${installer%-win-*}"
}

# Matches the exact patch, not the series, so old patches get updated.
check_dotnet_bundle() {
  local channel="$1" bundle="$2" framework="$3" label="$4"
  local logfile="${LSU_LOGDIR}/${bundle}-${channel}_install.log"
  local version workdir arch installer url

  url="$(dotnet_installer_url "$channel" "$bundle" x64)"

  if [[ -z "$url" ]]; then
    echo -e "${RED}No ${label} installer listed in the .Net ${channel} release index.${NC}"
    exit 1
  fi

  version="$(dotnet_installer_version "$url" "$bundle")"

  if [[ -d "${WINEPREFIX}/drive_c/Program Files/dotnet/shared/${framework}/${version}" ]]; then
    echo -e "${GREEN}Found existing ${label} ${version} install.${NC}"
    return
  fi

  workdir=$(mktemp -d)

  echo -e "${CYAN}Installing ${label} ${version}...${NC}"
  echo "" > "$logfile"

  # x86 first so the x64 build lands last, like the winetricks verbs.
  for arch in x86 x64; do
    url="$(dotnet_installer_url "$channel" "$bundle" "$arch")"
    installer="${url##*/}"

    if [[ -z "$url" ]]; then
      echo -e "${RED}No ${label} (${arch}) installer listed in the .Net ${channel} release index.${NC}"
      rm -rf "$workdir"
      exit 1
    fi

    if ! curl -sL --fail -o "${workdir}/${installer}" "$url"; then
      echo -e "${RED}Failed to download ${label} (${arch}) from ${url}${NC}"
      rm -rf "$workdir"
      exit 1
    fi

    if ! wine "${workdir}/${installer}" /quiet >> "$logfile" 2>&1; then
      echo -e "${RED}Installation failed for ${label} (${arch}):"
      tail -n 50 "$logfile"
      echo -e "Full log: ${logfile}${NC}"
      rm -rf "$workdir"
      exit 1
    fi
  done

  rm -rf "$workdir"
  echo -e "${GREEN}Successfully installed ${label} ${version}${NC}"
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

  check_dotnet_bundle 8.0 dotnet-runtime Microsoft.NETCore.App ".Net Runtime 8.0"

  check_dotnet_bundle 8.0 windowsdesktop-runtime Microsoft.WindowsDesktop.App ".Net Desktop Runtime 8.0"

  check_dotnet_bundle 8.0 aspnetcore-runtime Microsoft.AspNetCore.App "ASP.Net Core Runtime 8.0"

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

WINE_REPO="srounce/wine"
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

# All sangria releases are tagged prerelease, so the newest tag of any kind is
# the default. LSU_WINE_VERSION pins an exact tag.
wine_target_version() {
  if [[ -n "${LSU_WINE_VERSION:-}" ]]; then
    echo "${LSU_WINE_VERSION}"
  else
    github_newest_tag "$WINE_REPO"
  fi
}

check_wine() {
  echo -e "${CYAN}Checking for existing Wine installation...${NC}"

  local installed target
  installed="$(wine_installed_version)"
  target="$(wine_target_version)"

  if [[ "$UNATTENDED" == "1" ]]; then
    install_wine "$installed" "$target"
    return
  fi

  if confirm_component "Wine (sangria)" "$installed" "$target"; then
    install_wine "$installed" "$target"
  else
    echo -e "${YELLOW}Skipping Wine installation${NC}"
  fi
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
  base_url="https://github.com/${WINE_REPO}/releases/download/${target}"

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
  wine "\$@" &
  wine_pid=\$!
  "${bindir}/lsu-winehub-manager" &
  wait "\$wine_pid"
else
  exec wine "\$@"
fi
EOF
  chmod +x "${bindir}/lsu-launch-wrapper"

  cat > "${bindir}/lsu-winehub-manager" << EOF
#!/usr/bin/env bash

export WINEPREFIX="${WINEPREFIX}"
export PATH="${bindir}:\$PATH"

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

check_wine

check_tools

check_prefix

check_simhub

check_crewchief

check_winecarte

postinstall_winecarte

install_launch_wrapper

install_hidraw_device

fix_desktop_launchers
