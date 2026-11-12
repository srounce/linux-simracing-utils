#!/usr/bin/env bash
#
# Richard Burns Rally as packaged by RallySimFans (https://rallysimfans.hu/)
# module for linux-simracing-utils. See modules/example.sh for how modules
# work.
#
# The RSF installer is an interactive GUI that downloads the game and its
# content itself, so this module only finds the installer, runs it in the
# shared prefix and sets the DLL overrides the game folder needs.
# rallysimfans.hu refuses scripted downloads, so the user downloads the
# installer and this module looks for it.

for LSU_LIB in "${LSU_LIB:-}" "$(dirname -- "${BASH_SOURCE[0]}")"/{..,../..}/lib/lsu-common.sh; do
  [[ -f "$LSU_LIB" ]] && break
done
# shellcheck source=../lib/lsu-common.sh
source "$LSU_LIB" || { echo "lib/lsu-common.sh not found, run install.sh first." >&2; exit 1; }

LSU_MODULE_ID="rsf"
LSU_MODULE_NAME="Richard Burns Rally RSF"
LSU_MODULE_DESCRIPTION="The RallySimFans build of Richard Burns Rally"
LSU_MODULE_DEPENDS=""
LSU_MODULE_MIN_WINE=""

lsu_module_init

RSF_LOG="${LSU_LOGDIR}/rsf_install.log"
RSF_DOWNLOAD_PAGE="https://rallysimfans.hu/rbr/download.php?download=rsfrbr"
RSF_INSTALLER_NAME="Rallysimfans_Installer.exe"
RSF_DEFAULT_DIR="${WINEPREFIX}/drive_c/Richard Burns Rally"

# The RSF installer records itself under this key. On a 64-bit prefix it lands
# under Wow6432Node, since the installer is 32-bit.
RSF_REG_KEYS=('Software\Wow6432Node\Rallysimfans RBR' 'Software\Rallysimfans RBR')

# DLL overrides, set per executable so nothing else in the shared prefix is
# affected. An empty load order disables the DLL.
#
# The game folder ships its own copies of these. d3d9 is whichever wrapper
# (DXVK, dgVoodoo) the RSF launcher has put in place; without it Wine's own is
# used.
RSF_GAME_EXES=(RichardBurnsRally_SSE.exe RichardBurnsRally_NoSSE.exe RichardBurnsRally.exe)
RSF_GAME_OVERRIDES=(
  d3d9=native,builtin
  dinput8=native,builtin
  mfc70=native
  mfc71=native
  msvci70=native
  msvcp70=native
  msvcp71=native
  msvcr70=native
  msvcr71=native
)
# The launcher is a .Net 10 app, and .Net loads ICU when it finds one. Wine
# only has stubs of it, which fail ("Cannot get symbol u_charsToUChars from
# libicuuc") and the launcher exits. Without any, .Net falls back to Windows'
# own globalization functions, which Wine implements.
RSF_LAUNCHER_EXE=RSF_Launcher.exe
RSF_LAUNCHER_OVERRIDES=(icu= icuuc= icuin=)

# Every override as "<exe> <dll>=<load order>".
rsf_overrides() {
  local exe override

  for exe in "${RSF_GAME_EXES[@]}"; do
    for override in "${RSF_GAME_OVERRIDES[@]}"; do
      echo "${exe} ${override}"
    done
  done
  for override in "${RSF_LAUNCHER_OVERRIDES[@]}"; do
    echo "${RSF_LAUNCHER_EXE} ${override}"
  done
}

# Read straight from system.reg so a status check never starts Wine. Wine
# writes the file lazily, so right after the installer has run use
# rsf_reg_live instead.
rsf_reg_file() {
  local name="$1" key pattern value

  [[ -f "${WINEPREFIX}/system.reg" ]] || return 0

  for key in "${RSF_REG_KEYS[@]}"; do
    pattern="${key//\\/\\\\\\\\}"
    value="$(sed -n "/^\[${pattern}\]/,/^\[/ s/^\"${name}\"=\"\([^\"]*\)\"\$/\1/p" \
      "${WINEPREFIX}/system.reg" | head -n1)"
    if [[ -n "$value" ]]; then
      echo "${value//\\\\/\\}"
      return
    fi
  done
}

