#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════
#  GSOCKET SELF-HEALING FRAMEWORK — COMPLETE UNINSTALLER
#  Purpose: Remove all persistence layers, kernel modules, LD_PRELOAD,
#           and artifacts created by the installer.
#  WARNING: Run as root for complete removal. User-mode removes user layers only.
# ═══════════════════════════════════════════════════════════════════════

set -o pipefail

# ── Configuration (must match installer) ───────────────────────────────
BIN_ALIAS="systemd-networkd-worker"
SERVICE_NAME="systemd-network-monitor"
TIMER_NAME="systemd-network-monitor-timer"
MODULE_NAME="nf_conntrack_helper"
PROFILE_NAME="network-diagnostics"

# ── Logging ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[*] $1${NC}"; }
log_success() { echo -e "${GREEN}[+] $1${NC}"; }
log_warning() { echo -e "${YELLOW}[!] $1${NC}"; }
log_error()   { echo -e "${RED}[-] $1${NC}" >&2; }
log_removed() { echo -e "${CYAN}[-] $1${NC}"; }

# Counters
REMOVED_COUNT=0
FAILED_COUNT=0

# ── Helper: track removal ──────────────────────────────────────────────
mark_removed() {
    REMOVED_COUNT=$((REMOVED_COUNT + 1))
}

