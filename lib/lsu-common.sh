# Shared helpers for install.sh and the module scripts. Sourced, never run.
#
# Callers set LSU_LOGDIR and WINEPREFIX before using anything that touches the
# prefix or writes logs, and call lsu_init_runtime once for the temporary
# files the Wine and .Net helpers need.

[[ -n "${LSU_COMMON_LOADED:-}" ]] && return 0
LSU_COMMON_LOADED=1

: "${DEBUG:="0"}"
: "${UNATTENDED:="0"}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

run() {
  {
    echo "---"
    printf '%q ' "$@"
    echo
    "$@"
  } >> "${LSU_LOGDIR}/install.log" 2>&1
}

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

# Sangria tags look like sangria-11.18-pre3. Prints "<version> <pre>" with an
# empty <pre> for a full release, or fails for a tag of any other shape.
lsu_wine_version_key() {
  local v="${1#"${1%%[0-9]*}"}"

  [[ "$v" =~ ^([0-9]+(\.[0-9]+)*)(-(pre|rc)([0-9]+))?$ ]] || return 1
  echo "${BASH_REMATCH[1]} ${BASH_REMATCH[5]}"
}

# Prints lt, eq or gt for $1 against $2, or fails when either tag cannot be
# parsed. sort -V alone would put 11.18 before 11.18-pre3, so prereleases are
# ordered here: every -preN of a version comes before the version itself.
lsu_wine_cmp() {
  local a b av ap bv bp

  a="$(lsu_wine_version_key "$1")" || return 1
  b="$(lsu_wine_version_key "$2")" || return 1
  read -r av ap <<< "$a"
  read -r bv bp <<< "$b"

  if [[ "$av" != "$bv" ]]; then
    if [[ "$(printf '%s\n%s\n' "$av" "$bv" | sort -V | head -n1)" == "$av" ]]; then
      echo lt
    else
      echo gt
    fi
  elif [[ "$ap" == "$bp" ]]; then
    echo eq
  elif [[ -z "$ap" ]]; then
    echo gt
  elif [[ -z "$bp" ]]; then
    echo lt
  elif (( ap < bp )); then
    echo lt
  else
    echo gt
  fi
}

# Returns 0 when $1 is $2 or newer, 1 when older, 2 when either is unparseable.
lsu_wine_at_least() {
  local result
  result="$(lsu_wine_cmp "$1" "$2")" || return 2
  [[ "$result" != "lt" ]]
}

# Temporary files shared by the Wine and .Net helpers, removed on exit. A
# trapped signal has to exit itself, which then runs the EXIT trap.
lsu_init_runtime() {
  LSU_TMP="$(mktemp -d)"
  DOTNET_INDEX_DIR="${LSU_TMP}/dotnet-index"
  mkdir -p "$DOTNET_INDEX_DIR"

  SILENT_WINE="${LSU_TMP}/silent-wine"
  cat > "$SILENT_WINE" << EOF
#!/usr/bin/env bash
export WINEDEBUG=${WINEDEBUG:--all}
exec wine "\$@"
EOF
  chmod +x "$SILENT_WINE"
  export SILENT_WINE

  trap 'exit 130' SIGINT
  trap 'exit 143' SIGTERM
  trap lsu_cleanup_runtime EXIT
}

