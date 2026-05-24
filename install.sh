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

if [[ $DEBUG == "1" ]]; then
  set -x
else
  export WINEDEBUG="-all"
fi

if [[ "$UNATTENDED" != "1" ]]; then
  printf "${CYAN}Install directory: ${NC}"
  read -e -rp "" -i "$TARGET_DIR" TARGET_DIR
fi

LSU_LOGDIR="${TARGET_DIR}/log"
WINEPREFIX="${TARGET_DIR}/pfx"
export WINEPREFIX

mkdir -p ${LSU_LOGDIR}

if [[ "$TARGET_DIR" != "$SCRIPT_DIR" ]]; then
  cp "${SCRIPT_DIR}/install.sh" "${TARGET_DIR}/install.sh"
  chmod +x "${TARGET_DIR}/install.sh"
  echo -e "${GREEN}Installer copied to ${TARGET_DIR}/install.sh${NC}"
fi

bindir="${TARGET_DIR}/bin"
vardir="${TARGET_DIR}/var"
mkdir -p "${bindir}" "${vardir}"

export PATH="${bindir}:$PATH"

check_tools() {
  if ! command -v wine > /dev/null 2>&1; then
    echo -e "${RED}Wine is not installed, cannot proceed.${NC}"
  fi

  if ! command -v winetricks > /dev/null 2>&1; then
    # echo -e "${RED}Winetricks is not installed, cannot proceed.${NC}"
    install_winetricks
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

  WINEDLLOVERRIDES="mscoree,mshtml=" wineboot --init >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  wine reg add 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f >> "${LSU_LOGDIR}/prefix_setup.log" 2>&1

  echo -e "${GREEN}Prefix successfully created at $WINEPREFIX${NC}"
}

check_dotnet() {
  echo -e "${CYAN}Checking for existing .Net 4.8 install...${NC}"

  DOTNET_DIR="$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319"

  local install_log=$(mktemp)

  if [[ ! -d "$DOTNET_DIR" ]] || \
    [[ ! -f "$DOTNET_DIR/mscorlib.dll" ]] || \
    [[ $(stat -c%s "$DOTNET_DIR/mscorlib.dll" 2> /dev/null) -lt 1000000 ]]
  then
    echo -e "${CYAN}Installing .Net 4.8...${NC}"
    SILENT_WINE=$(mktemp)
    cat > $SILENT_WINE << 'EOF'
#!/bin/bash
export WINEDEBUG=-all
exec wine "$@"
EOF
    chmod +x $SILENT_WINE

    set +e
    WINE=$SILENT_WINE winetricks -q dotnet48 >> "${LSU_LOGDIR}/dotnet_install.log" 2>&1
    rm $SILENT_WINE
    set -e

    if [[ $? -gt 0 ]]; then
      echo -e "${RED}Installation failed for .Net 4.8:"
      cat $install_log
      echo -e "${NC}"
    else
      echo -e "${GREEN}Successfully installed .Net 4.8${NC}"
    fi
  else
    echo -e "${GREEN}Found existing .Net 4.8 install.${NC}"
  fi
}

check_prefix() {
  if [[ ! -d "$WINEPREFIX" ]] || [[ ! -d "$WINEPREFIX/drive_c" ]]; then
    setup_prefix
  fi
  
  check_dotnet
}

check_simhub() {
  echo -e "${CYAN}Checking for existing SimHub installation...${NC}"

  found_simhub=0
  if wine reg QUERY 'HKCU\Software\SimHub' /v LastInstalledVersion > /dev/null 2>&1; then
    found_simhub=1
  fi

  install_message="SimHub installation not found, do you want to install SimHub?"
  if [[ $found_simhub == "1" ]]; then
    install_message="SimHub installation found, do you want to update SimHub?"
  fi

  if [[ "$UNATTENDED" == "1" ]]; then
    install_simhub $found_simhub
    return
  fi

  while true; do
    printf "${CYAN}"
    read -rp "$install_message [Y/n]" simhub_confirm
    printf "${NC}"
    simhub_confirm="${simhub_confirm:-Y}"
    if [[ "$simhub_confirm" =~ ^[Yy]$ ]]; then
      install_simhub $found_simhub
      break
    elif [[ "$simhub_confirm" =~ ^[Nn]$ ]]; then
      echo -e "${YELLOW}Skipping SimHub installation${NC}"
      break
    else
      echo "Please enter y or n."
    fi 
  done

  unset simhub_confirm
}

install_simhub() {
  local workdir=$(mktemp -d)

  if [[ $1 == "1" ]]; then
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

  if [[ $1 == "1" ]]; then
    echo -e "${GREEN}SimHub successfully updated.${NC}"
  else
    echo -e "${GREEN}SimHub successfully installed.${NC}"
  fi
}

