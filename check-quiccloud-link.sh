#!/bin/bash
###############################################################################
# check-quiccloud-link.sh
# ตรวจสอบ QUIC.cloud Link Status ของทุก addon domain บนเซิร์ฟเวอร์
# ใช้ MySQL query ตรง (ไม่ต้องพึ่ง wp-cli)
###############################################################################

USERDOMAINS="/etc/userdomains"
TRUEUSERDOMAINS="/etc/trueuserdomains"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
GRAY='\033[0;90m'; NC='\033[0m'; BOLD='\033[1m'

total=0
cnt_anonymous=0; cnt_linked=0; cnt_not_activated=0
cnt_no_lscache=0; cnt_no_wp=0; cnt_error=0

declare -a list_anonymous=()
declare -a list_not_activated=()

if [[ ! -f "$USERDOMAINS" || ! -f "$TRUEUSERDOMAINS" ]]; then
    echo -e "${RED}ERROR: /etc/userdomains or /etc/trueuserdomains not found${NC}"; exit 1
fi

declare -A main_domains
declare -A user_main_domain
while IFS= read -r rawline; do
    domain=$(echo "$rawline" | awk -F': ' '{print $1}' | sed 's/:$//' | xargs)
    user=$(echo "$rawline" | awk -F': ' '{print $2}' | xargs)
    [[ -z "$domain" || -z "$user" ]] && continue
    main_domains["$domain"]=1
    user_main_domain["$user"]="$domain"
done < "$TRUEUSERDOMAINS"

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

get_qc_status() {
    local db_host="$1" db_port="$2" db_user="$3" db_pass="$4" db_name="$5" prefix="$6"
    local raw qc mysql_cmd
    mysql_cmd=(mysql -h "$db_host" -u "$db_user" -p"$db_pass" "$db_name" -N)
    [[ -n "$db_port" ]] && mysql_cmd+=(-P "$db_port")
    raw=$("${mysql_cmd[@]}" -e \
        "SELECT option_value FROM \`${prefix}options\` WHERE option_name = 'litespeed.cloud._summary' LIMIT 1;" 2>/dev/null)
    [[ $? -ne 0 || -z "$raw" ]] && return
    qc=$(echo "$raw" | grep -oP '"qc_activated"\s*:\s*"?\K[^",}]+' 2>/dev/null || true)
    [[ -z "$qc" ]] && qc=$(echo "$raw" | grep -oP 's:\d+:"qc_activated";s:\d+:"\K[^"]+' 2>/dev/null || true)
    echo "$qc"
}

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  QUIC.cloud Link Status Check${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

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
    [[ -z "$docroot" ]] && { cnt_error=$((cnt_error + 1)); continue; }
    [[ ! -f "${docroot}/wp-config.php" ]] && { cnt_no_wp=$((cnt_no_wp + 1)); continue; }
    [[ ! -d "${docroot}/wp-content/plugins/litespeed-cache" ]] && { cnt_no_lscache=$((cnt_no_lscache + 1)); continue; }

    parse_wpconfig "${docroot}/wp-config.php"
    [[ -z "$DB_NAME" || -z "$DB_USER" ]] && { cnt_error=$((cnt_error + 1)); continue; }

    qc_status=$(get_qc_status "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$DB_NAME" "$TABLE_PREFIX")

    case "$qc_status" in
        anonymous)  list_anonymous+=("$domain"); cnt_anonymous=$((cnt_anonymous + 1)) ;;
        linked|cdn) cnt_linked=$((cnt_linked + 1)) ;;
        *)          list_not_activated+=("$domain"); cnt_not_activated=$((cnt_not_activated + 1)) ;;
    esac

    echo -ne "\r  Scanned: ${total} domains..."
done < "$USERDOMAINS"

echo -ne "\r                              \r"

# ─── SUMMARY ────────────────────────────────────────────────────────────────
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  SUMMARY${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Total:           ${BOLD}${total}${NC}"
echo -e "  ${RED}Anonymous:       ${cnt_anonymous}${NC}"
echo -e "  ${YELLOW}Not Activated:   ${cnt_not_activated}${NC}"
echo -e "  ${GREEN}Linked (OK):     ${cnt_linked}${NC}"
echo ""

# ─── ANONYMOUS ──────────────────────────────────────────────────────────────
if [[ ${#list_anonymous[@]} -gt 0 ]]; then
    echo -e "${BOLD}${RED}  ★ ANONYMOUS — ต้อง Link to QUIC.cloud${NC}"
    echo -e "${RED}  $(printf '─%.0s' {1..50})${NC}"
    for d in "${list_anonymous[@]}"; do
        echo -e "  ${RED}${d}${NC}"
    done
    echo ""
fi

# ─── NOT ACTIVATED ──────────────────────────────────────────────────────────
if [[ ${#list_not_activated[@]} -gt 0 ]]; then
    echo -e "${BOLD}${YELLOW}  ● NOT ACTIVATED — ยังไม่ enable QUIC.cloud${NC}"
    echo -e "${YELLOW}  $(printf '─%.0s' {1..50})${NC}"
    for d in "${list_not_activated[@]}"; do
        echo -e "  ${YELLOW}${d}${NC}"
    done
    echo ""
fi

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
