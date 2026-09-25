#!/usr/bin/env bash
# الحارس (guard) — يعمل دائمًا بنسخة main (pull_request_target) ولا يشغّل أي كود من الـPR:
# ملفات الـPR تُقرأ كبيانات عبر git فقط. يخرج 1 عند أي خرق.
# الاستعمال: guard.sh <BASE_SHA> <HEAD_SHA>
set -uo pipefail
BASE=$1; HEAD=$2
fail=0; err() { echo "::error::$*"; fail=1; }
# الأسماء العربية حرفيًا: بلا core.quotePath=false يقتبسها git ("docs/00-\330…") فلا يطابقها أي نمط (مراجعة الحزمة 1، المانع 1)
g() { git -c core.quotePath=false "$@"; }
CHANGED=$(g diff --name-only "$BASE...$HEAD") || { echo "::error::cannot diff"; exit 1; }
echo "== changed files =="; echo "$CHANGED"

# 1) ملفات الحراسة: لا يمسّها أي PR (عيسى يعدّلها بنفسه على main)
# tests/ui/run_ui.sh = مشغّل المحاكي الذي يعدّ فحوصه run_mock.sh (0أ بند 2.6: إعدادات مشغّل الاختبارات)
PROTECTED='^(\.github/|tests/ci/|tests/COUNT$|tests/ui/run_ui\.sh$|docs/00-|docs/INVARIANTS\.md$)'
hit=$(echo "$CHANGED" | grep -E "$PROTECTED" || true)
[ -n "$hit" ] && err "guard files touched: $(echo $hit)"

# 2) لا حذف لملف اختبار، ولا علامة تخطٍّ أو حصر
del=$(g diff --diff-filter=D --name-only "$BASE...$HEAD" -- tests/ || true)
[ -n "$del" ] && err "test files deleted: $(echo $del)"
skip=$(g diff "$BASE...$HEAD" -- tests/ | grep -E '^\+' | grep -E '\.skip\(|\.only\(|describe\.skip|--\s*SKIP|process\.exit\(0\)' || true)
[ -n "$skip" ] && err "skip/only/exit(0) added in tests: $skip"

# 3) تقرير المراجع المستقل «معتمد» على آخر commit يغيّر كودًا (أي شيء خارج reviews/)
LAST=$(g log --format=%H "$BASE..$HEAD" -- . ':(exclude)reviews' | head -1)
if [ -n "$LAST" ]; then
  okrep=0
  # الحكم = آخر سطر غير فارغ حرفيًا، لا أي اقتباس للعبارة داخل تقرير BLOCKED (مراجعة الحزمة 1، BACKLOG 6)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    body=$(g show "$HEAD:$f" 2>/dev/null) || continue
    first=$(printf '%s\n' "$body" | head -1); last=$(printf '%s\n' "$body" | grep -v '^[[:space:]]*$' | tail -1)
    if echo "$first" | grep -qE "^reviewed: (commit )?${LAST:0:12}" && [ "$last" = 'الحكم: معتمد' ]; then okrep=1; fi
  done <<< "$(echo "$CHANGED" | grep '^reviews/' || true)"
  [ "$okrep" -eq 1 ] || err "no «الحكم: معتمد» review report for last code commit ${LAST:0:12}"
fi

# 4) لا أسرار في الإضافات
sec=$(g diff "$BASE...$HEAD" | grep -E '^\+' | grep -P 'sb_secret_|service_role_key\s*[:=]|-----BEGIN [A-Z ]*PRIVATE KEY-----|postgres(ql)?://[^:/@\s]+:[^@\s]+@(?!127\.0\.0\.1|localhost)' || true)
[ -n "$sec" ] && err "possible secret added"

[ "$fail" -eq 0 ] && echo "guard: PASS" || echo "guard: FAIL"
exit $fail
