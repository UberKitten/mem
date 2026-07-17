#!/bin/bash
# memory-distiller.sh — nightly LLM distiller for memory/threads.md
# (bash-3.2 compatible: macOS /bin/bash. No assoc arrays / ;& fallthrough / |&.)
#
# Three-stage pipeline (script-enforced), see docs/design.md § The distiller.
#   1. gather  (mechanical) — parse daily entries since the watermark, fold in the
#              current threads.md + per-slug staleness, assemble one working-set doc.
#              Also refresh the embeddings index + on-demand catalog via the `mem`
#              CLI if it exists (tolerated absent).
#   2. judge   (LLM)        — a `claude --print`-compatible CLI subprocess with
#              memory-distiller.prompt.md + the working set. Emits a complete
#              replacement threads.md.
#   3. enforce (mechanical) — validate format / <=16KB / sane thread count. On
#              failure: keep yesterday's threads.md, log loudly, exit nonzero (the
#              health check surfaces it). On success: write, git-commit, advance
#              the watermark.
#   A failed run degrades to "index one day stale," never "index destroyed."
#
# Invocation:
#   memory-distiller.sh                 # nightly/cron mode (writes, commits, advances watermark)
#   memory-distiller.sh --now           # same, on-demand (just labels logs)
#   memory-distiller.sh --no-commit     # write threads.md but don't git-commit / don't advance
#                                       #   watermark (dry-review / test mode)
#   memory-distiller.sh --since DATE    # override the input window (YYYY-MM-DD); doesn't persist
#   memory-distiller.sh --model NAME    # override the judge model
#   memory-distiller.sh --skip-judge    # reuse the last judge-output.md (gather+enforce only; for tests/CI)
#
# Configuration (env overrides a config file at $XDG_CONFIG_HOME/mem/config):
#   MEM_ROOT            workspace root (default: $HOME/memory-workspace)
#   MEM_CLAUDE_BIN      judge CLI binary (default: claude); must accept `--print` and
#                       read a prompt on stdin, writing the file content to stdout.
#   MEM_JUDGE_MODEL     judge model passed as `--model` (default: the CLI's default)
#   MEM_JUDGE_CMD       full override of the judge command (reads stdin -> stdout);
#                       if set, MEM_CLAUDE_BIN / MEM_JUDGE_MODEL are ignored.

set -euo pipefail

# --- config file (KEY=value lines; env always wins) ---
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mem/config"
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

REPO_ROOT="${MEM_ROOT:-$HOME/memory-workspace}"
MEM_DIR="$REPO_ROOT/memory"
THREADS_FILE="$MEM_DIR/threads.md"
# Prompt lives beside this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="${MEM_DISTILLER_PROMPT:-$SCRIPT_DIR/memory-distiller.prompt.md}"

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mem/distiller"
STATE_FILE="$STATE_DIR/state.json"
LOG_DIR="$STATE_DIR/logs"
LOCKDIR="$STATE_DIR/run.lock.d"
WORKING_SET="$STATE_DIR/working-set.md"
RAW_OUT="$STATE_DIR/judge-output.md"
TMP_THREADS="$STATE_DIR/threads.md.tmp"

HARD_CAP=16384          # 16 KB hard cap
MAX_THREADS=60          # sanity ceiling
# System python is stdlib-only and dodges macOS launchd-network (TCC) surprises.
PYTHON="${MEM_PYTHON:-python3}"

CLAUDE_BIN="${MEM_CLAUDE_BIN:-claude}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

# Optional long-lived headless auth token for the judge CLI. Interactive-login
# tokens often expire and 401 under cron; a setup/long-lived token lasts longer.
_oauth_token_file="${MEM_CLAUDE_OAUTH_TOKEN_FILE:-$HOME/.config/mem/claude-oauth-token}"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r "$_oauth_token_file" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$(cat "$_oauth_token_file")"
    export CLAUDE_CODE_OAUTH_TOKEN
fi

# --- flags ---
MODE="cron"
DO_COMMIT=true
SINCE_OVERRIDE=""
MODEL="${MEM_JUDGE_MODEL:-}"
SKIP_JUDGE=false        # reuse existing judge-output.md instead of calling the CLI (test/iterate)
while [ $# -gt 0 ]; do
    case "$1" in
        --now)        MODE="on-demand"; shift ;;
        --skip-judge) SKIP_JUDGE=true; shift ;;
        --no-commit)  DO_COMMIT=false; shift ;;
        --since)      SINCE_OVERRIDE="${2:-}"; shift 2 ;;
        --model)      MODEL="${2:-}"; shift 2 ;;
        *)            echo "memory-distiller: unknown arg: $1" >&2; exit 2 ;;
    esac
done

