#!/usr/bin/env bash
# quiet.sh: run a command with its output in a log file; print only what an agent needs.
# Keeps build/test noise out of a coding agent's context: the agent sees a short summary
# and the failures, and can open the log when it needs more.
#   quiet.sh [--name <label>] [--] <cmd…>
# Writes stdout+stderr to $QUIET_LOG_DIR/<time>-<label>.log and prints: the command, rc,
# elapsed time, a summary, the failures (capped) and the log path. Exits with the command's rc.
# What it recognises, by the log's content (so it also works through wrapper scripts):
#   compiler   cargo build/check/clippy/doc: error and warning counts, the error blocks
#   tests      cargo test (libtest) and nextest: result totals, failed test names, panic messages
#   generic    `*_RC=` and `<NAME> pass=<n> fail=<n>` lines always; on a failure nothing above explains, lines with
#              FAIL/ERROR/error/panicked and the last 20 lines
# Knobs (env):
#   QUIET_LOG_DIR    log directory (default <git toplevel or cwd>/.quiet-logs; add it to .gitignore)
#   QUIET_MAX_LINES  cap on each printed failure section (default 60)
set -uo pipefail

name=
while [ $# -gt 0 ]; do
  case $1 in
    --name) name=${2:-}; shift 2 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: quiet.sh [--name <label>] [--] <cmd…>" >&2; exit 2; }

max=${QUIET_MAX_LINES:-60}
tailn=20
top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
dir=${QUIET_LOG_DIR:-$top/.quiet-logs}
mkdir -p "$dir" || { echo "quiet: cannot create $dir" >&2; exit 2; }
if [ -z "$name" ]; then
  # Label from the first words that are not options, e.g. `cargo-test-mycrate`.
  name=$(printf '%s\n' "$@" | grep -v '^-' | head -3 | xargs -n1 basename 2>/dev/null | tr '\n' '-')
fi
name=$(printf '%s' "${name%-}" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)
log=$dir/$(date +%Y%m%d-%H%M%S)-${name:-cmd}.log
[ -e "$log" ] && log=${log%.log}-$$.log

printf -v cmdline '%q ' "$@"
echo "quiet: \$ ${cmdline% }"
t0=$(date +%s%N)
"$@" > "$log" 2>&1
rc=$?
t1=$(date +%s%N)
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1fs", (b - a) / 1e9 }')

# One pass over the log (ANSI colours stripped); sections are written to files in $tmp.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | awk -v out="$tmp" -v max="$max" '
function cap(file, line) { if (n[file]++ < max) print line > (out "/" file) }
function endblock() { inerr = 0; inpanic = 0 }
# compiler: `error[E0308]: …`, `error: …` (not the trailing "could not compile"), `warning: …`
/^error(\[E[0-9]+\])?: / {
  if ($0 ~ /^error: test (run )?failed/) next
  if ($0 ~ /^error: (could not compile|aborting due to|build failed)/) { cap("cerr", $0); next }
  errors++; inerr = 1; blk = 0; cap("cerr", $0); next
}
/^warning: / {
  if ($0 ~ /generated [0-9]+ warnings?/ || $0 ~ /^warning: build failed/) next
  warnings++; if (nw++ < 5) print > (out "/warn"); next
}
inerr {  # one block per error, its first 12 lines (rustc help notes run long)
  if ($0 == "") { cap("cerr", ""); endblock() }
  else if (++blk < 12) cap("cerr", $0); else if (blk == 12) cap("cerr", "  …"); next
}
# libtest: `test result: FAILED. 3 passed; 1 failed; 0 ignored; …`
/^test result: / {
  results++; if ($0 ~ /FAILED/) failedsuites++
  for (i = 1; i <= NF; i++) {
    v = $(i - 1) + 0
    if ($i ~ /^passed/) tp += v; else if ($i ~ /^failed/) tf += v; else if ($i ~ /^ignored/) ti += v
  }
  next
}
/^test .* \.\.\. FAILED$/ { endblock(); t = $0; sub(/^test /, "", t); sub(/ \.\.\. FAILED$/, "", t); if (!(t in seen)) { seen[t] = 1; cap("tfail", t) } next }
/^---- .* stdout ----$/ { endblock(); t = $0; sub(/^---- /, "", t); sub(/ stdout ----$/, "", t); if (!(t in seen)) { seen[t] = 1; cap("tfail", t) } next }
# nextest: `        FAIL [   0.004s] crate::bin some::test`, `     Summary [ 0.1s] 10 tests run: 9 passed, 1 failed, …`
/^ *(FAIL|SIGSEGV|SIGABRT|TIMEOUT|LEAK) \[/ { endblock(); t = $0; sub(/^ *[A-Z]+ \[[^]]*\] */, "", t); if (!(t in seen)) { seen[t] = 1; cap("tfail", t) } next }
/^ *Summary \[.*tests? run/ { nsum = $0; sub(/^ */, "", nsum); next }
# panics: the header line and the message lines after it, to a blank line or `note:`
/panicked at / { panics++; inpanic = 1; cap("panic", $0); next }
inpanic { if ($0 == "" || $0 ~ /^note: / || $0 ~ /^ *(PASS|FAIL|START|SLOW|Summary|SIGSEGV|SIGABRT|TIMEOUT|LEAK) \[/ || $0 ~ /^-----/ || $0 ~ /^test /) { endblock() } else cap("panic", "  " $0); next }
# generic: anything else that looks like a failure, and `<STAGE>_RC=<n>` lines from wrapper scripts
/FAIL|ERROR|[Ee]rror|panicked/ { cap("gen", NR ": " $0) }
/^[A-Z][A-Z0-9_]*_RC=|^[A-Z][A-Z0-9_]* pass=[0-9]+ fail=[0-9]+$/ { rcl[++nrc] = $0 }
END {
  s = ""
  if (errors || warnings) s = s sprintf("compiler: %d error(s), %d warning(s); ", errors, warnings)
  if (results) s = s sprintf("tests: %d passed, %d failed, %d ignored in %d suite(s); ", tp, tf, ti, results)
  if (nsum != "") s = s "nextest: " nsum "; "
  if (panics) s = s sprintf("%d panic(s); ", panics)
  for (i = 1; i <= nrc && i <= 10; i++) s = s rcl[i] " "
  print s > (out "/summary")
  for (f in n) if (n[f] > max) print n[f] - max > (out "/" f ".more")
}'

section() { # <file> <title>
  [ -s "$tmp/$1" ] || return 0
  echo "-- $2"
  cat "$tmp/$1"
  [ -s "$tmp/$1.more" ] && echo "   … $(cat "$tmp/$1.more") more line(s) in the log"
  return 0
}

summary=$(cat "$tmp/summary")
echo "quiet: rc=$rc elapsed=$elapsed lines=$(wc -l < "$log")${summary:+ | ${summary% }}"
if [ "$rc" = 0 ]; then
  section warn "first warnings"
else
  shown=0
  for s in cerr:"compiler errors" tfail:"failed tests" panic:"panics"; do
    [ -s "$tmp/${s%%:*}" ] && shown=1
    section "${s%%:*}" "${s#*:}"
  done
  # Nothing specific recognised: fall back to the generic grep.
  if [ "$shown" = 0 ]; then
    section gen "lines matching FAIL|ERROR|error|panicked"
    echo "-- last $tailn lines"
    tail -n "$tailn" "$log"
  fi
fi
echo "quiet: log $log"
exit "$rc"
