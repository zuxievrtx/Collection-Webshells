#!/bin/sh

# =============================================
#  AstarGanz User Creator Tool
#  Telegram: https://t.me/ibarat1337
#  Compatible: sh / bash
# =============================================

# ===== COLORS =====
R='\033[1;31m'
G='\033[1;32m'
Y='\033[1;33m'
B='\033[1;34m'
M='\033[1;35m'
C='\033[1;36m'
W='\033[1;37m'
D='\033[0;90m'
N='\033[0m'
BG_R='\033[41m'
BG_G='\033[42m'
BG_B='\033[44m'
BG_M='\033[45m'
BG_C='\033[46m'
BOLD='\033[1m'
DIM='\033[2m'

# ===== FUNCTIONS =====
line() {
  printf "${D}────────────────────────────────────────────────────${N}\n"
}

dline() {
  printf "${D}════════════════════════════════════════════════════${N}\n"
}

loading_bar() {
  MSG="$1"
  printf "  ${D}${MSG} [${N}"
  i=0
  while [ $i -lt 30 ]; do
    printf "${G}█${N}"
    sleep 0.03
    i=$((i + 1))
  done
  printf "${D}] ${G}Done!${N}\n"
}

spinner() {
  MSG="$1"
  CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  i=0
  while [ $i -lt 10 ]; do
    IDX=$((i % 10))
    CHAR=$(echo "$CHARS" | cut -c$((IDX + 1)))
    printf "\r  ${C}${CHAR}${N} ${D}${MSG}${N}"
    sleep 0.1
    i=$((i + 1))
  done
  printf "\r  ${G}✓${N} ${W}${MSG}${N}\n"
}

# ===== CLEAR & BANNER =====
clear

printf "\n"
dline
printf "${R}     █████╗ ███████╗████████╗ █████╗ ██████╗${N}\n"
printf "${R}    ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗${N}\n"
printf "${M}    ███████║███████╗   ██║   ███████║██████╔╝${N}\n"
printf "${M}    ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗${N}\n"
printf "${C}    ██║  ██║███████║   ██║   ██║  ██║██║  ██║${N}\n"
printf "${C}    ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝${N}\n"
printf "\n"
printf "    ${D}┌──────────────────────────────────────┐${N}\n"
printf "    ${D}│${N}  ${W}User Creator Tool ${D}v2.1${N}               ${D}│${N}\n"
printf "    ${D}│${N}  ${C}Telegram: ${W}@ibarat1337${N}               ${D}│${N}\n"
printf "    ${D}│${N}  ${C}Channel : ${W}https://t.me/ibarat1337${N}   ${D}│${N}\n"
printf "    ${D}└──────────────────────────────────────┘${N}\n"
dline
printf "\n"

# ===== PHASE 1: ROOT CHECK =====
printf "  ${BG_B}${W} PHASE 1 ${N} ${B}Access Verification${N}\n"
line
sleep 0.5

spinner "Detecting current user"

CURRENT_USER=$(whoami)
CURRENT_UID=$(id -u)

printf "  ${D}├─${N} ${W}User    : ${C}${CURRENT_USER}${N}\n"
printf "  ${D}├─${N} ${W}UID     : ${C}${CURRENT_UID}${N}\n"

if [ "$CURRENT_UID" -ne 0 ]; then
  printf "  ${D}└─${N} ${W}Access  : ${R}NOT ROOT ✗${N}\n"
  printf "\n"
  line
  printf "\n"
  printf "  ${R}[✗] ERROR: Root access required!${N}\n"
  printf "  ${D}    Jalankan ulang dengan:${N}\n"
  printf "\n"
  printf "  ${Y}    sudo sh adduser.sh${N}\n"
  printf "  ${Y}    sudo bash adduser.sh${N}\n"
  printf "\n"
  line
  printf "  ${D}Script by ${C}@ibarat1337${N}\n"
  printf "\n"
  exit 1
fi

printf "  ${D}└─${N} ${W}Access  : ${G}ROOT ✓${N}\n"
printf "\n"
sleep 0.3

# ===== PHASE 2: SERVER INFO =====
printf "  ${BG_M}${W} PHASE 2 ${N} ${M}Server Information${N}\n"
line
sleep 0.3

loading_bar "Gathering server info"
printf "\n"

# Detect OS
if [ -f /etc/os-release ]; then
  OS_NAME=$(. /etc/os-release && echo "$PRETTY_NAME")