lsu_cleanup_runtime() {
  [[ -n "${LSU_TMP:-}" ]] && rm -rf "$LSU_TMP"
  return 0
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

# Runs a winetricks verb unless $2 (a path, globs allowed) already exists.
lsu_require_winetricks() {
  local verb="$1" marker="${2:-}" label="${3:-$1}"
  local logfile="${LSU_LOGDIR}/${verb}_install.log"

  if [[ -n "$marker" ]] && compgen -G "$marker" > /dev/null; then
    echo -e "${GREEN}Found existing ${label} install.${NC}"
    return
  fi

  pin_winetricks_wine_arch

  echo -e "${CYAN}Installing ${label}...${NC}"
  if ! WINE=$SILENT_WINE winetricks -q "${verb}" > "$logfile" 2>&1; then
    echo -e "${RED}Installation failed for ${label}:"
    tail -n 50 "$logfile"
    echo -e "Full log: ${logfile}${NC}"
    exit 1
  fi
  echo -e "${GREEN}Successfully installed ${label}${NC}"
}

lsu_require_corefonts() {
  lsu_require_winetricks corefonts \
    "${WINEPREFIX}/drive_c/windows/Fonts/corefonts.installed" corefonts
}

lsu_require_dotnet48() {
  local dotnet_dir="$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319"

  echo -e "${CYAN}Checking for existing .Net 4.8 install...${NC}"

  # A stub mscorlib from Wine Mono is small; the real framework's is not.
  if [[ -f "$dotnet_dir/mscorlib.dll" ]] \
    && [[ $(stat -c%s "$dotnet_dir/mscorlib.dll" 2> /dev/null) -ge 1000000 ]]
  then
    echo -e "${GREEN}Found existing .Net 4.8 install.${NC}"
    return
  fi

  lsu_require_winetricks dotnet48 "" ".Net 4.8"
}

# Every dotnet runtime verb drops the same dotnet.exe, so only the shared
# framework directory and its version tell them apart. On a 64-bit prefix
# winetricks installs the x86 build alongside, under Program Files (x86);
# either build landing in Program Files is enough to call the verb done.
lsu_require_dotnet_runtime() {
  local verb="$1" framework="$2" version="$3" label="$4"

  lsu_require_winetricks "$verb" \
    "${WINEPREFIX}/drive_c/Program Files/dotnet/shared/${framework}/${version}.*" "$label"
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
lsu_require_dotnet_bundle() {
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

# The runtimes the base installer put in every prefix before apps became
# modules. Which app needs which is not yet known, so modules that ran on the
# old base ask for the whole set until that is worked out.
lsu_require_dotnet_legacy_set() {
  lsu_require_dotnet48
  lsu_require_dotnet_runtime dotnetcore3 Microsoft.NETCore.App 3.1 ".Net Core Runtime 3.1"
  lsu_require_dotnet_runtime dotnetcoredesktop3 Microsoft.WindowsDesktop.App 3.1 ".Net Core Desktop Runtime 3.1"
  lsu_require_dotnet_bundle 8.0 dotnet-runtime Microsoft.NETCore.App ".Net Runtime 8.0"
  lsu_require_dotnet_bundle 8.0 windowsdesktop-runtime Microsoft.WindowsDesktop.App ".Net Desktop Runtime 8.0"
  lsu_require_dotnet_bundle 8.0 aspnetcore-runtime Microsoft.AspNetCore.App "ASP.Net Core Runtime 8.0"
}

xdg_desktop_dir() {
  local desktop_dir
  desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  if [[ -z "$desktop_dir" || "$desktop_dir" == "$HOME" ]]; then
    desktop_dir="$HOME/Desktop"
  fi
  printf '%s' "$desktop_dir"
}

# Where wine writes the launchers for the programs it installs.
lsu_launcher_roots() {
  printf '%s\n' "$HOME/.local/share/applications/wine/Programs" "$(xdg_desktop_dir)"
}

# A launcher is ours if wine generated it against our prefix, or if an earlier
# install already wrapped it. Matching wrapped entries as well means a reinstall
# to a different TARGET_DIR repoints them.
is_lsu_launcher() {
  local launcher_path="$1"

  grep -qE "^Exec=.*(${WINEPREFIX}|lsu-launch-wrapper)" "$launcher_path"
}

lsu_refresh_desktop_database() {
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
}

# ---------------------------------------------------------------------------
# Module API, version 1. modules/example.sh documents the contract; what
# follows is the machinery behind it.
# ---------------------------------------------------------------------------

LSU_API=1

LSU_EXIT_OK=0
LSU_EXIT_FAIL=1
LSU_EXIT_SKIP=2
LSU_EXIT_UNSUPPORTED=3
LSU_EXIT_UNMET=4

lsu_result() {
  printf '%s=%s\n' "$1" "${2//$'\n'/ }" >> "$LSU_RESULT_FILE"
}

# Reads a key back out of a results file. The last value written wins.
lsu_result_get() {
  sed -n "s/^$2=//p" "$1" 2> /dev/null | tail -n1
}

# These end the module. They exit rather than return, so call them from the
# module_* function itself, not from inside a $(...) substitution.
lsu_skip() {
  if [[ -n "${1:-}" ]]; then
    echo -e "${YELLOW}$1${NC}"
    lsu_result message "$1"
  fi
  lsu_result status skipped
  exit $LSU_EXIT_SKIP
}

lsu_fail() {
  echo -e "${RED}$1${NC}" >&2
  lsu_result status failed
  lsu_result message "$1"
  exit $LSU_EXIT_FAIL
}

lsu_unmet() {
  echo -e "${RED}$1${NC}" >&2
  lsu_result status unmet
  lsu_result message "$1"
  exit $LSU_EXIT_UNMET
}

# Any command that fails unchecked ends the module as a failure. Without this,
# set -e would exit with the command's own status, and a curl or grep exiting
# 2 would read as a skip. A failure inside a $(...) only ends the subshell;
# the assignment around it then fails in the module itself and lands here.
_lsu_on_error() {
  local rc="$1" command="$2"

  [[ "$BASHPID" == "$LSU_MAIN_PID" ]] || exit "$rc"

  trap - ERR
  echo -e "${RED}${LSU_MODULE_NAME:-Module} failed (exit ${rc}): ${command}${NC}" >&2
  lsu_result status failed
  lsu_result message "failed (exit ${rc}): ${command}"
  exit $LSU_EXIT_FAIL
}

# Run by a module once its LSU_MODULE_* variables are set. Under install.sh
# the paths arrive in the environment. Run standalone they are worked out from
# where the library sits (or TARGET_DIR), ignoring any WINEPREFIX the shell
# happens to have, and results are printed instead of collected.
lsu_module_init() {
  set -eEuo pipefail

  if [[ -z "${LSU_RESULT_FILE:-}" ]]; then
    LSU_STANDALONE=1
    LSU_RESULT_FILE=/dev/stdout
    LSU_TARGET_DIR="${TARGET_DIR:-$(cd -- "$(dirname -- "$LSU_LIB")/.." && pwd)}"
    LSU_BINDIR="${LSU_TARGET_DIR}/bin"
    LSU_VARDIR="${LSU_TARGET_DIR}/var"
    LSU_LOGDIR="${LSU_TARGET_DIR}/log"
    WINEPREFIX="${LSU_TARGET_DIR}/pfx"
  else
    LSU_STANDALONE=0
  fi

  export WINEPREFIX
  export PATH="${LSU_BINDIR}:$PATH"

  if [[ "$DEBUG" == "1" ]]; then
    set -x
    export WINEDEBUG=${WINEDEBUG:-+seh,+loaddll,+module}
  else
    export WINEDEBUG=${WINEDEBUG:--all}
  fi

  : "${LSU_MODULE_DEPENDS:=""}"
  : "${LSU_MODULE_MIN_WINE:=""}"

  lsu_init_runtime

  LSU_MAIN_PID="$BASHPID"
  trap '_lsu_on_error "$?" "$BASH_COMMAND"' ERR
}

lsu_require_base() {
  if [[ ! -x "${LSU_BINDIR}/wine" ]] || [[ ! -f "${WINEPREFIX}/system.reg" ]] \
    || [[ ! -x "${LSU_BINDIR}/lsu-launch-wrapper" ]]
  then
    lsu_unmet "No linux-simracing-utils install found in ${LSU_TARGET_DIR}. Run install.sh first, or set TARGET_DIR to its install directory."
  fi

  mkdir -p "${LSU_LOGDIR}"
}

lsu_installed_wine_version() {
  cat "${LSU_VARDIR}/wine/.wine-version" 2> /dev/null || true
}

# install.sh checks this before it installs anything, and can offer to switch
# channel. This is the backstop for standalone runs and declined downgrades.
lsu_check_min_wine() {
  local installed rc=0

  [[ -n "$LSU_MODULE_MIN_WINE" ]] || return 0

  installed="$(lsu_installed_wine_version)"
  lsu_wine_at_least "$installed" "$LSU_MODULE_MIN_WINE" || rc=$?

  case "$rc" in
    0) ;;
    1) lsu_unmet "${LSU_MODULE_NAME} needs Wine ${LSU_MODULE_MIN_WINE} or newer, ${installed} is installed. Re-run install.sh and choose the prerelease channel, or pin a newer LSU_WINE_VERSION." ;;
    *) echo -e "${YELLOW}Unable to compare the installed Wine (${installed:-unknown}) with the ${LSU_MODULE_MIN_WINE} ${LSU_MODULE_NAME} needs, continuing.${NC}" ;;
  esac
}

