#!/bin/bash

# ============================================================
#  deploy_gsocket.sh — gsocket deployment (LOCAL, NO ENCRYPT)
#  Hanya menjalankan gs-netcat langsung tanpa bincrypter.
#
#  Struktur direktori yang dibutuhkan:
#    ./gs-netcat          ← binary gs-netcat (sudah ada lokal)
#
#  Cara pakai:
#    chmod +x deploy_gsocket.sh
#    ./deploy_gsocket.sh
#
#  Atau tentukan path binary manual:
#    GSNETCAT_PATH="/opt/tools/gs-netcat" ./deploy_gsocket.sh
#
#  Atau tentukan secret manual:
#    GS_SECRET="mysecret123" ./deploy_gsocket.sh
# ============================================================

# --- Konfigurasi path (bisa di-override lewat env variable) ---
GSNETCAT_BIN="${GSNETCAT_PATH:-./gs-netcat}"
SECRET_LENGTH=22

# --- Warna output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[*] $1${NC}"; }
log_success() { echo -e "${GREEN}[+] $1${NC}"; }
log_warning() { echo -e "${YELLOW}[!] $1${NC}"; }
log_error()   { echo -e "${RED}[-] $1${NC}" >&2; }

# ------------------------------------------------------------------
# generate_random_string <length>
# ------------------------------------------------------------------
generate_random_string() {
    local length="$1"
    if [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
    elif command -v openssl &>/dev/null; then
        openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$length"
    else
        log_error "Tidak ada sumber randomness (/dev/urandom atau openssl tidak tersedia)."
        exit 1
    fi
}

# ==================================================================
#  MAIN
# ==================================================================

log_info "Starting gsocket deployment (local mode, no encryption)..."

# --- VALIDASI BINARY LOKAL -------------------------------------------
log_info "Memvalidasi binary gs-netcat lokal..."

if [ ! -f "$GSNETCAT_BIN" ]; then
    log_error "gs-netcat tidak ditemukan di: $GSNETCAT_BIN"
    log_error "Letakkan binary gs-netcat di direktori yang sama dengan script ini,"
    log_error "atau set env variable: GSNETCAT_PATH=/path/ke/gs-netcat"
    exit 1
fi

if [ ! -x "$GSNETCAT_BIN" ]; then
    log_warning "gs-netcat belum executable, menambahkan permission..."
    chmod +x "$GSNETCAT_BIN" || {
        log_error "Gagal chmod +x $GSNETCAT_BIN"
        exit 1
    }
fi

log_success "gs-netcat OK → $GSNETCAT_BIN"

# --- SECRET -----------------------------------------------------------
if [ -n "$GS_SECRET" ]; then
    RANDOM_SECRET="$GS_SECRET"
    log_success "Menggunakan secret dari env variable GS_SECRET."
else
    log_info "Generating random secret (${SECRET_LENGTH} karakter)..."
    RANDOM_SECRET=$(generate_random_string "$SECRET_LENGTH")
    if [ -z "$RANDOM_SECRET" ] || [ "${#RANDOM_SECRET}" -ne "$SECRET_LENGTH" ]; then
        log_error "Gagal generate random secret. Exit."
        exit 1
    fi
fi

log_success "Secret: ${YELLOW}${RANDOM_SECRET}${NC}"

# --- LAUNCH GS-NETCAT ------------------------------------------------
GS_ARGS_VAL="-ilD -s ${RANDOM_SECRET}"
log_info "Menjalankan gs-netcat di background..."
log_info "Command: GS_ARGS=\"$GS_ARGS_VAL\" $GSNETCAT_BIN"

GS_ARGS="$GS_ARGS_VAL" "$GSNETCAT_BIN" &
GSNC_PID=$!   # capture PID langsung setelah &, sebelum sleep

sleep 2

# Cek apakah process masih jalan
if kill -0 "$GSNC_PID" 2>/dev/null; then
    log_success "gs-netcat berjalan di background (PID: ${GSNC_PID})."
    log_warning "Monitor: kill -0 ${GSNC_PID} || echo 'process mati'"
else
    # gs-netcat sering self-daemonize (fork + exit parent) — ini normal
    log_warning "PID ${GSNC_PID} tidak terlihat di shell — kemungkinan sudah self-daemonize (normal)."
    log_warning "Cek dengan: pgrep -f gs-netcat  ATAU  ps aux | grep gs-netcat"
fi

# --- SUMMARY ----------------------------------------------------------
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  DEPLOYMENT SELESAI${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "  Secret (connect key) : ${YELLOW}${RANDOM_SECRET}${NC}"
echo -e "  Binary               : ${YELLOW}${GSNETCAT_BIN}${NC}"
echo -e "${GREEN}----------------------------------------${NC}"
echo -e "  Koneksi dari remote  :"
echo -e "  ${YELLOW}gs-netcat -s ${RANDOM_SECRET} -i${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

exit 0
