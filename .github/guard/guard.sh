#!/usr/bin/env bash
# الحارس (guard) — يعمل دائمًا بنسخة main (pull_request_target) ولا يشغّل أي كود من الـPR:
# ملفات الـPR تُقرأ كبيانات عبر git فقط. يخرج 1 عند أي خرق.
# الاستعمال: guard.sh <BASE_SHA> <HEAD_SHA>
set -uo pipefail
BASE=$1; HEAD=$2
fail=0; err() { echo "::error::$*"; fail=1; }
CHANGED=$(git diff --name-only "$BASE...$HEAD") || { echo "::error::cannot diff"; exit 1; }
echo "== changed files =="; echo "$CHANGED"

# 1) ملفات الحراسة: لا يمسّها أي PR (عيسى يعدّلها بنفسه على main)
PROTECTED='^(\.github/|tests/ci/|tests/COUNT$|docs/00-|docs/INVARIANTS\.md$)'
hit=$(echo "$CHANGED" | grep -E "$PROTECTED" || true)
[ -n "$hit" ] && err "guard files touched: $(echo $hit)"

# 2) لا حذف لملف اختبار، ولا علامة تخطٍّ أو حصر
del=$(git diff --diff-filter=D --name-only "$BASE...$HEAD" -- tests/ || true)
[ -n "$del" ] && err "test files deleted: $(echo $del)"
skip=$(git diff "$BASE...$HEAD" -- tests/ | grep -E '^\+' | grep -E '\.skip\(|\.only\(|describe\.skip|--\s*SKIP|process\.exit\(0\)' || true)
[ -n "$skip" ] && err "skip/only/exit(0) added in tests: $skip"

# 3) تقرير المراجع المستقل «معتمد» على آخر commit يغيّر كودًا (أي شيء خارج reviews/)
LAST=$(git log --format=%H "$BASE..$HEAD" -- . ':(exclude)reviews' | head -1)
if [ -n "$LAST" ]; then
  okrep=0
  for f in $(echo "$CHANGED" | grep '^reviews/' || true); do
    body=$(git show "$HEAD:$f" 2>/dev/null) || continue
    if echo "$body" | grep -qE "reviewed: .*${LAST:0:12}" && echo "$body" | grep -q 'الحكم: معتمد'; then okrep=1; fi
  done
  [ "$okrep" -eq 1 ] || err "no «الحكم: معتمد» review report for last code commit ${LAST:0:12}"
fi

# 4) لا أسرار في الإضافات
sec=$(git diff "$BASE...$HEAD" | grep -E '^\+' | grep -P 'sb_secret_|service_role_key\s*[:=]|-----BEGIN [A-Z ]*PRIVATE KEY-----|postgres(ql)?://[^:/@\s]+:[^@\s]+@(?!127\.0\.0\.1|localhost)' || true)
[ -n "$sec" ] && err "possible secret added"

[ "$fail" -eq 0 ] && echo "guard: PASS" || echo "guard: FAIL"
exit $fail
