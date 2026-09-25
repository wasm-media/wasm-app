#!/usr/bin/env bash
# الحارس (guard) — يعمل دائمًا بنسخة main (pull_request_target) ولا يشغّل أي كود من الـPR:
# ملفات الـPR تُقرأ كبيانات عبر git فقط. يخرج 1 عند أي خرق.
# الاستعمال: guard.sh <BASE_SHA> <HEAD_SHA>
set -uo pipefail
BASE=$1; HEAD=$2
fail=0; err() { echo "::error::$*"; fail=1; }
# المسارات تُقرأ خامًا مفصولة بـNUL (-z): لا اقتباس لأي محرف (عربي، ", \, tab)، وبلا كشف إعادة التسمية
# (--no-renames): الملف المحمي المنقول يظهر حذفًا لمساره القديم فيُمسك. (مراجعة الحزمة 1: ج1 المانع 1، ج2 المانع)
g() { git -c core.quotePath=false "$@"; }
paths() { g diff --no-renames -z --name-only "$BASE...$HEAD" "$@"; }
mapfile -d '' -t CH < <(paths) || true
paths >/dev/null || { echo "::error::cannot diff"; exit 1; }
echo "== changed files =="; for f in "${CH[@]}"; do printf '%q\n' "$f"; done

# 1) ملفات الحراسة: لا يمسّها أي PR (عيسى يعدّلها بنفسه على main) — إضافة أو تعديل أو حذف أو نقل
# tests/ui/run_ui.sh = مشغّل المحاكي الذي يعدّ فحوصه run_mock.sh (0أ بند 2.6: إعدادات مشغّل الاختبارات)
# CODEOWNERS: GitHub يقرؤه من .github/ أو الجذر أو docs/ — الثلاثة محمية
PROTECTED='^(\.github/|tests/ci/|tests/COUNT$|tests/ui/run_ui\.sh$|docs/00-|docs/INVARIANTS\.md$|CODEOWNERS$|docs/CODEOWNERS$)'
hit=(); for f in "${CH[@]}"; do [[ "$f" =~ $PROTECTED ]] && hit+=("$(printf '%q' "$f")"); done
[ ${#hit[@]} -gt 0 ] && err "guard files touched: ${hit[*]}"

# 2) لا حذف لملف اختبار (والنقل حذف هنا)، ولا علامة تخطٍّ أو حصر
mapfile -d '' -t DEL < <(paths --diff-filter=D -- tests/) || true
[ ${#DEL[@]} -gt 0 ] && err "test files deleted: $(printf '%q ' "${DEL[@]}")"
skip=$(g diff --no-renames "$BASE...$HEAD" -- tests/ | grep -E '^\+' | grep -E '\.skip\(|\.only\(|describe\.skip|--\s*SKIP|process\.exit\(0\)' || true)
[ -n "$skip" ] && err "skip/only/exit(0) added in tests: $skip"

# 3) تقرير المراجع المستقل «معتمد» على آخر commit يغيّر كودًا (أي شيء خارج reviews/)
LAST=$(g log --format=%H "$BASE..$HEAD" -- . ':(exclude)reviews' | head -1)
if [ -n "$LAST" ]; then
  okrep=0
  # الحكم = آخر سطر غير فارغ حرفيًا، لا أي اقتباس للعبارة داخل تقرير BLOCKED (مراجعة الحزمة 1، BACKLOG 6)
  for f in "${CH[@]}"; do
    [[ "$f" == reviews/* ]] || continue
    body=$(g show "$HEAD:$f" 2>/dev/null) || continue
    first=$(printf '%s\n' "$body" | head -1); last=$(printf '%s\n' "$body" | grep -v '^[[:space:]]*$' | tail -1)
    if echo "$first" | grep -qE "^reviewed: (commit )?${LAST:0:12}" && [ "$last" = 'الحكم: معتمد' ]; then okrep=1; fi
  done
  [ "$okrep" -eq 1 ] || err "no «الحكم: معتمد» review report for last code commit ${LAST:0:12}"
fi

# 4) لا أسرار في الإضافات
sec=$(g diff "$BASE...$HEAD" | grep -E '^\+' | grep -P 'sb_secret_|service_role_key\s*[:=]|-----BEGIN [A-Z ]*PRIVATE KEY-----|postgres(ql)?://[^:/@\s]+:[^@\s]+@(?!127\.0\.0\.1|localhost)' || true)
[ -n "$sec" ] && err "possible secret added"

[ "$fail" -eq 0 ] && echo "guard: PASS" || echo "guard: FAIL"
exit $fail
