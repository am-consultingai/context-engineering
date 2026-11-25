#!/usr/bin/env bash
# Reveal which blind plan (A/B) came from which condition, then print the metrics summary.
# Run this only AFTER the blind scores are written (runs/<run>/blind-scores.md).
# Usage: ./unblind.sh [run-dir]     (default: runs/latest)
source "$(dirname "$0")/lib/common.sh"
RUN="${1:-$RUNS/latest}"; RUN="$(cd "$RUN" && pwd -P)"
[ -f "$RUN/meta.json" ] || die "not a run folder: $RUN"
[ -s "$RUN/blind-scores.md" ] || warn "no blind-scores.md in this run yet — you are unblinding before scoring."
echo "=========================== UNBLINDED ==========================="
py unblind "$RUN"
echo "================================================================="
cat "$RUN/summary.md"
