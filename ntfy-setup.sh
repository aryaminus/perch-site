#!/usr/bin/env bash
# ntfy-setup.sh — phone notifications for Perch without reading plugin docs.
#
# Perch has no server, so notifications go through ntfy: your gateway
# publishes to a topic, your phone subscribes to it. This script generates a
# secret topic, prints the EXACT lines for your gateway's ~/.hermes/.env
# (same variable names the in-app Notify screen renders — NTFY_TOPIC,
# NTFY_SERVER_URL, NTFY_TOKEN), and test-publishes so you know it works
# before you restart anything.
#
#   ./scripts/ntfy-setup.sh                        # ntfy.sh (works anywhere; they see metadata)
#   ./scripts/ntfy-setup.sh --server https://n.h.example.com   # your own server
#   ./scripts/ntfy-setup.sh --server http://192.168.1.50:8080  # LAN-only (warns: stops when you leave)
#   ./scripts/ntfy-setup.sh --token <tok>          # server needs auth
#   ./scripts/ntfy-setup.sh --topic <existing>     # reuse a topic you already made
#
# This script appends NOTHING. It prints; you paste. Your agent's config is yours.
set -euo pipefail

SERVER="https://ntfy.sh"
TOKEN=""
TOPIC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="${2:?--server needs a URL}"; shift 2 ;;
    --token) TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --topic) TOPIC="${2:?--topic needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,/^set /p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

if [ -z "$TOPIC" ]; then
  # Same shape as the app's suggestTopic: 20 chars, no l/1/0/o.
  TOPIC="perch-$(LC_ALL=C tr -dc 'abcdefghijkmnopqrstuvwxyz23456789' < /dev/urandom | head -c 20)"
fi

case "$SERVER" in
  *192.168.*|*10.*|*172.1[6-9].*|*172.2[0-9].*|*172.3[01].*|http://localhost*|http://127.*)
    echo "⚠️  LAN server: works at home, STOPS the moment you leave — which is"
    echo "   exactly when a phone notification is the entire point. Prefer a"
    echo "   public name (ntfy.sh or your own domain) unless you are on a tailnet."
    echo ;;
esac
if [ "$SERVER" = "https://ntfy.sh" ]; then
  echo "ℹ️  ntfy.sh is run by strangers: they see WHEN something fired and the"
  echo "   topic name, never your commands (Perch only ever sends \"a decision"
  echo "   is waiting\"). Self-host for stronger privacy."
  echo
fi

echo "1. Add these lines to your gateway's ~/.hermes/.env:"
echo
echo "   NTFY_TOPIC=${TOPIC}"
if [ "$SERVER" != "https://ntfy.sh" ]; then
  echo "   NTFY_SERVER_URL=${SERVER}"
fi
if [ -n "$TOKEN" ]; then
  echo "   NTFY_TOKEN=${TOKEN}   # keep this with the topic: it is a secret too"
fi
echo
echo "2. Install the approval bridge (a small hook plugin — the released gateway"
echo "   publishes nothing to ntfy for an approval on its own):"
echo
# This line used to print a path computed from THIS script's own location,
# which is correct inside a clone and nonsense when the file was downloaded on
# its own — the case the app actually tells people to use. It printed an
# instruction to copy a directory that was not there.
echo "   curl -fsSL ${PERCH_SITE:-https://aryaminus.github.io/perch-site}/install-approval-bridge.sh -o install-approval-bridge.sh"
SERVER_ARG=""
[[ "$SERVER" != "https://ntfy.sh" ]] && SERVER_ARG=" --server $SERVER"
echo "   bash install-approval-bridge.sh --topic ${TOPIC}${TOKEN:+ --token $TOKEN}${SERVER_ARG}"
echo "   # (it fetches the plugin, edits config.yaml and .env, and restarts — printing each step first)"
echo "   # or by hand:"
echo "   mkdir -p ~/.hermes/plugins/perch-approvals && cd ~/.hermes/plugins/perch-approvals"
echo "   curl -fsSLO ${PERCH_SITE:-https://aryaminus.github.io/perch-site}/perch-approvals/plugin.yaml"
echo "   curl -fsSLO ${PERCH_SITE:-https://aryaminus.github.io/perch-site}/perch-approvals/__init__.py"
echo "   # and in ~/.hermes/config.yaml:"
echo "   plugins:"
echo "     enabled:"
echo "       - perch-approvals"
echo
echo "3. Restart the gateway so it picks up the platform and the plugin:"
echo "   hermes gateway restart"
echo "4. Subscribe this phone to topic '${TOPIC}' in the ntfy app"
echo "   (or enter it on Perch's Notify screen to get the same config there)."
echo "   Prove it end to end with scripts/ntfy-delivery-test.sh."
echo
echo -n "Sending a test notification… "
AUTH=()
if [ -n "$TOKEN" ]; then AUTH=(-H "Authorization: Bearer ${TOKEN}"); fi
if curl -fsS -m 15 "${AUTH[@]}" -d "Perch test — if you see this, approvals will reach you." \
  "${SERVER}/${TOPIC}" > /dev/null; then
  echo "arrived (check the phone)."
else
  echo "FAILED."
  echo "The server did not accept the publish — check the URL, the token, and"
  echo "whether the server is reachable from HERE, not just from home."
  exit 1
fi
