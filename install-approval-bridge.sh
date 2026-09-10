#!/usr/bin/env bash
# install-approval-bridge.sh — put approvals on your phone, in one command.
#
# WHAT THIS IS. A run submitted to `POST /v1/runs` raises `approval.request` on
# its own event stream and nowhere else: `api_server_runs.py` notifies the
# stream's subscribers and never a platform adapter, so with Perch closed
# nothing tells your phone and the request fails closed at `approvals.timeout`
# (API-GROUND-TRUTH §9.4c, measured 2026-09-07). `gateway-plugins/perch-approvals`
# closes that by listening on the gateway's own `pre_approval_request` hook —
# which fires on api_server runs, before the stream is notified — and
# publishing one line to your ntfy topic (ADR-023).
#
# WHY A SCRIPT. It edits YOUR agent's config and restarts YOUR gateway. Those
# are your machine's, not an assistant's, which is why an agent could not do it
# for you and why every step below is printed before it happens and reversible
# after.
#
#   bash install-approval-bridge.sh                    # ntfy.sh, fresh topic
#   bash install-approval-bridge.sh --server https://ntfy.example.com
#   bash install-approval-bridge.sh --topic my-existing-topic --token tk_…
#   bash install-approval-bridge.sh --uninstall
#   bash install-approval-bridge.sh --dry-run          # print, change nothing
#
# WHAT IT SENDS. A title, "Open Perch to review the command and approve or deny
# it", and a `Click` to `perch://run/<run_id>`. **Never the command text** — the
# message may cross a server you do not run and a notification is readable on a
# lock screen. It never answers an approval; approving needs the command on
# screen.
set -euo pipefail

# WHERE THE PLUGIN COMES FROM.
#
# Two ways this script gets run, and it used to only work one of them. Inside a
# clone the plugin is a directory away. Downloaded on its own — which is how the
# app tells people to get it — `$(dirname $0)/..` is whatever folder they saved
# it in, so `cp -R "$ROOT/gateway-plugins/..."` copied nothing and the install
# "succeeded" with no plugin on the gateway. That failure is silent until an
# approval does not arrive, which is the worst place to discover it.
#
# So: use the local copy when there is one, and otherwise fetch the two files
# from the public site. Fetched to a temp dir and printed, never piped into
# anything — the whole point of a plugin you install on your own machine is
# that you can read it first.
# standalone-ok: the derived path is only ever tested with -d, and the download
# below is the branch that runs when it is absent.
SITE="${PERCH_SITE:-https://aryaminus.github.io/perch-site}"
LOCAL_PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/gateway-plugins/perch-approvals"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SERVER="https://ntfy.sh"
TOPIC=""
TOKEN=""
DRY=0
UNINSTALL=0
STAMP="$(date +%Y-%m-%d)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="${2:?--server needs a URL}"; shift 2 ;;
    --topic)  TOPIC="${2:?--topic needs a name}"; shift 2 ;;
    --token)  TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
# The topic IS the credential (ntfy has no other access control by default), so
# it is redacted out of anything printed — including the dry run, which
# otherwise echoed the whole thing while the header promised it would not.
redact() { [[ -z "$TOPIC" ]] && cat || sed "s/$TOPIC/<topic>/g"; }
# NO `eval`. Arguments are passed through as arguments.
#
# `eval "$@"` re-parsed a string built by interpolating $TOPIC, $SERVER and
# $TOKEN — values an operator pastes from a web page. A single quote in any of
# them ends the quoting and the rest executes. The operator is supplying their
# own arguments, so this is a correctness bug rather than an attack; it is also
# one line to not have.
#
# Every call site now passes a real argv, and the two that need a redirect use
# `append` below instead of embedding `>>` in a string.
run() {
  if [[ $DRY -eq 1 ]]; then say "   would: $*" | redact; else "$@"; fi
}

# `printf … >> file`, without a shell string. `--` guards a format that begins
# with a dash.
append() {
  local file="$1"; shift
  if [[ $DRY -eq 1 ]]; then say "   would: append to $file" | redact; return; fi
  printf -- "$@" >> "$file"
}
# "appended" is a claim about the past. In a dry run nothing happened, so the
# confirmation must not read as though it did.
did() { if [[ $DRY -eq 1 ]]; then say "   (dry run — nothing written)"; else say "   $*"; fi; }

