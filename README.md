# mem

Two-tier memory for long-running AI agents: append-only daily logs plus a small,
LLM-distilled index of open work that loads into every session.

A single stdlib-`python3` CLI for capture and recall, and a nightly distiller that
keeps a tiny `threads.md` index current. No database to run, no vector store
required, no framework. Just markdown files, `git`, and `ripgrep`.

## The idea in one minute

An agent that wakes fresh each session needs continuity. Two failure modes bracket
the naive approaches:

- **Dump the whole history into the prompt** → context bloat, buried signal.
- **Stash it in a store the agent queries on demand** → the agent rarely queries it,
  so the store fills up and never gets read.

`mem` splits the difference into two tiers:

1. **Append-only daily logs** — `memory/YYYY-MM-DD.md`, one structured entry per
   thing worth remembering. Cheap to write, never rewritten, greppable forever.
2. **A small always-injected index** — `memory/threads.md`, a few lines per open
   thread of work, regenerated nightly by an LLM from the logs. This is the piece
   that loads into every session.

**Push the index, keep the bodies on demand.** A fresh session sees what's in flight
from `threads.md`; when it needs detail, `mem thread <slug>` or `mem search` pulls
the full record in one command.

### Philosophy

- **Push, don't trust pull.** Recall-on-agent-initiative doesn't reliably happen.
  Inject a tiny index instead of hoping the agent searches.
- **Files + grep beat vector stores at personal scale.** Simpler, more reliable, and
  the tools are ones an agent already knows how to use. Embeddings are an optional
  supplement (`--deep`), never the default path.
- **Writing to the always-loaded tier is hard, on purpose.** A background LLM curates
  the index behind a **signal gate**: if nothing meaningful changed, it re-emits the
  file unchanged. An empty diff is a valued outcome.
- **No relative dates.** Entries carry the date in the filename; the distiller writes
  absolute dates only. "Yesterday" rots the moment it's persisted.
- **Cap-and-error, not truncate.** The index has a hard 16KB cap; over budget, the
  run is rejected and yesterday's index is kept. A bad run degrades to "one day
  stale," never "index destroyed."
- **Declarative, not imperative; no negative capability claims.** State lines
  describe the world. "X is broken" fossilizes into a refusal the agent cites at
  itself for months; capture the fix instead.

### Credits / prior art

The two-tier shape — append-only log + curated always-loaded index + background LLM
consolidation + grep-first recall — is something several agent-memory systems
arrived at independently. `mem` borrows specific, load-bearing ideas from:

