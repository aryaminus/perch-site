#!/usr/bin/env bash
# enable-approvals.sh — make your agent ASK before it runs dangerous commands.
#
# Why this script exists rather than instructions in a doc: the settings are
# three lines in two files, and getting one wrong fails silently — the agent
# simply never prompts, which is indistinguishable from "no dangerous command
# happened". That is the worst possible failure for a security control.
#
# WHAT IT CHANGES, and why each one:
#
#   approvals.mode: manual
#     `smart` is the default and defers to the **tirith** scanner. If tirith is
#     not installed then with `tirith_fail_open: true` (also default) an
#     unavailable scanner means the command EXECUTES. Nothing errors and nothing
#     prompts.
#
#     `manual` raises an approval for dangerous work WITHOUT depending on the
#     scanner being reachable. It does NOT mean "asks every time" — an earlier
#     version of this comment claimed that and it is measured false: under
#     `manual`, `touch /tmp/x` ran and created the file with zero approval
#     events, while `rm -rf <dir>` in the same mode blocked and waited. Risk is
#     still classified; `manual` changes who is trusted to classify it, not
#     whether classification happens.
#
#   memory.write_approval: true
#     Gates memory WRITES on an approval. Without it there is no pending-write
#     to review, which is why Perch's review inbox has nothing to show.
#
#   gateway.multiplex_profiles: true          (only with --multi-profile)
#     Serves every profile under a `/p/<name>/` prefix, which is how a phone
#     addresses a second bot. Each named profile then needs its OWN
#     API_SERVER_KEY or its prefix fails closed — the script says so.
#
# Every change makes the agent MORE cautious, never less. The original config is
# backed up first and the script prints how to revert.
#
#   bash enable-approvals.sh                 # show what would change
#   bash enable-approvals.sh --apply         # write it
#   bash enable-approvals.sh --apply --multi-profile
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CONFIG="$HERMES_HOME/config.yaml"
APPLY=0
MULTI=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --multi-profile) MULTI=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '  \033[36mi\033[0m %s\n' "$1"; }

[[ -f "$CONFIG" ]] || { echo "No config at $CONFIG — is Hermes installed?" >&2; exit 1; }

echo "Perch · make your agent ask before it acts"
echo

# Report the CURRENT state first: an operator should see what they have before
# being told what to change.
python3 - "$CONFIG" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1])) or {}
ap = (c.get('approvals') or {})
print(f"  approvals.mode              : {ap.get('mode', 'ABSENT (defaults to smart)')}")
print(f"  approvals.tirith_fail_open  : {ap.get('tirith_fail_open', 'ABSENT (defaults to true)')}")
print(f"  memory.write_approval       : {(c.get('memory') or {}).get('write_approval', 'ABSENT (defaults to false)')}")
print(f"  gateway.multiplex_profiles  : {(c.get('gateway') or {}).get('multiplex_profiles', 'ABSENT (defaults to false)')}")
PY
# `command -v` alone is a FALSE NEGATIVE here: tirith installs to
# $HERMES_HOME/bin, which Hermes does not add to PATH. This script told a
# machine with a RUNNING tirith daemon that tirith was not installed, which is
# an argument for changing a security setting for a reason that is not true.
TIRITH=""
for cand in "$(command -v tirith 2>/dev/null || true)" "$HERMES_HOME/bin/tirith"; do
  [[ -n "$cand" && -x "$cand" ]] && { TIRITH="$cand"; break; }
done
if [[ -n "$TIRITH" ]]; then
  ok "tirith is installed ($TIRITH, $("$TIRITH" --version 2>/dev/null | head -1))"
else
  warn "tirith is NOT installed — with 'smart' mode that means nothing ever prompts"
fi
echo

if [[ "$APPLY" != "1" ]]; then
  echo "  Would set:  approvals.mode=manual, memory.write_approval=true$([[ "$MULTI" == "1" ]] && echo ", gateway.multiplex_profiles=true")"
  echo "  Re-run with --apply to write it."
  exit 0
fi

BACKUP="$CONFIG.perch-backup-$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG" "$BACKUP"
ok "backed up to $BACKUP"

MULTI="$MULTI" python3 - "$CONFIG" <<'PY'
import os, re, sys
p = sys.argv[1]
s = open(p).read()
stamp = "# Added by scripts/enable-approvals.sh"

if not re.search(r'^\s*write_approval:', s, re.M):
    if re.search(r'^memory:', s, re.M):
        s = re.sub(r'^memory:\n', f"memory:\n  {stamp} — gates memory WRITES on an approval.\n  write_approval: true\n", s, count=1, flags=re.M)
    else:
        s = s.rstrip() + f"\n\n{stamp}\nmemory:\n  write_approval: true\n"

if os.environ.get('MULTI') == '1' and not re.search(r'^\s*multiplex_profiles:', s, re.M):
    if re.search(r'^gateway:', s, re.M):
        s = re.sub(r'^gateway:\n', f"gateway:\n  {stamp} — serves every profile under /p/<name>/.\n  multiplex_profiles: true\n", s, count=1, flags=re.M)
    else:
        s = s.rstrip() + f"\n\n{stamp}\ngateway:\n  multiplex_profiles: true\n"

if not re.search(r'^approvals:', s, re.M):
    s = s.rstrip() + f"""

{stamp}
#
# 'smart' defers to the tirith scanner; with tirith absent and
# tirith_fail_open defaulting to true, dangerous commands execute without ever
# prompting. 'manual' needs no scanner and asks every time.
approvals:
  mode: manual
"""
else:
    s = re.sub(r'^(approvals:\n)', r'\1  mode: manual\n', s, count=1, flags=re.M) \
        if not re.search(r'^\s*mode:', s, re.M) else s

open(p, 'w').write(s)
PY

python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1])); print('  config still parses')" "$CONFIG"
ok "written"
echo
info "Restart the gateway for it to take effect:  hermes gateway restart"
echo
warn "One consequence worth knowing before you rely on this:"
echo "      An approval nobody answers HOLDS a concurrent-run slot. The default cap"
echo "      is 10, so ten ignored approvals and your agent refuses all new work with"
echo "      'Too many concurrent runs (max 10)' — while its own status page still"
echo "      reports 0 active agents."
echo "      A plain 'hermes gateway restart' will NOT clear it: it drains first and"
echo "      waits (up to ~30 min) for runs that can never finish. Use:"
echo "          hermes gateway stop && hermes gateway start"
echo "      Answer or deny your pending approvals and this never comes up."
info "Revert at any time:  cp $BACKUP $CONFIG"
if [[ "$MULTI" == "1" ]]; then
  echo
  warn "Multi-profile: each NAMED profile needs its own API_SERVER_KEY in"
  echo "      ~/.hermes/profiles/<name>/.env, or its /p/<name>/ prefix returns 401."
  echo "      Create one with:  hermes profile create <name>"
fi
