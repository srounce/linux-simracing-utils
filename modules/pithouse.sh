#!/usr/bin/env bash
#
# MOZA Pit House (https://mozaracing.com/downloads) module for
# linux-simracing-utils. See modules/example.sh for how modules work.

for LSU_LIB in "${LSU_LIB:-}" "$(dirname -- "${BASH_SOURCE[0]}")"/{..,../..}/lib/lsu-common.sh; do
  [[ -f "$LSU_LIB" ]] && break
done
# shellcheck source=../lib/lsu-common.sh
source "$LSU_LIB" || { echo "lib/lsu-common.sh not found, run install.sh first." >&2; exit 1; }

LSU_MODULE_ID="pithouse"
LSU_MODULE_NAME="MOZA Pit House"
LSU_MODULE_DESCRIPTION="Settings and firmware for MOZA wheelbases, wheels and pedals"
LSU_MODULE_DEPENDS=""
LSU_MODULE_MIN_WINE="sangria-11.18-pre3"

lsu_module_init

LOGFILE="${LSU_LOGDIR}/pithouse_install.log"

PITHOUSE_DIR="${WINEPREFIX}/drive_c/Program Files (x86)/MOZA Pit House"

# The download page MOZA's support site links to. It is an HTML page that
# embeds a signed, expiring link to the installer package.
PITHOUSE_DOWNLOAD_PAGE="https://ace.gudsen.vip/racing/cdn/indirect/8a9851db-46a4-4f1a-a37e-9a2c0391473e"

# The package's own Launcher.ps1 reads its repository list from here, by
# channel. Wine's powershell.exe is a stub that runs nothing, so this script
# does the launcher's job itself.
PITHOUSE_VERSION_LIST="https://api.gudsen.vip/backend-service/backend/jsonManage/findByName?name=/Pit_House/Version_List.json"
: "${LSU_PITHOUSE_CHANNEL:="release"}"

# Pit House records its installed components in components.xml, so this stays
# accurate after Pit House updates itself.
pithouse_installed_version() {
  [[ -f "${PITHOUSE_DIR}/MOZA Pit House.exe" ]] || return 0

  local version
  version="$(sed -n '/<Name>rs21\.pc\.pit_house<\/Name>/,/<\/Package>/p' \
    "${PITHOUSE_DIR}/components.xml" 2> /dev/null \
    | grep -o -m1 '<Version>[^<]*' \
    | cut -d '>' -f 2 \
    || true)"

  echo "${version:-(unknown version)}"
}

# The list is a JSON document escaped into the "jsonStr" field of the API
# response. Repository URLs never contain a backslash, so the escaped quotes
# delimit them.
pithouse_repo_urls() {
  local channel="${LSU_PITHOUSE_CHANNEL//./\\.}"

  curl -sL --fail "$PITHOUSE_VERSION_LIST" 2> /dev/null \
    | grep -o "\\\\\"${channel}\\\\\":{\\\\\"repository_urls\\\\\":\[\(\\\\\"[^\\\\]*\\\\\",\?\)*\]" \
    | grep -o 'https://[^\\]*' \
    || true
}

pithouse_target_version() {
  grep -o -m1 'rs21\.pc\.pit_house/[^/]*$' <<< "$1" | cut -d / -f 2 || true
}

module_status() {
  lsu_result installed "$(pithouse_installed_version)"
  lsu_result available "$(pithouse_target_version "$(pithouse_repo_urls)")"
}

