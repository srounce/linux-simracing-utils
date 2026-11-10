#!/usr/bin/env bash
#
# SimHub (https://www.simhubdash.com/) module for linux-simracing-utils. See
# modules/example.sh for how modules work.

for LSU_LIB in "${LSU_LIB:-}" "$(dirname -- "${BASH_SOURCE[0]}")"/{..,../..}/lib/lsu-common.sh; do
  [[ -f "$LSU_LIB" ]] && break
done
# shellcheck source=../lib/lsu-common.sh
source "$LSU_LIB" || { echo "lib/lsu-common.sh not found, run install.sh first." >&2; exit 1; }

LSU_MODULE_ID="simhub"
LSU_MODULE_NAME="SimHub"
LSU_MODULE_DESCRIPTION="Dashboards, overlays, bass shakers and motion"
LSU_MODULE_DEPENDS=""
LSU_MODULE_MIN_WINE=""

lsu_module_init

SIMHUB_REPO="SHWotever/simhub"
SIMHUB_EXE="${WINEPREFIX}/drive_c/Program Files (x86)/SimHub/SimHubWPF.exe"
SIMHUB_LOG="${LSU_LOGDIR}/simhub_setup.log"

# SimHub maintains this itself and it is verbatim the upstream release tag, so
# it stays accurate even for installs this script did not perform. It is read
# straight from user.reg so a status check never has to start Wine.
simhub_installed_version() {
  [[ -f "${WINEPREFIX}/user.reg" ]] || return 0

  sed -n '/^\[Software\\\\SimHub\]/,/^\[/ s/^"LastInstalledVersion"="\([^"]*\)"$/\1/p' \
    "${WINEPREFIX}/user.reg" \
    | head -n1
}

module_status() {
  lsu_result installed "$(simhub_installed_version)"
  lsu_result available "$(github_latest_tag "$SIMHUB_REPO")"
}

module_install() {
  local installed target workdir="${LSU_TMP}/simhub"

  installed="$(simhub_installed_version)"
  target="$(github_latest_tag "$SIMHUB_REPO")"

  lsu_should_install "SimHub" "$installed" "$target" \
    || lsu_skip "Skipping SimHub installation"

  lsu_require_dotnet_legacy_set

  if [[ -n "$installed" ]]; then
    echo -e "${CYAN}Updating SimHub...${NC}"
  else
    echo -e "${CYAN}Installing SimHub...${NC}"
  fi

  mkdir -p "$workdir"
  curl -sL --fail "https://api.github.com/repos/${SIMHUB_REPO}/releases/latest" \
    | grep -m1 "browser_download_url" \
    | cut -d : -f 2,3 \
    | tr -d \" \
    | xargs curl -sL --fail > "${workdir}/simhub.zip"
  unzip -q -d "${workdir}/simhub" "${workdir}/simhub.zip"

  # The registry is not read back here: Wine writes it out lazily, and
  # /RESTARTAPPLICATIONS can leave SimHub running, so waiting on the
  # wineserver could block until the user closes it.
  wine "${workdir}"/simhub/SimHubSetup*.exe /TASKS="desktopicon,enablemotion,dashsandoverlays" /RESTARTAPPLICATIONS /VERYSILENT \
    >> "$SIMHUB_LOG" 2>&1 \
    || lsu_fail "Installation failed for SimHub, see ${SIMHUB_LOG}"

  [[ -f "$SIMHUB_EXE" ]] || lsu_fail "Installation failed for SimHub, see ${SIMHUB_LOG}"

  lsu_result version "${target:-$installed}"

  if [[ -n "$installed" ]]; then
    echo -e "${GREEN}SimHub successfully updated.${NC}"
  else
    echo -e "${GREEN}SimHub successfully installed.${NC}"
  fi
}

lsu_module_dispatch "$@"
