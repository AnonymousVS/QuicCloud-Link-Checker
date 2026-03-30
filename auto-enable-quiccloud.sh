#!/bin/bash
###############################################################################
# auto-enable-quiccloud.sh
# Auto enable QUIC.cloud สำหรับทุก addon domain ที่ยังไม่ได้ enable
# ใช้ PHP CLI + WP-CLI (ไม่ใช้ lsphp)
###############################################################################

USERDOMAINS="/etc/userdomains"
TRUEUSERDOMAINS="/etc/trueuserdomains"
PHP_CLI="/opt/cpanel/ea-php83/root/usr/bin/php"
WP_CLI="/usr/local/bin/wp"
WORKERS=$(nproc 2>/dev/null || echo 4)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'; BOLD='\033[1m'

TMPDIR=$(mktemp -d)
WORKLIST="${TMPDIR}/worklist.txt"
RESULT="${TMPDIR}/results.txt"
trap "rm -rf ${TMPDIR}" EXIT

# ─── Prerequisite checks ────────────────────────────────────────────────────
if [[ ! -f "$USERDOMAINS" || ! -f "$TRUEUSERDOMAINS" ]]; then
    echo -e "${RED}ERROR: /etc/userdomains or /etc/trueuserdomains not found${NC}"; exit 1
fi
if [[ ! -f "$PHP_CLI" ]]; then
    echo -e "${RED}ERROR: PHP CLI not found at ${PHP_CLI}${NC}"; exit 1
fi
if [[ ! -f "$WP_CLI" ]]; then
    echo -e "${RED}ERROR: WP-CLI not found at ${WP_CLI}${NC}"; exit 1
fi

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Auto Enable QUIC.cloud${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ─── Server IP (argument $1 หรือ auto-detect) ───────────────────────────────
DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

if [[ -n "$1" ]]; then
    SERVER_IP="$1"
elif [[ -t 0 ]]; then
    # Interactive mode
    echo -e "  Detected Server IP: ${BOLD}${DETECTED_IP}${NC}"
    echo ""
    read -rp "  กด Enter ใช้ IP นี้ หรือ พิมพ์ IP ใหม่: " INPUT_IP
    SERVER_IP="${INPUT_IP:-$DETECTED_IP}"
else
    # Piped mode (curl | bash) — ใช้ auto-detect
    SERVER_IP="$DETECTED_IP"
fi

if [[ -z "$SERVER_IP" ]]; then
    echo -e "${RED}ERROR: ไม่พบ Server IP${NC}"; exit 1
fi
echo -e "  Server IP: ${BOLD}${SERVER_IP}${NC}"
echo ""

# ─── Build main domain list ─────────────────────────────────────────────────
declare -A main_domains
declare -A user_main_domain
while IFS= read -r rawline; do
    domain=$(echo "$rawline" | awk -F': ' '{print $1}' | sed 's/:$//' | xargs)
    user=$(echo "$rawline" | awk -F': ' '{print $2}' | xargs)
    [[ -z "$domain" || -z "$user" ]] && continue
    main_domains["$domain"]=1
    user_main_domain["$user"]="$domain"
done < "$TRUEUSERDOMAINS"

# ─── Phase 1: Find NOT ACTIVATED domains ────────────────────────────────────
echo -e "${GRAY}Phase 1: Scanning for NOT ACTIVATED domains ...${NC}"

parse_wpconfig() {
    local wpconfig="$1"
    DB_NAME=$(grep -oP "DB_NAME['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    DB_USER=$(grep -oP "DB_USER['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    DB_PASS=$(grep -oP "DB_PASSWORD['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    local raw_host
    raw_host=$(grep -oP "DB_HOST['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    TABLE_PREFIX=$(grep '^\$table_prefix' "$wpconfig" | grep -oP "['\"]\\K[^'\"]+(?=['\"])" | head -1)
    if [[ "$raw_host" == *":"* ]]; then
        DB_HOST="${raw_host%%:*}"; DB_PORT="${raw_host##*:}"
    else
        DB_HOST="${raw_host:-localhost}"; DB_PORT=""
    fi
    TABLE_PREFIX="${TABLE_PREFIX:-wp_}"
}

total=0
while IFS= read -r rawline; do
    domain=$(echo "$rawline" | awk -F': ' '{print $1}' | sed 's/:$//' | xargs)
    user=$(echo "$rawline" | awk -F': ' '{print $2}' | xargs)
    [[ -z "$domain" || -z "$user" ]] && continue
    [[ "$domain" == "*" || "$user" == "nobody" ]] && continue
    echo "$domain" | grep -q '\.cp\.' && continue
    [[ -n "${main_domains[$domain]}" ]] && continue
    main_dom="${user_main_domain[$user]}"
    [[ -n "$main_dom" ]] && echo "$domain" | grep -q "\.${main_dom}$" && continue

    total=$((total + 1))

    docroot=""
    [[ -d "/home/${user}/${domain}" ]] && docroot="/home/${user}/${domain}"
    [[ -z "$docroot" && -d "/home/${user}/public_html/${domain}" ]] && docroot="/home/${user}/public_html/${domain}"
    [[ -z "$docroot" ]] && continue
    [[ ! -f "${docroot}/wp-config.php" ]] && continue
    [[ ! -d "${docroot}/wp-content/plugins/litespeed-cache" ]] && continue

    # Check DB for qc_activated
    parse_wpconfig "${docroot}/wp-config.php"
    [[ -z "$DB_NAME" || -z "$DB_USER" ]] && continue

    mysql_cmd=(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N)
    [[ -n "$DB_PORT" ]] && mysql_cmd+=(-P "$DB_PORT")

    raw=$("${mysql_cmd[@]}" -e \
        "SELECT option_value FROM \`${TABLE_PREFIX}options\` WHERE option_name = 'litespeed.cloud._summary' LIMIT 1;" 2>/dev/null)

    qc=""
    if [[ $? -eq 0 ]] && [[ -n "$raw" ]]; then
        qc=$(echo "$raw" | grep -oP '"qc_activated"\s*:\s*"?\K[^",}]+' 2>/dev/null || true)
    fi

    # Only NOT ACTIVATED
    case "$qc" in
        anonymous|linked|cdn) continue ;;
    esac

    # domain|user|docroot
    echo "${domain}|${user}|${docroot}" >> "$WORKLIST"

    echo -ne "\r  Scanned: ${total} domains..."

done < "$USERDOMAINS"

echo -ne "\r                              \r"

need_count=$(wc -l < "$WORKLIST" 2>/dev/null || echo 0)
echo -e "  Total scanned: ${BOLD}${total}${NC}"
echo -e "  NOT ACTIVATED: ${BOLD}${need_count}${NC}"
echo ""

if [[ "$need_count" -eq 0 ]]; then
    echo -e "${GREEN}  ✓ ทุกเว็บ enable QUIC.cloud แล้ว ไม่ต้องทำอะไร${NC}"
    exit 0
fi

# ─── Confirm ─────────────────────────────────────────────────────────────────
echo -e "${YELLOW}  จะ auto-enable QUIC.cloud ให้ ${need_count} เว็บ${NC}"
if [[ -t 0 ]]; then
    read -rp "  ดำเนินการต่อ? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${GRAY}  ยกเลิก${NC}"; exit 0
    fi
else
    echo -e "${GRAY}  (pipe mode — ดำเนินการอัตโนมัติ)${NC}"
fi
echo ""

# ─── Phase 2: Auto Enable (parallel) ────────────────────────────────────────
echo -e "${GRAY}Phase 2: Enabling QUIC.cloud (${WORKERS} workers) ...${NC}"
echo ""

enable_domain() {
    local line="$1"
    local server_ip="$2"
    local php_cli="$3"
    local wp_cli="$4"
    IFS='|' read -r domain user docroot <<< "$line"

    # Step 1: Set server IP
    local set_ip
    set_ip=$(sudo -u "$user" -i -- "$php_cli" "$wp_cli" litespeed-option set server_ip "$server_ip" --path="$docroot" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "FAIL|${domain}|set_ip: ${set_ip}"
        return
    fi

    # Step 2: Init QUIC.cloud
    local init_result
    init_result=$(sudo -u "$user" -i -- "$php_cli" "$wp_cli" litespeed-online init --path="$docroot" 2>&1)
    if echo "$init_result" | grep -q "successfully\|Init successfully"; then
        echo "OK|${domain}"
    else
        echo "FAIL|${domain}|init: ${init_result}"
    fi
}
export -f enable_domain

if command -v parallel &>/dev/null; then
    cat "$WORKLIST" | parallel -j "$WORKERS" --will-cite enable_domain {} "$SERVER_IP" "$PHP_CLI" "$WP_CLI" > "$RESULT"
else
    cat "$WORKLIST" | xargs -P "$WORKERS" -I {} bash -c 'enable_domain "$@"' _ {} "$SERVER_IP" "$PHP_CLI" "$WP_CLI" > "$RESULT"
fi

# ─── Phase 3: Report ────────────────────────────────────────────────────────
cnt_ok=$(grep -c '^OK|' "$RESULT" 2>/dev/null || echo 0)
cnt_fail=$(grep -c '^FAIL|' "$RESULT" 2>/dev/null || echo 0)

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  RESULT${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}✓ Enabled OK:    ${cnt_ok}${NC}"
echo -e "  ${RED}✗ Failed:        ${cnt_fail}${NC}"
echo ""

if [[ "$cnt_fail" -gt 0 ]]; then
    echo -e "${BOLD}${RED}  ✗ FAILED domains:${NC}"
    echo -e "${RED}  $(printf '─%.0s' {1..50})${NC}"
    grep '^FAIL|' "$RESULT" | while IFS='|' read -r status domain reason; do
        echo -e "  ${RED}${domain}${NC}"
        echo -e "  ${GRAY}  → ${reason}${NC}"
    done
    echo ""
fi

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