# --- single-instance lock ---
acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"; trap 'rm -rf "$LOCKDIR"' EXIT INT TERM; return 0
    fi
    local prev_pid; prev_pid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
    if [ -n "$prev_pid" ] && kill -0 "$prev_pid" 2>/dev/null; then return 1; fi
    rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" || return 1
    echo $$ > "$LOCKDIR/pid"; trap 'rm -rf "$LOCKDIR"' EXIT INT TERM; return 0
}
if ! acquire_lock; then
    echo "another memory-distiller is already running (lock: $LOCKDIR) — skipping"
    exit 0
fi

echo "=== memory-distiller ($MODE) starting at $(date) ==="

if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: prompt file missing: $PROMPT_FILE" >&2
    exit 1
fi

# --- mechanical freshness: refresh embeddings + catalog if the mem CLI exists ---
if command -v mem >/dev/null 2>&1; then
    echo "- mem CLI found — refreshing embeddings index + catalog"
    mem embed          >/dev/null 2>&1 && echo "  ok mem embed" || echo "  WARN: mem embed failed (non-fatal — likely no API key)"
    mem catalog --write >/dev/null 2>&1 && echo "  ok mem catalog --write" || echo "  WARN: mem catalog --write failed (non-fatal)"
else
    echo "- mem CLI not on PATH — skipping embed/catalog"
fi

# =====================================================================
# STAGE 1 — GATHER (mechanical)
# =====================================================================
echo "- gather: assembling working set"
GATHER_META_FILE="$STATE_DIR/gather-meta.json"
# NB: run the python heredoc standalone (NOT inside $(...)) — bash 3.2 mis-parses
# backticks in a quoted heredoc nested in command substitution. Meta goes to a file.
STATE_FILE="$STATE_FILE" MEM_DIR="$MEM_DIR" THREADS_FILE="$THREADS_FILE" \
    WORKING_SET="$WORKING_SET" SINCE_OVERRIDE="$SINCE_OVERRIDE" \
    GATHER_META_FILE="$GATHER_META_FILE" \
    "$PYTHON" - <<'PY'
import os, re, json, datetime, glob

mem_dir   = os.environ["MEM_DIR"]
state_f   = os.environ["STATE_FILE"]
threads_f = os.environ["THREADS_FILE"]
out_f     = os.environ["WORKING_SET"]
meta_f    = os.environ["GATHER_META_FILE"]
since_ovr = os.environ.get("SINCE_OVERRIDE", "").strip()

today = datetime.date.today()
today_s = today.isoformat()

# --- watermark ---
last_processed = ""
try:
    with open(state_f) as fh:
        last_processed = (json.load(fh) or {}).get("last_processed", "") or ""
except Exception:
    last_processed = ""

if since_ovr:
    cutoff = since_ovr
elif last_processed:
    cutoff = last_processed
else:
    cutoff = (today - datetime.timedelta(days=14)).isoformat()   # first-run lookback

DATED = re.compile(r"^(\d{4}-\d{2}-\d{2})\.md$")
ENTRY = re.compile(r"^### \d{2}:\d{2} \[([a-z0-9-]+)\]")

# --- per-slug staleness across ALL dated dailies (structured [slug] entries only) ---
slug_last = {}   # slug -> (latest_date, count)
all_dailies = []
for path in glob.glob(os.path.join(mem_dir, "*.md")):
    m = DATED.match(os.path.basename(path))
    if not m:
        continue
    d = m.group(1)
    all_dailies.append((d, path))
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except Exception:
        continue
    for line in text.splitlines():
        em = ENTRY.match(line)
        if em:
            slug = em.group(1)
            latest, cnt = slug_last.get(slug, ("0000-00-00", 0))
            slug_last[slug] = (max(latest, d), cnt + 1)

all_dailies.sort()

# --- window: dailies dated >= cutoff ---
window = [(d, p) for (d, p) in all_dailies if d >= cutoff]
input_nonempty = False
for _, p in window:
    try:
        if open(p, encoding="utf-8", errors="replace").read().strip():
            input_nonempty = True
            break
    except Exception:
        pass

# --- current threads.md ---
prev = ""
if os.path.exists(threads_f):
    prev = open(threads_f, encoding="utf-8", errors="replace").read().strip()

# --- build working set ---
parts = []
parts.append(f"# Distiller working set — assembled {today_s}")
parts.append("")
parts.append(f"TODAY (absolute, user-local): {today_s}")
parts.append(f"Input window: daily entries dated on or after {cutoff}.")
parts.append("")
parts.append("---")
parts.append("## CURRENT threads.md (carry-forward state — integrate, don't discard silently)")
parts.append("")
parts.append(prev if prev else "(none yet — this is the first run; build threads.md from the daily entries below.)")
parts.append("")
parts.append("---")
parts.append("## Per-slug staleness (structured `[slug]` entries seen across all dailies)")
parts.append("Days since last touch is a signal for expiry, not a rule. Old-but-load-bearing threads stay.")
parts.append("")
if slug_last:
    parts.append("| slug | last entry | days stale | # entries |")
    parts.append("|---|---|---|---|")
    for slug in sorted(slug_last):
        latest, cnt = slug_last[slug]
        try:
            days = (today - datetime.date.fromisoformat(latest)).days
        except Exception:
            days = "?"
        parts.append(f"| {slug} | {latest} | {days} | {cnt} |")
