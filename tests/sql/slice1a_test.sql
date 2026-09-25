-- اختبارات الشريحة 1أ — الشغلة ومراحلها (السيرفر)
-- تُشغَّل بمستخدم postgres على مشروع التطوير (أو محليًا فوق local_supabase_shim.sql).
-- كل شيء داخل كتلة واحدة تنتهي باستثناء متعمَّد يحمل النتائج ← لا يبقى أي أثر على القاعدة (لا مستخدمين ولا شغلات ولا عدّاد).
-- الهويات حقيقية في auth.users بإيميلات وهمية (بلا إرسال)، والتنفيذ يتقمّصها كما يفعل PostgREST:
--   SET ROLE authenticated/anon + request.jwt.claims. لا service_role في أي فحص سلوك.
-- كل هوية تحمل في JWT هجومًا ثابتًا: user_metadata.role = partner و app_metadata.role = partner — يجب أن يُتجاهلا.
-- الحكم: كل صف ok=true. أي false = فشل.

create temp table if not exists t_results(n serial, id text, ok boolean, detail text);
truncate t_results;

-- ينفّذ q بهوية who ويسجّل: want='ok' ينجح · غير ذلك = رمز SQLSTATE أو نص رسالة الخطأ المتوقع بالضبط
create or replace function pg_temp.chk(tid text, who text, uid uuid, q text, want text) returns void
language plpgsql as $f$
declare st text; msg text; good boolean; det text;
begin
  begin
    if who = 'anon' then
      set local role anon;
      perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    elsif who <> 'admin' then
      set local role authenticated;
      perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated',
        'user_metadata', json_build_object('role','partner'), 'app_metadata', json_build_object('role','partner'))::text, true);
    end if;
    execute q;
    reset role; perform set_config('request.jwt.claims', '', true);
    good := (want = 'ok'); det := 'succeeded';
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    good := (want <> 'ok' and (st = want or msg = want)); det := st || ': ' || msg;
  end;
  reset role; perform set_config('request.jwt.claims', '', true);
  insert into t_results(id, ok, detail) values (tid, good, left(det, 200));
end $f$;

-- يعيد نتيجة استعلام نصي واحد بهوية who (الأخطاء تمرّ للأعلى)
create or replace function pg_temp.val(who text, uid uuid, q text) returns text
language plpgsql as $f$
declare v text;
begin
  if who = 'anon' then
    set local role anon; perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  elsif who <> 'admin' then
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated',
      'user_metadata', json_build_object('role','partner'), 'app_metadata', json_build_object('role','partner'))::text, true);
  end if;
  execute q into v;
  reset role; perform set_config('request.jwt.claims', '', true);
  return v;
exception when others then
  reset role; perform set_config('request.jwt.claims', '', true);
  raise;
end $f$;

-- قراءة بهوية: تنجح إن كان عدد الصفوف 0 (أو رُفضت القراءة 42501)، مع شرط أن الشريك يقرأ ≥1 من الجدول نفسه
create or replace function pg_temp.read0(tid text, who text, uid uuid, tbl text, partner uuid) returns void
language plpgsql as $f$
declare c text; pc text; good boolean; det text; st text; msg text;
begin
  begin
    pc := pg_temp.val('partner', partner, format('select count(*) from %s', tbl));
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text; pc := 'ERR ' || st || ': ' || msg;
  end;
  begin
    c := pg_temp.val(who, uid, format('select count(*) from %s', tbl));
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text; c := 'ERR ' || st || ': ' || msg;
  end;
  good := (c = '0' or c like 'ERR 42501%') and pc ~ '^[0-9]+$' and pc::int >= 1;
  det := who || '=' || c || ' · partner=' || pc;
  insert into t_results(id, ok, detail) values (tid, good, left(det, 200));
end $f$;

create or replace function pg_temp.rec(tid text, good boolean, det text) returns void language sql as
$f$ insert into t_results(id, ok, detail) values (tid, coalesce(good,false), left(coalesce(det,'null'), 200)) $f$;

