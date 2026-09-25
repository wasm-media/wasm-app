#!/usr/bin/env bash
# فحص 1.2 + التزامن على النقل (B3): يفشل برمز خروج غير صفري إن لم تتحقق كل الشروط.
# يحتاج اتصالات متوازية حقيقية، فيُشغَّل على Postgres محلي (ثم في CI). DB = قاعدة فيها shim + الترحيلات.
set -uo pipefail
DB=${1:?db}
OUT=$(mktemp -d); chmod 777 "$OUT"
P1=11111111-1111-1111-1111-111111111111; P2=22222222-2222-2222-2222-222222222222
fail() { echo "FAIL: $*"; exit 1; }
psql -q -v ON_ERROR_STOP=1 -d "$DB" <<SQL || fail "fixtures"
insert into auth.users(id,email,aud,role) values ('$P1','p1@wasm.test','authenticated','authenticated'),('$P2','p2@wasm.test','authenticated','authenticated');
insert into public.user_roles values ('$P1','partner'),('$P2','partner');
SQL
as_partner() { printf "begin; set local role authenticated; select set_config('request.jwt.claims','{\"sub\":\"%s\",\"role\":\"authenticated\"}',true); %s commit;" "$1" "$2"; }

# (أ) 20 فتحًا متزامنًا من شريكين ← 20 رقمًا متتاليًا 9001..9020 بلا تكرار، والعدّاد 9020
for k in $(seq 1 20); do
  uid=$P1; [ $((k % 2)) -eq 0 ] && uid=$P2
  psql -qtA -d "$DB" -c "$(as_partner $uid "select pg_sleep(0.2); select public.create_job('عميل $k','شغلة $k','design');")" > "$OUT/cc_$k.out" 2>&1 &
done
wait
R=$(psql -qtA -d "$DB" -c "select count(*)||'|'||count(distinct job_number)||'|'||min(job_number)||'|'||max(job_number)||'|'||(select last_number from public.job_counter) from public.jobs")
echo "opens: $R"
[ "$R" = "20|20|9001|9020|9020" ] || fail "opens expected 20|20|9001|9020|9020 got $R"

# (ب) 10 نقلات متزامنة متطابقة للشغلة 9001 من «استقبال» ← نجاح واحد، 9 stale_stage، وسطر سجل واحد
# حتمي: الأول ينقل ويُبقي معاملته مفتوحة ثانية كاملة؛ التسعة يبدؤون وهو ما زال مفتوحًا.
# مع القفل: ينتظرون ثم يرون «عرض سعر» ← stale_stage. بدون القفل: يمرّون من فحص المرحلة ويعيدون «نجاح» كاذبًا.
psql -qtA -d "$DB" -c "$(as_partner $P1 "select public.move_job(9001,'intake','quote'); select pg_sleep(1);")" > "$OUT/mv_1.out" 2>&1 &
sleep 0.3
for k in $(seq 2 10); do
  uid=$P1; [ $((k % 2)) -eq 0 ] && uid=$P2
  psql -qtA -d "$DB" -c "$(as_partner $uid "select public.move_job(9001,'intake','quote');")" > "$OUT/mv_$k.out" 2>&1 &
done
wait
OK=$(grep -lx 'quote' "$OUT"/mv_*.out | wc -l); STALE=$(grep -l 'stale_stage' "$OUT"/mv_*.out | wc -l)
L=$(psql -qtA -d "$DB" -c "select stage||'|'||(select count(*) from public.job_stage_log where job_number=9001) from public.jobs where job_number=9001")
echo "moves: ok=$OK stale=$STALE state=$L"
[ "$OK" = "1" ] && [ "$STALE" = "9" ] && [ "$L" = "quote|1" ] || fail "moves expected ok=1 stale=9 quote|1"

# (ج) نقل وإلغاء متزامنان للشغلة 9002 ← واحد فقط ينجح، وسطر سجل واحد
psql -qtA -d "$DB" -c "$(as_partner $P1 "select public.move_job(9002,'intake','quote'); select pg_sleep(1);")" > "$OUT/x1.out" 2>&1 &
sleep 0.3
psql -qtA -d "$DB" -c "$(as_partner $P2 "select public.cancel_job(9002,'intake','سبب');")" > "$OUT/x2.out" 2>&1 &
wait
N=$(grep -lxE 'quote|cancelled' "$OUT"/x1.out "$OUT"/x2.out | wc -l)
L2=$(psql -qtA -d "$DB" -c "select count(*) from public.job_stage_log where job_number=9002")
echo "move-vs-cancel: winners=$N log=$L2"
[ "$N" = "1" ] && [ "$L2" = "1" ] || fail "move-vs-cancel expected 1 winner and 1 log line"
echo "PASS concurrency (3 checks)"
