#!/usr/bin/env bash
# CI — اختبار اللوحة بالمحاكي (Postgres 16 + PostgREST + محاكي الدخول بمفاتيح اختبار): عرضان بلغتين.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
min() { awk -v k="$1" '$1==k{print $2}' tests/COUNT; }
bash tests/ui/run_ui.sh | tee /tmp/mock.txt; rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || { echo "FAIL mock ui"; exit 1; }
[ "$(grep -c '^PASS \[' /tmp/mock.txt)" -eq 2 ] || { echo "FAIL expected 2 viewport passes"; exit 1; }
for n in $(grep -oE '^PASS \[[^]]+\] [0-9]+ checks' /tmp/mock.txt | awk '{print $(NF-1)}'); do
  [ "$n" -ge "$(min ui_mock)" ] || { echo "FAIL ui_mock count $n < $(min ui_mock)"; exit 1; }
done
echo "PASS mock"