else:
    parts.append("(no structured `### HH:MM [slug]` entries found yet. "
                 "Infer threads from the freeform daily content below.)")
parts.append("")
parts.append("---")
parts.append("## DAILY ENTRIES in window (source material)")
parts.append("Each file is a day of raw memory. New-grammar entries look like `### HH:MM [slug] summary`; "
             "older content is freeform `## heading` sections — treat freeform as opaque source text, "
             "still a valid signal for what threads are open.")
parts.append("")
if window:
    for d, p in window:
        try:
            body = open(p, encoding="utf-8", errors="replace").read().rstrip()
        except Exception:
            body = "(unreadable)"
        parts.append(f"### FILE: memory/{d}.md")
        parts.append("")
        parts.append(body)
        parts.append("")
else:
    parts.append("(no daily files in the input window.)")

with open(out_f, "w", encoding="utf-8") as fh:
    fh.write("\n".join(parts) + "\n")

meta = {
    "input_nonempty": bool(input_nonempty),
    "num_files": len(window),
    "watermark": cutoff,
    "today": today_s,
    "num_slugs": len(slug_last),
    "working_set_bytes": os.path.getsize(out_f),
}
with open(meta_f, "w", encoding="utf-8") as fh:
    json.dump(meta, fh)
print(json.dumps(meta))
PY

echo "  gather meta: $(cat "$GATHER_META_FILE")"
INPUT_NONEMPTY=$(jq -r 'if .input_nonempty then "true" else "false" end' "$GATHER_META_FILE")
TODAY=$(jq -r '.today' "$GATHER_META_FILE")

# =====================================================================
# STAGE 2 — JUDGE (LLM)
# =====================================================================
if [ "$SKIP_JUDGE" = true ]; then
    if [ ! -s "$RAW_OUT" ]; then
        echo "ERROR: --skip-judge but no existing judge output at $RAW_OUT" >&2
        exit 1
    fi
    echo "- judge: SKIPPED (--skip-judge) — reusing $RAW_OUT ($(wc -c < "$RAW_OUT" | tr -d ' ') bytes)"
else
    # Combined prompt = instructions + working set, piped on stdin (avoids ARG_MAX).
    if [ -n "${MEM_JUDGE_CMD:-}" ]; then
        echo "- judge: invoking custom MEM_JUDGE_CMD"
        echo "---------------------------------------------------"
        set +e
        { cat "$PROMPT_FILE"; echo; echo "==================== WORKING SET ===================="; echo; cat "$WORKING_SET"; } \
            | sh -c "$MEM_JUDGE_CMD" > "$RAW_OUT"
        JUDGE_RC=$?
        set -e
    else
        echo "- judge: invoking $CLAUDE_BIN --print${MODEL:+ --model $MODEL}"
        echo "---------------------------------------------------"
        CLAUDE_ARGS=(--print --permission-mode bypassPermissions)
        [ -n "$MODEL" ] && CLAUDE_ARGS+=(--model "$MODEL")
        set +e
        { cat "$PROMPT_FILE"; echo; echo "==================== WORKING SET ===================="; echo; cat "$WORKING_SET"; } \
            | "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" > "$RAW_OUT"
        JUDGE_RC=$?
        set -e
    fi
    echo "---------------------------------------------------"
    if [ "$JUDGE_RC" -ne 0 ]; then
        echo "ERROR: judge exited $JUDGE_RC — keeping previous threads.md" >&2
        exit "$JUDGE_RC"
    fi
    echo "  judge output: $(wc -c < "$RAW_OUT" | tr -d ' ') bytes"
fi

# =====================================================================
# STAGE 3 — ENFORCE (mechanical)
# =====================================================================
echo "- enforce: validating"
ENFORCE_RESULT="$STATE_DIR/enforce-result.txt"
set +e
# Standalone heredoc (not $(...)) — same bash-3.2 backtick quirk. Result → file.
# shellcheck disable=SC2094  # python reads RAW_OUT, writes ENFORCE_RESULT — different files
RAW_OUT="$RAW_OUT" TMP_THREADS="$TMP_THREADS" TODAY="$TODAY" \
    INPUT_NONEMPTY="$INPUT_NONEMPTY" HARD_CAP="$HARD_CAP" MAX_THREADS="$MAX_THREADS" \
    ENFORCE_RESULT="$ENFORCE_RESULT" \
    "$PYTHON" - > "$ENFORCE_RESULT" 2>&1 <<'PY'