# Pit House updates itself when it starts, so an install that is already
# there is only ever repaired, never updated, and that always asks first: a
# repair removes the program folder.
module_install() {
  local installed target repos

  installed="$(pithouse_installed_version)"
  repos="$(pithouse_repo_urls)"
  target="$(pithouse_target_version "$repos")"

  if [[ -n "$installed" ]]; then
    if [[ "$UNATTENDED" == "1" ]]; then
      lsu_skip "MOZA Pit House ${installed} is installed and updates itself, skipping."
    fi

    if [[ -n "$target" ]] && [[ "$installed" != "$target" ]]; then
      echo -e "${CYAN}MOZA Pit House ${installed} is installed, ${target} is available.${NC}"
      echo -e "${CYAN}Pit House updates itself when it starts, so a reinstall is only needed if that fails.${NC}"
    else
      echo -e "${CYAN}MOZA Pit House ${installed} is installed.${NC}"
    fi
    echo -e "${CYAN}A reinstall removes the Pit House program folder first. Settings and presets in Documents are not touched.${NC}"
    confirm "Reinstall/repair MOZA Pit House?" N \
      || lsu_skip "Skipping MOZA Pit House installation"
  elif [[ "$LSU_STANDALONE" == "1" ]] && [[ "$UNATTENDED" != "1" ]]; then
    echo -e "${CYAN}MOZA Pit House is not installed.${NC}"
    confirm "Install MOZA Pit House?" Y \
      || lsu_skip "Skipping MOZA Pit House installation"
  fi

  echo "" > "$LOGFILE"

  lsu_require_dotnet_legacy_set

  if [[ -n "$installed" ]]; then
    remove_pithouse
  fi

  install_pithouse "$repos"

  lsu_result version "$(pithouse_installed_version)"

  # install.sh runs this again later anyway; a standalone run has only this.
  module_fixup

  echo -e "
${YELLOW}Pit House only lists a MOZA device once Wine maps it to a COM port.${NC}
If a connected device does not show up, check that it appears in
${WINEPREFIX}/dosdevices as a comN link.
"
}

# Matched on the install path and prefix, since other programs (the MOZA
# SimHub plugin's stub, other prefixes) can run an exe of the same name.
pithouse_running() {
  local pid

  for pid in $(pgrep -f 'MOZA Pit House\\MOZA Pit House\.exe' || true); do
    if tr '\0' '\n' < "/proc/${pid}/environ" 2> /dev/null \
      | grep -qxF "WINEPREFIX=${WINEPREFIX}"
    then
      return 0
    fi
  done

  return 1
}

# The Qt installer refuses a target directory that already holds an install,
# so a reinstall goes through Pit House's own maintenance tool first. The tool
# finishes deleting the folder after it exits, hence the wait.
remove_pithouse() {
  local i

  if pithouse_running; then
    lsu_fail "MOZA Pit House is running. Close it and re-run this script."
  fi

  echo -e "${CYAN}Removing the existing MOZA Pit House install...${NC}"

  wine "${PITHOUSE_DIR}/MaintenanceTool.exe" --default-answer --confirm-command purge \
    >> "$LOGFILE" 2>&1 || true

  for i in {1..60}; do
    [[ -e "${PITHOUSE_DIR}" ]] || return 0
    sleep 1
  done

  lsu_fail "The existing MOZA Pit House install could not be removed, see ${LOGFILE}"
}

# The package is an NSIS self-extractor that unpacks the Qt installer into
# %TEMP% and hands over to Launcher.ps1. Under Wine the hand-over does nothing,
# so all that is used here is the unpacked Qt installer.
extract_pithouse_package() {
  local package="$1" tempdir dir

  for tempdir in "${WINEPREFIX}"/drive_c/users/*/AppData/Local/Temp; do
    rm -rf "${tempdir}"/MOZA_Pit_House_Installer_Package*
  done

  # The exit status reflects the skipped hand-over, not the extraction, so the
  # unpacked files are checked instead.
  wine "$package" /S >> "$LOGFILE" 2>&1 || true

  for dir in "${WINEPREFIX}"/drive_c/users/*/AppData/Local/Temp/MOZA_Pit_House_Installer_Package*; do
    if [[ -f "${dir}/MOZA_Pit_House_Installer.exe" ]]; then
      echo "$dir"
      return
    fi
  done
}

install_pithouse() {
  local repos="$1"
  local package_url package_dir repo_list script_path

  echo -e "${CYAN}Installing MOZA Pit House...${NC}"

  package_url="$(curl -sL --fail "$PITHOUSE_DOWNLOAD_PAGE" 2> /dev/null \
    | grep -o -m1 "https://cdn\.gudsen\.vip/[^\"' )]*\.exe[^\"' )]*" \
    | head -n1 \
    || true)"

  if [[ -z "$package_url" ]]; then
    lsu_fail "Unable to find the MOZA Pit House download link on ${PITHOUSE_DOWNLOAD_PAGE}"
  fi

  if ! curl -sL --fail -o "${LSU_TMP}/pithouse_package.exe" "$package_url"; then
    lsu_fail "Failed to download MOZA Pit House from ${package_url}"
  fi

  package_dir="$(extract_pithouse_package "${LSU_TMP}/pithouse_package.exe")"

  if [[ -z "$package_dir" ]]; then
    lsu_fail "Failed to unpack the MOZA Pit House package, see ${LOGFILE}"
  fi

  # Same fallback as Launcher.ps1: the list shipped in the package.
  if [[ -z "$repos" ]]; then
    echo -e "${YELLOW}Unable to fetch MOZA's repository list, using the one shipped with the installer.${NC}"
    repos="$(grep -o 'https://[^"]*' "${package_dir}/DefaultRepoUrls.json" || true)"
  fi

  if [[ -z "$repos" ]]; then
    lsu_fail "No MOZA Pit House repositories found for channel ${LSU_PITHOUSE_CHANNEL}."
  fi

  repo_list="$(paste -sd , <<< "$repos")"

  # Launcher.ps1 hands the installer this control script, which tells Pit
  # House which firmware channel it was installed from.
  script_path="${package_dir}/MOZA_Installer_script.qs"
  cat > "$script_path" << QS
