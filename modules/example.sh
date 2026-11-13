#!/usr/bin/env bash
#
# Example module for linux-simracing-utils. It installs nothing real: it
# writes a marker file under var/, so it is safe to try out.
#
# To write your own, copy this file to <install dir>/modules/local/<id>.sh,
# set LSU_MODULE_ID to the same <id>, and fill in the module_* functions.
# install.sh lists it in its menu on the next run, marked (local), and never
# overwrites it. A local module with the id of a published one replaces it.
# To publish a module for everyone, add it to modules/ in the repository and
# give it a line in modules/index.
#
# Contract (API 1)
# ----------------
# A module is a bash script run as `<id>.sh <verb>`:
#
#   meta     Prints the LSU_MODULE_* variables below. Built in, do not define.
#   status   Reports `installed` (empty when not installed) and `available`
#            (empty when unknown). Must be quick and must not start Wine: it
#            runs for every downloaded module before anything is installed,
#            possibly before Wine itself is.
#   install  Installs, updates or repairs the program. May prompt unless
#            UNATTENDED=1. Report the version that ended up installed.
#   fixup    Optional. Runs on every install.sh run for every downloaded
#            module, installed or not, after the desktop launchers have been
#            patched. For repairs that cannot wait for an update. Must do
#            nothing when the program is not installed.
#   remove   Optional. Uninstalls the program.
#
# Exit status:
#   0  done                      (return normally from module_<verb>)
#   1  failed                    (lsu_fail "why", or any command failing)
#   2  skipped / nothing to do   (lsu_skip "why")
#   3  verb not supported        (leave module_<verb> undefined)
#   4  requirement not met       (lsu_unmet "why")
#
# Do not `return 1` or `exit 2` to signal these yourself: an unchecked failing
# command already counts as a failure, whatever its exit status, and the
# helpers also record the reason for install.sh's summary.
#
# Results go back as `key=value` lines through `lsu_result key value`:
#   status:  installed, available
#   install: version, message (status is filled in by the helpers)
# Run standalone, they are printed instead.
#
# Environment, set by install.sh or, standalone, worked out from where this
# file sits (TARGET_DIR overrides that):
#   LSU_TARGET_DIR  the install directory
#   LSU_BINDIR      its bin/, first on PATH, so `wine` is the bundled one
#   LSU_VARDIR      its var/, for anything the module needs to keep
#   LSU_LOGDIR      its log/, write logs here as <id>_*.log
#   WINEPREFIX      the shared prefix
#   LSU_TMP         a scratch directory, removed when the module exits
#   UNATTENDED, DEBUG  as passed to install.sh
#
# Helpers from lib/lsu-common.sh, besides the ones above:
#   lsu_should_install NAME INSTALLED AVAILABLE   go ahead with an install?
#   confirm "question" Y|N                       ask yes/no
#   github_latest_tag owner/repo                 newest full release
#   github_newest_tag owner/repo                 newest release incl. pre
#   gitlab_latest_tag project-id                 newest tag
#   lsu_require_dotnet48                         .Net Framework 4.8
#   lsu_require_dotnet_runtime VERB FRAMEWORK VERSION LABEL   winetricks .Net
#   lsu_require_dotnet_bundle CHANNEL BUNDLE FRAMEWORK LABEL  Microsoft .Net
#   lsu_require_winetricks VERB [MARKER [LABEL]]  any winetricks verb
#   lsu_require_vcrun2022                        Visual C++ 2015-2022, x86+x64
#   lsu_require_corefonts                        (already in every prefix)
#   lsu_launcher_roots / is_lsu_launcher FILE    find this prefix's launchers
#   lsu_update_launchers                         write and patch launchers now
#
# Wine does not write launchers in this prefix itself, as it would point them
# at whatever "wine" is first on PATH. After the modules have run, install.sh
# writes them for the shortcuts the installers saved and points every one at
# the bundled Wine through the launch wrapper, so modules need not do that.

# Finds the shared library under install.sh or standalone. Keep as is.
for LSU_LIB in "${LSU_LIB:-}" "$(dirname -- "${BASH_SOURCE[0]}")"/{..,../..}/lib/lsu-common.sh; do
  [[ -f "$LSU_LIB" ]] && break
done
# shellcheck source=../lib/lsu-common.sh
source "$LSU_LIB" || { echo "lib/lsu-common.sh not found, run install.sh first." >&2; exit 1; }

LSU_MODULE_ID="example"                 # must match the file name
LSU_MODULE_NAME="Example"
LSU_MODULE_DESCRIPTION="Template for new modules, installs nothing"
LSU_MODULE_DEPENDS=""                   # other module ids, space separated
LSU_MODULE_MIN_WINE=""                  # e.g. sangria-11.18-pre3

lsu_module_init

EXAMPLE_VERSION="1.0.0"
EXAMPLE_MARKER="${LSU_VARDIR}/example/version"

example_installed_version() {
  cat "$EXAMPLE_MARKER" 2> /dev/null || true
}

module_status() {
  lsu_result installed "$(example_installed_version)"
  lsu_result available "$EXAMPLE_VERSION"
}

module_install() {
  local installed
  installed="$(example_installed_version)"

  lsu_should_install "$LSU_MODULE_NAME" "$installed" "$EXAMPLE_VERSION" \
    || lsu_skip "Skipping ${LSU_MODULE_NAME}."

  # A real module would ask for what its program needs here, e.g.
  #   lsu_require_dotnet48
  # then download its installer into "$LSU_TMP", run it with
  #   wine "${LSU_TMP}/setup.exe" /S >> "${LSU_LOGDIR}/example_install.log" 2>&1
  # and check the program actually landed in "$WINEPREFIX/drive_c".

  echo -e "${CYAN}Installing ${LSU_MODULE_NAME} ${EXAMPLE_VERSION}...${NC}"
  mkdir -p "$(dirname "$EXAMPLE_MARKER")"
  echo "$EXAMPLE_VERSION" > "$EXAMPLE_MARKER"

  lsu_result version "$EXAMPLE_VERSION"
  echo -e "${GREEN}${LSU_MODULE_NAME} ${EXAMPLE_VERSION} successfully installed.${NC}"
}

module_fixup() {
  [[ -n "$(example_installed_version)" ]] || return 0
  # Nothing to repair for the example.
}

module_remove() {
  [[ -n "$(example_installed_version)" ]] || lsu_skip "${LSU_MODULE_NAME} is not installed."
  rm -rf "$(dirname "$EXAMPLE_MARKER")"
  echo -e "${GREEN}${LSU_MODULE_NAME} removed.${NC}"
}

lsu_module_dispatch "$@"
