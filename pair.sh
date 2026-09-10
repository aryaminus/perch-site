#!/usr/bin/env bash
# pair.sh — put Perch on your phone, whatever your setup looks like.
#
# One command for every topology: the agent on this machine, on your LAN, behind
# Tailscale, behind a tunnel, or on a box in the cloud. It works out an address
# your PHONE can actually reach, checks the gateway really answers there, and
# prints a QR to scan (or a link to type).
#
#   bash pair.sh                      # figure everything out
#   bash pair.sh --url https://hermes.example.com   # tunnel / cloud / reverse proxy
#   bash pair.sh --lan                # force the LAN address
#   bash pair.sh --tailscale          # force the tailnet address
#   bash pair.sh --local              # loopback (emulator on THIS machine only)
#   bash pair.sh --no-dashboard       # gateway only
#   bash pair.sh --fix                # write missing keys to ~/.hermes/.env (asks first)
#
# ⚠️ THE QR IS A CREDENTIAL — and it reaches further than most people expect.
# The gateway API key is full control of an agent with a shell. If a dashboard
# is paired too, that token ALSO browses your home directory and reads media
# files by path (`/api/files`, `/api/media` — measured, not assumed). Show the
# code to a camera you own, in a room you trust. Never screenshot it into a chat.
#
# This script does not change your agent's configuration unless you pass --fix
# and answer yes. Your agent's config is yours.
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
ENV_FILE="$HERMES_HOME/.env"
# No repo-relative paths below this line: the app tells people to download this
# file on its own, so it must not assume it is sitting inside a clone. (A
# `ROOT=` computed from BASH_SOURCE lived here, unused, saying otherwise.)

MODE=auto
FORCE_URL=""
WANT_DASHBOARD=1
FIX=0
DASH_PORT="${HERMES_DASHBOARD_PORT:-9119}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) FORCE_URL="$2"; MODE=explicit; shift 2 ;;
    --lan) MODE=lan; shift ;;
    --tailscale|--ts) MODE=tailscale; shift ;;
    --local|--loopback) MODE=local; shift ;;
    --no-dashboard) WANT_DASHBOARD=0; shift ;;
    --fix) FIX=1; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '  \033[36mi\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

echo "Perch · pair a phone with your Hermes agent"

# ---------------------------------------------------------------- 1. the agent
step "Your agent"
if ! command -v hermes >/dev/null 2>&1; then
  bad "hermes not found on PATH."
  echo "     Perch is a client — it needs YOUR agent running somewhere."
  echo "     Install: https://github.com/NousResearch/hermes-agent"
  echo
  echo "     Already running it on ANOTHER machine? Run this script there,"
  echo "     or pair by hand with:  bash pair.sh --url https://that-host:8642"
  exit 1
fi
ok "hermes $(hermes --version 2>&1 | head -1 | sed -E 's/^Hermes Agent //')"

# Read a value from ~/.hermes/.env without sourcing it (it is not our file).
env_get() { [[ -f "$ENV_FILE" ]] && sed -nE "s/^$1=[\"']?([^\"']*)[\"']?[[:space:]]*$/\1/p" "$ENV_FILE" | tail -1; }

API_KEY="${HERMES_API_KEY:-$(env_get API_SERVER_KEY)}"

# The api_server is a gateway PLATFORM and stays off until it has a key. That
# is the single most common reason "nothing is listening on 8642".
if [[ -z "$API_KEY" ]]; then
  bad "API_SERVER_KEY is not set — the API server stays off without it."
  GEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
  if [[ "$FIX" == "1" ]]; then
    echo
    echo "  Add to $ENV_FILE:"
    echo "      API_SERVER_ENABLED=true"
    echo "      API_SERVER_KEY=$GEN"
    echo
    read -r -p "  Write those two lines now? [y/N] " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
      mkdir -p "$HERMES_HOME"; touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
      printf '\n# added by Perch pair.sh on %s\nAPI_SERVER_ENABLED=true\nAPI_SERVER_KEY=%s\n' \
        "$(date -u +%Y-%m-%d)" "$GEN" >> "$ENV_FILE"
      API_KEY="$GEN"
      ok "written — restart the gateway for it to take effect (hermes gateway restart)"
    else
      info "nothing written."; exit 1
    fi
  else
    echo
    echo "  Add to $ENV_FILE, then restart the gateway:"
    echo "      API_SERVER_ENABLED=true"
    echo "      API_SERVER_KEY=$GEN"
    echo
    echo "  Or re-run with --fix and this script will offer to write it."
    exit 1
  fi
