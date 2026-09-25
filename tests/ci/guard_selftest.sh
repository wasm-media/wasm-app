#!/usr/bin/env bash
# يثبت أن الحارس يستطيع الفشل: 20 طلب «فخ» يجب أن تُرفض، وطلب سليم واحد يجب أن يمرّ. يخرج 1 عند أي نتيجة غير متوقعة.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); G="$ROOT/.github/guard/guard.sh"
T=$(mktemp -d); cp -r "$ROOT/." "$T/r"; cd "$T/r" && rm -rf .git && git init -q -b main
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git add -A && git commit -qm base && BASE=$(git rev-parse HEAD)
bad=0
c() { git add -A; git commit -qm "$1"; }
report() { mkdir -p reviews; printf "reviewed: commit %s\n%s\n" "$1" "${2:-الحكم: معتمد}" > reviews/r.md; c report; }
run() { bash "$G" "$BASE" "$(git rev-parse HEAD)" >/dev/null 2>&1; rc=$?; got=$([ $rc -eq 0 ] && echo PASS || echo FAIL)
  if [ "$got" = "$2" ]; then echo "ok   $1 → $got"; else echo "BAD  $1 → $got (want $2)"; bad=1; fi; git checkout -q main; }
git checkout -qb t1; echo "# x" >> .github/workflows/guard.yml; c t1; report "$(git rev-parse HEAD)"; run "edit guard workflow" FAIL
git checkout -qb t2; printf "  guard:\n    runs-on: ubuntu-latest\n" >> .github/workflows/ci.yml; c t2; report "$(git rev-parse HEAD)"; run "add a job named guard" FAIL
git checkout -qb t3; git rm -q tests/sql/concurrency.sh; c t3; report "$(git rev-parse HEAD)"; run "delete a test file" FAIL
git checkout -qb t4; echo "await test.skip('x')" >> tests/ui/board.spec.mjs; c t4; report "$(git rev-parse HEAD)"; run "add a skip marker" FAIL
git checkout -qb t5; echo "sql 1" > tests/COUNT; c t5; report "$(git rev-parse HEAD)"; run "lower the test count" FAIL
git checkout -qb t6; echo "// c" >> web/app.js; c t6; report 0000000000000; run "report on another commit" FAIL
git checkout -qb t7; echo "// c" >> web/app.js; c t7; report "$(git rev-parse HEAD)"; echo "// later" >> web/app.js; c t7b; run "code after the report" FAIL
git checkout -qb t8; echo "const k='sb_secret_abc';" >> web/app.js; c t8; report "$(git rev-parse HEAD)"; run "secret added" FAIL
git checkout -qb t9; echo "// c" >> web/app.js; c t9; report "$(git rev-parse HEAD)" "الحكم: BLOCKED_FOR_CORRECTION"; run "blocked report" FAIL
git checkout -qb t10; echo "x" >> docs/INVARIANTS.md; c t10; report "$(git rev-parse HEAD)"; run "edit invariants" FAIL
git checkout -qb t11; echo "// c" >> web/app.js; c t11; report "$(git rev-parse HEAD)"; run "clean PR with approved report" PASS
# مراجعة الحزمة 1: اسم عربي (core.quotePath)، اقتباس عبارة الاعتماد داخل تقرير BLOCKED، مشغّل المحاكي
git checkout -qb t12; echo "- قاعدة: بلا مراجعة" >> "docs/00-بروتوكول-البناء-والمراجعة.md"; c t12; report "$(git rev-parse HEAD)"; run "edit the protocol (Arabic file name)" FAIL
git checkout -qb t13; echo "// c" >> web/app.js; c t13; report "$(git rev-parse HEAD)" "$(printf 'اقتباس: الحكم: معتمد\nالحكم: معتمد\nالحكم: BLOCKED_FOR_CORRECTION')"; run "blocked report that quotes the approval line" FAIL
git checkout -qb t14; printf 'echo "PASS [x] 45 checks"\nexit 0\n' > tests/ui/run_ui.sh; c t14; report "$(git rev-parse HEAD)"; run "replace the mock runner" FAIL
# مراجعة الحزمة 1 الجولة 2: النقل، والمحارف التي يقتبسها git حتى مع quotePath=false، وCODEOWNERS خارج .github/
git checkout -qb t15; git mv "docs/00-بروتوكول-البناء-والمراجعة.md" docs/protocol.md; echo "- قاعدة: بلا مراجعة" >> docs/protocol.md; c t15; report "$(git rev-parse HEAD)"; run "rename the protocol and edit it" FAIL
git checkout -qb t16; git mv docs/INVARIANTS.md docs/inv.md; c t16; report "$(git rev-parse HEAD)"; run "rename the invariants" FAIL
git checkout -qb t17; git mv .github/CODEOWNERS CODEOWNERS; echo "* @someone-else" >> CODEOWNERS; c t17; report "$(git rev-parse HEAD)"; run "move CODEOWNERS to the root" FAIL
git checkout -qb t18; printf 'on: push\n' > .github/workflows/de\"ploy.yml; c t18; report "$(git rev-parse HEAD)"; run "workflow with a quote in its name" FAIL
git checkout -qb t19; printf 'exit 0\n' > "tests/ci/a$(printf '\t')b.sh"; c t19; report "$(git rev-parse HEAD)"; run "tab in a guarded file name" FAIL
git checkout -qb t20; echo "x" > docs/CODEOWNERS; c t20; report "$(git rev-parse HEAD)"; run "add docs/CODEOWNERS" FAIL
git checkout -qb t21; git mv tests/sql/concurrency.sh tests/sql/conc2.sh; c t21; report "$(git rev-parse HEAD)"; run "rename a test file" FAIL
[ $bad -eq 0 ] && echo "PASS guard selftest (21)" || { echo "FAIL guard selftest"; exit 1; }