do $t$
declare
  p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid();
  emp uuid := gen_random_uuid(); nr uuid := gen_random_uuid();
  base int; a int; b int; c int; d int; x int; n int; txt text; st text; msg text;
  stages text[] := array['intake','quote','client_approval','design','review','execution','delivered'];
  i int; ok_moves int := 0; log_before int; log_after int;
  slice_tables text[] := array['public.jobs','public.job_notes','public.job_stage_log','public.user_roles','public.job_counter','public.people'];
  slice_funcs text[] := array['public.create_job','public.move_job','public.cancel_job','public.is_partner'];
  slice_funcs_names text[] := array['create_job','move_job','cancel_job','is_partner'];
  blanks text[] := array[E'\t', E'\n', E'\r\n', U&'\00A0', U&'\200B', U&'\200F', U&'\061C', U&'\3000', U&'\FEFF', U&'\00A0\200F '];
  missing text;
begin
  -- ===== التجهيز (أدمن): 4 هويات حقيقية؛ الأدوار تُزرع كما يزرعها الترحيل =====
  begin
    insert into auth.users(id, email, aud, role) values
      (p1, 'partner1@wasm.test', 'authenticated', 'authenticated'),
      (p2, 'partner2@wasm.test', 'authenticated', 'authenticated'),
      (emp, 'employee@wasm.test', 'authenticated', 'authenticated'),
      (nr, 'norole@wasm.test', 'authenticated', 'authenticated');
    execute format('insert into public.user_roles(user_id, role) values (%L,''partner''),(%L,''partner''),(%L,''employee'')', p1, p2, emp);
    perform pg_temp.rec('setup', true, 'fixtures');
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('setup', false, st || ': ' || msg);
  end;
  begin -- أسماء العرض تُزرع بالترحيل مثل الأدوار (B4)
    execute format('insert into public.people(user_id, display_name) values (%L,''الشريك الأول''),(%L,''الشريك الثاني''),(%L,''موظف'')', p1, p2, emp);
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('setup names', false, st || ': ' || msg);
  end;

  -- ===== 1.1 الترقيم: 3 شغلات على قاعدة جديدة ← 9001، 9002، 9003 وكلها «استقبال» =====
  begin
    base := pg_temp.val('admin', null, 'select last_number from public.job_counter');
    a := pg_temp.val('partner', p1, $q$select public.create_job('عميل أ','شغلة أ','design', null, 'ملاحظة سرية 500 شيكل')$q$)::int;
    b := pg_temp.val('partner', p1, $q$select public.create_job('عميل ب','شغلة ب','print')$q$)::int;
    c := pg_temp.val('partner', p2, $q$select public.create_job('عميل ج','شغلة ج','video', '2026-10-01')$q$)::int;
    perform pg_temp.rec('1.1', base = 9000 and a = 9001 and b = 9002 and c = 9003
      and (select count(*) from public.jobs where job_number in (a,b,c) and stage::text = 'intake') = 3
      and (select created_by from public.jobs where job_number = c) = p2,
      format('base=%s got %s,%s,%s', base, a, b, c));
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('1.1', false, st || ': ' || msg);
  end;

  -- ===== 1.3 نقل من «استقبال» حتى «تسليم» ← 6 أسطر بالترتيب (الفتح ليس انتقالًا) =====
  begin
    log_before := (select count(*) from public.job_stage_log where job_number = a);
    for i in 1..6 loop
      perform pg_temp.val('partner', p1, format('select public.move_job(%s, %L, %L)', a, stages[i], stages[i+1]));
      ok_moves := ok_moves + 1;
    end loop;
    select string_agg(from_stage || '>' || to_stage, ',' order by id) into txt from public.job_stage_log where job_number = a;
    perform pg_temp.rec('1.3', log_before = 0
      and (select count(*) from public.job_stage_log where job_number = a) = 6
      and txt = 'intake>quote,quote>client_approval,client_approval>design,design>review,review>execution,execution>delivered'
      and (select bool_and(moved_by = p1 and moved_at is not null and moved_at <= clock_timestamp()) from public.job_stage_log where job_number = a)
      and (select stage::text from public.jobs where job_number = a) = 'delivered',
      txt);
    perform pg_temp.rec('1.3 mover name (partner reads)',
      pg_temp.val('partner', p2, format('select string_agg(distinct p.display_name, '','') from public.job_stage_log l join public.people p on p.user_id = l.moved_by where l.job_number = %s', a)) = 'الشريك الأول',
      'name via people');
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('1.3', false, st || ': ' || msg);
  end;

  -- ===== 1.4 الرجوع خطوة من كل مرحلة بين «عرض سعر» و«تنفيذ» + الإلغاء بسبب =====
  begin
    for i in 2..6 loop
      perform pg_temp.val('partner', p1, format('select public.move_job(%s, %L, %L)', b, stages[i-1], stages[i]));
      perform pg_temp.chk('1.4 back ' || stages[i], 'partner', p1,
        format('select public.move_job(%s, %L, %L)', b, stages[i], stages[i-1]), 'ok');
      perform pg_temp.val('partner', p1, format('select public.move_job(%s, %L, %L)', b, stages[i-1], stages[i]));
    end loop;
    -- b الآن في «تنفيذ»: إلغاء من مرحلة متأخرة · c في «استقبال»: إلغاء من أول مرحلة
    perform pg_temp.chk('1.4 cancel@execution', 'partner', p1, format($q$select public.cancel_job(%s, 'execution', 'العميل انسحب')$q$, b), 'ok');
    perform pg_temp.chk('1.4 cancel@intake', 'partner', p2, format($q$select public.cancel_job(%s, 'intake', 'مكرر')$q$, c), 'ok');
    perform pg_temp.rec('1.4 cancel log', (select count(*) from public.job_stage_log
        where job_number = b and to_stage::text = 'cancelled' and reason = 'العميل انسحب' and moved_by = p1) = 1
      and (select stage::text from public.jobs where job_number = c) = 'cancelled', 'reason logged');
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('1.4', false, st || ': ' || msg);
  end;

  -- شغلة d جديدة في «استقبال» لفحوص الرفض
  begin
    d := pg_temp.val('partner', p1, $q$select public.create_job('عميل د','شغلة د','event')$q$)::int;
  exception when others then d := -1; end;

  -- ===== 2.1 الرفض — لكل بند فحص إيجابي بالعملية نفسها للدور المسموح =====
  -- الفتح
  perform pg_temp.chk('R open +partner', 'partner', p2, $q$select public.create_job('ع','ش','other')$q$, 'ok');
  perform pg_temp.chk('R open -employee', 'employee', emp, $q$select public.create_job('ع','ش','other')$q$, 'not_partner');
  perform pg_temp.chk('R open -norole(metadata=partner)', 'norole', nr, $q$select public.create_job('ع','ش','other')$q$, 'not_partner');
  perform pg_temp.chk('R open -anon', 'anon', null, $q$select public.create_job('ع','ش','other')$q$, '42501');
  -- metadata في auth.users نفسه = partner لا يمنح شيئًا
  begin
    update auth.users set raw_user_meta_data = '{"role":"partner"}' where id = nr;
  exception when others then null; end;
  perform pg_temp.chk('R open -norole(db metadata=partner)', 'norole', nr, $q$select public.create_job('ع','ش','other')$q$, 'not_partner');
  -- النقل والإلغاء
  perform pg_temp.chk('R move -employee', 'employee', emp, format($q$select public.move_job(%s,'intake','quote')$q$, d), 'not_partner');
  perform pg_temp.chk('R move -norole', 'norole', nr, format($q$select public.move_job(%s,'intake','quote')$q$, d), 'not_partner');
  perform pg_temp.chk('R move -anon', 'anon', null, format($q$select public.move_job(%s,'intake','quote')$q$, d), '42501');
  perform pg_temp.chk('R cancel -employee', 'employee', emp, format($q$select public.cancel_job(%s,'intake','x')$q$, d), 'not_partner');
  perform pg_temp.chk('R cancel -norole', 'norole', nr, format($q$select public.cancel_job(%s,'intake','x')$q$, d), 'not_partner');
  perform pg_temp.chk('R cancel -anon', 'anon', null, format($q$select public.cancel_job(%s,'intake','x')$q$, d), '42501');
  -- منح الأدوار: لا أحد من التطبيق (والإيجابي: الأدمن/الترحيل يزرع)
  perform pg_temp.chk('R role +admin(migration)', 'admin', null, format($q$insert into public.user_roles(user_id, role) values (%L,'employee')$q$, nr), 'ok');
  perform pg_temp.chk('R role -admin undo', 'admin', null, format($q$delete from public.user_roles where user_id = %L$q$, nr), 'ok');
  perform pg_temp.chk('R role -norole self', 'norole', nr, format($q$insert into public.user_roles(user_id, role) values (%L,'partner')$q$, nr), '42501');
  perform pg_temp.chk('R role -employee self', 'employee', emp, format($q$update public.user_roles set role = 'partner' where user_id = %L$q$, emp), '42501');
  perform pg_temp.chk('R role -partner grant', 'partner', p1, format($q$insert into public.user_roles(user_id, role) values (%L,'partner')$q$, nr), '42501');
  perform pg_temp.chk('R role -partner revoke', 'partner', p1, format($q$delete from public.user_roles where user_id = %L$q$, p2), '42501');
  perform pg_temp.chk('R role -anon', 'anon', null, format($q$insert into public.user_roles(user_id, role) values (%L,'partner')$q$, nr), '42501');
  -- الشريك: رقم/مرحلة من عنده، تعديل بعد الفتح، حذف
  perform pg_temp.chk('R insert direct -partner', 'partner', p1, $q$insert into public.jobs(job_number, client, title, job_type, stage, created_by) values (9999,'ع','ش','other','design', auth.uid())$q$, '42501');
  perform pg_temp.chk('R set number -partner', 'partner', p1, $q$select public.create_job('ع','ش','other', null, null, 9500)$q$, '42883');
  update t_results set ok = ok and to_regprocedure('public.create_job(text,text,text,date,text)') is not null where id = 'R set number -partner';
  perform pg_temp.rec('R signatures fixed (no number/stage/who/when params)',
    to_regprocedure('public.create_job(text,text,text,date,text)') is not null
    and to_regprocedure('public.move_job(integer,text,text)') is not null
    and to_regprocedure('public.cancel_job(integer,text,text)') is not null
    and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('create_job','move_job','cancel_job')) = 3,
    'exactly one overload each');
  perform pg_temp.chk('R edit number -partner', 'partner', p1, format($q$update public.jobs set job_number = 9998 where job_number = %s$q$, d), '42501');
  perform pg_temp.chk('R edit client -partner', 'partner', p1, format($q$update public.jobs set client = 'آخر' where job_number = %s$q$, d), '42501');
  perform pg_temp.chk('R edit stage direct -partner', 'partner', p1, format($q$update public.jobs set stage = 'delivered' where job_number = %s$q$, d), '42501');
  perform pg_temp.chk('R edit notes -partner', 'partner', p1, format($q$update public.job_notes set body = 'x' where job_number = %s$q$, a), '42501');
  perform pg_temp.chk('R delete job -partner', 'partner', p1, format($q$delete from public.jobs where job_number = %s$q$, d), '42501');
  perform pg_temp.chk('R truncate -partner', 'partner', p1, 'truncate public.jobs cascade', '42501');
  -- القفز والتزامن والنهائية
  perform pg_temp.chk('R skip forward', 'partner', p1, format($q$select public.move_job(%s,'intake','client_approval')$q$, d), 'invalid_transition');
  perform pg_temp.chk('R back from intake', 'partner', p1, format($q$select public.move_job(%s,'intake','intake')$q$, d), 'invalid_transition');
  perform pg_temp.chk('R move +partner', 'partner', p1, format($q$select public.move_job(%s,'intake','quote')$q$, d), 'ok');
  perform pg_temp.chk('R stale second request', 'partner', p2, format($q$select public.move_job(%s,'intake','quote')$q$, d), 'stale_stage');
  begin
    for i in 3..4 loop
      perform pg_temp.val('partner', p1, format('select public.move_job(%s, %L, %L)', d, stages[i-1], stages[i]));
    end loop; -- d الآن «تصميم»
  exception when others then perform pg_temp.rec('setup d@design', false, sqlerrm);
  end;
  perform pg_temp.chk('R skip back', 'partner', p1, format($q$select public.move_job(%s,'design','quote')$q$, d), 'invalid_transition');
  perform pg_temp.chk('R skip forward 2', 'partner', p1, format($q$select public.move_job(%s,'design','execution')$q$, d), 'invalid_transition');
  perform pg_temp.chk('R move to cancelled via move', 'partner', p1, format($q$select public.move_job(%s,'design','cancelled')$q$, d), 'invalid_transition');
  perform pg_temp.chk('R bad stage value', 'partner', p1, format($q$select public.move_job(%s,'design','printing')$q$, d), 'invalid_stage');
  perform pg_temp.chk('R missing job', 'partner', p1, $q$select public.move_job(1,'intake','quote')$q$, 'job_not_found');
  perform pg_temp.chk('R from delivered', 'partner', p1, format($q$select public.move_job(%s,'delivered','execution')$q$, a), 'final_stage');
  perform pg_temp.chk('R cancel delivered', 'partner', p1, format($q$select public.cancel_job(%s,'delivered','x')$q$, a), 'final_stage');
  perform pg_temp.chk('R from cancelled', 'partner', p1, format($q$select public.move_job(%s,'cancelled','intake')$q$, c), 'final_stage');
  perform pg_temp.chk('R cancel cancelled', 'partner', p1, format($q$select public.cancel_job(%s,'cancelled','x')$q$, c), 'final_stage');
  perform pg_temp.chk('R cancel stale', 'partner', p1, format($q$select public.cancel_job(%s,'intake','x')$q$, d), 'stale_stage');
  perform pg_temp.chk('R cancel empty reason', 'partner', p1, format($q$select public.cancel_job(%s,'design','')$q$, d), 'reason_required');
  perform pg_temp.chk('R cancel blank reason', 'partner', p1, format($q$select public.cancel_job(%s,'design','   ')$q$, d), 'reason_required');
  perform pg_temp.chk('R cancel null reason', 'partner', p1, format($q$select public.cancel_job(%s,'design',null)$q$, d), 'reason_required');
  -- الحقول الإلزامية والنوع
  perform pg_temp.chk('R no client', 'partner', p1, $q$select public.create_job('  ','ش','other')$q$, 'client_required');
  perform pg_temp.chk('R null client', 'partner', p1, $q$select public.create_job(null,'ش','other')$q$, 'client_required');
  perform pg_temp.chk('R no title', 'partner', p1, $q$select public.create_job('ع','','other')$q$, 'title_required');
  perform pg_temp.chk('R bad type', 'partner', p1, $q$select public.create_job('ع','ش','banner')$q$, 'invalid_type');
  -- الترقيم: الفشل لا يستهلك رقمًا، لا تكرار، لا فجوة
  begin
    x := pg_temp.val('admin', null, 'select last_number from public.job_counter')::int;
    perform pg_temp.chk('R failed open (no number)', 'partner', p1, $q$select public.create_job('','ش','other')$q$, 'client_required');
    n := pg_temp.val('partner', p1, $q$select public.create_job('ع','ش','other')$q$)::int;
    perform pg_temp.rec('R numbers gapless', n = x + 1
      and (select count(*) = count(distinct job_number) and max(job_number) - min(job_number) + 1 = count(*) and min(job_number) = 9001 from public.jobs),
      format('before=%s next=%s', x, n));
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('R numbers gapless', false, st || ': ' || msg);
  end;
  -- السجل: لا كتابة مباشرة، لا تعديل، لا حذف، ولا «من/متى» من المتصفح
  perform pg_temp.chk('R log insert -partner', 'partner', p1, format($q$insert into public.job_stage_log(job_number, from_stage, to_stage, moved_by, moved_at) values (%s,'intake','quote',%L,'2020-01-01')$q$, d, p2), '42501');
  perform pg_temp.chk('R log update -partner', 'partner', p1, format($q$update public.job_stage_log set moved_by = %L where job_number = %s$q$, p2, a), '42501');
  perform pg_temp.chk('R log delete -partner', 'partner', p1, format($q$delete from public.job_stage_log where job_number = %s$q$, a), '42501');
  perform pg_temp.chk('R move who/when param', 'partner', p1, format($q$select public.move_job(%s,'design','review', %L, '2020-01-01'::timestamptz)$q$, d, p2), '42883');
  update t_results set ok = ok and to_regprocedure('public.move_job(integer,text,text)') is not null where id = 'R move who/when param';
  -- الحذف ممنوع حتى على الأدمن (I8)
  perform pg_temp.chk('R delete job -admin(I8)', 'admin', null, format($q$delete from public.jobs where job_number = %s$q$, d), 'no_delete');
  perform pg_temp.chk('R delete log -admin(I8)', 'admin', null, format($q$delete from public.job_stage_log where job_number = %s$q$, a), 'no_delete');
  perform pg_temp.chk('R truncate -admin(I8)', 'admin', null, 'truncate public.job_stage_log', 'no_delete');

  -- ===== 2.2 القراءات: صفر صفوف لغير الشريك، والشريك يقرأ ≥1 من الجدول نفسه =====
  for i in 1..4 loop
    perform pg_temp.read0('2.2 employee ' || (array['jobs','job_notes','job_stage_log','people'])[i], 'employee', emp, (array['public.jobs','public.job_notes','public.job_stage_log','public.people'])[i], p1);
    perform pg_temp.read0('2.2 norole ' || (array['jobs','job_notes','job_stage_log','people'])[i], 'norole', nr, (array['public.jobs','public.job_notes','public.job_stage_log','public.people'])[i], p1);
    perform pg_temp.read0('2.2 anon ' || (array['jobs','job_notes','job_stage_log','people'])[i], 'anon', null, (array['public.jobs','public.job_notes','public.job_stage_log','public.people'])[i], p1);
  end loop;
  -- user_roles والعدّاد: لا يقرأهما أحد من التطبيق، ولا الشريك (الإيجابي: الأدمن يرى الصفوف)
  begin
    perform pg_temp.rec('2.2 user_roles/counter hidden',
      (select count(*) from public.user_roles) >= 3 and (select count(*) from public.job_counter) = 1
      and not has_table_privilege('authenticated', 'public.user_roles', 'select')
      and not has_table_privilege('authenticated', 'public.job_counter', 'select')
      and not has_table_privilege('anon', 'public.user_roles', 'select')
      and not has_table_privilege('anon', 'public.job_counter', 'select'), 'admin sees rows; app roles no select');
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('2.2 user_roles/counter hidden', false, st || ': ' || msg);
  end;

  -- ===== 2.4 الثوابت — كل كاشف يُثبت أولًا أنه يرى عيّنة مزروعة، ثم أن الحالة الحقيقية نظيفة (B6) =====
  begin
    select string_agg(t, ',') into missing from unnest(slice_tables) t where to_regclass(t) is null;
    if missing is not null then raise exception 'missing tables: %', missing; end if;
    select string_agg(f, ',') into missing from unnest(slice_funcs) f where to_regproc(f) is null;
    if missing is not null then raise exception 'missing functions: %', missing; end if;
    -- المزروعات: جدول بلا RLS، عرض بلا security_invoker، دالة definer بلا search_path، ودالة definer تسرّب الملاحظات بلا فحص دور
    create table public.zz_plant(x int);
    create view public.zz_view as select job_number from public.jobs;
    create function public.zz_nopath() returns int language sql security definer as 'select 1';
    create function public.zz_leak() returns setof text language sql security definer set search_path = '' as 'select body from public.job_notes';
    grant execute on function public.zz_leak() to authenticated;
    for i in 1..2 loop
      perform pg_temp.rec(format('I4 RLS on every public table [%s]', case when i = 1 then 'plant' else 'real' end),
        coalesce((select array_agg(c.relname::text order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relkind in ('r','p') and not c.relrowsecurity), '{}') = case when i = 1 then array['zz_plant'] else '{}'::text[] end, 'rls');
      perform pg_temp.rec(format('I4 views security_invoker [%s]', case when i = 1 then 'plant' else 'real' end),
        coalesce((select array_agg(c.relname::text order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relkind = 'v' and not coalesce(c.reloptions @> array['security_invoker=true'], false)), '{}') = case when i = 1 then array['zz_view'] else '{}'::text[] end, 'views');
      perform pg_temp.rec(format('I5 anon no table privilege [%s]', case when i = 1 then 'plant' else 'real' end),
        coalesce((select array_agg(c.relname::text order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relkind in ('r','p','v','m')
            and has_table_privilege('anon', c.oid, 'select,insert,update,delete,truncate,references,trigger')), '{}') = case when i = 1 then array['zz_plant','zz_view'] else '{}'::text[] end, 'anon tables');
      perform pg_temp.rec(format('I5 anon executes no public function [%s]', case when i = 1 then 'plant' else 'real' end),
        coalesce((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')), '{}') = case when i = 1 then array['zz_leak','zz_nopath'] else '{}'::text[] end, 'anon exec');
      perform pg_temp.rec(format('I4 definer funcs pin search_path [%s]', case when i = 1 then 'plant' else 'real' end),
        coalesce((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.prosecdef and not coalesce(p.proconfig::text like '%search_path=%', false)), '{}') = case when i = 1 then array['zz_nopath'] else '{}'::text[] end, 'search_path');
      -- كل دالة definer مكشوفة يجب أن تكون ضمن الدوال المختبرة سلوكيًا بفحص الدور في هذا الملف
      perform pg_temp.rec(format('I4 definer funcs all behavior-tested [%s]', case when i = 1 then 'plant' else 'real' end),
        coalesce((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.prosecdef and p.proname <> all (slice_funcs_names)), '{}') = case when i = 1 then array['zz_leak','zz_nopath'] else '{}'::text[] end, 'allowlist');
      if i = 1 then
        drop table public.zz_plant; drop view public.zz_view; drop function public.zz_nopath(); drop function public.zz_leak();
      end if;
    end loop;
    perform pg_temp.rec('I8 no delete/truncate for app roles on slice tables',
      not exists (select 1 from unnest(slice_tables) t, unnest(array['anon','authenticated','service_role']) r
        where has_table_privilege(r, t, 'delete') or has_table_privilege(r, t, 'truncate')), 'anon/authenticated/service_role');
    perform pg_temp.rec('I4 private schema not reachable by app roles',
      to_regnamespace('private') is not null
      and not has_schema_privilege('anon', 'private', 'usage') and not has_schema_privilege('authenticated', 'private', 'usage'), 'private');
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('2.4 invariants', false, st || ': ' || msg);
  end;

  -- I9: كل نقل ناجح = سطر واحد في المعاملة نفسها؛ النقل الفاشل لا يترك سطرًا
  begin
    log_before := (select count(*) from public.job_stage_log);
    perform pg_temp.chk('I9 failed move', 'partner', p1, format($q$select public.move_job(%s,'design','execution')$q$, d), 'invalid_transition');
    log_after := (select count(*) from public.job_stage_log);
    perform pg_temp.chk('I9 ok move', 'partner', p1, format($q$select public.move_job(%s,'design','review')$q$, d), 'ok');
    perform pg_temp.rec('I9 log atomic', log_after = log_before
      and (select count(*) from public.job_stage_log) = log_before + 1
      and (select count(*) from public.job_stage_log l join public.jobs j using (job_number)) = (select count(*) from public.job_stage_log)
      and (select stage::text from public.jobs where job_number = d) = (select to_stage::text from public.job_stage_log where job_number = d order by id desc limit 1),
      format('before=%s after_fail=%s', log_before, log_after));
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('I9 log atomic', false, st || ': ' || msg);
  end;

  -- ===== B1: الفراغ = أي مسافة أو محرف تنسيق Unicode (tab، سطر جديد، NBSP، ZWSP، RLM، ALM، مسافة عريضة، BOM) =====
  for i in 1..array_length(blanks, 1) loop
    perform pg_temp.chk(format('B1 blank client #%s', i), 'partner', p1, format('select public.create_job(%L, %L, %L)', blanks[i], 'ش', 'other'), 'client_required');
    perform pg_temp.chk(format('B1 blank title #%s', i), 'partner', p1, format('select public.create_job(%L, %L, %L)', 'ع', blanks[i], 'other'), 'title_required');
    perform pg_temp.chk(format('B1 blank reason #%s', i), 'partner', p1, format('select public.cancel_job(%s, %L, %L)', d, 'review', blanks[i]), 'reason_required');
  end loop;
  perform pg_temp.chk('B1 +text with RLM inside', 'partner', p1, format('select public.create_job(%L, %L, %L)', U&'\200Fعميل', U&'شغلة\00A0أ', 'other'), 'ok');

  -- ===== B2: حتى المالك (محرر SQL / لوحة Supabase، بلا هوية مستخدم) لا يغيّر مرحلة بلا سطر ولا يعدّل السجل =====
  perform pg_temp.chk('B2 owner stage edit (no actor)', 'admin', null, format($q$update public.jobs set stage = 'delivered' where job_number = %s$q$, d), 'no_actor');
  perform pg_temp.chk('B2 owner field edit', 'admin', null, format($q$update public.jobs set client = 'آخر' where job_number = %s$q$, d), 'immutable_field');
  perform pg_temp.chk('B2 owner number edit', 'admin', null, format($q$update public.jobs set job_number = 9998 where job_number = %s$q$, d), 'immutable_field');
  perform pg_temp.chk('B2 owner log update', 'admin', null, format($q$update public.job_stage_log set reason = 'مزوّر', moved_at = '2020-01-01' where job_number = %s$q$, a), 'log_immutable');
  perform pg_temp.chk('B2 owner log insert', 'admin', null, format($q$insert into public.job_stage_log(job_number, from_stage, to_stage, moved_by, moved_at) values (%s,'review','delivered',%L,'2020-01-01')$q$, d, p2), 'log_direct_insert');
  perform pg_temp.chk('B2 owner job insert', 'admin', null, format($q$insert into public.jobs(job_number, client, title, job_type, created_by) values (9500,'ع','ش','other',%L)$q$, p1), 'no_actor');
  perform pg_temp.chk('B2 owner counter jump', 'admin', null, 'update public.job_counter set last_number = last_number + 5', 'counter_step');
  perform pg_temp.chk('B2 owner notes after open', 'admin', null, format($q$insert into public.job_notes(job_number, body) values (%s,'سعر 900')$q$, d), 'notes_after_open');
  perform pg_temp.chk('B2 owner notes edit', 'admin', null, format($q$update public.job_notes set body = 'x' where job_number = %s$q$, a), 'immutable_field');
  -- مالك ينتحل هوية شريك في محرر SQL: القاعدة نفسها تفرض خريطة المراحل وتكتب السطر
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', p1, 'role', 'authenticated')::text, true);
    begin
      execute format($q$update public.jobs set stage = 'delivered' where job_number = %s$q$, d);
      txt := 'succeeded';
    exception when others then txt := sqlerrm; end;
    perform pg_temp.rec('B2 owner+actor skip -> invalid_transition', txt = 'invalid_transition', txt);
    log_before := (select count(*) from public.job_stage_log where job_number = d);
    execute format($q$update public.jobs set stage = 'execution' where job_number = %s and stage = 'review'$q$, d);
    perform pg_temp.rec('B2 owner+actor valid move writes log line',
      (select count(*) from public.job_stage_log where job_number = d) = log_before + 1
      and (select to_stage::text || '/' || moved_by::text from public.job_stage_log where job_number = d order by id desc limit 1) = 'execution/' || p1::text,
      'trigger logged');
    perform set_config('request.jwt.claims', '', true);
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform set_config('request.jwt.claims', '', true);
    perform pg_temp.rec('B2 owner+actor', false, st || ': ' || msg);
  end;

  -- ينهي كل شيء بالتراجع ويحمل النتائج
  -- سطر ملخّص (يقرؤه الإنسان على التطوير) ثم JSON كامل بعد «##» (للمقارنة الآلية)
  raise exception 'WASM_TEST_RESULTS % ## %',
    (select count(*) || ' total, ' || count(*) filter (where ok) || ' ok, FAILED: ' || coalesce(string_agg(id || ' => ' || detail, ' | ') filter (where not ok), 'none') from t_results),
    (select jsonb_agg(jsonb_build_object('id', r.id, 'ok', r.ok, 'd', r.detail) order by r.n) from t_results r);
end $t$;