- **[Letta](https://github.com/letta-ai/letta) sleep-time agents** — background
  memory consolidation on a delta since the last watermark, and the "integrate /
  update / organize / infer sensibly / be precise" refinement principles the
  distiller prompt is built on.
- **OpenClaw** — the daily-log-plus-curated-`MEMORY.md` file contract and the
  standing "search before answering about the past" recall discipline.
- **[Hermes](https://github.com/NousResearch) (NousResearch)** — hard char caps that
  *error* instead of truncating, "declarative not imperative," and the ban on
  negative capability claims that "harden into refusals."
- **Stanford generative agents ([arXiv 2304.03442](https://arxiv.org/abs/2304.03442))** —
  the reflection pattern: periodically distill an append-only memory stream into
  higher-level summaries rather than re-deriving them per query.

## Install

Requirements: `python3` (3.8+, stdlib only), [`ripgrep`](https://github.com/BurntSushi/ripgrep)
(`rg`), `git`, and `jq` (for the distiller wrapper only).

```sh
git clone https://github.com/UberKitten/mem.git ~/mem
ln -s ~/mem/bin/mem ~/.local/bin/mem          # or anywhere on your PATH

mkdir -p ~/.config/mem
cp ~/mem/install/config.example ~/.config/mem/config
$EDITOR ~/.config/mem/config                   # set MEM_ROOT to your notes dir
```

Point `MEM_ROOT` at the directory where your notes live (ideally a git repo). The
daily logs go in `$MEM_ROOT/memory/`.

## Quickstart (60 seconds)

```sh
# capture — one entry, tagged with a thread slug
mem -t deploy-pipeline "staging cutover verified, prod scheduled Friday"

# capture with a longer body via stdin
echo "valves arrive next week; controller firmware update deferred until then" \
  | mem -t garden-irrigation "drip zones re-plumbed"

# bare capture lands under [misc]
mem "picked the blue tiles for the bathroom"

# recall — reconstruct a whole thread, chronological
mem thread deploy-pipeline

# recall — grep everything, newest file first
mem search firmware

# the last few things you logged
mem recent

# retire a thread (an explicit signal to the distiller)
mem close deploy-pipeline "shipped to prod"
```

Every capture appends to today's `memory/YYYY-MM-DD.md` and, if `MEM_ROOT` is a git
repo, commits it. That's the whole write path.

## Entry grammar

One line format is the contract that capture, recall, and the distiller all depend
on:

```markdown
### 14:32 [deploy-pipeline] staging cutover verified, prod scheduled Friday
optional body — any markdown, any length, until the next ### or EOF
```

- **slug** is `[a-z0-9-]+`, one per entry (`mem` without `-t` uses `[misc]`).
- **date** is the filename; **time** is the header. Entries never carry relative
  dates.
- Older freeform notes in the same directory don't break anything — non-matching
  content is opaque text that grep still covers. You can adopt this mid-stream.

## The distiller

A nightly job turns the daily logs into `threads.md`. Three script-enforced stages:
**gather** (parse entries since the watermark, mechanical), **judge** (an LLM emits a
fresh `threads.md`), **enforce** (validate format + 16KB cap + sane thread count;
keep yesterday's file on any failure). It also refreshes the embeddings index and
the catalog if those are in use.

The judge is the shell command configured in `MEM_JUDGE_CMD`. It receives the prompt
and working set on stdin and must write a complete `threads.md` candidate to stdout;
stderr remains visible in the distiller log. Provider, model, and authentication
options belong to that command or its environment. For example:

```sh
MEM_JUDGE_CMD='llm -m gpt-4o'
# Explicit Claude Code adapter:
MEM_JUDGE_CMD='claude --print'
```

The wrapper permits only one concurrent run and does not impose a judge timeout. A
nonzero judge exit stops the run with the same status and leaves the previous
`threads.md` unchanged.

Run it by hand:

```sh
# dry review — writes threads.md, no git commit, watermark not advanced
bash distiller/memory-distiller.sh --no-commit

# real run
bash distiller/memory-distiller.sh --now
```

### Scheduling

**launchd (macOS)** — edit the paths in `install/com.example.mem-distiller.plist`
(`__HOME__`, `__REPO__`), then:

```sh
cp install/com.example.mem-distiller.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.mem-distiller.plist
launchctl kickstart -k gui/$(id -u)/com.example.mem-distiller   # run once now
```

**systemd (Linux)** — edit the `ExecStart` path in `install/mem-distiller.service`,
then:

```sh
mkdir -p ~/.config/systemd/user
cp install/mem-distiller.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now mem-distiller.timer
```

**plain cron** — 04:30 nightly:

```cron
30 4 * * * /bin/bash /path/to/mem/distiller/memory-distiller.sh >> ~/.local/share/mem/distiller/logs/cron.log 2>&1
```

**health check** — `install/health-check.sh` exits nonzero if `threads.md` hasn't
refreshed within a grace window (default 48h). Wire it into whatever alerting you
use.

## Harness integration

The index only helps if it loads into every session. Inject `threads.md` (and
optionally `generated/catalog.md`) into your agent's always-loaded context — a
`CLAUDE.md`, an `AGENTS.md`, a system-prompt preamble, whatever your harness reads.
Keep the raw-dailies injection short (a day or two); the index carries older context
by pointer.

The generic pattern, in a context-assembly step that runs before each session:

```sh
CTX=~/.config/your-agent/CONTEXT.md
{
  cat ~/identity.md                      # your persona / standing instructions

  echo; echo "<!-- Source: memory/threads.md -->"
  cat "$MEM_ROOT/memory/threads.md"      # the always-injected index of open work

  echo; echo "<!-- Source: generated/catalog.md -->"
  cat "$MEM_ROOT/generated/catalog.md"   # one-line map of on-demand files

  # only the last couple of days of raw log — the index covers the rest
  for d in $(ls "$MEM_ROOT/memory/"*.md | grep -E '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -2); do
    echo; echo "<!-- Source: $d -->"; cat "$d"
  done
} > "$CTX"
```

Then add a one-line standing instruction to your persona file so the agent pulls on
the index instead of guessing:

> Before answering about prior work, decisions, or preferences, run `mem search
> <term>` or `mem thread <slug>`. The `threads.md` index above lists what's open;
> the dailies are the source of truth.

## Optional: the `--deep` embeddings lane

Grep is the default and needs nothing extra. If you want semantic recall too:

```sh
# one-time: a venv holding sqlite-vec (system python is often externally-managed)
uv venv ~/.local/share/mem/venv
uv pip install --python ~/.local/share/mem/venv/bin/python sqlite-vec

# an OpenAI-compatible embeddings key — env, or a Bitwarden item id in config
export OPENAI_API_KEY=sk-...

mem embed                    # build the index (incremental; nightly via the distiller)
mem search --deep "that thing about the irrigation controller firmware"
```

`--deep` returns hybrid results (top-k vector hits merged with keyword hits). With no
key or no index, it prints a notice and falls back to plain search. The index lives
at `$XDG_DATA_HOME/mem/index.db`, per-machine, never committed. The API key flows
env/Bitwarden → process only; it is never printed or logged.

## Configuration reference

Environment variables override values in `~/.config/mem/config` (plain `KEY=value`
lines). See `install/config.example`.

| Variable | Default | Purpose |
|---|---|---|
| `MEM_ROOT` | `~/memory-workspace` | Workspace root; dailies live in `$MEM_ROOT/memory/` |
| `MEM_VAULT` | *(unset)* | Optional extra read-only root folded into search + catalog |
| `MEM_VAULT_LABEL` | `vault` | Display label for `MEM_VAULT` paths in output |
| `MEM_NO_COMMIT` | *(unset)* | Any value disables the git commit on capture/close |
| `MEM_JUDGE_CMD` | *(required)* | Judge shell command; prompt and working set on stdin, candidate `threads.md` on stdout |
| `MEM_PYTHON` | `python3` | Python interpreter the distiller uses |
| `OPENAI_API_KEY` | *(unset)* | Embeddings key for `--deep` (takes precedence over Bitwarden) |
| `MEM_OPENAI_BW_ITEM` | *(unset)* | Bitwarden item id/name holding the embeddings key |
| `MEM_EMBED_MODEL` | `text-embedding-3-large` | Embeddings model |
| `MEM_EMBED_DIMS` | `3072` | Embedding dimensions |
| `MEM_EMBED_BASE_URL` | `https://api.openai.com/v1` | Embeddings API base URL |
| `MEM_DEEP_REMOTE` | *(unset)* | ssh host to delegate `search --deep` to when this machine has no key/index — the keyless-client pattern (remote host needs `mem` at `~/bin/mem` and its own key + index) |
| `MEM_HEALTH_GRACE_HOURS` | `48` | Staleness grace window for the health check |

## Layout

```
bin/mem                              the CLI (single-file python3, stdlib only)
distiller/memory-distiller.sh        nightly gather → judge → enforce wrapper
distiller/memory-distiller.prompt.md the distiller's LLM prompt
install/config.example               sample ~/.config/mem/config
install/com.example.mem-distiller.plist   launchd template (macOS)
install/mem-distiller.service|.timer      systemd user units (Linux)
install/health-check.sh              staleness check example
docs/design.md                       architecture reference
```

## License

MIT. See [LICENSE](LICENSE).

≽^•⩊•^≼
