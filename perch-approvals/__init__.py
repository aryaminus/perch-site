"""perch-approvals — an approval raised on your gateway reaches your phone.

Why this exists. A run submitted to ``POST /v1/runs`` raises ``approval.request``
on its event stream and nowhere else: ``api_server_runs.py`` notifies the
stream's subscribers, never a platform adapter, so with Perch closed nothing
tells the phone (Perch's API-GROUND-TRUTH §9.4c, measured 2026-09-07). The
approval then fails closed at ``approvals.timeout``.

What it uses. ``tools/approval.py`` fires the public ``pre_approval_request``
lifecycle hook on every surface — api_server runs included — *before* it hands
the request to the stream. This plugin listens there and publishes to the ntfy
topic you already configured. No core change, no new dependency: the standard
library POSTs one small message.

What it sends. A title, a body that says a decision is waiting, and a
``Click`` deep link (``perch://run/<run_id>``) so the tap lands on the right
conversation. **Never the command text.** The message crosses a server you may
not run (ntfy.sh is the default), and a notification is readable on a lock
screen; Perch's own notifications follow the same rule.

What it does not do. Answer. Approving is a consequential decision that needs
the command on screen; denying from a notification is offered by Perch's own
local notifications, not from here.

Configuration — the same variables as the ntfy adapter and Perch's Notify
screen, so one setup serves both:

    NTFY_TOPIC          topic to publish to (required unless NTFY_PUBLISH_TOPIC)
    NTFY_PUBLISH_TOPIC  publish topic, when it differs from the subscribe topic
    NTFY_SERVER_URL     default https://ntfy.sh — self-host to keep it private
    NTFY_TOKEN          bearer token, or user:pass for basic auth (optional)

Install: copy this directory to ``~/.hermes/plugins/perch-approvals`` and add
``perch-approvals`` to ``plugins.enabled`` in ``~/.hermes/config.yaml``, then
``hermes gateway restart``. Perch's ``scripts/ntfy-setup.sh`` prints the exact
steps.
"""
from __future__ import annotations

import base64
import logging
import os
import threading
import urllib.request

logger = logging.getLogger(__name__)

DEFAULT_SERVER = "https://ntfy.sh"
TITLE = "Your agent needs a decision"
BODY = "Open Perch to review the command and approve or deny it."


def _get(name: str, default=None):
    """Scope-aware read with the same fallback the ntfy adapter uses."""
    try:
        from agent.secret_scope import UnscopedSecretError, get_secret

        try:
            value = get_secret(name, default)
        except UnscopedSecretError:
            value = os.getenv(name)
    except Exception:
        value = os.getenv(name)
    return value if value not in (None, "") else default


def _auth_header(token: str) -> str:
    lowered = token.lower()
    if lowered.startswith("bearer ") or lowered.startswith("basic "):
        return token
    if ":" in token:
        return "Basic " + base64.b64encode(token.encode()).decode()
    return f"Bearer {token}"


def _publish(server: str, topic: str, token, run_id: str) -> None:
    headers = {
        "Title": TITLE,
        "Priority": "high",
        "Tags": "perch,approval",
        "Click": f"perch://run/{run_id}",
        "Content-Type": "text/plain; charset=utf-8",
    }
    if token:
        headers["Authorization"] = _auth_header(str(token))
    req = urllib.request.Request(f"{server}/{topic}", data=BODY.encode("utf-8"), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=8) as res:  # the operator's own server, by their config
            res.read()
        logger.info("perch-approvals: published approval notice for %s", run_id)
    except Exception as exc:  # a notification failure must never touch the approval itself
        logger.warning("perch-approvals: publish failed: %s", exc)


def notify_approval(command, description, pattern_key, pattern_keys, session_key, surface, **kwargs):
    # Only gateway surfaces: a CLI or TUI prompt has a person at the keyboard,
    # and a "smart" decision is made by the auxiliary model with nobody to ask.
    if surface != "gateway":
        return
    topic = _get("NTFY_PUBLISH_TOPIC") or _get("NTFY_TOPIC")
    if not topic:
        logger.debug("perch-approvals: no NTFY_TOPIC configured; nothing published")
        return
    server = str(_get("NTFY_SERVER_URL") or DEFAULT_SERVER).rstrip("/")
    # On api_server runs the approval's session key IS the run id
    # (gateway/platforms/api_server_runs.py: approval_session_key = run_id).
    run_id = str(session_key)
    # Off the agent thread: this hook runs before the request reaches the
    # stream, and a slow publish must not delay the card in a live client.
    threading.Thread(target=_publish, args=(server, topic, _get("NTFY_TOKEN"), run_id), daemon=True).start()


def register(ctx):
    ctx.register_hook("pre_approval_request", notify_approval)