mark_failed() {
    FAILED_COUNT=$((FAILED_COUNT + 1))
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 1 — FIND INSTALLED BINARY
# ═══════════════════════════════════════════════════════════════════════
# The binary could be in multiple locations. We search for it by name
# and also by the hash file pattern.
# ═══════════════════════════════════════════════════════════════════════

find_binary() {
    local paths=(
        "/usr/lib/systemd/${BIN_ALIAS}"
        "/usr/lib/x86_64-linux-gnu/${BIN_ALIAS}"
        "/usr/libexec/${BIN_ALIAS}"
        "/var/lib/systemd/${BIN_ALIAS}"
        "$HOME/.local/libexec/${BIN_ALIAS}"
    )

    for p in "${paths[@]}"; do
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done

    # Fallback: search by name
    local found
    found=$(find /usr/lib /usr/libexec /var/lib "$HOME/.local" -name "$BIN_ALIAS" -type f 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

find_hash_file() {
    local bin_path="$1"
    [ -z "$bin_path" ] && return 1

    local dir
    dir=$(dirname "$bin_path")
    local hash_file="${dir}/.$(basename "$bin_path").conf"

    if [ -f "$hash_file" ]; then
        echo "$hash_file"
        return 0
    fi

    # Search for hash files matching pattern
    local found
    found=$(find "$dir" -name ".*.conf" -type f 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

find_launcher() {
    local bin_path="$1"
    [ -z "$bin_path" ] && return 1

    local dir
    dir=$(dirname "$bin_path")
    local launcher="${dir}/.$(basename "$bin_path").launcher"

    if [ -f "$launcher" ]; then
        echo "$launcher"
        return 0
    fi

    return 1
}

find_healer() {
    local bin_path="$1"
    [ -z "$bin_path" ] && return 1

    local dir
    dir=$(dirname "$bin_path")
    local healer="${dir}/.$(basename "$bin_path").heal"

    if [ -f "$healer" ]; then
        echo "$healer"
        return 0
    fi

    return 1
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 2 — KILL RUNNING PROCESSES
# ═══════════════════════════════════════════════════════════════════════

kill_processes() {
    log_info "Terminating running processes..."

    # Kill by exact name match
    local pids
    pids=$(pgrep -x "$BIN_ALIAS" 2>/dev/null)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            if kill -TERM "$pid" 2>/dev/null; then
                log_removed "Sent SIGTERM to PID $pid"
                mark_removed
            else
                log_warning "Failed to signal PID $pid"
                mark_failed
            fi
        done
        sleep 2
        # Force kill if still running
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null
                log_removed "Force-killed PID $pid"
            fi
        done
    else
        log_info "No running processes found"
    fi

    # Also kill healer process
    local healer_name=".$(basename "$BIN_ALIAS" 2>/dev/null).heal"
    if [ -n "$healer_name" ] && [ "$healer_name" != ".heal" ]; then
        local healer_pids
        healer_pids=$(pgrep -f "$healer_name" 2>/dev/null)
        if [ -n "$healer_pids" ]; then
            for pid in $healer_pids; do
                kill -KILL "$pid" 2>/dev/null
                log_removed "Killed healer PID $pid"
                mark_removed
            done
        fi
    fi

    # Remove PID file
    local pid_file="/run/${BIN_ALIAS}.pid"
    [ ! -f "$pid_file" ] && pid_file="/tmp/.${BIN_ALIAS}.pid"
    if [ -f "$pid_file" ]; then
        rm -f "$pid_file"
        log_removed "PID file: $pid_file"
        mark_removed
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 3 — REMOVE PERSISTENCE LAYERS
# ═══════════════════════════════════════════════════════════════════════

# ── Layer 3a: Systemd Service + Timer ──────────────────────────────────
remove_systemd() {
    log_info "Checking systemd layers..."
    local removed=0

    # System services
    if [ -w "/etc/systemd/system" ]; then
        if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
            systemctl stop "${SERVICE_NAME}.service" 2>/dev/null
            systemctl disable "${SERVICE_NAME}.service" 2>/dev/null
            rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
            log_removed "Systemd system service"
            removed=1
        fi
        if [ -f "/etc/systemd/system/${TIMER_NAME}.timer" ]; then
            systemctl stop "${TIMER_NAME}.timer" 2>/dev/null
            systemctl disable "${TIMER_NAME}.timer" 2>/dev/null
            rm -f "/etc/systemd/system/${TIMER_NAME}.timer"
            log_removed "Systemd system timer"
            removed=1
        fi
    fi

    # User services
    if [ -f "$HOME/.config/systemd/user/${SERVICE_NAME}.service" ]; then
        systemctl --user stop "${SERVICE_NAME}.service" 2>/dev/null
        systemctl --user disable "${SERVICE_NAME}.service" 2>/dev/null
        rm -f "$HOME/.config/systemd/user/${SERVICE_NAME}.service"
        log_removed "Systemd user service"
        removed=1
    fi
    if [ -f "$HOME/.config/systemd/user/${TIMER_NAME}.timer" ]; then
        systemctl --user stop "${TIMER_NAME}.timer" 2>/dev/null
        systemctl --user disable "${TIMER_NAME}.timer" 2>/dev/null
        rm -f "$HOME/.config/systemd/user/${TIMER_NAME}.timer"
        log_removed "Systemd user timer"
        removed=1
    fi

    if [ "$removed" -eq 1 ]; then
        systemctl daemon-reload 2>/dev/null
        systemctl --user daemon-reload 2>/dev/null
        mark_removed
    else
        log_info "No systemd layers found"
    fi
}

# ── Layer 3b: Crontab ──────────────────────────────────────────────────
remove_cron() {
    log_info "Checking crontab..."

    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null)

    if echo "$current_crontab" | grep -q "systemd-networkd-worker"; then
        # Remove lines containing our binary or launcher
        echo "$current_crontab" | grep -v "systemd-networkd-worker" | crontab -
        log_removed "Crontab entries"
        mark_removed
    else
        log_info "No crontab entries found"
    fi
}

# ── Layer 3c: Profile Injection ────────────────────────────────────────
remove_profile() {
    log_info "Checking profile files..."
    local removed=0
    local marker="# network-diagnostics-v2"

    for rc_file in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
        [ ! -f "$rc_file" ] && continue
        if grep -q "$marker" "$rc_file" 2>/dev/null; then
            # Remove marker line and the line after it
            sed -i "/${marker}/,+1d" "$rc_file"
            log_removed "Profile injection: $rc_file"
            removed=1
        fi
    done

    # System-wide profile.d
    if [ "$(id -u)" -eq 0 ] && [ -f "/etc/profile.d/${PROFILE_NAME}.sh" ]; then
        rm -f "/etc/profile.d/${PROFILE_NAME}.sh"
        log_removed "System profile.d: /etc/profile.d/${PROFILE_NAME}.sh"
        removed=1
    fi

    if [ "$removed" -eq 1 ]; then
        mark_removed
    else
        log_info "No profile injections found"
    fi
}

# ── Layer 3d: rc.local ─────────────────────────────────────────────────
remove_rclocal() {
    log_info "Checking rc.local..."
    [ "$(id -u)" -ne 0 ] && return

    local rc_local="/etc/rc.local"
    [ ! -f "$rc_local" ] && return

    local marker="# network-monitor-init"
    if grep -q "$marker" "$rc_local" 2>/dev/null; then
        # Remove marker line and the line after it
        sed -i "/${marker}/,+1d" "$rc_local"
        log_removed "rc.local entries"
        mark_removed
    else
        log_info "No rc.local entries found"
    fi
}

# ── Layer 3e: XDG Autostart ────────────────────────────────────────────
remove_xdg_autostart() {
    log_info "Checking XDG autostart..."
    local desktop_file="$HOME/.config/autostart/gnome-keyring-daemon.desktop"

    if [ -f "$desktop_file" ]; then
        # Verify it's ours before deleting
        if grep -q "systemd-networkd-worker" "$desktop_file" 2>/dev/null; then
            rm -f "$desktop_file"
            log_removed "XDG autostart: $desktop_file"
            mark_removed
        else
            log_warning "XDG desktop file exists but doesn't match — skipping"
        fi
    else
        log_info "No XDG autostart found"
    fi
}

# ── Layer 3f: PROMPT_COMMAND ───────────────────────────────────────────
remove_prompt_command() {
    log_info "Checking PROMPT_COMMAND..."
    local removed=0

    for rc_file in "$HOME/.bashrc" "$HOME/.bash_profile"; do
        [ ! -f "$rc_file" ] && continue
        if grep -q "PROMPT_COMMAND.*systemd-networkd-worker" "$rc_file" 2>/dev/null; then
            sed -i "/PROMPT_COMMAND.*systemd-networkd-worker/d" "$rc_file"
            log_removed "PROMPT_COMMAND from: $rc_file"
            removed=1
        fi
    done

    if [ "$removed" -eq 1 ]; then
        mark_removed
    else
        log_info "No PROMPT_COMMAND hooks found"
    fi
}

# ── Layer 3g: SSH Authorized Keys Hook ─────────────────────────────────
remove_ssh_hook() {
    log_info "Checking SSH authorized_keys..."
    local auth_keys="$HOME/.ssh/authorized_keys"

    [ ! -f "$auth_keys" ] && return

    local marker="# network-authorized-key"
    if grep -q "$marker" "$auth_keys" 2>/dev/null; then
        # Remove marker line and the key line after it
        sed -i "/${marker}/,+1d" "$auth_keys"
        log_removed "SSH authorized_keys hook"
        mark_removed
    else
        log_info "No SSH hook found"
    fi
}

# ── Layer 3h: Sudoers Hook ─────────────────────────────────────────────
remove_sudoers_hook() {
    log_info "Checking sudoers..."
    [ "$(id -u)" -ne 0 ] && return

    local sudoers_file="/etc/sudoers.d/010-network-monitor"
    if [ -f "$sudoers_file" ]; then
        rm -f "$sudoers_file"
        log_removed "Sudoers hook: $sudoers_file"
        mark_removed
    else
        log_info "No sudoers hook found"
    fi
}

# ── Layer 3i: PAM Hook ─────────────────────────────────────────────────
remove_pam_hook() {
    log_info "Checking PAM configuration..."
    [ "$(id -u)" -ne 0 ] && return

    local pam_file="/etc/pam.d/common-auth"
    [ ! -f "$pam_file" ] && return

    local marker="# network-auth-check"
    if grep -q "$marker" "$pam_file" 2>/dev/null; then
        # Remove marker line and the pam_exec line after it
        sed -i "/${marker}/,+1d" "$pam_file"
        log_removed "PAM hook from: $pam_file"
        mark_removed
    else
        log_info "No PAM hook found"
    fi
}

# ── Layer 3j: Init.d Script ────────────────────────────────────────────
remove_initd() {
    log_info "Checking init.d..."
    [ "$(id -u)" -ne 0 ] && return

    local init_script="/etc/init.d/network-monitor-helper"
    if [ -f "$init_script" ]; then
        update-rc.d network-monitor-helper remove 2>/dev/null
        rm -f "$init_script"
        log_removed "Init.d script: $init_script"
        mark_removed
    else
        log_info "No init.d script found"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 4 — REMOVE KERNEL MODULE
# ═══════════════════════════════════════════════════════════════════════

remove_lkm() {
    log_info "Checking kernel module..."
    [ "$(id -u)" -ne 0 ] && return

    # Check if module is loaded
    if lsmod 2>/dev/null | grep -q "^${MODULE_NAME} "; then
        rmmod "$MODULE_NAME" 2>/dev/null
        if [ $? -eq 0 ]; then
            log_removed "LKM unloaded: $MODULE_NAME"
            mark_removed
        else
            log_error "Failed to unload LKM: $MODULE_NAME"
            mark_failed
        fi
    else
        log_info "LKM not loaded"
    fi

    # Remove from modules-load.d
    if [ -f "/etc/modules-load.d/modules.conf" ]; then
        if grep -q "^${MODULE_NAME}$" "/etc/modules-load.d/modules.conf" 2>/dev/null; then
            sed -i "/^${MODULE_NAME}$/d" "/etc/modules-load.d/modules.conf"
            log_removed "LKM from modules-load.d"
            mark_removed
        fi
    fi

    # Remove modprobe config
    if [ -f "/etc/modprobe.d/${MODULE_NAME}.conf" ]; then
        rm -f "/etc/modprobe.d/${MODULE_NAME}.conf"
        log_removed "LKM modprobe config"
        mark_removed
    fi

    # Remove kernel module file
    local kver
    kver=$(uname -r)
    local ko_dest="/lib/modules/${kver}/kernel/drivers/net/${MODULE_NAME}.ko"
    if [ -f "$ko_dest" ]; then
        rm -f "$ko_dest"
        depmod -a 2>/dev/null
        log_removed "LKM file: $ko_dest"
        mark_removed
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 5 — REMOVE LD_PRELOAD LIBRARY
# ═══════════════════════════════════════════════════════════════════════

remove_ldpreload() {
    log_info "Checking LD_PRELOAD..."

    # Check both possible locations
    local lib_paths=(
        "/usr/lib/x86_64-linux-gnu/libnfnetlink.so.1"
        "$HOME/.local/lib/libnfnetlink.so.1"
    )

    local removed=0
    for lib_path in "${lib_paths[@]}"; do
        if [ -f "$lib_path" ]; then
            # Verify it's ours
            if grep -q "systemd-networkd-worker" "$lib_path" 2>/dev/null || \
               strings "$lib_path" 2>/dev/null | grep -q "HIDE_PLACEHOLDER"; then
                rm -f "$lib_path"
                log_removed "LD_PRELOAD library: $lib_path"
                removed=1
            fi
        fi
    done

    # Remove from /etc/ld.so.preload
    if [ -f "/etc/ld.so.preload" ]; then
        for lib_path in "${lib_paths[@]}"; do
            if grep -qF "$lib_path" "/etc/ld.so.preload" 2>/dev/null; then
                sed -i "\|${lib_path}|d" "/etc/ld.so.preload"
                log_removed "LD_PRELOAD entry from /etc/ld.so.preload"
                removed=1
            fi
        done
    fi

    if [ "$removed" -eq 1 ]; then
        mark_removed
    else
        log_info "No LD_PRELOAD library found"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 6 — REMOVE BINARY AND SUPPORT FILES
# ═══════════════════════════════════════════════════════════════════════

remove_binary() {
    log_info "Removing binary and support files..."

    local bin_path="$1"
    if [ -z "$bin_path" ]; then
        log_warning "Binary path not found — may have been manually removed"
        return
    fi

    local dir
    dir=$(dirname "$bin_path")
    local base
    base=$(basename "$bin_path")

    # Remove binary
    if [ -f "$bin_path" ]; then
        if command -v shred &>/dev/null; then
            shred -u -- "$bin_path" 2>/dev/null
        else
            rm -f "$bin_path"
        fi
        log_removed "Binary: $bin_path"
        mark_removed
    fi

    # Remove hash file
    local hash_file="${dir}/.${base}.conf"
    if [ -f "$hash_file" ]; then
        if command -v shred &>/dev/null; then
            shred -u -- "$hash_file" 2>/dev/null
        else
            rm -f "$hash_file"
        fi
        log_removed "Hash file: $hash_file"
        mark_removed
    fi

    # Remove launcher
    local launcher="${dir}/.${base}.launcher"
    if [ -f "$launcher" ]; then
        rm -f "$launcher"
        log_removed "Launcher: $launcher"
        mark_removed
    fi

    # Remove healer
    local healer="${dir}/.${base}.heal"
    if [ -f "$healer" ]; then
        rm -f "$healer"
        log_removed "Healer: $healer"
        mark_removed
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 7 — CLEANUP TRACES
# ═══════════════════════════════════════════════════════════════════════

clean_traces() {
    log_info "Cleaning remaining traces..."

    # Clear history
    history -c 2>/dev/null
    > "$HOME/.bash_history" 2>/dev/null

    # Remove work directories
    rm -rf /tmp/systemd-private-* 2>/dev/null

    if [ "$(id -u)" -eq 0 ]; then
        # Clear logs mentioning our components
        for lf in /var/log/auth.log /var/log/syslog /var/log/kern.log; do
            [ -f "$lf" ] && sed -i "/systemd-networkd-worker/d" "$lf" 2>/dev/null
            [ -f "$lf" ] && sed -i "/nf_conntrack_helper/d" "$lf" 2>/dev/null
        done

        # Vacuum journal for our service
        if systemctl status "${SERVICE_NAME}.service" &>/dev/null; then
            journalctl --vacuum-time=1s 2>/dev/null
        fi
    fi

    log_success "Traces cleaned"
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 8 — VERIFICATION
# ═══════════════════════════════════════════════════════════════════════

verify_removal() {
    log_info "Verifying removal..."
    local issues=0

    # Check for running processes
    if pgrep -x "$BIN_ALIAS" >/dev/null 2>&1; then
        log_error "Process still running: $BIN_ALIAS"
        issues=$((issues + 1))
    fi

    # Check systemd
    if systemctl list-units --type=service --all 2>/dev/null | grep -q "$SERVICE_NAME"; then
        log_error "Systemd service still exists"
        issues=$((issues + 1))
    fi

    # Check cron
    if crontab -l 2>/dev/null | grep -q "$BIN_ALIAS"; then
        log_error "Crontab entries still exist"
        issues=$((issues + 1))
    fi

    # Check profile
    if grep -q "network-diagnostics-v2" "$HOME/.bashrc" 2>/dev/null; then
        log_error "Profile injection still exists"
        issues=$((issues + 1))
    fi

    # Check LKM (root only)
    if [ "$(id -u)" -eq 0 ] && lsmod 2>/dev/null | grep -q "^${MODULE_NAME} "; then
        log_error "LKM still loaded"
        issues=$((issues + 1))
    fi

    # Check LD_PRELOAD
    if [ -f "/etc/ld.so.preload" ] && grep -q "libnfnetlink" "/etc/ld.so.preload" 2>/dev/null; then
        log_error "LD_PRELOAD entry still exists"
        issues=$((issues + 1))
    fi

    if [ "$issues" -eq 0 ]; then
        log_success "Verification passed — all layers removed"
        return 0
    else
        log_warning "Verification found $issues remaining issues"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 9 — MAIN
# ═══════════════════════════════════════════════════════════════════════

main() {
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   GSOCKET FRAMEWORK UNINSTALLER              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    if [ "$(id -u)" -ne 0 ]; then
        log_warning "Not running as root — root-only layers will be skipped"
        log_warning "Run with sudo for complete removal"
        echo ""
    fi

    # 1. Find the binary
    log_info "Locating installed binary..."
    local bin_path
    bin_path=$(find_binary)

    if [ -n "$bin_path" ]; then
        log_success "Found binary: $bin_path"
    else
        log_warning "Binary not found — may have been manually removed"
        # Try to find hash file anyway
        local hash_file
        hash_file=$(find_hash_file "")
        if [ -n "$hash_file" ]; then
            log_info "Found hash file: $hash_file"
            bin_path=$(dirname "$hash_file")/${BIN_ALIAS}
        fi
    fi

    # 2. Kill processes first
    kill_processes

    # 3. Remove persistence layers (order matters — remove triggers before targets)
    remove_systemd
    remove_cron
    remove_profile
    remove_rclocal
    remove_xdg_autostart
    remove_prompt_command
    remove_ssh_hook
    remove_sudoers_hook
    remove_pam_hook
    remove_initd

    # 4. Remove kernel-level hiding
    remove_lkm

    # 5. Remove user-space hiding
    remove_ldpreload

    # 6. Remove binary and support files
    remove_binary "$bin_path"

    # 7. Clean traces
    clean_traces

    # 8. Verify
    verify_removal
    local verify_status=$?

    # 9. Summary
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   UNINSTALLATION SUMMARY                     ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
    printf "${GREEN}║${NC} Items removed: ${YELLOW}%3d${NC}                              ${GREEN}║${NC}\n" "$REMOVED_COUNT"
    printf "${GREEN}║${NC} Failures:      ${YELLOW}%3d${NC}                              ${GREEN}║${NC}\n" "$FAILED_COUNT"
    if [ "$verify_status" -eq 0 ]; then
        echo -e "${GREEN}║${NC} Status: ${GREEN}CLEAN${NC}                                ${GREEN}║${NC}"
    else
        echo -e "${GREEN}║${NC} Status: ${RED}ISSUES REMAIN${NC}                        ${GREEN}║${NC}"
    fi
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"

    if [ "$verify_status" -ne 0 ]; then
        log_warning "Some layers could not be removed. Manual inspection may be required."
        log_info "Check: systemctl, crontab -l, ~/.bashrc, /etc/pam.d/common-auth"
        exit 1
    fi

    log_success "System is clean. Ready for retest."
}

main "$@"
