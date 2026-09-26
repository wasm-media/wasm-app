#!/usr/bin/env bash
# يشغّل اختبار اللوحة على عرضين، كل عرض على قاعدة جديدة: shim + كل الترحيلات + هويات الاختبار.
# يحتاج: PostgreSQL محلي، PostgREST (PGRST_BIN)، Node، Playwright + Chromium. يخرج 1 عند أي فشل.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); CODE=$(cd "$HERE/../.." && pwd)
PGRST_BIN=${PGRST_BIN:-/tmp/pgrst/postgrest}
SHOTS=${SHOTS:-}
DB=wasm_ui; SECRET='local-ui-test-secret-0123456789-abcdefghij'
export JWT_SECRET=$SECRET WEB_ROOT="$CODE/web" PORT=8080 PGRST=http://127.0.0.1:3001
export TEST_USERS='{"partner1@wasm.test":{"id":"aaaaaaaa-0000-0000-0000-000000000001","password":"test-pass"},"partner2@wasm.test":{"id":"aaaaaaaa-0000-0000-0000-000000000002","password":"test-pass"},"employee@wasm.test":{"id":"aaaaaaaa-0000-0000-0000-000000000003","password":"test-pass"}}'
TMP=$(mktemp -d); chmod 755 "$TMP"
for f in "$CODE"/tests/sql/local_supabase_shim.sql "$CODE"/supabase/migrations/*.sql "$HERE"/ui_fixture.sql; do cp "$f" "$TMP/"; done
chmod 644 "$TMP"/*.sql
cat > "$TMP/pgrst.conf" <<CONF
db-uri = "postgres://authenticator:authpass@127.0.0.1:5432/$DB"
db-schemas = "public"
db-anon-role = "anon"
jwt-secret = "$SECRET"
server-port = 3001
server-host = "127.0.0.1"
CONF
# الإدارة: محليًا عبر مستخدم النظام postgres؛ وفي CI عبر عنوان اتصال (PGADMIN=postgresql://postgres:postgres@127.0.0.1:5432)
adm() { local db=$1; shift; if [ -n "${PGADMIN:-}" ]; then psql "$PGADMIN/$db" "$@"; else su postgres -c "psql -d $db $(printf '%q ' "$@")"; fi; }
RC=0
# كل عرض بلغة متصفح مختلفة: الجوال بالعربية الفلسطينية (أرقام هندية افتراضيًا)، والحاسوب بالإنجليزية الأمريكية (شهر قبل يوم)
for RUN in 390x844:ar-PS 1440x900:en-US; do
  VP=${RUN%%:*}; LANG_UI=${RUN##*:}
  adm postgres -qc "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
  FILES=(-f "$TMP/local_supabase_shim.sql"); for m in $(ls "$TMP"/2026*.sql | sort); do FILES+=(-f "$m"); done
  adm "$DB" -q -v ON_ERROR_STOP=1 "${FILES[@]}" -f "$TMP/ui_fixture.sql" >/dev/null 2>"$TMP/db.err" || { echo "FAIL db setup"; cat "$TMP/db.err"; exit 1; }
  "$PGRST_BIN" "$TMP/pgrst.conf" > "$TMP/pgrst.log" 2>&1 & PG=$!
  node "$HERE/server.mjs" > "$TMP/server.log" 2>&1 & SV=$!
  for i in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:3001/ && curl -s -o /dev/null http://127.0.0.1:8080/ && break; sleep 0.3; done
  VIEWPORT=$VP LANG_UI=$LANG_UI SHOTS=$SHOTS node "$HERE/board.spec.mjs" || RC=1
  kill $PG $SV 2>/dev/null; wait $PG $SV 2>/dev/null
done
[ $RC -eq 0 ] && echo "PASS ui (both viewports)" || echo "FAIL ui"
exit $RC