check_crewchief() {
  echo -e "${CYAN}Checking for existing CrewChief installation...${NC}"

  found_crewchief=0
  if [[ -f "${WINEPREFIX}/drive_c/CrewChiefV4/CrewChiefV4.exe" ]]; then
    found_crewchief=1
  fi

  install_message="CrewChief installation not found, do you want to install CrewChief?"
  if [[ $found_crewchief == "1" ]]; then
    install_message="CrewChief installation found, do you want to update CrewChief?"
  fi

  if [[ "$UNATTENDED" == "1" ]]; then
    install_crewchief $found_crewchief
    return
  fi

  while true; do
    printf "${CYAN}"
    read -rp "$install_message [Y/n]" crewchief_confirm
    printf "${NC}"
    crewchief_confirm="${crewchief_confirm:-Y}"
    if [[ "$crewchief_confirm" =~ ^[Yy]$ ]]; then
      install_crewchief $found_crewchief
      break
    elif [[ "$crewchief_confirm" =~ ^[Nn]$ ]]; then
      echo -e "${YELLOW}Skipping CrewChief installation${NC}"
      break
    else
      echo "Please enter y or n."
    fi 
  done

  unset crewchief_confirm
}

install_crewchief() {
  local workdir=$(mktemp -d)

  if [[ $1 == "1" ]]; then
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

  if [[ $1 == "1" ]]; then
    echo -e "${GREEN}CrewChief successfully updated.${NC}"
  else
    echo -e "${GREEN}CrewChief successfully installed.${NC}"
  fi
}

check_winecarte() {
  echo -e "${CYAN}Checking for existing Winecarte installation...${NC}"

  found_winecarte=0
  if [[ ! -f "${TARGET_DIR}/bin/winecarte}" ]]; then
    found_winecarte=1
  fi

  install_message="Winecarte installation not found, do you want to install Winecarte?"
  if [[ $found_winecarte == "1" ]]; then
    install_message="Winecarte installation found, do you want to update Winecarte?"
  fi

  if [[ "$UNATTENDED" == "1" ]]; then
    install_winecarte $found_winecarte
    return
  fi

  while true; do
    printf "${CYAN}"
    read -rp "$install_message [Y/n]" winecarte_confirm
    printf "${NC}"
    winecarte_confirm="${winecarte_confirm:-Y}"
    if [[ "$winecarte_confirm" =~ ^[Yy]$ ]]; then
      install_winecarte $found_winecarte
      break
    elif [[ "$winecarte_confirm" =~ ^[Nn]$ ]]; then
      echo -e "${YELLOW}Skipping Winecarte installation${NC}"
      break
    else
      echo "Please enter y or n."
    fi 
  done

  unset winecarte_confirm
}

install_winecarte() {
  local workdir=$(mktemp -d)

  if [[ $1 == "1" ]]; then
    echo -e "${CYAN}Updating Winecarte...${NC}"
  else
    echo -e "${CYAN}Install Winecarte...${NC}"
  fi

  mkdir "${workdir}/winecarte"
  curl -sL --fail "https://api.github.com/repos/srounce/winecarte/releases/328366058" \
    | grep "browser_download_url" \
    | cut -d : -f 2,3 \
    | tr -d \" \
    | xargs curl -sL --fail > "${workdir}/winecarte.tar.gz"
  tar -xzf "${workdir}/winecarte.tar.gz" -C "${bindir}" --strip-components=1

  rm -rf ${workdir}

  if [[ $1 == "1" ]]; then
    echo -e "${GREEN}Winecarte successfully updated.${NC}"
  else
    echo -e "${GREEN}Winecarte successfully installed.${NC}"
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
  cat > "${bindir}/lsu-launch-wrapper" << EOF
#!/bin/bash

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
#!/bin/bash

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

  patch_desktop_launcher \
    "SimHub" \
    "$HOME/.local/share/applications/wine/Programs/SimHub/SimHub.desktop"

  patch_desktop_launcher \
    "CrewChief" \
    "$HOME/.local/share/applications/wine/Programs/CrewChiefV4.desktop"
  
  echo -e "${CYAN}Desktop launchers successfully patched.${NC}"
}

patch_desktop_launcher() {
  local name="$1"
  local launcher_path="$2"
  
  sed -i "s|^Exec=.* \"C:|Exec=${bindir}/lsu-launch-wrapper \"C:|" "$launcher_path"
}

check_tools

check_prefix
check_dotnet

check_simhub

check_crewchief

check_winecarte

postinstall_winecarte

install_launch_wrapper

fix_desktop_launchers