elif [ -f /etc/redhat-release ]; then
  OS_NAME=$(cat /etc/redhat-release)
else
  OS_NAME=$(uname -s)
fi

# Detect info
HOSTNAME_SRV=$(hostname 2>/dev/null || echo "Unknown")
KERNEL=$(uname -r 2>/dev/null || echo "Unknown")
ARCH=$(uname -m 2>/dev/null || echo "Unknown")
UPTIME=$(uptime -p 2>/dev/null || uptime 2>/dev/null | sed 's/.*up /up /' | sed 's/,.*//' || echo "Unknown")
CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "?")
TOTAL_RAM=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo "Unknown")
USED_RAM=$(free -h 2>/dev/null | awk '/^Mem:/{print $3}' || echo "Unknown")
TOTAL_DISK=$(df -h / 2>/dev/null | awk 'NR==2{print $2}' || echo "Unknown")
USED_DISK=$(df -h / 2>/dev/null | awk 'NR==2{print $3}' || echo "Unknown")
IP_LOCAL=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "Unknown")
IP_PUBLIC=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || curl -s --max-time 5 ipinfo.io/ip 2>/dev/null || echo "N/A")
TOTAL_USERS=$(cat /etc/passwd 2>/dev/null | wc -l || echo "?")
SUDO_USERS=$(grep -Po '^sudo.+:\K.*$' /etc/group 2>/dev/null || echo "None")
DATE_NOW=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date || echo "Unknown")

# Detect SSH port
SSH_PORT="22"
if [ -f /etc/ssh/sshd_config ]; then
  DETECTED_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
  if [ -n "$DETECTED_PORT" ]; then
    SSH_PORT="$DETECTED_PORT"
  fi
fi

# Detect SSH status
SSH_STATUS="Unknown"
if command -v systemctl > /dev/null 2>&1; then
  if systemctl is-active sshd > /dev/null 2>&1 || systemctl is-active ssh > /dev/null 2>&1; then
    SSH_STATUS="Active ✓"
  else
    SSH_STATUS="Inactive ✗"
  fi
elif command -v service > /dev/null 2>&1; then
  if service sshd status > /dev/null 2>&1 || service ssh status > /dev/null 2>&1; then
    SSH_STATUS="Active ✓"
  else
    SSH_STATUS="Inactive ✗"
  fi
fi

# Detect auth method
SSH_AUTH="Password"
if [ -f /etc/ssh/sshd_config ]; then
  PASS_AUTH=$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
  if [ "$PASS_AUTH" = "no" ]; then
    SSH_AUTH="Key Only"
  fi
fi

printf "  ${D}┌────────────────────────────────────────────┐${N}\n"
printf "  ${D}│${N} ${R}♦${N} ${W}Hostname  ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$HOSTNAME_SRV"
printf "  ${D}│${N} ${R}♦${N} ${W}OS        ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$OS_NAME"
printf "  ${D}│${N} ${R}♦${N} ${W}Kernel    ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$KERNEL"
printf "  ${D}│${N} ${R}♦${N} ${W}Arch      ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$ARCH"
printf "  ${D}│${N} ${R}♦${N} ${W}CPU       ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "${CPU_CORES} Cores"
printf "  ${D}│${N} ${R}♦${N} ${W}RAM       ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "${USED_RAM} / ${TOTAL_RAM}"
printf "  ${D}│${N} ${R}♦${N} ${W}Disk /    ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "${USED_DISK} / ${TOTAL_DISK}"
printf "  ${D}│${N} ${R}♦${N} ${W}Uptime    ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$UPTIME"
printf "  ${D}├────────────────────────────────────────────┤${N}\n"
printf "  ${D}│${N} ${Y}♦${N} ${W}Local IP  ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$IP_LOCAL"
printf "  ${D}│${N} ${Y}♦${N} ${W}Public IP ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$IP_PUBLIC"
printf "  ${D}├────────────────────────────────────────────┤${N}\n"
printf "  ${D}│${N} ${M}♦${N} ${W}SSH Port  ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$SSH_PORT"
printf "  ${D}│${N} ${M}♦${N} ${W}SSH Status${D}:${N} ${G}%-27s${N}${D}│${N}\n" "$SSH_STATUS"
printf "  ${D}│${N} ${M}♦${N} ${W}SSH Auth  ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$SSH_AUTH"
printf "  ${D}├────────────────────────────────────────────┤${N}\n"
printf "  ${D}│${N} ${G}♦${N} ${W}Users     ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "${TOTAL_USERS} total"
printf "  ${D}│${N} ${G}♦${N} ${W}Sudoers   ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$SUDO_USERS"
printf "  ${D}│${N} ${G}♦${N} ${W}Date      ${D}:${N} ${C}%-27s${N}${D}│${N}\n" "$DATE_NOW"
printf "  ${D}└────────────────────────────────────────────┘${N}\n"
printf "\n"
sleep 0.5

