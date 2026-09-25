#!/usr/bin/env bash
# CI — على Supabase حقيقي من `supabase start` (نفس Postgres وPostgREST وAuth المستعملة في الإنتاج):
# اختبارات SQL، ثم التزامن، ثم اللوحة بوضع REAL على عرضين (دخول وخروج حقيقيان، والتسجيل الذاتي مرفوض).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
fail() { echo "FAIL: $*"; exit 1; }
min() { awk -v k="$1" '$1==k{print $2}' tests/COUNT; }
eval "$(supabase status -o env | grep -E '^[A-Z_]+=' | sed 's/^/export /')"
for v in API_URL DB_URL ANON_KEY SERVICE_ROLE_KEY; do [ -n "${!v:-}" ] || fail "supabase status missing $v"; done

# 1) SQL — الملف ينتهي باستثناء متعمَّد يحمل «N total, M ok»
OUT=$(psql "$DB_URL" -f tests/sql/slice1a_test.sql 2>&1 | grep -oE 'WASM_TEST_RESULTS [0-9]+ total, [0-9]+ ok, FAILED: [^#]*' | head -1)
echo "sql: $OUT"
T=$(echo "$OUT" | sed -E 's/WASM_TEST_RESULTS ([0-9]+) total.*/\1/'); K=$(echo "$OUT" | sed -E 's/.* ([0-9]+) ok,.*/\1/')
[ -n "$T" ] && [ "$T" = "$K" ] && [ "$T" -ge "$(min sql)" ] || fail "sql tests ($OUT)"

# 2) التزامن (اتصالات متوازية حقيقية)
bash tests/sql/concurrency.sh "$DB_URL" || fail "concurrency"

# 3) اللوحة على Supabase حقيقي
for RUN in 390x844:ar-PS 1440x900:en-US; do
  supabase db reset >/dev/null 2>&1 || fail "db reset"
  for u in partner1 partner2 employee; do
    code=$(curl -s -o /tmp/u.json -w '%{http_code}' -X POST "$API_URL/auth/v1/admin/users" \
      -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'content-type: application/json' \
      -d "{\"email\":\"$u@wasm.test\",\"password\":\"test-pass\",\"email_confirm\":true}")
    [ "$code" = 200 ] || fail "create user $u ($code: $(cat /tmp/u.json))"
  done
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<'SQL' || fail "seed roles/names"
insert into public.user_roles(user_id, role)
  select id, case email when 'employee@wasm.test' then 'employee'::public.app_role else 'partner'::public.app_role end
  from auth.users where email like '%@wasm.test';
insert into public.people(user_id, display_name)
  select id, case email when 'partner1@wasm.test' then 'الشريك الأول' when 'partner2@wasm.test' then 'الشريك الثاني' else 'موظف' end
  from auth.users where email like '%@wasm.test';
SQL
  REAL=1 CONFIG_URL="$API_URL" CONFIG_ANON="$ANON_KEY" WEB_ROOT="$ROOT/web" PORT=8080 node tests/ui/server.mjs > /tmp/srv.log 2>&1 & SV=$!
  for i in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8080/ && break; sleep 0.3; done
  VP=${RUN%%:*}; LANG_UI=${RUN##*:}
  REAL=1 AUTH_URL="$API_URL" ANON_KEY="$ANON_KEY" VIEWPORT=$VP LANG_UI=$LANG_UI SHOTS=${SHOTS:-} node tests/ui/board.spec.mjs | tee /tmp/ui.txt; rc=${PIPESTATUS[0]}
  kill $SV 2>/dev/null
  [ "$rc" -eq 0 ] || fail "ui real $RUN"
  n=$(grep -c '^ok' /tmp/ui.txt); [ "$n" -ge "$(min ui_real)" ] || fail "ui_real count $n < $(min ui_real)"
done
echo "PASS real"
