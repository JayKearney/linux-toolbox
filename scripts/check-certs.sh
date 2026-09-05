#!/bin/bash

set -euo pipefail

DOMAINS_FILE="$(dirname "$0")/domains.txt"
WARN_DAYS=${1:-30}
CRIT_DAYS=${2:-7}
EXIT_CODE=0

get_expiry_date() {
  local domain=$1
  echo | openssl s_client -servername "$domain" -connect "$domain":443 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null \
    | cut -d= -f2
}

days_until_expiry() {
  local expiry_date=$1
  local expiry_epoch now_epoch
  expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null \
    || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s)
  now_epoch=$(date +%s)
  echo $(( (expiry_epoch - now_epoch) / 86400 ))
}

while IFS= read -r domain; do
  [[ -z "$domain" || "$domain" == \#* ]] && continue

  expiry=$(get_expiry_date "$domain")
  if [[ -z "$expiry" ]]; then
    echo "❌ $domain — could not retrieve certificate"
    EXIT_CODE=2
    continue
  fi

  days_left=$(days_until_expiry "$expiry")

  if (( days_left < 0 )); then
    echo "🔴 CRITICAL: $domain — EXPIRED $(( -days_left )) days ago"
    EXIT_CODE=2
  elif (( days_left < CRIT_DAYS )); then
    echo "🔴 CRITICAL: $domain — expires in $days_left days"
    EXIT_CODE=2
  elif (( days_left < WARN_DAYS )); then
    echo "🟡 WARNING: $domain — expires in $days_left days"
    (( EXIT_CODE < 1 )) && EXIT_CODE=1
  else
    echo "🟢 OK: $domain — $days_left days remaining"
  fi
done < "$DOMAINS_FILE"

exit $EXIT_CODE