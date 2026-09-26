# Design

`mem` is a two-tier memory system for a long-running AI agent (or any agent-like
workflow that wakes fresh each session and needs continuity). This document is the
architectural reference; the README is the user-facing quickstart.

## Why two tiers

Pull-based agent memory — a semantic-graph or vector store the agent is *supposed*
to query when it needs something — reliably fails in practice: recall on the
agent's own initiative mostly doesn't happen, so the store fills up and never gets
read. Meanwhile, dumping the entire raw log into every prompt balloons the context
and buries the signal.

The fix is to **push a tiny index and keep the bodies on demand.** Two tiers:

1. **Append-only daily logs** (`memory/YYYY-MM-DD.md`) — the raw record. Cheap to
   write, never rewritten, greppable forever.
2. **A small always-injected index** (`memory/threads.md`) — a few lines per open
   thread of work, regenerated nightly by an LLM from the daily logs. This is what
   loads into every session so a fresh agent knows what is in flight without
   carrying the whole history.

Recall closes the loop: `mem search` / `mem thread` / `mem search --deep` fetch the
bodies in one command when the index points at something worth reading.

This shape — append-only log + curated small always-loaded file + background LLM
consolidation + grep-first retrieval — is what several independent agent-memory
systems converged on. See the credits in the README.

## Architecture

```
capture (mem CLI, in-flow, 1 command)
   └→ memory/YYYY-MM-DD.md          append-only dailies, structured entries
        └→ distiller (nightly LLM job)
             └→ memory/threads.md   small always-injected index of OPEN work
harness injects: your identity/context files + threads.md + last-N-days dailies + catalog
recall: mem search (ripgrep) / mem search --deep (embeddings) / mem thread <slug> / read the file
```

## The entry grammar (the contract)

Everything depends on one line format, appended to today's daily:

```markdown
### 14:32 [deploy-pipeline] staging cutover verified, prod scheduled for Friday
optional body — any markdown, any length, until the next ### or EOF
```

- **slug**: `[a-z0-9-]+`, one per entry. `mem` without `-t` uses `[misc]`.
- **date** comes from the filename, **time** from the header — entries never
  contain relative dates ("today", "yesterday"), which rot once persisted.
- **Legacy / freeform content** (older dailies, plain `## heading` notes) must not
  break any parser: non-matching content is treated as opaque text that grep still
  covers. You can adopt the format mid-stream without migrating old notes.

## The CLI

Single stdlib-only `python3` script (`bin/mem`). Core verbs shell out to `rg` and
`git` only. Verbs:

| verb | behavior |
|---|---|
| `mem [-t slug] "summary"` | append an entry (body via stdin pipe if piped), then `git add + commit` if the workspace is a git repo |
| `mem search <pattern>` | ripgrep (`rg -i`) across `memory/ docs/ reference/ skills/` (+ optional `MEM_VAULT`), newest-first by mtime, grouped by file with heading context |
| `mem search --deep <query>` | embeddings lane (below); falls back to plain search with a warning if the index or key is unavailable |
| `mem thread <slug>` | every entry with that slug across all dailies, chronological, with dates — reconstructs a work arc in one command |
| `mem threads` | print `memory/threads.md` |
| `mem recent [n]` | last n entries (default 10) |
| `mem show <date>` | print that daily |
| `mem close <slug> <reason>` | append a `### HH:MM [slug] CLOSED: <reason>` entry — an explicit retire signal the distiller honors |
| `mem catalog [--write]` | generate the on-demand-file catalog; `--write` saves to `generated/catalog.md` |
| `mem embed` | (re)build the `--deep` index incrementally |

### Catalog

`mem catalog` produces one line per file across `reference/`, `docs/`,
`skills/*/SKILL.md` (name + description from frontmatter), and — if `MEM_VAULT` is
set — the vault's top-level directories (name + file count only, never enumerating
the vault's files). Line shape: `- path — one-line description`. Description comes
from YAML frontmatter `description:` if present, else the first heading/line,
truncated ~100 chars. Target ≤3KB; over budget, the least-recently-modified groups
collapse to `dir/ (N files)`. Output is deterministically sorted so the injected
context stays cache-friendly.

### `--deep` embeddings lane (optional)

- Model: any OpenAI-compatible embeddings endpoint (default
  `text-embedding-3-large`, 3072 dims; both overridable).
