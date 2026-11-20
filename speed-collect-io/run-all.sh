#!/usr/bin/env bash
# Run every part in order, one log per part in logs/. With all 4 engines this took ~3 h here.
# BENCH_ENGINES / BENCH_DIR / connection variables: see R/connect.R.
set -u
cd "$(dirname "$0")" || exit 1
mkdir -p logs
for f in 0[0-7]-*.R; do
  echo "== $f $(date +%T)"
  Rscript "$f" > "logs/${f%.R}.log" 2>&1 || echo "FAILED: $f (see logs/${f%.R}.log)"
done
Rscript build-report.R