import os, re, sys, datetime

raw_f   = os.environ["RAW_OUT"]
out_f   = os.environ["TMP_THREADS"]
today   = os.environ["TODAY"]
nonempty = os.environ["INPUT_NONEMPTY"] == "true"
hard_cap = int(os.environ["HARD_CAP"])
max_threads = int(os.environ["MAX_THREADS"])

def fail(msg):
    print("FAIL: " + msg)
    sys.exit(3)

raw = open(raw_f, encoding="utf-8", errors="replace").read()

# Split off optional distiller notes (follow-up channel — never in threads.md).
notes = ""
if "===DISTILLER-NOTES===" in raw:
    raw, notes = raw.split("===DISTILLER-NOTES===", 1)

body = raw.strip()

# Strip an accidental code fence wrapping the whole output.
if body.startswith("```"):
    lines = body.splitlines()
    if lines and lines[0].startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    body = "\n".join(lines).strip()

if not body:
    fail("empty judge output")

# Drop any header comment the model emitted (we finalize it deterministically).
lines = body.splitlines()
if lines and lines[0].lstrip().startswith("<!-- generated by memory-distiller"):
    lines = lines[1:]
# also drop leading blank lines
while lines and not lines[0].strip():
    lines = lines[1:]
body = "\n".join(lines).strip()

if "# Open Threads" not in body:
    fail("missing '# Open Threads' H1 — output not in threads.md format")

thread_count = len(re.findall(r"(?m)^## ", body))
if thread_count == 0 and nonempty:
    fail("zero threads but input was non-empty (suspected LLM refusal / off-format)")
if thread_count > max_threads:
    fail(f"thread count {thread_count} exceeds ceiling {max_threads}")

now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
# Finalize header (size computed on the assembled file).
def assemble(size_kb):
    header = (f"<!-- generated by memory-distiller · {now} · "
              f"{size_kb}/16KB · do not hand-edit -->")
    return header + "\n" + body + "\n"

provisional = assemble("0.0")
size_kb = round(len(provisional.encode("utf-8")) / 1024, 1)
final = assemble(size_kb)
total = len(final.encode("utf-8"))

if total > hard_cap:
    fail(f"size {total} bytes exceeds hard cap {hard_cap}")

with open(out_f, "w", encoding="utf-8") as fh:
    fh.write(final)

print(f"OK threads={thread_count} bytes={total} kb={size_kb}")
notes = notes.strip()
if notes:
    print("NOTES-START")
    print(notes)
    print("NOTES-END")
PY
ENFORCE_RC=$?
set -e
cat "$ENFORCE_RESULT"

if [ "$ENFORCE_RC" -ne 0 ]; then
    echo "ERROR: enforce rejected the judge output — KEEPING previous threads.md, index goes one day stale" >&2
    echo "       (raw judge output preserved at $RAW_OUT for inspection)" >&2
    exit 4
fi

# Surface any distiller notes for follow-up (evergreen facts etc. — NOT written to threads.md).
if grep -q '^NOTES-START$' "$ENFORCE_RESULT"; then
    echo "- distiller flagged notes for follow-up:"
    sed -n '/^NOTES-START$/,/^NOTES-END$/p' "$ENFORCE_RESULT" | sed '1d;$d'
fi

# --- commit the validated file into place ---
mv "$TMP_THREADS" "$THREADS_FILE"
echo "- wrote $THREADS_FILE"

if [ "$DO_COMMIT" = true ]; then
    if [ -d "$REPO_ROOT/.git" ]; then
        cd "$REPO_ROOT"
        git add "$THREADS_FILE"
        if git diff --cached --quiet -- "$THREADS_FILE"; then
            echo "- threads.md unchanged — nothing to commit"
        else
            git commit -q -m "distiller: refresh memory/threads.md" -- "$THREADS_FILE"
            echo "- committed threads.md"
        fi
    else
        echo "- $REPO_ROOT is not a git repo — skipping commit"
    fi
    # advance watermark to today (only on a real committing run)
    "$PYTHON" - "$STATE_FILE" "$TODAY" <<'PY'
import sys, json, os
state_f, today = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(state_f):
    try:
        data = json.load(open(state_f)) or {}
    except Exception:
        data = {}
data["last_processed"] = today
tmp = state_f + ".tmp"
json.dump(data, open(tmp, "w"))
os.replace(tmp, state_f)
PY
    echo "- advanced watermark: last_processed=$TODAY"
else
    echo "- --no-commit: threads.md left in working tree, watermark NOT advanced"
fi

echo "=== memory-distiller complete at $(date) ==="