else
  ok "API_SERVER_KEY is set"
fi

# ------------------------------------------------------- 2. a reachable address
# The critical step. A phone cannot reach 127.0.0.1 on your laptop, so a QR
# built from the loopback URL is born broken — it looks right and never works.
step "An address your phone can reach"

lan_ip() {
  case "$(uname -s)" in
    Darwin)
      for i in $(route -n get default 2>/dev/null | awk '/interface:/{print $2}') en0 en1; do
        ip=$(ipconfig getifaddr "$i" 2>/dev/null) && [[ -n "$ip" ]] && { echo "$ip"; return; }
      done ;;
    *)
      ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' ;;
  esac
}
ts_ip() { command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1; }

PORT="${HERMES_API_PORT:-8642}"
HOST=""; WHY=""
case "$MODE" in
  explicit) HOST=""; WHY="you passed --url" ;;
  local)    HOST="127.0.0.1"; WHY="you passed --local" ;;
  lan)      HOST="$(lan_ip)"; WHY="your LAN address" ;;
  tailscale) HOST="$(ts_ip)"; WHY="your tailnet address" ;;
  auto)
    # Tailscale first: it works from anywhere, not just this network, and is
    # encrypted end to end — so it is the best default when it exists.
    if HOST="$(ts_ip)" && [[ -n "$HOST" ]]; then WHY="your tailnet — reachable from anywhere, encrypted"
    elif HOST="$(lan_ip)" && [[ -n "$HOST" ]]; then WHY="your local network — works while the phone is on this WiFi"
    else HOST="127.0.0.1"; WHY="no network address found"; fi ;;
esac

if [[ -n "$FORCE_URL" ]]; then
  URL="${FORCE_URL%/}"
else
  [[ -n "$HOST" ]] || { bad "could not work out an address. Pass --url explicitly."; exit 1; }
  URL="http://$HOST:$PORT"
fi
ok "$URL — $WHY"

