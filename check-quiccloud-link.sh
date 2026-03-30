#!/bin/bash
###############################################################################
# check-quiccloud-link.sh
# ตรวจสอบ QUIC.cloud Link Status ของทุก addon domain บนเซิร์ฟเวอร์
# ใช้ MySQL query ตรง (ไม่ต้องพึ่ง wp-cli)
#
# สถานะ:
#   anonymous      = activate แล้วแต่ยังไม่ link account ← ปุ่ม "Link to QUIC.cloud"
#   (empty)        = ยังไม่ activate QUIC.cloud เลย
#   linked / cdn   = สมบูรณ์แล้ว (ใช้ Cloudflare เป็น CDN)
###############################################################################

USERDOMAINS="/etc/userdomains"
TRUEUSERDOMAINS="/etc/trueuserdomains"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
GRAY='\033[0;90m'; NC='\033[0m'; BOLD='\033[1m'

# Counters
total=0
cnt_anonymous=0; cnt_linked=0; cnt_not_activated=0
cnt_no_lscache=0; cnt_no_wp=0; cnt_error=0

# Result arrays
declare -a list_anonymous=()
declare -a list_linked=()
declare -a list_not_activated=()
declare -a list_no_lscache=()
declare -a list_no_wp=()
declare -a list_error=()

# ─── Prerequisite checks ────────────────────────────────────────────────────
if [[ ! -f "$USERDOMAINS" ]]; then
    echo -e "${RED}ERROR: $USERDOMAINS not found${NC}"; exit 1
fi
if [[ ! -f "$TRUEUSERDOMAINS" ]]; then
    echo -e "${RED}ERROR: $TRUEUSERDOMAINS not found${NC}"; exit 1
fi

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

# ─── Function: parse wp-config.php ──────────────────────────────────────────
parse_wpconfig() {
    local wpconfig="$1"
    DB_NAME=$(grep -oP "DB_NAME['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    DB_USER=$(grep -oP "DB_USER['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    DB_PASS=$(grep -oP "DB_PASSWORD['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    DB_HOST=$(grep -oP "DB_HOST['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    TABLE_PREFIX=$(grep '^\$table_prefix' "$wpconfig" | grep -oP "['\"]\\K[^'\"]+(?=['\"])" | head -1)
    DB_HOST="${DB_HOST:-localhost}"
    TABLE_PREFIX="${TABLE_PREFIX:-wp_}"
}

# ─── Function: get qc_activated via MySQL ───────────────────────────────────
get_qc_status() {
    local db_host="$1" db_user="$2" db_pass="$3" db_name="$4" prefix="$5"
    local raw qc

    raw=$(mysql -h "$db_host" -u "$db_user" -p"$db_pass" "$db_name" -N -e \
        "SELECT option_value FROM \`${prefix}options\` WHERE option_name = 'litespeed.cloud._summary' LIMIT 1;" 2>/dev/null)

    if [[ $? -ne 0 ]] || [[ -z "$raw" ]]; then
        echo ""
        return
    fi

    # JSON parse
    qc=$(echo "$raw" | grep -oP '"qc_activated"\s*:\s*"?\K[^",}]+' 2>/dev/null || true)

    # Fallback: PHP serialized
    if [[ -z "$qc" ]]; then
        qc=$(echo "$raw" | grep -oP 's:\d+:"qc_activated";s:\d+:"\K[^"]+' 2>/dev/null || true)
    fi

    echo "$qc"
}

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  QUIC.cloud Link Status Check - All Addon Domains${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GRAY}Scanning /etc/userdomains ...${NC}"
echo ""

# ─── Process each domain ────────────────────────────────────────────────────
while IFS= read -r rawline; do
    domain=$(echo "$rawline" | awk -F': ' '{print $1}' | sed 's/:$//' | xargs)
    user=$(echo "$rawline" | awk -F': ' '{print $2}' | xargs)

    [[ -z "$domain" || -z "$user" ]] && continue
    [[ "$domain" == "*" ]] && continue
    [[ "$user" == "nobody" ]] && continue
    echo "$domain" | grep -q '\.cp\.' && continue

    # Filter out main domains
    [[ -n "${main_domains[$domain]}" ]] && continue

    # Filter out cPanel subdomains
    main_dom="${user_main_domain[$user]}"
    if [[ -n "$main_dom" ]] && echo "$domain" | grep -q "\.${main_dom}$"; then
        continue
    fi

    # ─── Addon domain found ──────────────────────────────────────────────
    total=$((total + 1))

    # Find document root
    docroot=""
    if [[ -d "/home/${user}/${domain}" ]]; then
        docroot="/home/${user}/${domain}"
    elif [[ -d "/home/${user}/public_html/${domain}" ]]; then
        docroot="/home/${user}/public_html/${domain}"
    fi

    if [[ -z "$docroot" ]]; then
        list_error+=("${domain}|${user}|PATH_NOT_FOUND")
        cnt_error=$((cnt_error + 1))
        continue
    fi

    # Check WordPress
    if [[ ! -f "${docroot}/wp-config.php" ]]; then
        list_no_wp+=("${domain}|${user}|${docroot}")
        cnt_no_wp=$((cnt_no_wp + 1))
        continue
    fi

    # Check LiteSpeed Cache plugin
    if [[ ! -d "${docroot}/wp-content/plugins/litespeed-cache" ]]; then
        list_no_lscache+=("${domain}|${user}|${docroot}")
        cnt_no_lscache=$((cnt_no_lscache + 1))
        continue
    fi

    # Parse wp-config.php
    parse_wpconfig "${docroot}/wp-config.php"

    if [[ -z "$DB_NAME" ]] || [[ -z "$DB_USER" ]]; then
        list_error+=("${domain}|${user}|DB_PARSE_FAILED")
        cnt_error=$((cnt_error + 1))
        continue
    fi

    # Query MySQL
    qc_status=$(get_qc_status "$DB_HOST" "$DB_USER" "$DB_PASS" "$DB_NAME" "$TABLE_PREFIX")

    # Classify
    case "$qc_status" in
        anonymous)
            list_anonymous+=("${domain}|${user}|${docroot}")
            cnt_anonymous=$((cnt_anonymous + 1))
            ;;
        linked|cdn)
            list_linked+=("${domain}|${user}|${docroot}")
            cnt_linked=$((cnt_linked + 1))
            ;;
        *)
            list_not_activated+=("${domain}|${user}|${docroot}")
            cnt_not_activated=$((cnt_not_activated + 1))
            ;;
    esac

    # Progress indicator
    echo -ne "\r  Scanned: ${total} domains..."