rsf_reg_live() {
  local name="$1" key value

  for key in "${RSF_REG_KEYS[@]}"; do
    value="$(wine reg query "HKLM\\${key}" /v "$name" 2> /dev/null \
      | tr -d '\r' \
      | sed -n "s/^ *${name} *REG_SZ *//p" \
      | head -n1 \
      || true)"
    if [[ -n "$value" ]]; then
      echo "$value"
      return
    fi
  done
}

# Maps the Windows InstallPath to the prefix through dosdevices, so an install
# to another drive is found too. Falls back to the installer's default folder.
rsf_game_dir() {
  local path="$1" drive

  if [[ "$path" =~ ^([A-Za-z]):\\?(.*)$ ]]; then
    drive="${BASH_REMATCH[1],,}"
    path="${BASH_REMATCH[2]//\\//}"
    echo "${WINEPREFIX}/dosdevices/${drive}:/${path}"
  else
    echo "$RSF_DEFAULT_DIR"
  fi
}

# $1 is the InstallPath, $2 the InstallVersion, as recorded by the installer.
rsf_version_of() {
  local dir

  dir="$(rsf_game_dir "$1")"

  [[ -f "${dir}/RichardBurnsRally_SSE.exe" ]] || return 0
  [[ -f "${dir}/rsf_launcher/RSF_Launcher.exe" ]] || return 0

  echo "${2:-(unknown version)}"
}

rsf_installed_version() {
  rsf_version_of "$(rsf_reg_file InstallPath)" "$(rsf_reg_file InstallVersion)"
}

# Newest first, so a browser's "Rallysimfans_Installer(1).exe" beats an older
# download. LSU_RSF_INSTALLER, then the install directory, then Downloads.
rsf_find_installer() {
  local downloads candidate

  if [[ -n "${LSU_RSF_INSTALLER:-}" ]]; then
    [[ -f "$LSU_RSF_INSTALLER" ]] && echo "$LSU_RSF_INSTALLER"
    return 0
  fi

  if [[ -f "${LSU_TARGET_DIR}/${RSF_INSTALLER_NAME}" ]]; then
    echo "${LSU_TARGET_DIR}/${RSF_INSTALLER_NAME}"
    return 0
  fi

  downloads="$(xdg-user-dir DOWNLOAD 2> /dev/null || true)"
  if [[ -z "$downloads" || "$downloads" == "$HOME" ]]; then
    downloads="$HOME/Downloads"
  fi

  candidate="$(ls -t "$downloads"/Rallysimfans_Installer*.exe 2> /dev/null | head -n1 || true)"
  [[ -n "$candidate" ]] && echo "$candidate"
  return 0
}

module_status() {
  lsu_result installed "$(rsf_installed_version)"
  # rallysimfans.hu does not publish the current version to scripts.
  lsu_result available ""
}

