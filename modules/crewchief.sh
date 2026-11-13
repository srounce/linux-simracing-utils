#!/usr/bin/env bash
#
# CrewChief (https://thecrewchief.org/) module for linux-simracing-utils. See
# modules/example.sh for how modules work.

for LSU_LIB in "${LSU_LIB:-}" "$(dirname -- "${BASH_SOURCE[0]}")"/{..,../..}/lib/lsu-common.sh; do
  [[ -f "$LSU_LIB" ]] && break
done
# shellcheck source=../lib/lsu-common.sh
source "$LSU_LIB" || { echo "lib/lsu-common.sh not found, run install.sh first." >&2; exit 1; }

LSU_MODULE_ID="crewchief"
LSU_MODULE_NAME="CrewChief"
LSU_MODULE_DESCRIPTION="Spotter and virtual race engineer"
LSU_MODULE_DEPENDS=""
LSU_MODULE_MIN_WINE=""

lsu_module_init

CREWCHIEF_DIR="${WINEPREFIX}/drive_c/CrewChiefV4"
CREWCHIEF_GITLAB_PROJECT="mr_belowski%2FCrewChiefV4"
CREWCHIEF_LOG="${LSU_LOGDIR}/cc_install.log"

# The msi is served unversioned, so the tag that was current at install time is
# recorded alongside the install rather than read back out of it.
crewchief_installed_version() {
  local marker="${CREWCHIEF_DIR}/.crewchief-version"

  [[ -f "${CREWCHIEF_DIR}/CrewChiefV4.exe" ]] || return 0

  if [[ -f "$marker" ]]; then
    cat "$marker"
  else
    echo "(unknown version)"
  fi
}

module_status() {
  lsu_result installed "$(crewchief_installed_version)"
  lsu_result available "$(gitlab_latest_tag "$CREWCHIEF_GITLAB_PROJECT")"
}

module_install() {
  local installed target workdir="${LSU_TMP}/crewchief"

  installed="$(crewchief_installed_version)"
  target="$(gitlab_latest_tag "$CREWCHIEF_GITLAB_PROJECT")"

  lsu_should_install "CrewChief" "$installed" "$target" \
    || lsu_skip "Skipping CrewChief installation"

  lsu_require_dotnet_legacy_set

  if [[ -n "$installed" ]]; then
    echo -e "${CYAN}Updating CrewChief...${NC}"
  else
    echo -e "${CYAN}Installing CrewChief...${NC}"
  fi

  mkdir -p "$workdir"

  # An msi dropped into the install directory is used instead of downloading.
  if [[ -f "${LSU_TARGET_DIR}/CrewChiefV4.msi" ]]; then
    cp "${LSU_TARGET_DIR}/CrewChiefV4.msi" "${workdir}/CrewChiefV4.msi"
  else
    curl -sL --fail \
      -o "${workdir}/CrewChiefV4.msi" \
      -H 'Referer: https://thecrewchief.org' \
      "https://thecrewchief.org/downloads/CrewChiefV4.msi"
  fi

  wine msiexec /i "${workdir}/CrewChiefV4.msi" /qn /l*v "$CREWCHIEF_LOG" \
    INSTALLFOLDER='C:\CrewChiefV4' \
    || true

  if [[ ! -f "${CREWCHIEF_DIR}/CrewChiefV4.exe" ]]; then
    lsu_fail "Installation failed for CrewChief, see ${CREWCHIEF_LOG}"
  fi

  # Without a known tag the marker would keep asserting a version this install
  # can no longer vouch for.
  if [[ -n "$target" ]]; then
    echo "$target" > "${CREWCHIEF_DIR}/.crewchief-version"
  else
    rm -f "${CREWCHIEF_DIR}/.crewchief-version"
  fi

  lsu_result version "$(crewchief_installed_version)"

  if [[ -n "$installed" ]]; then
    echo -e "${GREEN}CrewChief successfully updated.${NC}"
  else
    echo -e "${GREEN}CrewChief successfully installed.${NC}"
  fi
}

lsu_module_dispatch "$@"
