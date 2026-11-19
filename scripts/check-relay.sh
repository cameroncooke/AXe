#!/usr/bin/env bash
# Checks from outside that the AXe Mirror relay service is usable: the published records are
# there, every relay they name answers, and its certificate is not about to expire.
# Run by .github/workflows/relay-monitor.yml on a schedule; a non-zero exit is the alarm.
# Run it by hand the same way: scripts/check-relay.sh
set -u

DOMAIN=${AXE_RELAY_DOMAIN:-axe-cli.com}
TRIES=${AXE_RELAY_TRIES:-3}          # a relay is down only if it fails this many times in a row
PAUSE=${AXE_RELAY_PAUSE:-20}         # seconds between tries
MIN_DAYS=${AXE_RELAY_MIN_CERT_DAYS:-14}
failures=0

fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
pass() { echo "ok    $*"; }

# The text of a TXT record, asked of two public resolvers over HTTPS so that no DNS tool is needed.
txt() {
  local name=$1 answer
  for resolver in https://cloudflare-dns.com/dns-query https://dns.google/resolve; do
    answer=$(curl -fsS -m 10 -H 'accept: application/dns-json' "$resolver?name=$name&type=TXT" 2>/dev/null \
      | python3 -c 'import json,sys; print("".join(json.load(sys.stdin).get("Answer",[{}])[0].get("data","").split("\" \"")).strip("\""))' 2>/dev/null)
    if [ -n "$answer" ]; then echo "$answer"; return 0; fi
  done
  return 1
}

relays_record=$(txt "_relays.$DOMAIN") || relays_record=""
case "$relays_record" in
  "v=1 "*) pass "_relays.$DOMAIN: $relays_record" ;;
  *) fail "_relays.$DOMAIN is missing or not a version 1 record: '$relays_record'" ;;
esac

config_record=$(txt "_mirror.$DOMAIN") || config_record=""
case "$config_record" in
  "v=1"*) pass "_mirror.$DOMAIN is published" ;;
  *) fail "_mirror.$DOMAIN is missing or not a version 1 record: '$config_record'" ;;
esac

relays=$(printf '%s\n' "$relays_record" | tr ' ' '\n' | grep '^https://' || true)
if [ -z "$relays" ]; then fail "the relay record names no relay"; fi

for relay in $relays; do
  host=${relay#https://}; host=${host%%/*}
  up=""
  for try in $(seq 1 "$TRIES"); do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$host/ping" 2>/dev/null)
    if [ "$code" = "200" ]; then up=yes; break; fi
    echo "      $host/ping answered '$code' (try $try of $TRIES)"
    [ "$try" -lt "$TRIES" ] && sleep "$PAUSE"
  done
  if [ -n "$up" ]; then pass "$host answers"; else fail "$host does not answer at /ping"; fi

  end=$(echo | openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -z "$end" ]; then
    fail "$host: the certificate could not be read"
  else
    days=$(python3 -c 'import sys,time,email.utils; print(int((email.utils.mktime_tz(email.utils.parsedate_tz(sys.argv[1]))-time.time())//86400))' "$end" 2>/dev/null || echo -1)
    if [ "$days" -ge "$MIN_DAYS" ]; then pass "$host: certificate good for $days more days"; else fail "$host: certificate expires in $days days ($end)"; fi
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