# ===== PHASE 3: CREATE USER =====
printf "  ${BG_G}${W} PHASE 3 ${N} ${G}Create New User${N}\n"
line
printf "\n"

# Input username
printf "  ${Y}⟫${N} ${W}Username baru${N} : "
read USERNAME

# Validate
if [ -z "$USERNAME" ]; then
  printf "\n  ${R}[✗] Username tidak boleh kosong!${N}\n\n"
  exit 1
fi

# Check if exists
if id "$USERNAME" > /dev/null 2>&1; then
  printf "\n  ${R}[✗] User '${W}${USERNAME}${R}' sudah ada di system!${N}\n\n"
  exit 1
fi

# Input password
printf "  ${Y}⟫${N} ${W}Password${N}      : "
stty -echo 2>/dev/null
read PASSWORD
stty echo 2>/dev/null
printf "${D}(hidden)${N}\n"

printf "  ${Y}⟫${N} ${W}Konfirmasi${N}    : "
stty -echo 2>/dev/null
read PASSWORD2
stty echo 2>/dev/null
printf "${D}(hidden)${N}\n"

# Validate password
if [ -z "$PASSWORD" ]; then
  printf "\n  ${R}[✗] Password tidak boleh kosong!${N}\n\n"
  exit 1
fi

if [ "$PASSWORD" != "$PASSWORD2" ]; then
  printf "\n  ${R}[✗] Password tidak cocok!${N}\n\n"
  exit 1
fi

printf "\n"
line

# Confirmation
printf "\n  ${Y}[?] Buat user ${W}'${USERNAME}'${Y} dengan akses root? ${D}(y/n)${N} : "
read CONFIRM

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  printf "\n  ${R}[✗] Dibatalkan oleh user${N}\n\n"
  exit 0
fi

printf "\n"

# ===== CREATING USER =====
spinner "Creating user '${USERNAME}'"

useradd -m -s /bin/bash "$USERNAME" 2>/dev/null
if [ $? -ne 0 ]; then
  adduser --disabled-password --gecos "" "$USERNAME" 2>/dev/null
  if [ $? -ne 0 ]; then
    printf "  ${R}[✗] Gagal membuat user!${N}\n\n"
    exit 1
  fi
fi

spinner "Setting password"
echo "${USERNAME}:${PASSWORD}" | chpasswd 2>/dev/null

spinner "Adding to sudo group"
usermod -aG sudo "$USERNAME" 2>/dev/null
if [ $? -ne 0 ]; then
  usermod -aG wheel "$USERNAME" 2>/dev/null
fi

spinner "Setting home directory permissions"
chmod 750 "/home/${USERNAME}" 2>/dev/null

spinner "Verifying user"

# Verify
NEW_UID=$(id -u "$USERNAME" 2>/dev/null)
NEW_GID=$(id -g "$USERNAME" 2>/dev/null)
NEW_GROUPS=$(id -Gn "$USERNAME" 2>/dev/null)
NEW_SHELL=$(grep "^${USERNAME}:" /etc/passwd 2>/dev/null | cut -d: -f7)

printf "\n"

# ===== PHASE 4: RESULT =====
printf "  ${BG_G}${W} PHASE 4 ${N} ${G}User Created Successfully!${N}\n"
line
printf "\n"

