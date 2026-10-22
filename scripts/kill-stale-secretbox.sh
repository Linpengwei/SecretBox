#!/bin/bash
# Reap SecretBox instances left frozen by an abandoned Xcode debug session.
#
# A debug session that is never stopped (⌘.) leaves the app process traced by
# debugserver (or SIGSTOPped): invisible, but still registered with
# LaunchServices, so opening SecretBox merely "activates" the frozen process
# and the app appears unable to start. This script kills exactly those
# processes — running instances are never touched.
#
# Usage: scripts/kill-stale-secretbox.sh [min_age_seconds]
#   min_age_seconds  only reap instances older than this (default 0 = any age).
#   For automatic background protection, run this periodically from a
#   LaunchAgent with a large min age (e.g. 86400) so a breakpoint paused
#   earlier today is never reaped.
set -euo pipefail

min_age="${1:-0}"
reaped=0

while read -r pid stat age; do
  if [ "$age" -lt "$min_age" ] 2>/dev/null; then
    echo "skip pid $pid (frozen, but only ${age}s old < ${min_age}s)" >&2
    continue
  fi
  echo "killing frozen SecretBox instance pid $pid (stat=$stat, age=${age}s)"
  kill -9 "$pid"
  reaped=$((reaped + 1))
done < <(ps axo pid=,stat=,etime=,command= | awk -v min_age="$min_age" '
  /SecretBox\.app\/Contents\/MacOS\/SecretBox( |$)/ && !/awk/ && ($2 ~ /[TX]/) {
    e = $3; d = 0
    if (e ~ /-/) { split(e, p, "-"); d = p[1] + 0; e = p[2] }
    n = split(e, h, ":"); sec = d * 86400
    if (n == 3) sec += h[1] * 3600 + h[2] * 60 + h[3]
    else if (n == 2) sec += h[1] * 60 + h[2]
    else sec += h[1] + 0
    if (sec >= min_age) print $1, $2, sec
  }')

if [ "$reaped" -eq 0 ]; then
  echo "no frozen SecretBox instances found"
else
  echo "reaped $reaped instance(s) — you can open SecretBox again"
fi
