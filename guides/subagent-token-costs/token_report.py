#!/usr/bin/env python3
"""Where Claude Code subagents spend their tokens, read from the local session transcripts.

Usage:
  token_report.py [--project PATH] [--since YYYY-MM-DD]

  --project  a repository path (the transcripts of the sessions run there) or a transcript
             directory under ~/.claude/projects/. Default: every project.
  --since    only count turns from this date on (default: 30 days ago).

Spend is weighted at API prices, in units of one uncached input token: cache read 0.1,
5-minute cache write 1.25, output 5. On a subscription these weights are a proxy for how
fast the usage limit is used up, not an exact match.

What it prints, for subagent turns only (the main session is left out):
  - weight by the size of the context at each turn;
  - cache-write weight split into first-turn writes, incremental writes (the new tokens of
    each turn) and full rewrites (a turn that re-writes most of a large context because the
    cache expired), with the rewrites split by the idle gap before them;
  - an estimate of what the 1-hour subagent cache (`subagentPromptCacheTtl: "1h"`) would
    change: rewrites after a 5-60 minute gap become cache reads, every other cache write
    costs 2 instead of 1.25;
  - peak context per subagent, and which tools and Bash commands fill the context.
"""
import argparse, collections, datetime, glob, json, os, re

ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
ap.add_argument('--project')
ap.add_argument('--since', default=(datetime.date.today() - datetime.timedelta(days=30)).isoformat())
args = ap.parse_args()

root = os.path.expanduser('~/.claude/projects')
if not args.project:
    dirs = [root + '/*']
elif os.path.isdir(os.path.join(root, os.path.basename(args.project.rstrip('/')))):
    dirs = [os.path.join(root, os.path.basename(args.project.rstrip('/')))]
else:  # a repository path: Claude Code names its transcript directory after the path
    dirs = [os.path.join(root, re.sub(r'[^A-Za-z0-9]', '-', os.path.abspath(args.project)))]

READ, WRITE, WRITE_1H, OUT = 0.1, 1.25, 2.0, 5.0


def when(ts):
    return datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))


def bucket(ctx):
    for lim, name in ((50e3, '<50k'), (100e3, '50-100k'), (200e3, '100-200k'), (400e3, '200-400k')):
        if ctx < lim:
            return name
    return '>=400k'


total = 0.0
by_ctx = collections.Counter()
writes = collections.Counter()      # first, incremental, rewrite
rewrites_by_gap = collections.Counter()
rewrite_events = 0
peaks, agents = [], collections.Counter()
tool_bytes, tool_calls = collections.Counter(), collections.Counter()
bash_bytes, bash_calls = collections.Counter(), collections.Counter()

for d in dirs:
    for f in glob.glob(d + '/*/subagents/*.jsonl'):
        try:
            lines = open(f).readlines()
        except OSError:
            continue
        kind = '?'
        try:
            kind = json.load(open(f.replace('.jsonl', '.meta.json'))).get('agentType', '?')
        except (OSError, ValueError):
            pass
        turns, order, tool_of, bash_cmd = {}, [], {}, {}
        for line in lines:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            ts = rec.get('timestamp', '')
            if ts < args.since:
                continue
            msg = rec.get('message') or {}
            content = msg.get('content')
            if isinstance(content, list):
                for b in content:
                    if b.get('type') == 'tool_use':
                        tool_of[b['id']] = b['name']
                        tool_calls[b['name']] += 1
                        if b['name'] == 'Bash':
                            bash_cmd[b['id']] = b.get('input', {}).get('command', '')
                    elif b.get('type') == 'tool_result':
                        n = len(json.dumps(b.get('content', '')))
                        tool_bytes[tool_of.get(b.get('tool_use_id'), '?')] += n
                        cmd = bash_cmd.get(b.get('tool_use_id'))
                        if cmd is not None:
                            # first program after any leading `cd …&&` / `VAR=…`
                            words = re.sub(r'^(\s*(cd \S+|[A-Za-z_]+=\S*)\s*(&&|;)?\s*)+', '', cmd).split()
                            key = ' '.join(words[:2]) if words and words[0] in ('git', 'gh', 'cargo', 'npm', 'python3', 'timeout') else (words[0] if words else '')
                            bash_bytes[key] += n
                            bash_calls[key] += 1
            usage = msg.get('usage')
            if usage and msg.get('id'):
                if msg['id'] not in turns:
                    order.append(msg['id'])
                turns[msg['id']] = (ts, usage)   # streamed messages repeat; keep the last
        prev, peak = None, 0
        for i, mid in enumerate(order):
            ts, u = turns[mid]
            cr = u.get('cache_read_input_tokens', 0)
            cw = u.get('cache_creation_input_tokens', 0)
            ctx = cr + cw + u.get('input_tokens', 0)
            w = READ * cr + WRITE * cw + OUT * u.get('output_tokens', 0)
            total += w
            by_ctx[bucket(ctx)] += w
            peak = max(peak, ctx)
            gap = (when(ts) - when(prev)).total_seconds() if prev else 0
            prev = ts
            if i == 0:
                writes['first'] += WRITE * cw
            elif cw > 0.5 * ctx and ctx > 30e3:
                writes['rewrite'] += WRITE * cw
                rewrite_events += 1
                rewrites_by_gap['>60m' if gap > 3600 else '5-60m' if gap > 300 else '<=5m'] += WRITE * cw
            else:
                writes['incremental'] += WRITE * cw
        if order:
            peaks.append(peak)
            agents[kind] += 1

if not total:
    raise SystemExit('no subagent turns found since %s in %s' % (args.since, dirs))


def pct(v):
    return '%.0f%%' % (100 * v / total)


M = lambda v: '%.1fM' % (v / 1e6)
print('subagent weight since %s: %s (%d subagents)' % (args.since, M(total), len(peaks)))
print('by context size at the turn:', {k: pct(by_ctx[k]) for k in ('<50k', '50-100k', '100-200k', '200-400k', '>=400k') if by_ctx[k]})
print('cache writes: first-turn %s, incremental %s, full rewrites %s (%d events, %s of weight)' % (
    M(writes['first']), M(writes['incremental']), M(writes['rewrite']), rewrite_events, pct(writes['rewrite'])))
print('full rewrites by idle gap before them:', {k: M(v) for k, v in rewrites_by_gap.items()})
gain = rewrites_by_gap['5-60m'] * (1 - READ / WRITE)
cost = (WRITE_1H / WRITE - 1) * (writes['first'] + writes['incremental'] + rewrites_by_gap['<=5m'] + rewrites_by_gap['>60m'])
print('1-hour subagent cache, estimate: saves %s, costs %s, net %+.0f%% of subagent weight' % (M(gain), M(cost), 100 * (cost - gain) / total))
peaks.sort()
q = lambda p: peaks[min(len(peaks) - 1, int(p * len(peaks)))] / 1e3
print('peak context per subagent: p50 %dk p90 %dk max %dk; above 200k: %d' % (q(.5), q(.9), peaks[-1] / 1e3, sum(p > 200e3 for p in peaks)))
print('agent types:', dict(agents.most_common()))
tb = sum(tool_bytes.values()) or 1
print('tool result bytes:', ', '.join('%s %.0f%% (%d calls)' % (k, 100 * v / tb, tool_calls[k]) for k, v in tool_bytes.most_common(6)))
bb = sum(bash_bytes.values()) or 1
print('Bash result bytes by command:', ', '.join('%s %.0f%%' % (k, 100 * v / bb) for k, v in bash_bytes.most_common(10)))