printf "  ${D}┌──────────────────────────────────────────────┐${N}\n"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}│${N}   ${G}✓ USER BERHASIL DIBUAT!${N}                    ${D}│${N}\n"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}│${N}   ${W}Username ${D}: ${C}%-32s${N}${D}│${N}\n" "$USERNAME"
printf "  ${D}│${N}   ${W}UID      ${D}: ${C}%-32s${N}${D}│${N}\n" "$NEW_UID"
printf "  ${D}│${N}   ${W}GID      ${D}: ${C}%-32s${N}${D}│${N}\n" "$NEW_GID"
printf "  ${D}│${N}   ${W}Home     ${D}: ${C}%-32s${N}${D}│${N}\n" "/home/${USERNAME}"
printf "  ${D}│${N}   ${W}Shell    ${D}: ${C}%-32s${N}${D}│${N}\n" "$NEW_SHELL"
printf "  ${D}│${N}   ${W}Groups   ${D}: ${C}%-32s${N}${D}│${N}\n" "$NEW_GROUPS"
printf "  ${D}│${N}   ${W}Sudo     ${D}: ${G}%-32s${N}${D}│${N}\n" "Enabled ✓"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}└──────────────────────────────────────────────┘${N}\n"

printf "\n"

# ===== PHASE 5: CONNECTION INFO =====
printf "  ${BG_C}${W} PHASE 5 ${N} ${C}Connection Information${N}\n"
line
printf "\n"

spinner "Generating login credentials"
printf "\n"

# Build SSH command
if [ "$SSH_PORT" = "22" ]; then
  SSH_CMD_LOCAL="ssh ${USERNAME}@${IP_LOCAL}"
  SSH_CMD_PUBLIC="ssh ${USERNAME}@${IP_PUBLIC}"
else
  SSH_CMD_LOCAL="ssh -p ${SSH_PORT} ${USERNAME}@${IP_LOCAL}"
  SSH_CMD_PUBLIC="ssh -p ${SSH_PORT} ${USERNAME}@${IP_PUBLIC}"
fi

printf "  ${D}┌──────────────────────────────────────────────┐${N}\n"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}│${N}   ${Y}★ LOGIN INFORMATION${N}                        ${D}│${N}\n"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}│${N}   ${W}IP Local  ${D}: ${C}%-32s${N}${D}│${N}\n" "$IP_LOCAL"
printf "  ${D}│${N}   ${W}IP Public ${D}: ${C}%-32s${N}${D}│${N}\n" "$IP_PUBLIC"
printf "  ${D}│${N}   ${W}SSH Port  ${D}: ${C}%-32s${N}${D}│${N}\n" "$SSH_PORT"
printf "  ${D}│${N}   ${W}Username  ${D}: ${C}%-32s${N}${D}│${N}\n" "$USERNAME"
printf "  ${D}│${N}   ${W}Auth      ${D}: ${C}%-32s${N}${D}│${N}\n" "$SSH_AUTH"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}├──────────────────────────────────────────────┤${N}\n"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}│${N}   ${M}⟫ Login via Local Network:${N}                 ${D}│${N}\n"
printf "  ${D}│${N}   ${Y}  %-40s${N}${D}│${N}\n" "$SSH_CMD_LOCAL"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}│${N}   ${M}⟫ Login via Public IP:${N}                     ${D}│${N}\n"
printf "  ${D}│${N}   ${Y}  %-40s${N}${D}│${N}\n" "$SSH_CMD_PUBLIC"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}│${N}   ${M}⟫ Login Lokal:${N}                             ${D}│${N}\n"
printf "  ${D}│${N}   ${Y}  su - %-36s${N}${D}│${N}\n" "$USERNAME"
printf "  ${D}│${N}                                              ${D}│${N}\n"
printf "  ${D}└──────────────────────────────────────────────┘${N}\n"

# Warning jika SSH auth key-only
if [ "$SSH_AUTH" = "Key Only" ]; then
  printf "\n"
  printf "  ${R}[!] WARNING: SSH dikonfigurasi Key-Only${N}\n"
  printf "  ${D}    Password login via SSH tidak akan bisa.${N}\n"
  printf "  ${D}    Tambahkan SSH key ke: /home/${USERNAME}/.ssh/authorized_keys${N}\n"
fi

# Warning jika public IP N/A
if [ "$IP_PUBLIC" = "N/A" ]; then
  printf "\n"
  printf "  ${Y}[!] NOTE: Public IP tidak terdeteksi${N}\n"
  printf "  ${D}    Server mungkin di belakang NAT/Firewall.${N}\n"
  printf "  ${D}    Gunakan IP Local untuk login.${N}\n"
fi

printf "\n"
dline
printf "\n"
printf "  ${D}Script by${N} ${R}AstarGanz${N} ${D}|${N} ${C}Telegram: @ibarat1337${N}\n"
printf "  ${D}${DIM}https://t.me/ibarat1337${N}\n"
printf "\n"
dline
printf "\n"