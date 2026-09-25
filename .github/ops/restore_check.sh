#!/usr/bin/env bash
# الاستعادة التجريبية (P7، P13، D25): تحمّل نسخة البيانات في قاعدة Supabase مؤقتة داخل الـrunner
# (مكدّس `supabase start` بالترحيلات نفسها)، ثم تطابق عدد الصفوف جدولًا جدولًا مع ما في النسخة.
# لا يُطبع أي صف من البيانات. QUIET=1 (سجل الإنتاج العام): stdout = أسماء الجداول وحكمها بلا أعداد،
# والأعداد تذهب إلى stderr ليُشفَّر تقريرها مع النسخة. يخرج 1 عند أي اختلاف.
# الاستعمال: [QUIET=1] restore_check.sh <data.sql> <DB_URL>
set -uo pipefail
DUMP=$1; DB=$2
detail() { if [ "${QUIET:-0}" = 1 ]; then echo "$*" >&2; else echo "$*"; fi; }
# 1) الأعداد المتوقعة من النسخة نفسها: أسطر كل كتلة COPY حتى «\.»
awk '/^COPY "[^"]+"\."[^"]+" /{match($0,/"[^"]+"\."[^"]+"/); t=substr($0,RSTART,RLENGTH); gsub(/"/,"",t); n=0; inb=1; next}
     inb && $0=="\\."{print t, n; inb=0; next} inb{n++}' "$DUMP" > /tmp/expected.txt
N=$(wc -l < /tmp/expected.txt)
for must in auth.users public.jobs public.job_stage_log public.user_roles public.people public.job_counter; do
  grep -q "^$must " /tmp/expected.txt || { echo "FAIL: table $must missing from the dump"; exit 1; }
done
[ "$N" -ge 8 ] || { echo "FAIL: only $N tables in the dump"; exit 1; }
# 2) تفريغ الجداول الموجودة في النسخة (الترحيلات تزرع بعضها، مثل job_counter) ثم التحميل — بوضع replica فلا تعمل الـtriggers
TABLES=$(awk '{split($1,a,"."); printf "%s\"%s\".\"%s\"", (NR>1?", ":""), a[1], a[2]}' /tmp/expected.txt)
psql "$DB" -v ON_ERROR_STOP=1 -q -c "set session_replication_role = replica; truncate $TABLES cascade;" > /tmp/restore.log 2>&1 \
  || { echo "FAIL: truncate before restore"; tail -5 /tmp/restore.log; exit 1; }
psql "$DB" -v ON_ERROR_STOP=1 -q -f "$DUMP" >> /tmp/restore.log 2>&1 || { echo "FAIL: restore"; grep -E 'ERROR' /tmp/restore.log | sed 's/DETAIL.*//' | cut -c1-160 | head -5; exit 1; }
# 3) المطابقة
bad=0
while read -r t n; do
  a=$(psql "$DB" -Atc "select count(*) from \"${t%%.*}\".\"${t#*.}\"") || { echo "FAIL: count $t"; exit 1; }
  if [ "$a" = "$n" ]; then
    detail "ok   $t $n"; [ "${QUIET:-0}" = 1 ] && echo "ok   $t"
  else
    detail "BAD  $t expected=$n restored=$a"; [ "${QUIET:-0}" = 1 ] && echo "BAD  $t (counts differ)"; bad=1
  fi
done < /tmp/expected.txt
detail "rows total: $(awk '{s+=$2} END{print s}' /tmp/expected.txt)"
[ $bad -eq 0 ] && echo "PASS restore ($N tables)" || { echo "FAIL restore"; exit 1; }
