#!/bin/bash
###############################################################################
# check-quiccloud-link.sh
# ตรวจสอบ QUIC.cloud Link Status ของทุก addon domain บนเซิร์ฟเวอร์
# ใช้ MySQL query ตรง + Parallel processing
###############################################################################

USERDOMAINS="/etc/userdomains"
TRUEUSERDOMAINS="/etc/trueuserdomains"

# จำนวน parallel workers (auto-detect CPU cores)
WORKERS=$(nproc 2>/dev/null || echo 4)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
GRAY='\033[0;90m'; NC='\033[0m'; BOLD='\033[1m'

TMPDIR=$(mktemp -d)
WORKLIST="${TMPDIR}/worklist.txt"
RESULT="${TMPDIR}/results.txt"
trap "rm -rf ${TMPDIR}" EXIT

if [[ ! -f "$USERDOMAINS" || ! -f "$TRUEUSERDOMAINS" ]]; then
    echo -e "${RED}ERROR: /etc/userdomains or /etc/trueuserdomains not found${NC}"; exit 1
fi

echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  QUIC.cloud Link Status Check (${WORKERS} workers)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ─── Phase 1: Build domain list (single-thread, fast) ───────────────────────
echo -e "${GRAY}Phase 1: Building domain list ...${NC}"

declare -A main_domains
declare -A user_main_domain
while IFS= read -r rawline; do
    domain=$(echo "$rawline" | awk -F': ' '{print $1}' | sed 's/:$//' | xargs)
    user=$(echo "$rawline" | awk -F': ' '{print $2}' | xargs)
    [[ -z "$domain" || -z "$user" ]] && continue
    main_domains["$domain"]=1
    user_main_domain["$user"]="$domain"
done < "$TRUEUSERDOMAINS"

total=0
cnt_no_wp=0; cnt_no_lscache=0; cnt_error=0

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

    # Find docroot
    docroot=""
    [[ -d "/home/${user}/${domain}" ]] && docroot="/home/${user}/${domain}"
    [[ -z "$docroot" && -d "/home/${user}/public_html/${domain}" ]] && docroot="/home/${user}/public_html/${domain}"
    [[ -z "$docroot" ]] && { cnt_error=$((cnt_error + 1)); continue; }
    [[ ! -f "${docroot}/wp-config.php" ]] && { cnt_no_wp=$((cnt_no_wp + 1)); continue; }
    [[ ! -d "${docroot}/wp-content/plugins/litespeed-cache" ]] && { cnt_no_lscache=$((cnt_no_lscache + 1)); continue; }

    # Parse wp-config.php
    wpconfig="${docroot}/wp-config.php"
    db_name=$(grep -oP "DB_NAME['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    db_user=$(grep -oP "DB_USER['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    db_pass=$(grep -oP "DB_PASSWORD['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    raw_host=$(grep -oP "DB_HOST['\"]\\s*,\\s*['\"]\\K[^'\"]+(?=['\"])" "$wpconfig" | head -1)
    prefix=$(grep '^\$table_prefix' "$wpconfig" | grep -oP "['\"]\\K[^'\"]+(?=['\"])" | head -1)

    if [[ "$raw_host" == *":"* ]]; then
        db_host="${raw_host%%:*}"; db_port="${raw_host##*:}"
    else
        db_host="${raw_host:-localhost}"; db_port=""
    fi
    prefix="${prefix:-wp_}"

    [[ -z "$db_name" || -z "$db_user" ]] && { cnt_error=$((cnt_error + 1)); continue; }

    # Write to worklist: domain|db_host|db_port|db_user|db_pass|db_name|prefix
    echo "${domain}|${db_host}|${db_port}|${db_user}|${db_pass}|${db_name}|${prefix}" >> "$WORKLIST"

done < "$USERDOMAINS"

wp_count=$(wc -l < "$WORKLIST" 2>/dev/null || echo 0)
echo -e "  Total: ${BOLD}${total}${NC} domains, ${BOLD}${wp_count}${NC} WordPress+LSCache to query"
echo ""

# ─── Phase 2: Parallel MySQL queries ────────────────────────────────────────
echo -e "${GRAY}Phase 2: Querying databases (${WORKERS} parallel workers) ...${NC}"

check_domain() {
    local line="$1"
    IFS='|' read -r domain db_host db_port db_user db_pass db_name prefix <<< "$line"

    local mysql_cmd=(mysql -h "$db_host" -u "$db_user" -p"$db_pass" "$db_name" -N --connect-timeout=5)
    [[ -n "$db_port" ]] && mysql_cmd+=(-P "$db_port")

    local raw qc
    raw=$("${mysql_cmd[@]}" -e \
        "SELECT option_value FROM \`${prefix}options\` WHERE option_name = 'litespeed.cloud._summary' LIMIT 1;" 2>/dev/null)

    if [[ $? -ne 0 ]] || [[ -z "$raw" ]]; then
        echo "not_activated|${domain}"
        return
    fi

    qc=$(echo "$raw" | grep -oP '"qc_activated"\s*:\s*"?\K[^",}]+' 2>/dev/null || true)
    [[ -z "$qc" ]] && qc=$(echo "$raw" | grep -oP 's:\d+:"qc_activated";s:\d+:"\K[^"]+' 2>/dev/null || true)

    case "$qc" in
        anonymous)  echo "anonymous|${domain}" ;;
        linked|cdn) echo "linked|${domain}" ;;
        *)          echo "not_activated|${domain}" ;;
    esac
}
export -f check_domain

# Run parallel
if command -v parallel &>/dev/null; then
    # GNU parallel available
    cat "$WORKLIST" | parallel -j "$WORKERS" --will-cite check_domain > "$RESULT"
else
    # Fallback: xargs -P
    cat "$WORKLIST" | xargs -P "$WORKERS" -I {} bash -c 'check_domain "$@"' _ {} > "$RESULT"
fi

# ─── Phase 3: Aggregate results ─────────────────────────────────────────────
cnt_anonymous=$(grep -c '^anonymous|' "$RESULT" 2>/dev/null || echo 0)
cnt_linked=$(grep -c '^linked|' "$RESULT" 2>/dev/null || echo 0)
cnt_not_activated=$(grep -c '^not_activated|' "$RESULT" 2>/dev/null || echo 0)

mapfile -t list_anonymous < <(grep '^anonymous|' "$RESULT" | cut -d'|' -f2 | sort)
mapfile -t list_not_activated < <(grep '^not_activated|' "$RESULT" | cut -d'|' -f2 | sort)

echo ""

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
