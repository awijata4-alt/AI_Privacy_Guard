#!/usr/bin/env bash
# Launcher for the Python hooks (fail-closed).
#
# Problem it solves: when a hook command points at an interpreter that does not
# exist (e.g. venv/Scripts/python.exe on Linux, a fresh clone without venv,
# a broken venv), the shell exits with 127. Claude Code treats any exit code
# other than 2 as a non-blocking error, so the prompt / tool call went through
# unchecked. This launcher turns "no interpreter" into exit 2 (block).
#
# Usage (settings.json):
#   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/run_hook.sh" guard.py
#
# Interpreter lookup order:
#   1. $BIELIK_GUARD_PYTHON           (explicit path, e.g. a venv outside the repo)
#   2. <repo>/venv/Scripts/python.exe (Windows venv)
#   3. <repo>/venv/bin/python         (Linux / macOS venv)
# A system Python is deliberately NOT used: without `transformers` guard.py
# would block anyway, and a silent fallback would hide a broken setup.
#
# Emergency switch: BIELIK_GUARD_BYPASS=1 lets the action through when no
# interpreter is found; every use is written to the event log.
#
# Stdout is reserved for the hook's JSON; diagnostics go to stderr.

set -u

SELF="${0//\\//}"                       # Windows backslashes -> forward slashes
HOOK_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)" || HOOK_DIR=""
SCRIPT="${1:-}"

block() {
  echo "[AI-Privacy-Guard] BLOKADA (fail-closed): $1" >&2
  echo "[AI-Privacy-Guard] Awaryjnie: ustaw BIELIK_GUARD_BYPASS=1 (uzycie trafia do rejestru zdarzen)." >&2
  exit 2
}

if [ -z "$HOOK_DIR" ]; then
  block "nie ustalono katalogu hookow z '$0'."
fi

case "$SCRIPT" in
  guard.py|pre_tool_hook.py|outbound_pii_hook.py) ;;
  *) block "nieznany skrypt hooka: '${SCRIPT}'." ;;
esac

ROOT="$(cd "$HOOK_DIR/../.." && pwd)"

PY=""
for candidate in "${BIELIK_GUARD_PYTHON:-}" "$ROOT/venv/Scripts/python.exe" "$ROOT/venv/bin/python"; do
  if [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ]; then
    PY="$candidate"
    break
  fi
done

if [ -n "$PY" ]; then
  "$PY" "$HOOK_DIR/$SCRIPT"
  rc=$?
  # 126/127 = interpreter could not start (broken venv) -> must not pass through.
  if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    block "interpreter '$PY' nie uruchomil sie (kod $rc) - uszkodzony venv?"
  fi
  exit "$rc"
fi

if [ "${BIELIK_GUARD_BYPASS:-}" = "1" ]; then
  echo "[AI-Privacy-Guard] Brak interpretera Pythona, BIELIK_GUARD_BYPASS=1 - przepuszczam ($SCRIPT)." >&2
  event="{\"type\":\"guard.bypass\",\"object\":\"run_hook.sh:${SCRIPT}\",\"result\":\"success\",\"severity\":\"high\",\"reason\":\"BIELIK_GUARD_BYPASS=1: przepuszczono mimo braku interpretera Pythona\"}"
  if ! printf '%s' "$event" | node "$HOOK_DIR/log-event.js" append >/dev/null 2>&1; then
    echo "[AI-Privacy-Guard] Nie zapisano uzycia BIELIK_GUARD_BYPASS w rejestrze." >&2
  fi
  exit 0
fi

block "nie znaleziono interpretera Pythona dla $SCRIPT (sprawdzono: BIELIK_GUARD_PYTHON, venv/Scripts/python.exe, venv/bin/python). Utworz venv w katalogu repo albo ustaw BIELIK_GUARD_PYTHON."
