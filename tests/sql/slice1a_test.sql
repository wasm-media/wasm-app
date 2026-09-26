-- اختبارات الشريحة 1أ — الشغلة ومراحلها (السيرفر) — ومعها الشريحة 2 (المهام والملفات والمدير) في آخر الملف
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

-- مثل val لكن لا يرمي: الخطأ يرجع نصًا «ERR <رمز>: <رسالة>» فيفشل الفحص وحده ولا يوقف الملف (الشريحة 2)
create or replace function pg_temp.v(who text, uid uuid, q text) returns text
language plpgsql as $f$
declare st text; msg text;
begin
  return pg_temp.val(who, uid, q);
exception when others then
  get stacked diagnostics st = returned_sqlstate, msg = message_text;
  return 'ERR ' || st || ': ' || msg;
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
  slice_tables text[] := array['public.jobs','public.job_notes','public.job_stage_log','public.user_roles','public.job_counter','public.people',
                                'public.tasks','public.task_log','public.task_files'];
  slice_funcs text[] := array['public.create_job','public.move_job','public.cancel_job','public.is_partner',
    'public.is_manager','public.whoami','public.assignable_people','public.create_task','public.edit_task','public.assign_task',
    'public.set_task_status','public.cancel_task','public.begin_task_upload','public.finish_task_upload','public.approve_task_file',
    'public.can_get_task_object','public.can_put_task_object'];
  slice_funcs_names text[] := array['create_job','move_job','cancel_job','is_partner',
    'is_manager','whoami','assignable_people','create_task','edit_task','assign_task',
    'set_task_status','cancel_task','begin_task_upload','finish_task_upload','approve_task_file',
    'can_get_task_object','can_put_task_object'];
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

  -- ===== P18 (الحزمة 1): زرع الشريكين — الدور والاسم لحساب جديد تطابق بصمة بريده صفًّا في private.partner_seed =====
  -- البصمة = sha256 للبريد بحروف صغيرة بلا مسافات أطراف. لا بريد حقيقي في المستودع.
  declare
    s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid(); s3 uuid := gen_random_uuid();
    h text := encode(sha256(convert_to('seeded@wasm.test', 'UTF8')), 'hex');
    h2 text := encode(sha256(convert_to('later@wasm.test', 'UTF8')), 'hex');
  begin
    begin
      execute format('insert into private.partner_seed(email_sha256, display_name) values (%L, %L), (%L, %L)', h, 'شريك مزروع', h2, 'لاحق');
      insert into auth.users(id, email, aud, role) values (s1, 'Seeded@WASM.test', 'authenticated', 'authenticated');
      perform pg_temp.rec('P18 seeded email -> partner + name',
        (select role::text from public.user_roles where user_id = s1) = 'partner'
        and (select display_name from public.people where user_id = s1) = 'شريك مزروع', 'role/name');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('P18 seeded email -> partner + name', false, st || ': ' || msg);
    end;
    begin
      insert into auth.users(id, email, aud, role) values (s2, 'stranger@wasm.test', 'authenticated', 'authenticated');
      perform pg_temp.rec('P18 unseeded email -> no role, no name',
        not exists (select 1 from public.user_roles where user_id = s2) and not exists (select 1 from public.people where user_id = s2), 'none');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('P18 unseeded email -> no role, no name', false, st || ': ' || msg);
    end;
    begin -- تغيير البريد إلى بريد مزروع لا يمنح شيئًا: الزرع عند الإنشاء فقط
      insert into auth.users(id, email, aud, role) values (s3, 'x3@wasm.test', 'authenticated', 'authenticated');
      update auth.users set email = 'later@wasm.test' where id = s3;
      perform pg_temp.rec('P18 email change to seeded email grants nothing',
        not exists (select 1 from public.user_roles where user_id = s3), 'insert-only');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('P18 email change to seeded email grants nothing', false, st || ': ' || msg);
    end;
    perform pg_temp.chk('P18 employee reads seed', 'employee', emp, 'select count(*) from private.partner_seed', '42501');
    perform pg_temp.chk('P18 anon reads seed', 'anon', null, 'select count(*) from private.partner_seed', '42501');
    perform pg_temp.chk('P18 partner adds seed', 'partner', p1,
      format('insert into private.partner_seed(email_sha256, display_name) values (%L, %L)', repeat('a', 64), 'x'), '42501');
    perform pg_temp.chk('P18 employee adds seed', 'employee', emp,
      format('insert into private.partner_seed(email_sha256, display_name) values (%L, %L)', repeat('b', 64), 'x'), '42501');
    perform pg_temp.chk('P18 bad fingerprint rejected', 'admin', null,
      format('insert into private.partner_seed(email_sha256, display_name) values (%L, %L)', 'not-a-hash', 'x'), '23514');
    perform pg_temp.chk('P18 blank name rejected', 'admin', null,
      format('insert into private.partner_seed(email_sha256, display_name) values (%L, %L)', repeat('c', 64), U&'\200F '), '23514');
    begin
      perform pg_temp.rec('P18 seed trigger fn not callable by app roles',
        to_regprocedure('private.seed_partner()') is not null
        and not has_function_privilege('anon', 'private.seed_partner()', 'execute')
        and not has_function_privilege('authenticated', 'private.seed_partner()', 'execute')
        and not has_function_privilege('service_role', 'private.seed_partner()', 'execute'), 'execute');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('P18 seed trigger fn not callable by app roles', false, st || ': ' || msg);
    end;
    begin
      perform pg_temp.rec('P18 seed table not writable by service_role',
        to_regclass('private.partner_seed') is not null
        and not has_table_privilege('service_role', 'private.partner_seed', 'insert')
        and not has_table_privilege('service_role', 'private.partner_seed', 'select'), 'service_role');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('P18 seed table not writable by service_role', false, st || ': ' || msg);
    end;
  end;

  -- =====================================================================================================
  -- ===== الشريحة 2 (الحزمة 2): المهام (2أ) · الملفات (2ب) · المدير (2ج) · حسابات الموظفين (2د) =====
  -- الهويات: الشريكان p1/p2 · المدير mgr · الموظف أ emp · الموظف ب e2 · بلا دور nr · بلا دخول anon.
  -- كل رفض برمزه المسمّى، ومقابله فحص إيجابي. مسار المالك (تعديل مباشر) مختبر أيضًا (N7).
  -- =====================================================================================================
  begin -- أي انهيار غير متوقع في كتلة الشريحة 2 = فحص فاشل واحد باسمه (لا يوقف الملف ولا يخفي النتائج)
  declare
    mgr uuid := gen_random_uuid(); e2 uuid := gen_random_uuid();
    j1 int; j2 int; j3 int;
    t1 bigint; t2 bigint; t3 bigint; t4 bigint; t5 bigint; t6 bigint; t7 bigint; t8 bigint;
    f1 bigint; f2 bigint; f3 bigint; path1 text; path2 text; path3 text; r text; lb int; la int;
    blob jsonb := '{"size": 1000, "mimetype": "application/pdf"}';
  begin
    -- ---------- التجهيز ----------
    begin
      insert into auth.users(id, email, aud, role) values
        (mgr, 'manager@wasm.test', 'authenticated', 'authenticated'), (e2, 'employee2@wasm.test', 'authenticated', 'authenticated');
      execute format('insert into public.user_roles(user_id, role) values (%L, %L::public.app_role), (%L, %L::public.app_role)', mgr, 'manager', e2, 'employee');
      execute format('insert into public.people(user_id, display_name) values (%L, %L), (%L, %L)', mgr, 'المدير', e2, 'موظف ب');
      j1 := pg_temp.val('partner', p1, $q$select public.create_job('عميل سري جدًا','شغلة المهام','design')$q$)::int;
      j2 := pg_temp.val('partner', p1, $q$select public.create_job('عميل الإلغاء','شغلة ستلغى','print')$q$)::int;
      j3 := pg_temp.val('partner', p1, $q$select public.create_job('عميل التسليم','شغلة ستسلم','video')$q$)::int;
      perform pg_temp.rec('S2 setup', j1 is not null and j2 is not null and j3 is not null, 'manager, employee B, 3 jobs');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('S2 setup', false, st || ': ' || msg);
    end;

    -- ---------- 2أ-1 إنشاء المهام ----------
    begin
      t1 := pg_temp.val('partner', p1, format($q$select public.create_task(%s, 'تصميم بوستر', %L, '2026-10-05', 'مقاس A3')$q$, j1, emp))::bigint;
      t2 := pg_temp.val('partner', p1, format($q$select public.create_task(%s, 'مهمة الموظف أ الثانية', %L)$q$, j1, emp))::bigint;
      t3 := pg_temp.val('manager', mgr, format($q$select public.create_task(%s, 'مهمة الموظف ب', %L, '2026-10-06')$q$, j1, e2))::bigint;
      t4 := pg_temp.val('partner', p1, format($q$select public.create_task(%s, 'مهمة الشريك الثاني', %L)$q$, j1, p2))::bigint;
      t5 := pg_temp.val('manager', mgr, format($q$select public.create_task(%s, 'مهمة المدير لنفسه', %L)$q$, j1, mgr))::bigint;
      perform pg_temp.rec('2A create: partner->employee, manager->employee, partner->partner, manager->self',
        t1 is not null and t2 is not null and t3 is not null and t4 is not null and t5 is not null
        and (select status::text || '/' || assignee::text || '/' || created_by::text || '/' || job_number || '/' || job_title from public.tasks where id = t1)
          = 'new/' || emp || '/' || p1 || '/' || j1 || '/شغلة المهام'
        and (select due_date from public.tasks where id = t1) = '2026-10-05'::date
        and (select created_by from public.tasks where id = t3) = mgr, 'tasks');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('2A create: partner->employee, manager->employee, partner->partner, manager->self', false, st || ': ' || msg);
    end;
    perform pg_temp.chk('2A create -employee', 'employee', emp, format($q$select public.create_task(%s, 'x', %L)$q$, j1, emp), 'not_allowed');
    perform pg_temp.chk('2A create -norole', 'norole', nr, format($q$select public.create_task(%s, 'x', %L)$q$, j1, emp), 'not_allowed');
    perform pg_temp.chk('2A create -anon', 'anon', null, format($q$select public.create_task(%s, 'x', %L)$q$, j1, emp), '42501');
    perform pg_temp.chk('2A create blank title', 'partner', p1, format($q$select public.create_task(%s, %L, %L)$q$, j1, U&'\00A0\200F ', emp), 'title_required');
    perform pg_temp.chk('2A create unknown job', 'partner', p1, format($q$select public.create_task(999999, 'x', %L)$q$, emp), 'job_not_found');
    perform pg_temp.chk('2A create assignee without role', 'partner', p1, format($q$select public.create_task(%s, 'x', %L)$q$, j1, nr), 'invalid_assignee');
    perform pg_temp.chk('2A create assignee unknown', 'partner', p1, format($q$select public.create_task(%s, 'x', %L)$q$, j1, gen_random_uuid()), 'invalid_assignee');
    perform pg_temp.chk('2C manager cannot assign a partner', 'manager', mgr, format($q$select public.create_task(%s, 'x', %L)$q$, j1, p1), 'invalid_assignee');
    perform pg_temp.chk('2A task: who/when are not parameters', 'partner', p1, format($q$select public.create_task(%s, 'x', %L, null, null, %L)$q$, j1, emp, p2), '42883');
    -- لا كتابة مباشرة لأي دور (كل كتابة عبر الدوال)
    perform pg_temp.chk('2A direct insert -partner', 'partner', p1, format($q$insert into public.tasks(job_number, job_title, title, assignee, created_by) values (%s, 'x', 'x', %L, %L)$q$, j1, emp, p1), '42501');
    perform pg_temp.chk('2A direct update -employee', 'employee', emp, format($q$update public.tasks set status = 'done' where id = %s$q$, t1), '42501');
    perform pg_temp.chk('2A direct update -manager', 'manager', mgr, format($q$update public.tasks set title = 'x' where id = %s$q$, t1), '42501');
    perform pg_temp.chk('2A direct delete -partner', 'partner', p1, format($q$delete from public.tasks where id = %s$q$, t1), '42501');

    -- ---------- 2أ-2 القراءة: الموظف يرى مهامه فقط، ورقم الشغلة وعنوانها داخلها ----------
    perform pg_temp.rec('2A employee A sees exactly his 2 tasks',
      pg_temp.v('employee', emp, 'select count(*) from public.tasks') = '2'
      and pg_temp.v('employee', emp, 'select string_agg(title, ''|'' order by id) from public.tasks') = 'تصميم بوستر|مهمة الموظف أ الثانية', 'emp');
    perform pg_temp.rec('2A employee B sees exactly his 1 task',
      pg_temp.v('employee', e2, 'select count(*) from public.tasks') = '1'
      and pg_temp.v('employee', e2, format('select count(*) from public.tasks where id = %s', t1)) = '0', 'e2');
    perform pg_temp.rec('2A employee sees job number + title inside the task',
      pg_temp.v('employee', emp, format('select job_number || ''/'' || job_title from public.tasks where id = %s', t1)) = j1 || '/شغلة المهام', 'inline job');
    perform pg_temp.rec('2A tasks table carries no client/money column (I1)',
      not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'tasks'
        and column_name ~ '(client|price|amount|cost|total|fee|money)'), 'columns');
    perform pg_temp.read0('2A employee reads jobs (still 0)', 'employee', emp, 'public.jobs', p1);
    perform pg_temp.read0('2A employee reads job_notes (still 0)', 'employee', emp, 'public.job_notes', p1);
    perform pg_temp.read0('2A employee reads job_stage_log (still 0)', 'employee', emp, 'public.job_stage_log', p1);
    perform pg_temp.read0('2A norole reads tasks', 'norole', nr, 'public.tasks', p1);
    perform pg_temp.read0('2A anon reads tasks', 'anon', null, 'public.tasks', p1);
    perform pg_temp.read0('2A norole reads task_log', 'norole', nr, 'public.task_log', p1);
    perform pg_temp.read0('2A anon reads task_log', 'anon', null, 'public.task_log', p1);
    perform pg_temp.rec('2A partner + manager see all tasks',
      pg_temp.v('partner', p2, format('select count(*) from public.tasks where job_number = %s', j1)) = '5'
      and pg_temp.v('manager', mgr, format('select count(*) from public.tasks where job_number = %s', j1)) = '5', 'all');
    perform pg_temp.rec('2A whoami: role + own name only',
      pg_temp.v('employee', emp, 'select role || ''/'' || display_name from public.whoami()') = 'employee/موظف'
      and pg_temp.v('manager', mgr, 'select role || ''/'' || display_name from public.whoami()') = 'manager/المدير'
      and pg_temp.v('partner', p1, 'select role || ''/'' || display_name from public.whoami()') = 'partner/الشريك الأول'
      and pg_temp.v('norole', nr, 'select count(*) from public.whoami()') = '0', 'whoami');
    perform pg_temp.chk('2A whoami -anon', 'anon', null, 'select * from public.whoami()', '42501');

    -- ---------- 2ج المدير: يرى الشغلات بلا ملاحظات ولا سجل مراحل، ولا يحرّكها ----------
    perform pg_temp.rec('2C manager reads jobs', pg_temp.v('manager', mgr, format('select client from public.jobs where job_number = %s', j1)) = 'عميل سري جدًا', 'jobs');
    perform pg_temp.rec('2C manager reads no job_notes / job_stage_log / user_roles-free',
      pg_temp.v('manager', mgr, 'select count(*) from public.job_notes') = '0'
      and pg_temp.v('manager', mgr, 'select count(*) from public.job_stage_log') = '0'
      and pg_temp.v('partner', p1, 'select count(*) from public.job_notes') <> '0', 'notes/log');
    perform pg_temp.chk('2C manager reads user_roles', 'manager', mgr, 'select count(*) from public.user_roles', '42501');
    perform pg_temp.rec('2C jobs columns are exactly the 8 reviewed ones (new column => decide what the manager sees)',
      (select string_agg(column_name::text, ',' order by ordinal_position) from information_schema.columns
        where table_schema = 'public' and table_name = 'jobs') = 'job_number,client,title,job_type,due_date,stage,created_by,created_at', 'columns');
    perform pg_temp.chk('2C manager opens job', 'manager', mgr, $q$select public.create_job('c','t','design')$q$, 'not_partner');
    perform pg_temp.chk('2C manager moves job', 'manager', mgr, format($q$select public.move_job(%s,'intake','quote')$q$, j1), 'not_partner');
    perform pg_temp.chk('2C manager cancels job', 'manager', mgr, format($q$select public.cancel_job(%s,'intake','x')$q$, j1), 'not_partner');
    perform pg_temp.rec('2C manager is not partner', pg_temp.v('manager', mgr, 'select public.is_partner()') = 'false'
      and pg_temp.v('manager', mgr, 'select public.is_manager()') = 'true'
      and pg_temp.v('partner', p1, 'select public.is_manager()') = 'false'
      and pg_temp.v('employee', emp, 'select public.is_manager()') = 'false', 'is_manager');
    perform pg_temp.rec('2C people: partner + manager read names, employee none',
      pg_temp.v('manager', mgr, 'select count(*) from public.people') = pg_temp.v('partner', p1, 'select count(*) from public.people')
      and pg_temp.v('employee', emp, 'select count(*) from public.people') = '0', 'people');
    perform pg_temp.rec('2C assignable people: partner all roles, manager staff only',
      pg_temp.v('partner', p1, format('select count(*) from public.assignable_people() where user_id in (%L,%L,%L,%L)', p2, mgr, emp, e2)) = '4'
      and pg_temp.v('manager', mgr, format('select count(*) from public.assignable_people() where user_id in (%L,%L)', p1, p2)) = '0'
      and pg_temp.v('manager', mgr, format('select count(*) from public.assignable_people() where user_id in (%L,%L,%L)', mgr, emp, e2)) = '3'
      and pg_temp.v('partner', p1, format('select count(*) from public.assignable_people() where user_id = %L', nr)) = '0', 'assignable');
    perform pg_temp.chk('2C assignable -employee', 'employee', emp, 'select count(*) from public.assignable_people()', 'not_allowed');

    -- ---------- 2أ-3 الحالات ----------
    begin
      lb := (select count(*) from public.task_log where task_id = t1);
      perform pg_temp.val('employee', emp, format($q$select public.set_task_status(%s,'new','in_progress')$q$, t1));
      la := (select count(*) from public.task_log where task_id = t1);
      perform pg_temp.rec('2A employee: new -> in_progress, one log line',
        (select status::text from public.tasks where id = t1) = 'in_progress' and la = lb + 1
        and (select kind || '/' || from_status || '>' || to_status || '/' || by_user || '/' || by_name from public.task_log where task_id = t1 order by id desc limit 1)
          = 'status/new>in_progress/' || emp || '/موظف', format('%s->%s', lb, la));
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('2A employee: new -> in_progress, one log line', false, st || ': ' || msg);
    end;
    perform pg_temp.chk('2A employee stale from', 'employee', emp, format($q$select public.set_task_status(%s,'new','in_progress')$q$, t1), 'stale_status');
    perform pg_temp.chk('2A employee approves own (in_progress->done)', 'employee', emp, format($q$select public.set_task_status(%s,'in_progress','done')$q$, t1), 'invalid_transition');
    perform pg_temp.chk('2A employee skips (new->ready)', 'employee', emp, format($q$select public.set_task_status(%s,'new','ready_for_review')$q$, t2), 'invalid_transition');
    perform pg_temp.chk('2A employee: someone else''s task is invisible', 'employee', emp, format($q$select public.set_task_status(%s,'new','in_progress')$q$, t3), 'task_not_found');
    perform pg_temp.chk('2A norole sets status', 'norole', nr, format($q$select public.set_task_status(%s,'new','in_progress')$q$, t2), 'not_allowed');
    perform pg_temp.chk('2A bad status value', 'employee', emp, format($q$select public.set_task_status(%s,'new','flying')$q$, t2), 'invalid_status');
    perform pg_temp.chk('2A employee: in_progress -> ready', 'employee', emp, format($q$select public.set_task_status(%s,'in_progress','ready_for_review')$q$, t1), 'ok');
    perform pg_temp.chk('2A employee approves from review', 'employee', emp, format($q$select public.set_task_status(%s,'ready_for_review','done')$q$, t1), 'not_allowed');
    perform pg_temp.chk('2A employee returns own task', 'employee', emp, format($q$select public.set_task_status(%s,'ready_for_review','in_progress','x')$q$, t1), 'not_allowed');
    perform pg_temp.chk('2A partner return with blank note', 'partner', p1, format($q$select public.set_task_status(%s,'ready_for_review','in_progress',%L)$q$, t1, E'\t' || U&'\200B'), 'note_required');
    perform pg_temp.chk('2A partner return with note', 'partner', p1, format($q$select public.set_task_status(%s,'ready_for_review','in_progress','عدّل الألوان')$q$, t1), 'ok');
    perform pg_temp.rec('2A employee reads the return note in his task log',
      pg_temp.v('employee', emp, format($q$select note || '/' || by_name from public.task_log where task_id = %s and to_status = 'in_progress' and from_status = 'ready_for_review'$q$, t1)) = 'عدّل الألوان/الشريك الأول', 'note');
    perform pg_temp.chk('2A note on a non-return move', 'employee', emp, format($q$select public.set_task_status(%s,'in_progress','ready_for_review','ملاحظة')$q$, t1), 'invalid_transition');
    perform pg_temp.chk('2A employee: ready again', 'employee', emp, format($q$select public.set_task_status(%s,'in_progress','ready_for_review')$q$, t1), 'ok');
    perform pg_temp.chk('2A partner approves -> done', 'partner', p2, format($q$select public.set_task_status(%s,'ready_for_review','done')$q$, t1), 'ok');
    perform pg_temp.chk('2A done is final (status)', 'partner', p1, format($q$select public.set_task_status(%s,'done','in_progress','x')$q$, t1), 'final_status');
    perform pg_temp.chk('2A done is final (cancel)', 'partner', p1, format($q$select public.cancel_task(%s,'done','x')$q$, t1), 'final_status');
    perform pg_temp.chk('2A done is final (edit)', 'partner', p1, format($q$select public.edit_task(%s,'x',null,null)$q$, t1), 'final_status');
    perform pg_temp.chk('2A done is final (assign)', 'partner', p1, format($q$select public.assign_task(%s,%L)$q$, t1, e2), 'final_status');
    -- المدير يراجع مهام غيره، ولا يعتمد مهمة مكلّفًا هو بها
    perform pg_temp.chk('2C manager: own task new -> in_progress', 'manager', mgr, format($q$select public.set_task_status(%s,'new','in_progress')$q$, t5), 'ok');
    perform pg_temp.chk('2C manager: own task -> ready', 'manager', mgr, format($q$select public.set_task_status(%s,'in_progress','ready_for_review')$q$, t5), 'ok');
    perform pg_temp.chk('2C manager approves own task', 'manager', mgr, format($q$select public.set_task_status(%s,'ready_for_review','done')$q$, t5), 'own_review');
    perform pg_temp.chk('2C manager returns own task', 'manager', mgr, format($q$select public.set_task_status(%s,'ready_for_review','in_progress','x')$q$, t5), 'own_review');
    perform pg_temp.chk('2C partner approves manager''s task', 'partner', p1, format($q$select public.set_task_status(%s,'ready_for_review','done')$q$, t5), 'ok');
    perform pg_temp.chk('2C employee B -> ready', 'employee', e2, format($q$select public.set_task_status(%s,'new','in_progress')$q$, t3), 'ok');
    perform pg_temp.chk('2C employee B -> ready 2', 'employee', e2, format($q$select public.set_task_status(%s,'in_progress','ready_for_review')$q$, t3), 'ok');
    perform pg_temp.chk('2C manager returns employee''s task with note', 'manager', mgr, format($q$select public.set_task_status(%s,'ready_for_review','in_progress','أضف الشعار')$q$, t3), 'ok');
    perform pg_temp.chk('2A partner (assignee) moves own task', 'partner', p2, format($q$select public.set_task_status(%s,'new','in_progress')$q$, t4), 'ok');

    -- ---------- 2أ-4 التعديل وإعادة التكليف والإلغاء ----------
    perform pg_temp.chk('2A employee edits', 'employee', emp, format($q$select public.edit_task(%s,'x',null,null)$q$, t2), 'not_allowed');
    perform pg_temp.chk('2A employee reassigns', 'employee', emp, format($q$select public.assign_task(%s,%L)$q$, t2, e2), 'not_allowed');
    perform pg_temp.chk('2A employee cancels', 'employee', emp, format($q$select public.cancel_task(%s,'new','x')$q$, t2), 'not_allowed');
    perform pg_temp.chk('2A edit blank title', 'partner', p1, format($q$select public.edit_task(%s,%L,null,null)$q$, t2, ' '), 'title_required');
    begin
      lb := (select count(*) from public.task_log where task_id = t2);
      perform pg_temp.val('manager', mgr, format($q$select public.edit_task(%s,'مهمة معدّلة','2026-11-01','وصف جديد')$q$, t2));
      perform pg_temp.rec('2A manager edits: fields + one log line',
        (select title || '/' || due_date || '/' || description from public.tasks where id = t2) = 'مهمة معدّلة/2026-11-01/وصف جديد'
        and (select count(*) from public.task_log where task_id = t2) = lb + 1
        and (select kind from public.task_log where task_id = t2 order by id desc limit 1) = 'edit', 'edit');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('2A manager edits: fields + one log line', false, st || ': ' || msg);
    end;

    -- ---------- 2ب الملفات (قبل إعادة التكليف: الموظف أ يرفع على t2) ----------
    begin
      r := pg_temp.val('employee', emp, format($q$select file_id || ' ' || object_path from public.begin_task_upload(%s, 'بوستر نهائي.pdf', 'application/pdf', 1000, 'draft')$q$, t2));
      f1 := split_part(r, ' ', 1)::bigint; path1 := split_part(r, ' ', 2);
      perform pg_temp.rec('2B employee reserves an upload on his task', f1 is not null and path1 ~ ('^t' || t2 || '/[0-9a-f-]{36}\.pdf$'), r);
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('2B employee reserves an upload on his task', false, st || ': ' || msg);
    end;
    perform pg_temp.chk('2B svg refused', 'employee', emp, format($q$select * from public.begin_task_upload(%s, 'a.svg', 'image/svg+xml', 10, 'draft')$q$, t2), 'file_type');
    perform pg_temp.chk('2B html refused', 'employee', emp, format($q$select * from public.begin_task_upload(%s, 'a.html', 'text/html', 10, 'draft')$q$, t2), 'file_type');
    perform pg_temp.chk('2B over 50MB refused', 'employee', emp, format($q$select * from public.begin_task_upload(%s, 'a.mp4', 'video/mp4', 52428801, 'final')$q$, t2), 'file_too_large');
    perform pg_temp.chk('2B exactly 50MB ok', 'employee', emp, format($q$select * from public.begin_task_upload(%s, 'a.mp4', 'video/mp4', 52428800, 'final')$q$, t2), 'ok');
    perform pg_temp.chk('2B bad kind', 'employee', emp, format($q$select * from public.begin_task_upload(%s, 'a.pdf', 'application/pdf', 10, 'secret')$q$, t2), 'invalid_kind');
    perform pg_temp.chk('2B blank name', 'employee', emp, format($q$select * from public.begin_task_upload(%s, %L, 'application/pdf', 10, 'draft')$q$, t2, U&'\3000'), 'file_name_required');
    perform pg_temp.chk('2B employee B uploads on A''s task', 'employee', e2, format($q$select * from public.begin_task_upload(%s, 'a.pdf', 'application/pdf', 10, 'draft')$q$, t2), 'task_not_found');
    perform pg_temp.chk('2B norole uploads', 'norole', nr, format($q$select * from public.begin_task_upload(%s, 'a.pdf', 'application/pdf', 10, 'draft')$q$, t2), 'not_allowed');
    perform pg_temp.chk('2B upload on a done task', 'partner', p1, format($q$select * from public.begin_task_upload(%s, 'a.pdf', 'application/pdf', 10, 'draft')$q$, t1), 'final_status');
    perform pg_temp.chk('2B finish before the object exists', 'employee', emp, format($q$select public.finish_task_upload(%s)$q$, f1), 'upload_missing');
    -- Storage بهوية المستخدم (كما يفعل storage-api: دور authenticated + JWT)
    perform pg_temp.chk('2B employee B puts into A''s reserved path', 'employee', e2, format($q$insert into storage.objects(bucket_id, name, owner, metadata) values ('task-files', %L, %L, %L)$q$, path1, e2, blob), '42501');
    perform pg_temp.chk('2B employee puts into an unreserved path', 'employee', emp, format($q$insert into storage.objects(bucket_id, name, owner, metadata) values ('task-files', %L, %L, %L)$q$, 't' || t2 || '/' || gen_random_uuid() || '.pdf', emp, blob), '42501');
    perform pg_temp.chk('2B anon puts', 'anon', null, format($q$insert into storage.objects(bucket_id, name, metadata) values ('task-files', %L, %L)$q$, path1, blob), '42501');
    perform pg_temp.chk('2B employee puts into his reserved path', 'employee', emp, format($q$insert into storage.objects(bucket_id, name, owner, metadata) values ('task-files', %L, %L, %L)$q$, path1, emp, blob), 'ok');
    perform pg_temp.chk('2B same path twice (no overwrite)', 'employee', emp, format($q$insert into storage.objects(bucket_id, name, owner, metadata) values ('task-files', %L, %L, %L)$q$, path1, emp, blob), '42501');
    perform pg_temp.chk('2B employee B finishes A''s upload', 'employee', e2, format($q$select public.finish_task_upload(%s)$q$, f1), 'file_not_found');
    perform pg_temp.chk('2B employee finishes', 'employee', emp, format($q$select public.finish_task_upload(%s)$q$, f1), 'ok');
    perform pg_temp.rec('2B file row: real size/type from Storage, uploader, not approved',
      (select size_bytes || '/' || mime || '/' || kind || '/' || uploaded_by || '/' || file_name || '/' || (approved_at is null) from public.task_files where id = f1)
        = '1000/application/pdf/draft/' || emp || '/بوستر نهائي.pdf/true', 'row');
    perform pg_temp.rec('2B readers of the object: uploader, partner, manager — not employee B, norole, anon',
      pg_temp.v('employee', emp, format('select count(*) from storage.objects where name = %L', path1)) = '1'
      and pg_temp.v('partner', p2, format('select count(*) from storage.objects where name = %L', path1)) = '1'
      and pg_temp.v('manager', mgr, format('select count(*) from storage.objects where name = %L', path1)) = '1'
      and pg_temp.v('employee', e2, format('select count(*) from storage.objects where name = %L', path1)) = '0'
      and pg_temp.v('norole', nr, format('select count(*) from storage.objects where name = %L', path1)) = '0', 'objects');
    perform pg_temp.chk('2B anon lists objects', 'anon', null, format('select 1/(1 - count(*))::int from storage.objects where name = %L', path1), 'ok');
    perform pg_temp.rec('2B task_files rows follow the task',
      pg_temp.v('employee', emp, format('select count(*) from public.task_files where id = %s', f1)) = '1'
      and pg_temp.v('employee', e2, format('select count(*) from public.task_files where id = %s', f1)) = '0'
      and pg_temp.v('norole', nr, 'select count(*) from public.task_files') = '0', 'task_files');
    perform pg_temp.read0('2B anon reads task_files', 'anon', null, 'public.task_files', p1);
    -- لا نقل ولا إعادة تسمية ولا استبدال ولا حذف لأي دور، ولا حذف حتى من المالك (I8)
    begin
      perform pg_temp.rec('2B no update/delete policy: app roles change 0 rows, object untouched',
        pg_temp.v('employee', emp, format($q$with x as (update storage.objects set name = 'moved.pdf' where name = %L returning 1) select count(*) from x$q$, path1)) = '0'
        and pg_temp.v('partner', p1, format($q$with x as (update storage.objects set metadata = '{}' where name = %L returning 1) select count(*) from x$q$, path1)) = '0'
        and pg_temp.v('manager', mgr, format($q$with x as (delete from storage.objects where name = %L returning 1) select count(*) from x$q$, path1)) in ('0', 'ERR 42501: Direct deletion from storage tables is not allowed. Use the Storage API instead.')
        and (select count(*) from storage.objects where bucket_id = 'task-files' and name = path1 and metadata = blob) = 1, 'objects');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('2B no update/delete policy: object untouched after app-role update/delete', false, st || ': ' || msg);
    end;
    -- حتى بإذن الحذف الذي يستعمله storage-api نفسه (storage.allow_delete_query) — أي حذف عبر API أو لوحة Supabase
    begin
      perform set_config('storage.allow_delete_query', 'true', true);
      delete from storage.objects where bucket_id = 'task-files' and name = path1;
      perform set_config('storage.allow_delete_query', '', true);
      perform pg_temp.rec('2B owner deletes object via the storage path (I8)', false, 'succeeded');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform set_config('storage.allow_delete_query', '', true);
      perform pg_temp.rec('2B owner deletes object via the storage path (I8)', msg = 'no_delete', msg);
    end;
    perform pg_temp.chk('2B owner renames object (I8)', 'admin', null, format($q$update storage.objects set name = 'x.pdf' where bucket_id = 'task-files' and name = %L$q$, path1), 'immutable_field');
    perform pg_temp.chk('2B owner deletes file row (I8)', 'admin', null, format('delete from public.task_files where id = %s', f1), 'no_delete');
    perform pg_temp.chk('2B direct insert task_files -partner', 'partner', p1, format($q$insert into public.task_files(task_id, object_path, file_name, mime, kind, uploaded_by) values (%s,'x','x','application/pdf','draft',%L)$q$, t2, p1), '42501');
    perform pg_temp.rec('2B bucket: private, 50MB, 6 types, no svg',
      (select not public and file_size_limit = 52428800
         and allowed_mime_types::text[] @> array['application/pdf','image/jpeg','image/png','image/webp','video/mp4','application/zip']
         and not (allowed_mime_types::text[] && array['image/svg+xml','text/html'])
       from storage.buckets where id = 'task-files'), 'bucket');
    perform pg_temp.chk('2B approve -employee', 'employee', emp, format($q$select public.approve_task_file(%s)$q$, f1), 'not_allowed');
    perform pg_temp.chk('2B approve -manager', 'manager', mgr, format($q$select public.approve_task_file(%s)$q$, f1), 'ok');
    perform pg_temp.chk('2B approve twice', 'partner', p1, format($q$select public.approve_task_file(%s)$q$, f1), 'already_approved');
    perform pg_temp.rec('2B approval recorded', (select approved_by = mgr and approved_at is not null from public.task_files where id = f1), 'approved');
    -- رفع ثانٍ للمدير على مهمة الموظف ب (يُستعمل بعد إعادة التكليف)
    begin
      r := pg_temp.val('manager', mgr, format($q$select file_id || ' ' || object_path from public.begin_task_upload(%s, 'مراجعة.png', 'image/png', 500, 'review')$q$, t3));
      f2 := split_part(r, ' ', 1)::bigint; path2 := split_part(r, ' ', 2);
      perform pg_temp.val('manager', mgr, format($q$insert into storage.objects(bucket_id, name, owner, metadata) values ('task-files', %L, %L, '{"size": 500, "mimetype": "image/png"}') returning 1$q$, path2, mgr));
      perform pg_temp.val('manager', mgr, format('select public.finish_task_upload(%s)', f2));
      perform pg_temp.rec('2B manager uploads on employee B''s task; B reads it, A does not',
        pg_temp.v('employee', e2, format('select count(*) from storage.objects where name = %L', path2)) = '1'
        and pg_temp.v('employee', emp, format('select count(*) from storage.objects where name = %L', path2)) = '0', 'f2');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('2B manager uploads on employee B''s task; B reads it, A does not', false, st || ': ' || msg);
    end;
    -- حجز منتهٍ (أكثر من 15 دقيقة) لا يقبل رفعًا
    begin
      r := pg_temp.val('employee', emp, format($q$select file_id || ' ' || object_path from public.begin_task_upload(%s, 'قديم.pdf', 'application/pdf', 10, 'draft')$q$, t2));
      f3 := split_part(r, ' ', 1)::bigint; path3 := split_part(r, ' ', 2);
      update public.task_files set reserved_at = now() - interval '16 minutes' where id = f3;
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('2B expired reservation setup', false, st || ': ' || msg);
    end;
    perform pg_temp.chk('2B expired reservation refuses upload', 'employee', emp, format($q$insert into storage.objects(bucket_id, name, owner, metadata) values ('task-files', %L, %L, %L)$q$, path3, emp, blob), '42501');

    -- ---------- 2أ-4 إعادة التكليف: الموظف أ يفقد المهمة وسجلها وملفاتها فورًا ----------
    begin
      lb := (select count(*) from public.task_log where task_id = t2);
      perform pg_temp.val('partner', p1, format('select public.assign_task(%s, %L)', t2, e2));
      perform pg_temp.rec('2A reassign: new assignee, one log line',
        (select assignee from public.tasks where id = t2) = e2 and (select count(*) from public.task_log where task_id = t2) = lb + 1
        and (select kind || '/' || from_assignee || '>' || to_assignee from public.task_log where task_id = t2 order by id desc limit 1) = 'assign/' || emp || '>' || e2, 'assign');
      perform pg_temp.rec('2A after reassign: A sees 1 task, no log, no file; B sees 2',
        pg_temp.v('employee', emp, 'select count(*) from public.tasks') = '1'
        and pg_temp.v('employee', emp, format('select count(*) from public.task_log where task_id = %s', t2)) = '0'
        and pg_temp.v('employee', emp, format('select count(*) from public.task_files where task_id = %s', t2)) = '0'
        and pg_temp.v('employee', emp, format('select count(*) from storage.objects where name = %L', path1)) = '0'
        and pg_temp.v('employee', e2, 'select count(*) from public.tasks') = '2'
        and pg_temp.v('employee', e2, format('select count(*) from storage.objects where name = %L', path1)) = '1', 'revoked');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('2A reassign: new assignee, one log line', false, st || ': ' || msg);
    end;
    perform pg_temp.chk('2C manager reassigns to a partner', 'manager', mgr, format('select public.assign_task(%s, %L)', t2, p1), 'invalid_assignee');
    perform pg_temp.chk('2C manager reassigns to employee A', 'manager', mgr, format('select public.assign_task(%s, %L)', t2, emp), 'ok');
    perform pg_temp.chk('2A reassign to the same person', 'partner', p1, format('select public.assign_task(%s, %L)', t2, emp), 'invalid_assignee');
    perform pg_temp.chk('2A cancel blank reason', 'manager', mgr, format($q$select public.cancel_task(%s,'in_progress',%L)$q$, t3, U&'\061C'), 'reason_required');
    perform pg_temp.chk('2A cancel stale', 'manager', mgr, format($q$select public.cancel_task(%s,'new','x')$q$, t3), 'stale_status');
    perform pg_temp.chk('2A manager cancels with reason', 'manager', mgr, format($q$select public.cancel_task(%s,'in_progress','العميل غيّر رأيه')$q$, t3), 'ok');
    perform pg_temp.rec('2A cancel logged with reason',
      (select from_status || '>' || to_status || '/' || note from public.task_log where task_id = t3 order by id desc limit 1) = 'in_progress>cancelled/العميل غيّر رأيه', 'cancel');
    perform pg_temp.chk('2A cancelled is final', 'employee', e2, format($q$select public.set_task_status(%s,'cancelled','in_progress')$q$, t3), 'final_status');
    perform pg_temp.chk('2B upload on a cancelled task', 'manager', mgr, format($q$select * from public.begin_task_upload(%s, 'a.pdf', 'application/pdf', 10, 'draft')$q$, t3), 'final_status');

    -- ---------- السجل والجداول: لا كتابة مباشرة، ولا تعديل، ولا حذف (I8، I9) ----------
    perform pg_temp.chk('2A log insert -partner', 'partner', p1, format($q$insert into public.task_log(task_id, kind, by_user, by_name) values (%s,'status',%L,'x')$q$, t1, p1), '42501');
    perform pg_temp.chk('2A log insert -owner', 'admin', null, format($q$insert into public.task_log(task_id, kind, by_user, by_name) values (%s,'status',%L,'x')$q$, t1, p1), 'log_direct_insert');
    perform pg_temp.chk('2A log update -owner', 'admin', null, format($q$update public.task_log set note = 'x' where task_id = %s$q$, t1), 'log_immutable');
    perform pg_temp.chk('2A log delete -owner (I8)', 'admin', null, format('delete from public.task_log where task_id = %s', t1), 'no_delete');
    perform pg_temp.chk('2A task delete -owner (I8)', 'admin', null, format('delete from public.tasks where id = %s', t1), 'no_delete');
    perform pg_temp.chk('2A task truncate -owner (I8)', 'admin', null, 'truncate public.tasks cascade', 'no_delete');
    perform pg_temp.chk('2A owner status change without actor', 'admin', null, format($q$update public.tasks set status = 'ready_for_review' where id = %s$q$, t4), 'no_actor');
    perform pg_temp.chk('2A owner changes job of a task', 'admin', null, format($q$update public.tasks set job_number = %s where id = %s$q$, j2, t4), 'immutable_field');
    -- مسار المالك بهوية (N7): التعديل المباشر يمرّ بالخريطة نفسها ويكتب سطره
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', p1, 'role', 'authenticated')::text, true);
      lb := (select count(*) from public.task_log where task_id = t4);
      update public.tasks set status = 'ready_for_review' where id = t4;
      la := (select count(*) from public.task_log where task_id = t4);
      perform pg_temp.rec('2A owner direct update = one log line (N7)', la = lb + 1
        and (select from_status || '>' || to_status || '/' || by_user || '/' || by_name from public.task_log where task_id = t4 order by id desc limit 1)
          = 'in_progress>ready_for_review/' || p1 || '/الشريك الأول', format('%s->%s', lb, la));
      begin
        update public.tasks set status = 'new' where id = t4;
        perform pg_temp.rec('2A owner direct invalid jump refused', false, 'succeeded');
      exception when others then
        get stacked diagnostics st = returned_sqlstate, msg = message_text;
        perform pg_temp.rec('2A owner direct invalid jump refused', msg = 'invalid_transition', msg);
      end;
      begin
        update public.tasks set status = 'in_progress' where id = t4;
        perform pg_temp.rec('2A owner direct return without note refused', false, 'succeeded');
      exception when others then
        get stacked diagnostics st = returned_sqlstate, msg = message_text;
        perform pg_temp.rec('2A owner direct return without note refused', msg = 'note_required', msg);
      end;
      perform set_config('request.jwt.claims', '', true);
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform set_config('request.jwt.claims', '', true);
      perform pg_temp.rec('2A owner direct update = one log line (N7)', false, st || ': ' || msg);
    end;
    perform pg_temp.rec('2A every task has its creation line',
      (select count(*) from public.tasks t where job_number = j1 and not exists
        (select 1 from public.task_log l where l.task_id = t.id and l.kind = 'create' and l.to_status = 'new' and l.to_assignee is not null)) = 0
      and (select count(*) from public.tasks where job_number = j1) = 5, 'create lines');

    -- ---------- D27-2: إلغاء الشغلة يلغي مهامها المفتوحة؛ التسليم مرفوض مع مهمة مفتوحة ----------
    begin
      t6 := pg_temp.val('partner', p1, format($q$select public.create_task(%s, 'مهمة ستلغى 1', %L)$q$, j2, emp))::bigint;
      t7 := pg_temp.val('partner', p1, format($q$select public.create_task(%s, 'مهمة ستلغى 2', %L)$q$, j2, e2))::bigint;
      perform pg_temp.val('employee', e2, format($q$select public.set_task_status(%s,'new','in_progress')$q$, t7));
      perform pg_temp.val('partner', p1, format($q$select public.cancel_job(%s,'intake','العميل انسحب')$q$, j2));
      perform pg_temp.rec('D27 cancelling the job cancels its open tasks, with the job reason',
        (select count(*) from public.tasks where job_number = j2 and status = 'cancelled') = 2
        and (select count(*) from public.task_log where task_id in (t6, t7) and to_status = 'cancelled' and note like '%العميل انسحب%' and by_user = p1) = 2, 'cascade');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('D27 cancelling the job cancels its open tasks, with the job reason', false, st || ': ' || msg);
    end;
    perform pg_temp.chk('2A task on a cancelled job', 'partner', p1, format($q$select public.create_task(%s, 'x', %L)$q$, j2, emp), 'job_closed');
    begin
      t8 := pg_temp.val('partner', p1, format($q$select public.create_task(%s, 'مهمة قبل التسليم', %L)$q$, j3, emp))::bigint;
      for i in 1..5 loop
        perform pg_temp.val('partner', p1, format('select public.move_job(%s, %L, %L)', j3, stages[i], stages[i+1]));
      end loop;
      perform pg_temp.rec('D27 setup: job at «execution» with an open task', (select stage::text from public.jobs where job_number = j3) = 'execution', 'setup');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('D27 setup: job at «execution» with an open task', false, st || ': ' || msg);
    end;
    perform pg_temp.chk('D27 deliver with an open task', 'partner', p1, format($q$select public.move_job(%s,'execution','delivered')$q$, j3), 'open_tasks');
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', p1, 'role', 'authenticated')::text, true);
      update public.jobs set stage = 'delivered' where job_number = j3;
      perform set_config('request.jwt.claims', '', true);
      perform pg_temp.rec('D27 owner direct deliver with an open task refused', false, 'succeeded');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform set_config('request.jwt.claims', '', true);
      perform pg_temp.rec('D27 owner direct deliver with an open task refused', msg = 'open_tasks', msg);
    end;
    perform pg_temp.chk('D27 task done', 'employee', emp, format($q$select public.set_task_status(%s,'new','in_progress')$q$, t8), 'ok');
    perform pg_temp.chk('D27 task done 2', 'employee', emp, format($q$select public.set_task_status(%s,'in_progress','ready_for_review')$q$, t8), 'ok');
    perform pg_temp.chk('D27 task done 3', 'partner', p1, format($q$select public.set_task_status(%s,'ready_for_review','done')$q$, t8), 'ok');
    perform pg_temp.chk('D27 deliver once all tasks are final', 'partner', p1, format($q$select public.move_job(%s,'execution','delivered')$q$, j3), 'ok');
    perform pg_temp.chk('2A task on a delivered job', 'manager', mgr, format($q$select public.create_task(%s, 'x', %L)$q$, j3, emp), 'job_closed');

    -- ---------- 2ب: دوال سياسات Storage تُختبر بهوياتها ----------
    perform pg_temp.rec('2B can_get_task_object by identity',
      pg_temp.v('employee', e2, format('select public.can_get_task_object(%L)', path2)) = 'true'
      and pg_temp.v('employee', emp, format('select public.can_get_task_object(%L)', path2)) = 'false'
      and pg_temp.v('norole', nr, format('select public.can_get_task_object(%L)', path2)) = 'false'
      and pg_temp.v('partner', p1, format('select public.can_get_task_object(%L)', 'nothing/here.pdf')) = 'false', 'get');
    perform pg_temp.rec('2B can_put_task_object only for the reserver, once',
      pg_temp.v('employee', emp, format('select public.can_put_task_object(%L)', path1)) = 'false'
      and pg_temp.v('manager', mgr, format('select public.can_put_task_object(%L)', 't1/x.pdf')) = 'false', 'put');
    perform pg_temp.chk('2B storage helpers -anon', 'anon', null, format('select public.can_get_task_object(%L)', path2), '42501');

    -- ---------- 2د: حسابات الموظفين — الزرع بالدور، والمدير له دور manager ----------
    declare
      s4 uuid := gen_random_uuid(); s5 uuid := gen_random_uuid();
    begin
      execute format('insert into private.partner_seed(email_sha256, display_name, role) values (%L, %L, %L::public.app_role), (%L, %L, %L::public.app_role)',
        encode(sha256(convert_to('staff.test.manager@wasmmedia.net', 'UTF8')), 'hex'), 'مدير مزروع', 'manager',
        encode(sha256(convert_to('staff.test.employee@wasmmedia.net', 'UTF8')), 'hex'), 'موظف مزروع', 'employee');
      insert into auth.users(id, email, aud, role) values
        (s4, 'staff.test.manager@wasmmedia.net', 'authenticated', 'authenticated'), (s5, 'Staff.Test.Employee@wasmmedia.net', 'authenticated', 'authenticated');
      perform pg_temp.rec('2D seed with role: manager + employee',
        (select role::text from public.user_roles where user_id = s4) = 'manager'
        and (select display_name from public.people where user_id = s4) = 'مدير مزروع'
        and (select role::text from public.user_roles where user_id = s5) = 'employee', 'seed roles');
      perform pg_temp.rec('2D existing partner seed rows stay partners',
        (select count(*) from private.partner_seed where role = 'partner') >= 2
        and (select count(*) from private.partner_seed where email_sha256 in
          ('f77ecc76e2ecabe657977672b2b6ad5dda5f5ca79ae25414c31f45e1a620a6c3', '2b66dd9dfc952a6cffe9a718ce623a11ddd1a2ffab92209c3e59b7c743115755') and role = 'partner') = 2, 'partners');
      perform pg_temp.rec('2D the four staff are seeded (D29)',
        (select string_agg(display_name || ':' || role, ',' order by display_name) from private.partner_seed where email_sha256 in (
          encode(sha256(convert_to('staff.ahd.jabali@wasmmedia.net', 'UTF8')), 'hex'),
          encode(sha256(convert_to('staff.eman.qudwa@wasmmedia.net', 'UTF8')), 'hex'),
          encode(sha256(convert_to('staff.reem.qattanani@wasmmedia.net', 'UTF8')), 'hex'),
          encode(sha256(convert_to('staff.ahmad.ashi@wasmmedia.net', 'UTF8')), 'hex')))
        = 'أحمد العشي:employee,إيمان القدوة:employee,ريم القطناني:employee,عهد الجبالي:manager', 'staff');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('2D seed with role: manager + employee', false, st || ': ' || msg);
    end;

    -- ---------- I4 / I5 / I8 على الجديد ----------
    begin
      perform pg_temp.rec('S2 I4 RLS on tasks/task_log/task_files',
        (select bool_and(relrowsecurity) from pg_class where oid in ('public.tasks'::regclass, 'public.task_log'::regclass, 'public.task_files'::regclass)), 'rls');
      perform pg_temp.rec('S2 I8 no delete/truncate/update grants on the new tables',
        not exists (select 1 from unnest(array['public.tasks','public.task_log','public.task_files']) tb, unnest(array['anon','authenticated','service_role']) rl
          where has_table_privilege(rl, tb, 'delete') or has_table_privilege(rl, tb, 'truncate') or has_table_privilege(rl, tb, 'update') or has_table_privilege(rl, tb, 'insert')), 'grants');
      perform pg_temp.rec('S2 I4 storage: RLS on, only select+insert policies for the bucket, no public bucket',
        (select relrowsecurity from pg_class where oid = 'storage.objects'::regclass)
        and (select count(*) from storage.buckets where public) = 0
        and (select string_agg(polcmd::text, '' order by polcmd) from pg_policy where polrelid = 'storage.objects'::regclass
             and coalesce(pg_get_expr(polqual, polrelid), '') || coalesce(pg_get_expr(polwithcheck, polrelid), '') like '%task-files%') = 'ar', 'storage');
      perform pg_temp.rec('S2 I4 storage policies apply to authenticated only',
        not exists (select 1 from pg_policy where polrelid = 'storage.objects'::regclass
          and (coalesce(pg_get_expr(polqual, polrelid), '') || coalesce(pg_get_expr(polwithcheck, polrelid), '')) like '%task-files%'
          and polroles <> array[(select oid from pg_roles where rolname = 'authenticated')]), 'roles');
    exception when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      perform pg_temp.rec('S2 I4 invariants', false, st || ': ' || msg);
    end;
  end;
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform pg_temp.rec('S2 block aborted', false, st || ': ' || msg);
  end;

  -- ينهي كل شيء بالتراجع ويحمل النتائج
  -- سطر ملخّص (يقرؤه الإنسان على التطوير) ثم JSON كامل بعد «##» (للمقارنة الآلية)
  raise exception 'WASM_TEST_RESULTS % ## %',
    (select count(*) || ' total, ' || count(*) filter (where ok) || ' ok, FAILED: ' || coalesce(string_agg(id || ' => ' || detail, ' | ') filter (where not ok), 'none') from t_results),
    (select jsonb_agg(jsonb_build_object('id', r.id, 'ok', r.ok, 'd', r.detail) order by r.n) from t_results r);
end $t$;
