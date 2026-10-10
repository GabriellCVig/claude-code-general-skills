# Cutting Claude Code subagent token costs: what we measured and what worked

We build a Rust project with Claude Code. Lead sessions plan the work and hand each piece to a
subagent, a worker with its own context. In early October 2026 we measured where the tokens
went. A third of all spend was the same mistake: workers waited so long that their prompt cache
expired. This page covers how we found it, the rules that fixed it, and two small scripts you
can reuse.

## The cost model in one paragraph

Each turn sends the whole context again. Prompt caching makes most of it cheap. Multiples of
one uncached input token:

| Part of a turn | Cost |
|---|---|
| Cache read | 0.1× |
| Cache write, 5-minute cache | 1.25× |
| Cache write, 1-hour cache | 2× |
| Output token | 5× |

Subagents and agent-team teammates use the 5-minute cache by default, even on a subscription;
the main session gets 1 hour. If a subagent's next turn comes more than 5 minutes after its
last one, the whole context is written to the cache again. That one turn costs 12.5 times
what a cached turn would: at 300k tokens of context, 375k units instead of 30k. The idle time
can come from a long blocking command, a long `sleep`, or the lead waking an idle worker with a
message.

## What we measured

`token_report.py` reads the local transcripts under `~/.claude/projects/`. It weights every
subagent turn at the prices above. It also marks a **full rewrite**: a turn that writes most of
a context larger than 30k to the cache again.

| | Before (2026-09-27 to 10-04) | After (2026-10-05 to 10-10) |
|---|---|---|
| Subagents' share of all spend | 89% | (not re-measured) |
| Full rewrites, share of subagent spend | **41%** | **3%** |

Before, the biggest single cause was one documented habit: wait for a remote job with
`timeout 590 …`. Each wait outlasted the 5-minute cache, so every check-in rewrote the whole
context.

## The rules that fixed it

We put these in the repository's `CLAUDE.md`, so every session and subagent reads them. Before,
they lived in private memory files that workers never saw.

1. **No call blocks longer than 4 minutes.** Wait with `timeout 240 …` and repeat on exit code
   124. Never `sleep` past 240 s. Every turn under 5 minutes keeps the cache warm.
2. **The agent that starts a long job doesn't wait for it.** That covers a benchmark or a full
   test-gate run. The agent writes the job id to a results file and finishes; the lead, or a
   fresh worker, picks up the result.
3. **Start fresh agents; don't wake idle ones.** An idle worker woken after more than 5
   minutes rewrites its whole context. A new worker that reads the old one's report file starts
   small.
4. **Workers report to files.** The worker writes its result to a file or the issue and sends
   the lead one line: done or blocked, and where to read. This keeps the lead's context small.
5. **Keep build and test output out of the context.** Run them through `quiet.sh` (below).
6. **Read by line range.** When the agent knows where to look, it doesn't read a large file
   whole.
7. **Build once per round.** Make every edit, then build and test once, and re-run only the
   failing suites. Reviewers read and don't build.

We changed no settings and kept the 5-minute cache. The fix was in how the agents work.

## Should you switch subagents to the 1-hour cache?

Claude Code lets you change it. Set `"subagentPromptCacheTtl": "1h"` in settings, set the env
var `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL=1h`, or add `experimental: cacheTtl: 1h` to one
agent's frontmatter. See the [prompt caching docs](https://code.claude.com/docs/en/prompt-caching.md).

It's a trade:

- **It saves:** rewrites after an idle gap of 5–60 minutes become cache reads, about 92% cheaper.
- **It costs:** every other cache write goes from 1.25× to 2×. That includes each turn's new
  tokens, which is a cost you pay all the time.

`token_report.py` estimates the net for your own transcripts. For us, after the rules above,
rewrites after a 5–60 minute gap were only 3.9M of 209M. The 1-hour cache would have saved 3.6M
and added 18.9M: **7% more spend**. Before the rules, at 41% rewrites, it would very likely have
paid off. So fix the waiting habits first, then run the estimate. If agents in your workflow
must sit idle for 5–60 minutes, the 1-hour cache is the right tool.

## Where the spend goes now

Large contexts: 76% of subagent spend comes from turns with more than 100k tokens of context.
Most of what fills a context is file reading through Bash, not build output:

| Bash command | Share of Bash result bytes |
|---|---|
| `sed` (range reads) | 38% |
| `grep` | 17% |
| `cat` | 9% |
| build and test output (through `quiet.sh`) | about 1% |

The next levers are narrower reads (`grep -l`/`-c`/`-m`, smaller ranges), splitting very large
source files, and smaller units of work per worker.

## The scripts

### `token_report.py`

```sh
python3 token_report.py --project /path/to/repo --since 2026-10-01
```

It only reads `~/.claude/projects/`. It prints:

- subagent spend by context size;
- cache writes split into first-turn, incremental and full rewrites, with the rewrites split by
  idle gap (5 minutes or less, 5–60 minutes, over 60 minutes);
- the 1-hour cache estimate;
- peak context per subagent;
- which tools, and which Bash commands, fill the context.

Leave out `--project` to cover every project. The transcript format is Claude Code's internal
JSONL, not a public API, so a future version may break the script.

### `quiet.sh`

```sh
./quiet.sh cargo test -p mycrate
./quiet.sh --name lint -- make lint
```

Runs the command with all its output in a log file (default `.quiet-logs/` at the git root;
add that to `.gitignore`). It prints only:

- the command, exit code, run time and line count;
- a summary;
- the failures, capped at 60 lines per section;
- the log path.

It exits with the command's exit code.

It understands output from cargo build/check/clippy (error blocks and counts), cargo test and
nextest (totals, failed test names, panic messages), and `<STAGE>_RC=<n>` lines. For anything
else that fails, it falls back to matching lines with FAIL/ERROR/error/panicked and the last 20
lines. The parsers are Rust-specific, but the pattern isn't: the agent sees what failed and
opens the log only when it needs more. Tell agents to use it in your `CLAUDE.md`, for example
"Run builds and tests through `quiet.sh`".