function Controller()
{
    installer.setValue("experimentalFirmwareCommand", "${LSU_PITHOUSE_CHANNEL}")
}
QS

  echo -e "${CYAN}Downloading and installing Pit House components, this can take several minutes...${NC}"

  if ! wine "${package_dir}/MOZA_Pit_House_Installer.exe" \
    -d --no-proxy \
    --set-temp-repository "$repo_list" \
    --script "Z:${script_path//\//\\}" \
    --accept-licenses --default-answer --confirm-command \
    install >> "$LOGFILE" 2>&1
  then
    echo -e "${RED}Installation failed for MOZA Pit House:"
    tail -n 50 "$LOGFILE"
    echo -e "Full log: ${LOGFILE}${NC}"
    lsu_fail "Installation failed for MOZA Pit House, see ${LOGFILE}"
  fi

  rm -rf "$package_dir"

  if [[ ! -f "${PITHOUSE_DIR}/MOZA Pit House.exe" ]]; then
    lsu_fail "Installation failed for MOZA Pit House, see ${LOGFILE}"
  fi

  install_pithouse_vcredist

  echo -e "${GREEN}MOZA Pit House $(pithouse_installed_version) successfully installed.${NC}"
}

# The installer starts these through PowerShell, which Wine's stub skips, so
# they are run here with the same arguments.
install_pithouse_vcredist() {
  local vcredist

  echo -e "${CYAN}Installing Visual C++ runtimes for Pit House...${NC}"

  for vcredist in "2010/vcredist_x86.exe /q /norestart" "2015_2022/vc_redist.x86.exe /quiet /norestart"; do
    set -- $vcredist
    if [[ ! -f "${PITHOUSE_DIR}/vcredist/$1" ]]; then
      echo -e "${YELLOW}Pit House did not ship vcredist/$1, skipping it.${NC}"
      continue
    fi
    wine "${PITHOUSE_DIR}/vcredist/$1" "${@:2}" >> "$LOGFILE" 2>&1 \
      || echo -e "${YELLOW}vcredist/$1 reported a failure, see ${LOGFILE}${NC}"
  done
}

# Wine writes Exec lines of the form:
#   Exec=env "WINEPREFIX=<prefix>" wine "C:\\...\\MOZA Pit House.lnk"
# where the bare "wine" is whatever is first on PATH, not the Wine install.sh
# set up, and the target is the menu or desktop shortcut rather than the exe.
# install.sh points it at the launch wrapper but keeps the .lnk, so this runs
# after it, on every run, to aim the wrapper at the exe instead. Pit House
# rewrites the launcher when it updates itself.
module_fixup() {
  local root launcher_path
  local exec_line="Exec=${LSU_BINDIR}/lsu-launch-wrapper "'"C:\\\\Program Files (x86)\\\\MOZA Pit House\\\\MOZA Pit House.exe"'

  [[ -n "$(pithouse_installed_version)" ]] || return 0

  exec_line=${exec_line//\\/\\\\}
  exec_line=${exec_line//&/\\&}
  exec_line=${exec_line//|/\\|}

  echo -e "${CYAN}Patching MOZA Pit House desktop launchers...${NC}"

  shopt -s globstar nullglob

  while read -r root; do
    [[ -d "$root" ]] || continue

    for launcher_path in "$root"/**/"MOZA Pit House.desktop"; do
      is_lsu_launcher "$launcher_path" || continue

      sed -i "s|^Exec=.*|${exec_line}|" "$launcher_path"
    done
  done < <(lsu_launcher_roots)

  shopt -u globstar nullglob

  if command -v update-desktop-database > /dev/null; then
    update-desktop-database ~/.local/share/applications > /dev/null 2>&1 || true
  fi
}

lsu_module_dispatch "$@"