[[ -d "$HERMES_HOME" ]] || { echo "No Hermes home at $HERMES_HOME. Install Hermes Agent first: https://github.com/NousResearch/hermes-agent" >&2; exit 1; }

# Needed to fetch the plugin when there is no local copy. Checked up front
# rather than at the download, so the message arrives before anything is
# touched — and only when it is actually needed.
if [[ ! -d "$LOCAL_PLUGIN" ]] && ! command -v curl >/dev/null 2>&1; then
  echo "This script needs 'curl' to download the plugin ($SITE/perch-approvals)." >&2
  echo "Install curl, or fetch these two files by hand into $HERMES_HOME/plugins/perch-approvals/:" >&2
  echo "  $SITE/perch-approvals/plugin.yaml" >&2
  echo "  $SITE/perch-approvals/__init__.py" >&2
  exit 1
fi

if [[ $UNINSTALL -eq 1 ]]; then
  say "Perch · removing the approval bridge"
  run rm -rf "$HERMES_HOME/plugins/perch-approvals"
  say "   plugin directory removed"
  say
  say "Two things this does NOT touch, because they may be yours:"
  say "  · the 'perch-approvals' line under plugins.enabled in $HERMES_HOME/config.yaml"
  say "  · NTFY_TOPIC and friends in $HERMES_HOME/.env — the ntfy PLATFORM uses them too"
  say "Remove them by hand if nothing else wants them, then: hermes gateway restart"
  exit 0
fi

# A topic name IS the credential: ntfy has no other access control by default,
# so anyone who learns it can read your notices. 20 hex chars, not a word.
#
# Resolve it BEFORE the header prints. An existing NTFY_TOPIC in .env wins (step
# 3 has always honoured it), but the header used to print a freshly generated
# topic that step 3 then discarded — so the summary at the top named one topic
# and the install used another. Two different secrets on one screen, and the
# user has no way to know which one to subscribe to.
if [[ -z "$TOPIC" && -f "$HERMES_HOME/.env" ]] && grep -qE "^NTFY_TOPIC=" "$HERMES_HOME/.env"; then
  TOPIC="$(grep -E '^NTFY_TOPIC=' "$HERMES_HOME/.env" | head -1 | cut -d= -f2-)"