# Whether module_install should go ahead, from what is installed against what
# is available. Under install.sh the module was picked in a menu that already
# showed both, so only a reinstall of something current asks again. Run
# standalone, every case asks, as install.sh used to. Unattended runs install
# what is missing and update what is outdated.
lsu_should_install() {
  local name="$1" installed="$2" target="$3"
  local outdated=0

  if [[ -z "$installed" ]] || { [[ -n "$target" ]] && [[ "$installed" != "$target" ]]; }; then
    outdated=1
  fi

  if [[ "$UNATTENDED" == "1" ]]; then
    (( outdated )) && return 0
    echo -e "${GREEN}${name} ${installed} is installed and no newer release was found.${NC}"
    return 1
  fi

  if [[ "$LSU_STANDALONE" == "0" ]] && (( outdated )); then
    return 0
  fi

  confirm_component "$name" "$installed" "$target"
}

_lsu_module_meta() {
  lsu_result id "$LSU_MODULE_ID"
  lsu_result name "$LSU_MODULE_NAME"
  lsu_result description "$LSU_MODULE_DESCRIPTION"
  lsu_result api "$LSU_API"
  lsu_result depends "$LSU_MODULE_DEPENDS"
  lsu_result min_wine "$LSU_MODULE_MIN_WINE"
}

