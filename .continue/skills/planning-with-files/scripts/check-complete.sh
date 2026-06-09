#!/usr/bin/env bash
# Check if all phases in task_plan.md are complete
# Default invocation: advisory echo, always exits 0 (Stop hook status report).
# With --gate: deliberate completion gate, opt-in per plan via <plan-dir>/.mode.
# Used by Stop hook to report task completion status.
#
# Plan-file resolution (v2.40+):
#   1. $1 (explicit path) — first non-flag positional argument
#   2. resolve-plan-dir.sh: $PLAN_ID env → .planning/.active_plan → newest mtime
#   3. Legacy ./task_plan.md
#
# This restores slug-mode parity: the Stop hook and any caller invoking with
# zero args now respects the active plan dir instead of silently defaulting to
# the legacy root path.
#
# Gate mode (v3, --gate flag):
#   The gate is OFF unless ALL of these hold (design "Gate decision table"):
#     1. <plan-dir>/.mode exists and contains "gate" (explicit opt-in)
#     2. an in_progress phase exists (not merely complete<total)
#     3. the Stop hook input JSON on stdin does not set stop_hook_active=true
#     4. the block counter (<plan-dir>/.stop_blocks) is below cap (PWF_GATE_CAP, default 20)
#     5. the ledger advanced since the last block (stall → allow stop)
#   When all hold, it emits a single-line block-decision JSON on stdout and
#   exits 0. Otherwise it falls back to advisory output and exits 0.
#   Without --gate, or in non-gated mode, behavior is byte-equivalent to v2.43.
#
# Stdin handling: the Claude Code Stop hook pipes a JSON payload on stdin. To
# avoid hanging when nothing is piped, stdin is read ONLY when fd 0 is not a
# TTY ([ -t 0 ]). Hook-piped input is EOF-terminated, so the read returns; an
# interactive terminal (TTY) is skipped entirely. No data on stdin is treated
# as stop_hook_active=false.

GATE=0
PLAN_FILE=""
for _arg in "$@"; do
    case "$_arg" in
        --gate) GATE=1 ;;
        *)
            if [ -z "$PLAN_FILE" ]; then
                PLAN_FILE="$_arg"
            fi
            ;;
    esac
done

PLAN_DIR=""
if [ -n "${PLAN_FILE}" ]; then
    PLAN_DIR="$(dirname "${PLAN_FILE}")"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null)" || SCRIPT_DIR="."
    RESOLVER="${SCRIPT_DIR}/resolve-plan-dir.sh"
    RESOLVED_DIR=""
    if [ -f "${RESOLVER}" ]; then
        RESOLVED_DIR="$(sh "${RESOLVER}" 2>/dev/null)"
    fi
    if [ -n "${RESOLVED_DIR}" ] && [ -f "${RESOLVED_DIR}/task_plan.md" ]; then
        PLAN_FILE="${RESOLVED_DIR}/task_plan.md"
        PLAN_DIR="${RESOLVED_DIR}"
    else
        PLAN_FILE="task_plan.md"
        PLAN_DIR="."
    fi
fi

if [ ! -f "$PLAN_FILE" ]; then
    echo "[planning-with-files] No task_plan.md found — no active planning session."
    exit 0
fi

# Count total phases
TOTAL=$(grep -c "### Phase" "$PLAN_FILE" || true)

# Check for **Status:** format first
COMPLETE=$(grep -cF "**Status:** complete" "$PLAN_FILE" || true)
IN_PROGRESS=$(grep -cF "**Status:** in_progress" "$PLAN_FILE" || true)
PENDING=$(grep -cF "**Status:** pending" "$PLAN_FILE" || true)

# Fallback: check for [complete] inline format if **Status:** not found
if [ "$COMPLETE" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] && [ "$PENDING" -eq 0 ]; then
    COMPLETE=$(grep -c "\[complete\]" "$PLAN_FILE" || true)
    IN_PROGRESS=$(grep -c "\[in_progress\]" "$PLAN_FILE" || true)
    PENDING=$(grep -c "\[pending\]" "$PLAN_FILE" || true)
fi

# Default to 0 if empty
: "${TOTAL:=0}"
: "${COMPLETE:=0}"
: "${IN_PROGRESS:=0}"
: "${PENDING:=0}"