done < "$USERDOMAINS"

echo -ne "\r                              \r"

# ─── SUMMARY ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  SUMMARY${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Total addon domains scanned:   ${BOLD}${total}${NC}"
echo ""
echo -e "  ${RED}● ANONYMOUS (Need Link):       ${cnt_anonymous}${NC}"
echo -e "  ${YELLOW}● NOT ACTIVATED:               ${cnt_not_activated}${NC}"
echo -e "  ${GREEN}● LINKED (OK):                 ${cnt_linked}${NC}"
echo -e "  ${GRAY}● No LiteSpeed Cache plugin:   ${cnt_no_lscache}${NC}"
echo -e "  ${GRAY}● No WordPress:                ${cnt_no_wp}${NC}"
echo -e "  ${GRAY}● Error/Path not found:        ${cnt_error}${NC}"
echo ""

# ─── ANONYMOUS ──────────────────────────────────────────────────────────────
if [[ ${#list_anonymous[@]} -gt 0 ]]; then
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${RED}  ★ ANONYMOUS — ต้อง Link to QUIC.cloud (${cnt_anonymous} sites)${NC}"
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════${NC}"
    printf "  ${RED}%-40s %-20s %s${NC}\n" "DOMAIN" "USER" "PATH"
    echo -e "  ${RED}$(printf '─%.0s' {1..80})${NC}"
    for entry in "${list_anonymous[@]}"; do
        IFS='|' read -r d u p <<< "$entry"
        printf "  %-40s %-20s %s\n" "$d" "$u" "$p"
    done
    echo ""
fi

# ─── NOT ACTIVATED ──────────────────────────────────────────────────────────
if [[ ${#list_not_activated[@]} -gt 0 ]]; then
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${YELLOW}  ● NOT ACTIVATED — ยังไม่ enable QUIC.cloud (${cnt_not_activated} sites)${NC}"
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    printf "  ${YELLOW}%-40s %-20s %s${NC}\n" "DOMAIN" "USER" "PATH"
    echo -e "  ${YELLOW}$(printf '─%.0s' {1..80})${NC}"
    for entry in "${list_not_activated[@]}"; do
        IFS='|' read -r d u p <<< "$entry"
        printf "  %-40s %-20s %s\n" "$d" "$u" "$p"
    done
    echo ""
fi

# ─── LINKED (OK) ────────────────────────────────────────────────────────────
if [[ ${#list_linked[@]} -gt 0 ]]; then
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  ✓ LINKED — สมบูรณ์แล้ว (${cnt_linked} sites)${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    printf "  ${GREEN}%-40s %-20s %s${NC}\n" "DOMAIN" "USER" "PATH"
    echo -e "  ${GREEN}$(printf '─%.0s' {1..80})${NC}"
    for entry in "${list_linked[@]}"; do
        IFS='|' read -r d u p <<< "$entry"
        printf "  %-40s %-20s %s\n" "$d" "$u" "$p"
    done
    echo ""
fi

# ─── NO LITESPEED CACHE ────────────────────────────────────────────────────
if [[ ${#list_no_lscache[@]} -gt 0 ]]; then
    echo -e "${GRAY}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${GRAY}  No LiteSpeed Cache plugin (${cnt_no_lscache} sites) — skipped${NC}"
    echo -e "${GRAY}───────────────────────────────────────────────────────────────${NC}"
fi

# ─── ERRORS ─────────────────────────────────────────────────────────────────
if [[ ${#list_error[@]} -gt 0 ]]; then
    echo -e "${GRAY}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${GRAY}  Errors (${cnt_error})${NC}"
    echo -e "${GRAY}───────────────────────────────────────────────────────────────${NC}"
    for entry in "${list_error[@]}"; do
        IFS='|' read -r d u reason <<< "$entry"
        echo -e "  ${GRAY}${d} (${u}) — ${reason}${NC}"
    done
    echo ""
fi

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Done. Total: ${total} | Anonymous: ${cnt_anonymous} | Not Activated: ${cnt_not_activated} | Linked: ${cnt_linked}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