if [[ "$URL" == http://127.0.0.1:* || "$URL" == http://localhost:* ]]; then
  warn "This is a LOOPBACK address. A real phone cannot reach it — it only works"
  echo "      for an emulator running on this same machine. For a real device use"
  echo "      --lan, --tailscale, or --url with a tunnel."
fi

# D27 in the app, enforced here too: the key is a shell, and plain HTTP to a
# routable host puts it on the wire in clear.
host_only="$(printf '%s' "$URL" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"
scheme="$(printf '%s' "$URL" | sed -E 's#^([a-z]+)://.*#\1#')"
# ANCHORED AT BOTH ENDS. This was a prefix match, so `192.168.evil.com`,
# `10.evil.com` and `127.evil.com` — all registrable public hostnames — read as
# private and cleartext was allowed to them. The app's own `isPrivateHost` does
# not have this bug: it parses a full dotted quad. Only reachable by the
# operator passing their own --url, so a correctness bug rather than an attack,
# and one that would have told someone their key was safe when it was not.
private_host=0
if [[ "$host_only" == "localhost" || "$host_only" == "::1" || "$host_only" == "[::1]" ]]; then
  private_host=1
elif [[ "$host_only" =~ ^(127|10)\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  private_host=1
elif [[ "$host_only" =~ ^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  private_host=1
elif [[ "$host_only" =~ ^169\.254\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  private_host=1
elif [[ "$host_only" =~ ^172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  private_host=1
elif [[ "$host_only" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  private_host=1
elif [[ "$host_only" == *.ts.net || "$host_only" == *.tailscale.net || "$host_only" == *.local ]]; then
  private_host=1
fi

if [[ "$scheme" == "http" ]] && [[ $private_host -eq 0 ]]; then
  bad "Refusing: $URL is plain HTTP to a public host."
  echo "     Your API key would cross the internet in clear, and that key is a shell."
  echo "     Use https://, or put the gateway on Tailscale and use its ts.net name."
  exit 1
fi

# Prove it, rather than assuming it. Binding to 127.0.0.1 is the default, and a
# gateway bound to loopback is invisible at its own LAN address.
step "Checking it actually answers there"
CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$URL/health" 2>/dev/null) || CODE=000
if [[ "$CODE" == "200" ]]; then
  ok "GET $URL/health → 200"
else
  bad "GET $URL/health → ${CODE:-no answer}"
  echo
  if [[ "$MODE" == "explicit" ]]; then
    # We did not choose this address, so we must not guess at its cause. A
    # hostname the user supplied that does not answer is a DNS, tunnel or proxy
    # question, and telling them to rebind the gateway would send them to the
    # wrong machine entirely.
    echo "     That address is yours, so this is about the path to it, not the agent:"
    echo "       · does the name resolve, and is the tunnel or proxy up?"
    echo "       · does it forward to the gateway's port ($PORT)?"
    echo "       · from this machine, does  curl $URL/health  work?"
    if [[ "$CODE" == "404" || "$CODE" == "502" || "$CODE" == "503" ]]; then
      echo "     HTTP $CODE means something answered but it was not the gateway."
    fi
  elif [[ "$CODE" == "000" && "$URL" != http://127.0.0.1:* ]]; then
    # Do not assert the loopback half — measure it. "Bound to loopback" and
    # "gateway is down" need opposite fixes, and guessing sends people to the
    # wrong one.
    LOOP=$(curl -s -m 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null) || LOOP=000
    if [[ "$LOOP" == "200" ]]; then
      echo "     It answers on 127.0.0.1:$PORT but not at $host_only, so it is bound to"
      echo "     loopback — invisible from any other device. To let your phone in, set"
      echo "     in $ENV_FILE:"
      echo "         API_SERVER_HOST=0.0.0.0"
      echo "     then restart the gateway. Only do this on a network you trust —"
      echo "     or keep it on loopback and use Tailscale, which needs no exposure."
    else
      echo "     It does not answer on 127.0.0.1:$PORT either, so the API server is not"
      echo "     running — this is not a network problem. Check:"
      echo "         hermes gateway status"
      echo "     and that API_SERVER_ENABLED=true and API_SERVER_KEY are set in"
      echo "     $ENV_FILE (the platform stays off without a key)."
    fi
  fi
  exit 1
fi

# ------------------------------------------------------------- 3. the dashboard
# Optional, and its absence must never be framed as a problem.
DASH_URL=""; DASH_TOKEN=""
if [[ "$WANT_DASHBOARD" == "1" ]]; then
  step "Your dashboard (optional — adds search, skills, live updates)"
  # Same host, dashboard port. A tunnel that forwards only one port will simply
  # not answer, which is the correct outcome — better than inventing a hostname.
  CAND="$(printf '%s' "$URL" | sed -E "s#:[0-9]+\$##"):$DASH_PORT"
  DCODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$CAND/api/status" 2>/dev/null) || DCODE=000
  if [[ "$DCODE" != "200" ]]; then
    info "no dashboard at $CAND — skipping. Perch works fully without one."
    info "want it? run:  hermes dashboard --host 0.0.0.0 --port $DASH_PORT --no-open"
  else
    GATED=$(curl -s -m 5 "$CAND/api/status" | sed -nE 's/.*"auth_required"[[:space:]]*:[[:space:]]*(true|false).*/\1/p')
    if [[ "$GATED" == "true" ]]; then
      ok "found at $CAND — it is password/OAuth protected"
      info "sign in from inside Perch; a QR cannot carry a password safely."
    else
      # Ungated: the session token is the credential. It is regenerated on every
      # dashboard restart unless the operator pins one — which silently unpairs
      # the phone later, surfacing as an unexplained 401. Fix it now, not then.
      PINNED="$(env_get HERMES_DASHBOARD_SESSION_TOKEN)"
      DASH_TOKEN="${PINNED:-$(curl -s -m 5 "$CAND/" | sed -nE 's/.*__HERMES_SESSION_TOKEN__[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)}"
      if [[ -z "$DASH_TOKEN" ]]; then
        info "found at $CAND but could not read its session token — skipping."
      elif [[ -n "$PINNED" ]]; then
        DASH_URL="$CAND"
        ok "found at $CAND — token is pinned, so this pairing survives restarts"
      else
        DASH_URL="$CAND"
        warn "found at $CAND, but its token is REGENERATED ON EVERY RESTART."
        echo "      Pair now and the phone silently stops working the next time you"
        echo "      restart the dashboard — showing up much later as a 401."
        NEW="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
        echo
        echo "      Pin one by adding to $ENV_FILE:"
        echo "          HERMES_DASHBOARD_SESSION_TOKEN=$NEW"
        if [[ "$FIX" == "1" ]]; then
          read -r -p "      Write it now? (restart the dashboard afterwards) [y/N] " reply
          if [[ "$reply" =~ ^[Yy]$ ]]; then
            mkdir -p "$HERMES_HOME"; touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
            printf '\n# added by Perch pair.sh on %s\nHERMES_DASHBOARD_SESSION_TOKEN=%s\n' \
              "$(date -u +%Y-%m-%d)" "$NEW" >> "$ENV_FILE"
            ok "written. Restart the dashboard, then re-run this script."
            echo "      (Pairing with the CURRENT token now would break on that restart.)"
            DASH_URL=""; DASH_TOKEN=""
          fi
        else
          info "re-run with --fix to have this script offer to write it."
        fi
      fi
    fi
  fi
fi

# ------------------------------------------------------------------ 4. the code
# `#` and space were missing, so a key containing either produced a TRUNCATED
# QR — everything after the `#` is a fragment the app never sees, and the
# pairing silently half-worked. `%` stays first or it re-encodes its own output.
urlenc() {
  # `|` as the delimiter, not `#`: with `#` the hash substitution is `s##%23#g`,
  # which sed reads as an empty pattern — a silent no-op, and the exact bug this
  # line exists to fix.
  printf '%s' "$1" | sed 's|%|%25|g; s|:|%3A|g; s|/|%2F|g; s|+|%2B|g; s|=|%3D|g; s|&|%26|g; s|?|%3F|g; s|#|%23|g; s| |%20|g'
}
PAIR="perch://connect?endpoint=$(urlenc "$URL")&apikey=$(urlenc "$API_KEY")"
[[ -n "$DASH_URL" && -n "$DASH_TOKEN" ]] && PAIR="$PAIR&dashboard=$(urlenc "$DASH_URL")&dashtoken=$(urlenc "$DASH_TOKEN")"

step "Scan this with Perch"
echo "  Gateway:   $URL"
[[ -n "$DASH_URL" ]] && echo "  Dashboard: $DASH_URL"
echo "  This QR carries your API key. Treat it like the key it is."
[[ -n "$DASH_URL" ]] && echo "  It also carries a dashboard token, which can read files under $HOME."
echo

if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 "$PAIR"
elif command -v python3 >/dev/null 2>&1 && python3 -c "import qrcode" >/dev/null 2>&1; then
  python3 -c "import qrcode,sys; q=qrcode.QRCode(); q.add_data(sys.argv[1]); q.print_ascii(invert=True)" "$PAIR"
else
  info "no QR renderer — install one for the code itself:"
  echo "      brew install qrencode   ·   apt install qrencode   ·   pip install qrcode"
fi

echo
echo "  No camera? In Perch tap \"Enter details instead\" and type:"
echo "      Address:  $URL"
echo "      API key:  $API_KEY"
[[ -n "$DASH_URL" ]] && echo "      Dashboard: $DASH_URL"
echo
echo "  Or open this link on the phone itself:"
echo "      $PAIR"
echo