_lsu_module_usage() {
  echo "usage: ${0##*/} meta|status|install|fixup|remove"
  echo
  echo "${LSU_MODULE_NAME}: ${LSU_MODULE_DESCRIPTION}"
  echo "Normally run by install.sh. Run standalone it works on the install"
  echo "directory it sits in, or on TARGET_DIR if that is set."
}

# The last line of every module. Runs module_<verb> and exits with the
# contract's status: a function that simply returns has succeeded.
lsu_module_dispatch() {
  local verb="${1:-help}"

  case "$verb" in
    meta)
      _lsu_module_meta
      exit $LSU_EXIT_OK
      ;;
    status) ;;
    install|fixup|remove) lsu_require_base ;;
    help|-h|--help)
      _lsu_module_usage
      exit $LSU_EXIT_OK
      ;;
    *)
      _lsu_module_usage >&2
      lsu_result status unsupported
      exit $LSU_EXIT_UNSUPPORTED
      ;;
  esac

  if ! declare -F "module_${verb}" > /dev/null; then
    lsu_result status unsupported
    exit $LSU_EXIT_UNSUPPORTED
  fi

  if [[ "$verb" == "install" ]]; then
    lsu_check_min_wine
  fi

  "module_${verb}"
  exit $LSU_EXIT_OK
}