fi
# openssl is the usual source of randomness here and is not guaranteed to be
# installed. /dev/urandom is, on every system this script can run on, so the
# fallback is the portable one rather than an error — a missing openssl should
# not stop an install over twenty random characters.
if [[ -z "$TOPIC" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    TOPIC="perch-$(openssl rand -hex 10)"
  else
    # Bounded read, and `cut` rather than a second `head` — see ntfy-setup.sh:
    # the `tr < /dev/urandom | head` spelling dies of SIGPIPE under pipefail.
    TOPIC="perch-$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | cut -c1-20)"
  fi
fi
[[ ${#TOPIC} -ge 12 ]] || { echo "Could not generate a topic — pass one with --topic." >&2; exit 1; }

say "Perch · approval bridge (ADR-023)"
say "  gateway home : $HERMES_HOME"
say "  ntfy server  : $SERVER"
say "  topic        : ${TOPIC:0:10}…   (kept out of this transcript; it is a secret)"
[[ "$SERVER" == "https://ntfy.sh" ]] && say "  ⚠️  ntfy.sh is public infrastructure. It sees that a decision is waiting and
      when — never the command, which this bridge does not send. Point --server
      at your own ntfy to keep even that metadata at home."
say

# ── 1. the plugin ───────────────────────────────────────────────────────────
say "1. plugin -> $HERMES_HOME/plugins/perch-approvals"
run mkdir -p "$HERMES_HOME/plugins"
if [[ -d "$LOCAL_PLUGIN" ]]; then
  say "   source: $LOCAL_PLUGIN"
  run cp -R "$LOCAL_PLUGIN" "$HERMES_HOME/plugins/"
else
  say "   source: $SITE/perch-approvals  (no local copy beside this script)"
  SRC="$(mktemp -d)"; trap 'rm -rf "$SRC"' EXIT
  mkdir -p "$SRC/perch-approvals"
  for f in plugin.yaml __init__.py; do
    curl -fsSL "$SITE/perch-approvals/$f" -o "$SRC/perch-approvals/$f" || {
      echo "   ✗ could not download $SITE/perch-approvals/$f" >&2
      echo "     Check your connection, or clone the repo and run this from there." >&2
      exit 1
    }
  done
  # Two files, ~12K. Refuse an empty or HTML-shaped download rather than
  # installing a 404 page as a gateway plugin.
  head -1 "$SRC/perch-approvals/plugin.yaml" | grep -qi "^<" && {
    echo "   ✗ $SITE/perch-approvals/plugin.yaml returned a web page, not the plugin" >&2; exit 1; }
  [[ -s "$SRC/perch-approvals/__init__.py" ]] || { echo "   ✗ __init__.py downloaded empty" >&2; exit 1; }
  say "   downloaded — read them before continuing if you like:"
  say "     $SRC/perch-approvals/plugin.yaml"
  say "     $SRC/perch-approvals/__init__.py"
  run cp -R "$SRC/perch-approvals" "$HERMES_HOME/plugins/"
fi

# ── 2. config.yaml ──────────────────────────────────────────────────────────
CFG="$HERMES_HOME/config.yaml"
say "2. enable it in $CFG"
if [[ -f "$CFG" ]] && grep -q "perch-approvals" "$CFG"; then
  say "   already enabled — leaving it alone"
elif [[ -f "$CFG" ]] && grep -qE "^plugins:" "$CFG"; then
  say "   ⚠️  $CFG already has a 'plugins:' section, and merging YAML blind is how"
  say "       a config gets corrupted. Add this line under plugins.enabled yourself:"
  say "           - perch-approvals"
else
  run cp "$CFG" "$CFG.perch-bak-$STAMP" 2>/dev/null || true
  append "$CFG" '\n# Perch approval bridge, added %s by scripts/install-approval-bridge.sh (ADR-023).\n# Remove this block and ~/.hermes/plugins/perch-approvals to undo.\nplugins:\n  enabled:\n    - perch-approvals\n' "$STAMP"
  did "appended (backup: $CFG.perch-bak-$STAMP)"
fi

# ── 3. .env ─────────────────────────────────────────────────────────────────
ENVF="$HERMES_HOME/.env"
say "3. topic in $ENVF"
if [[ -f "$ENVF" ]] && grep -qE "^NTFY_TOPIC=" "$ENVF"; then
  say "   NTFY_TOPIC is already set — leaving it. The bridge uses whatever is there."
  TOPIC="$(grep -E '^NTFY_TOPIC=' "$ENVF" | head -1 | cut -d= -f2-)"
else
  run cp "$ENVF" "$ENVF.perch-bak-$STAMP" 2>/dev/null || true
  append "$ENVF" '\n# Perch approval bridge, added %s. The ntfy PLATFORM reads these too.\nNTFY_TOPIC=%s\n' "$STAMP" "$TOPIC"
  [[ "$SERVER" != "https://ntfy.sh" ]] && append "$ENVF" 'NTFY_SERVER_URL=%s\n' "$SERVER"
  [[ -n "$TOKEN" ]] && append "$ENVF" 'NTFY_TOKEN=%s\n' "$TOKEN"
  did "written (backup: $ENVF.perch-bak-$STAMP)"
fi

# ── 4. restart ──────────────────────────────────────────────────────────────
say "4. restart the gateway so it loads the plugin"
say "   ⚠️  This interrupts any run in flight."
if [[ $DRY -eq 1 ]]; then
  say "   would: hermes gateway restart"
else
  hermes gateway restart || { echo "restart failed — run 'hermes gateway restart' yourself once the gateway is idle" >&2; exit 1; }
fi

say
say "Done. Now:"
say "  · subscribe this phone to '${TOPIC:0:10}…' in the ntfy app, or paste the"
say "    same topic into Perch's Notify screen"
# SELF, not a repo path. Downloaded on its own — the way the app tells people
# to get it — "scripts/install-approval-bridge.sh --uninstall" names a file that
# is not there, and telling someone the undo command is one they cannot run is
# worse than saying nothing.
say "  · undo any time:        bash $(basename "${BASH_SOURCE[0]}") --uninstall"
if [[ -d "$LOCAL_PLUGIN" ]]; then
  say "  · prove it end to end:  scripts/ntfy-delivery-test.sh"  # repo-path-ok: this branch only runs from a clone
else
  say "  · to check it works: raise an approval and watch the topic in the ntfy app"
fi