- Store: sqlite + [`sqlite-vec`](https://github.com/asg017/sqlite-vec) at
  `$XDG_DATA_HOME/mem/index.db` (per-machine, **not** in git).
- Chunking: per structured entry for dailies; per `##` section for other markdown;
  ~500-token target, path+heading kept as metadata.
- Incremental: the index tracks file mtime+hash; `mem embed` re-embeds only changed
  files (the distiller runs it nightly).
- Key handling: `OPENAI_API_KEY` env, or a Bitwarden item named by
  `MEM_OPENAI_BW_ITEM`. The key flows env/Bitwarden → process only; it is never
  printed, logged, or read back. No key ⇒ the lane cleanly falls back to plain
  search.
- Results: hybrid — top-k vector hits merged with `rg` hits on the same query,
  deduped by (file, chunk), printed with paths + dates.

The `--deep` lane is entirely optional. The core system is grep-only and needs no
API key, no daemon, and no third-party python packages.

## The distiller

Three files: `distiller/memory-distiller.sh` (wrapper), `memory-distiller.prompt.md`
(the prompt), and an install unit (launchd plist / systemd timer). Runs nightly.

### Pipeline (three stages, script-enforced)

1. **Gather (mechanical):** parse entries since the `last_processed` watermark
   (`state.json`) from the dailies; include the current `threads.md`; compute
   per-thread staleness (days since last entry). Assemble one working-set document.
   Also run `mem embed` and `mem catalog --write` (mechanical freshness, no LLM).
2. **Judge (LLM):** the shell command in `MEM_JUDGE_CMD` receives the prompt +
   working set on stdin and writes a complete new `threads.md` candidate to stdout.
   Provider, model, and authentication options are part of that command or its
   environment; the distiller adds none. Stderr is inherited. The single-instance
   lock prevents overlapping runs, and the wrapper imposes no judge timeout. A
   nonzero exit stops the run with the same status and preserves the previous file.
3. **Enforce + commit (mechanical):** validate — parses as the expected format,
   ≤16KB, sane thread count (reject if empty-when-input-nonempty or >60 threads).
   On failure: keep yesterday's `threads.md`, log loudly, exit nonzero (the health
   check surfaces it). On success: write, `git add + commit`, advance the watermark.
   **A failed run degrades to "index one day stale," never "index destroyed."**

### threads.md format

Carries a `do-not-hand-edit` header. Per thread: slug, status
(`active`/`parked`/`waiting-on-operator`), absolute last-touched date, 1–3 line
current state, and a pointer line (`→ mem thread <slug> · memory/<date>.md`).

```markdown
<!-- generated by memory-distiller · 2026-07-16 04:31 · 11.2/16KB · do not hand-edit -->
# Open Threads

## deploy-pipeline — active, last 2026-07-11 (9 entries)
Blue/green cutover script verified on staging; prod rollout gated on the Friday change window.
→ mem thread deploy-pipeline · memory/2026-07-11.md

## garden-irrigation — parked, last 2026-07-04
Drip zones re-plumbed; controller firmware update deferred until the new valves arrive.
→ mem thread garden-irrigation · memory/2026-07-04.md
```

There is **no "standing notes" section** — `threads.md` holds open work only.
Evergreen facts (gotchas, stable config, reusable recipes) belong in your
always-loaded context files, not the index. If the distiller notices such a fact it
flags it in the run log for human follow-up, never writes it to `threads.md`.

### Prompt guardrails

The distiller prompt bakes in the failure-mode mitigations the field has converged
on:

- **Signal gate** — if nothing meaningful changed, output the previous `threads.md`
  unchanged. An empty diff is a valued outcome.
- **No relative dates** — absolute dates only.
- **Declarative facts, not imperatives** — state lines describe; they never instruct
  (imperatives get re-read as standing directives).
- **No negative capability claims** — capture the fix, never "X is broken" (bare
  negatives fossilize into refusals).
- **Stale-in-a-week test** — no SHAs, PR numbers, or "phase N done" bookkeeping in
  state lines.
- **Expiry at LLM discretion** — staleness is a signal, not a rule; `CLOSED:`
  entries are explicit retire signals.
- **Budget** — aim ≤14KB so the 16KB hard cap has headroom.

## Harness integration

The index is only useful if it loads into every session. Inject `threads.md` (and
optionally `generated/catalog.md`) into whatever always-loaded context your agent
harness uses — a `CLAUDE.md`, an `AGENTS.md`, a system-prompt preamble. Keep the
raw-dailies injection short (a couple of days); the index carries the older context
by pointer. See the README's "Harness integration" section for the concrete pattern.

## Deliberate non-goals

- **No vector store as the primary path.** Grep is the default; embeddings are an
  optional supplement. At personal scale, files + grep are simpler and more
  reliable, and the tools are ones an agent already knows how to use.
- **No inline memory editing by the chat agent.** Writes are append-only captures;
  curation of the always-loaded tier is a separate, scheduled, background job.
- **No hidden state.** The agent only "remembers" what is on disk. Everything is
  plain markdown you can read, grep, and version-control.