# advisory_report: the v2.43 status echo. Always exit 0 after calling.
advisory_report() {
    if [ "$COMPLETE" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
        echo "[planning-with-files] ALL PHASES COMPLETE ($COMPLETE/$TOTAL). If the user has additional work, add new phases to task_plan.md before starting."
    else
        echo "[planning-with-files] Task in progress ($COMPLETE/$TOTAL phases complete). Update progress.md before stopping."
        if [ "$IN_PROGRESS" -gt 0 ]; then
            echo "[planning-with-files] $IN_PROGRESS phase(s) still in progress."
        fi
        if [ "$PENDING" -gt 0 ]; then
            echo "[planning-with-files] $PENDING phase(s) pending."
        fi
    fi
}

# ---- Default (advisory) path: byte-equivalent to v2.43 ----
if [ "$GATE" -ne 1 ]; then
    advisory_report
    exit 0
fi

# ---- Gate path (--gate). Resolves to advisory unless every guard says block. ----

# Guard 1: gated mode. The .mode file must contain "gate". Absent or other
# content means advisory mode (legacy behavior preserved).
MODE_FILE="${PLAN_DIR}/.mode"
if [ ! -f "${MODE_FILE}" ] || ! grep -q "gate" "${MODE_FILE}" 2>/dev/null; then
    advisory_report
    exit 0
fi

# Guard 3: stop_hook_active. Read the Stop hook JSON from stdin only when fd 0
# is not a TTY (see header). A true value means we are already inside a forced
# continuation; allow the stop to avoid runaway recursion.
STDIN_JSON=""
if [ ! -t 0 ]; then
    STDIN_JSON="$(cat 2>/dev/null)"
fi
case "${STDIN_JSON}" in
    *'"stop_hook_active"'*[Tt]rue*)
        advisory_report
        exit 0
        ;;
esac

# Guard 2: an in_progress phase must exist. Merely complete<total is a normal
# state and must NOT block (issue #178 lesson).
if [ "$IN_PROGRESS" -le 0 ]; then
    advisory_report
    exit 0
fi

# ledger_line_count: total lines across all <plan-dir>/ledger-*.jsonl files.
# Echoes a single integer (0 when no ledger files exist).
ledger_line_count() {
    _total=0
    for _lf in "${PLAN_DIR}"/ledger-*.jsonl; do
        [ -f "${_lf}" ] || continue
        _n="$(grep -c '' "${_lf}" 2>/dev/null || echo 0)"
        _total=$((_total + _n))
    done
    printf "%s" "${_total}"
}

CAP="${PWF_GATE_CAP:-20}"
case "${CAP}" in
    ''|*[!0-9]*) CAP=20 ;;
esac

BLOCKS_FILE="${PLAN_DIR}/.stop_blocks"
BLOCKS="$(cat "${BLOCKS_FILE}" 2>/dev/null || echo 0)"
case "${BLOCKS}" in
    ''|*[!0-9]*) BLOCKS=0 ;;
esac

LEDGER_FILE="${PLAN_DIR}/.gate_last_ledger"
LEDGER_PREV="$(cat "${LEDGER_FILE}" 2>/dev/null || echo 0)"
case "${LEDGER_PREV}" in
    ''|*[!0-9]*) LEDGER_PREV=0 ;;
esac
LEDGER_NOW="$(ledger_line_count)"

# Guard 4: block-count cap. At or over the cap, allow the stop.
if [ "${BLOCKS}" -ge "${CAP}" ]; then
    advisory_report
    echo "[planning-with-files] gate cap reached ($BLOCKS/$CAP) — allowing stop."
    exit 0
fi

# Guard 5: stall detection. If we have blocked before (BLOCKS > 0) and the
# ledger line count has not advanced since the last block, nothing progressed:
# allow the stop instead of looping.
if [ "${BLOCKS}" -gt 0 ] && [ "${LEDGER_NOW}" -eq "${LEDGER_PREV}" ]; then
    advisory_report
    echo "[planning-with-files] no progress since last gate block — allowing stop."
    exit 0
fi

# All guards passed: block the stop.
# json_escape: escape a string for safe inclusion in a JSON string literal.
# Handles backslash and double-quote (the only characters that can break the
# fixed template since the phase heading is single-line plain text).
json_escape() {
    printf "%s" "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# first_in_progress_phase: heading text of the first phase whose Status is
# in_progress. Reads the plan top-to-bottom, remembers the most recent
# "### " heading, and prints it (with the "### " prefix stripped) at the first
# in_progress status line. Plain text only — no plan body beyond the heading.
first_in_progress_phase() {
    awk '
        /^### / { heading = substr($0, 5); next }
        /\*\*Status:\*\* in_progress/ { print heading; exit }
        /\[in_progress\]/            { print heading; exit }
    ' "$PLAN_FILE"
}

PHASE_NAME="$(first_in_progress_phase)"
if [ -z "${PHASE_NAME}" ]; then
    PHASE_NAME="unknown phase"
fi
PHASE_ESCAPED="$(json_escape "${PHASE_NAME}")"

NEW_BLOCKS=$((BLOCKS + 1))
printf "%s\n" "${NEW_BLOCKS}" > "${BLOCKS_FILE}" 2>/dev/null || true
printf "%s\n" "${LEDGER_NOW}" > "${LEDGER_FILE}" 2>/dev/null || true

printf '{"decision":"block","reason":"[planning-with-files] Gated plan incomplete: phase '\''%s'\'' is in_progress (%s/%s complete, gate block %s/%s). Finish or update the plan, then stop."}\n' \
    "${PHASE_ESCAPED}" "${COMPLETE}" "${TOTAL}" "${NEW_BLOCKS}" "${CAP}"
exit 0