module_install() {
  local installed installer reply install_path version

  installed="$(rsf_installed_version)"

  # Nothing to do without someone at the keyboard to drive the installer.
  if [[ "$UNATTENDED" == "1" ]]; then
    if [[ -n "$installed" ]]; then
      lsu_skip "${LSU_MODULE_NAME} ${installed} is installed. The RSF installer needs you at the keyboard, so it is not re-run unattended."
    fi
    lsu_skip "The RSF installer needs you at the keyboard. Run install.sh without UNATTENDED to install ${LSU_MODULE_NAME}."
  fi

  if [[ -n "$installed" ]]; then
    echo -e "${CYAN}This opens the RSF installer again, where you can repair the install or change what is installed.${NC}"
  fi
  lsu_should_install "$LSU_MODULE_NAME" "$installed" "" \
    || lsu_skip "Skipping ${LSU_MODULE_NAME}."

  installer="$(rsf_find_installer)"

  while [[ -z "$installer" ]]; do
    echo -e "
${YELLOW}The RSF installer was not found.${NC}
rallysimfans.hu does not allow scripted downloads, so download
${RSF_INSTALLER_NAME} in your browser from
  ${RSF_DOWNLOAD_PAGE}
and save it to your Downloads folder or to ${LSU_TARGET_DIR}.
"
    printf "${CYAN}"
    read -rp "Press Enter once it is downloaded, type its path, or q to skip: " reply \
      || reply=q
    printf "${NC}"

    case "$reply" in
      q|Q) lsu_skip "Skipping ${LSU_MODULE_NAME}." ;;
      "") installer="$(rsf_find_installer)" ;;
      *)
        reply="${reply/#\~/$HOME}"
        if [[ -f "$reply" ]]; then
          installer="$reply"
        else
          echo -e "${RED}${reply} does not exist.${NC}"
        fi
        ;;
    esac
  done

  echo -e "${CYAN}Using ${installer}${NC}"
  echo -e "\n${CYAN}The RSF installer opens in its own window. In it:${NC}"
  # Not echo -e: the Windows paths are full of backslashes.
  cat << EOF
 - Keep the install folder at C:\Richard Burns Rally unless you need it elsewhere.
 - RSF's base game files come from its torrent. If you have downloaded it, point
   the installer at that folder. Drive Z: is your Linux file system, so your
   home folder is Z:${HOME//\//\\}.
This script carries on once the installer window is closed.

EOF

  echo "" > "$RSF_LOG"

  # The RSF launcher refuses to start without Microsoft's own runtime.
  lsu_require_vcrun2022

  # A GUI installer's exit status says little: a cancelled install also exits
  # cleanly. The game files are checked instead.
  wine "$installer" >> "$RSF_LOG" 2>&1 || true

  install_path="$(rsf_reg_live InstallPath)"
  version="$(rsf_version_of "$install_path" "$(rsf_reg_live InstallVersion)")"

  if [[ -z "$version" ]]; then
    lsu_fail "${LSU_MODULE_NAME} was not installed: the RSF installer closed before the game was in place. See ${RSF_LOG}"
  fi

  rsf_apply_dll_overrides

  lsu_result version "$version"

  if [[ -n "$installed" ]]; then
    echo -e "${GREEN}${LSU_MODULE_NAME} ${version} successfully updated.${NC}"
  else
    echo -e "${GREEN}${LSU_MODULE_NAME} ${version} successfully installed.${NC}"
  fi
}

rsf_apply_dll_overrides() {
  local regfile="${LSU_TMP}/rsf-dll-overrides.reg" exe override

  echo -e "${CYAN}Setting DLL overrides for Richard Burns Rally...${NC}"

  {
    printf 'Windows Registry Editor Version 5.00\r\n'
    while read -r exe override; do
      printf '\r\n[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\%s\\DllOverrides]\r\n' "$exe"
      printf '"%s"="%s"\r\n' "${override%%=*}" "${override#*=}"
    done < <(rsf_overrides)
  } > "$regfile"

  wine reg import "Z:${regfile//\//\\}" >> "$RSF_LOG" 2>&1 \
    || lsu_fail "Unable to set the DLL overrides for Richard Burns Rally, see ${RSF_LOG}"
}

# Only the presence of each override is checked, not its value, so one changed
# by hand in winecfg is left alone.
rsf_dll_overrides_missing() {
  local exe override section

  [[ -f "${WINEPREFIX}/user.reg" ]] || return 0

  while read -r exe override; do
    section="$(sed -n "/^\[Software\\\\\\\\Wine\\\\\\\\AppDefaults\\\\\\\\${exe//./\\.}\\\\\\\\DllOverrides\]/I,/^\[/p" \
      "${WINEPREFIX}/user.reg")"
    grep -qiF "\"${override%%=*}\"=" <<< "$section" || return 0
  done < <(rsf_overrides)

  return 1
}

# Also covers games installed before this module existed, or by hand.
module_fixup() {
  [[ -n "$(rsf_installed_version)" ]] || return 0

  # For installs from before the module required it, or where another
  # program's bundled runtime installer left Wine's msvcp140 in place; see
  # lsu_require_vcrun2022. Nothing to do once it is there.
  lsu_has_vcrun2022 || lsu_require_vcrun2022

  rsf_dll_overrides_missing || return 0

  echo "" >> "$RSF_LOG"
  rsf_apply_dll_overrides
}

lsu_module_dispatch "$@"
