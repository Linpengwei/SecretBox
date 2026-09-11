#!/usr/bin/env bash
# Generate the 200-scenario persona test set with claude / codex / opencode in parallel.
# Each CLI gets two persona batches; raw outputs land in raw/<persona>.json (stderr in .err).
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p raw

run() { # $1 tool, $2 persona
  local tool="$1" persona="$2"
  local prompt
  prompt="$(cat "prompts/${persona}.md")"
  echo "[start] ${tool} ${persona}"
  case "$tool" in
    claude)
      # default gateway model (ZHIPU/GLM-5.3) currently returns 400 from the relay;
      # deepseek-v4-flash-0731 is the working mapping in ~/.claude/settings.json
      claude -p "$prompt" --model deepseek-v4-flash-0731 >"raw/${persona}.json" 2>"raw/${persona}.err" ;;
    codex)
      codex exec --sandbox read-only "$prompt" < /dev/null >"raw/${persona}.json" 2>"raw/${persona}.err" ;;
    opencode)
      opencode run "$prompt" >"raw/${persona}.json" 2>"raw/${persona}.err" ;;
  esac
  local rc=$?
  echo "[done ] ${tool} ${persona} rc=${rc} bytes=$(wc -c <"raw/${persona}.json" | tr -d ' ')"
  return "$rc"
}

run claude   sre              & p1=$!
run claude   developer        & p2=$!
run codex    product_manager  & p3=$!
run codex    designer         & p4=$!
run opencode novice           & p5=$!
run opencode admin            & p6=$!

fail=0
for p in $p1 $p2 $p3 $p4 $p5 $p6; do
  wait "$p" || fail=1
done
echo "ALL_DONE fail=${fail}"
exit "$fail"
