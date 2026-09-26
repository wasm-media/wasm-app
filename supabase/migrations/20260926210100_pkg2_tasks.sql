-- الحزمة 2 — الشريحة 2أ (المهام) و2ج (المدير) و2د (زرع الموظفين بالدور).
-- المبدأ نفسه في الشريحة 1: لا كتابة مباشرة من التطبيق؛ كل كتابة عبر دالة تفحص الدور، والقواعد تُفرض في
-- حرّاس القاعدة (triggers) فتسري حتى على المالك (N7)، وكل تغيير يكتب سطر سجل في المعاملة نفسها (I9).
-- الموظف لا يقرأ jobs: رقم الشغلة وعنوانها منسوخان في صف المهمة (I1، I2 — D27-1).

-- ===== الدور: من جدول الأدوار وحده =====
create function private.role_of(p_uid uuid) returns public.app_role
language sql stable security definer set search_path = '' as $$
  select r.role from public.user_roles r where r.user_id = p_uid
$$;
revoke execute on function private.role_of(uuid) from public;

create function public.is_manager() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles r where r.user_id = auth.uid() and r.role = 'manager')
$$;

-- الدور والاسم للمستخدم الحالي فقط (الواجهة تختار شاشتها منه). بلا دور = لا صف.
create function public.whoami() returns table (role text, display_name text)
language sql stable security definer set search_path = '' as $$
  select r.role::text, p.display_name from public.user_roles r left join public.people p on p.user_id = r.user_id
   where r.user_id = auth.uid()
$$;

-- ===== D28: المدير يقرأ الشغلات والأسماء — لا ملاحظات الشغلة ولا سجل مراحلها (قد يحويان سعرًا — I1) =====
create policy jobs_manager_read on public.jobs for select to authenticated using (public.is_manager());
create policy people_manager_read on public.people for select to authenticated using (public.is_manager());

-- ===== 2د: الزرع بالدور (الحسابات الموجودة شريكان؛ الموظفون بلا بريد حقيقي — D29) =====
alter table private.partner_seed add column role public.app_role not null default 'partner';
create or replace function private.seed_partner() returns trigger
language plpgsql security definer set search_path = '' as $$
declare nm text; rl public.app_role;
begin
  select s.display_name, s.role into nm, rl from private.partner_seed s
   where s.email_sha256 = pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(pg_catalog.lower(pg_catalog.btrim(new.email)), 'UTF8')), 'hex');
  if nm is not null then
    insert into public.user_roles(user_id, role) values (new.id, rl) on conflict (user_id) do nothing;
    insert into public.people(user_id, display_name) values (new.id, nm) on conflict (user_id) do nothing;
  end if;
  return new;
end $$;
revoke execute on function private.seed_partner() from public, anon, authenticated, service_role;

-- ===== المهام =====
create type public.task_status as enum ('new', 'in_progress', 'ready_for_review', 'done', 'cancelled');
create type public.task_log_kind as enum ('create', 'status', 'assign', 'edit');

create table public.tasks (
  id          bigint generated always as identity primary key,
  job_number  integer not null references public.jobs(job_number) on delete restrict,
  job_title   text not null,                       -- منسوخ من الشغلة عند الإنشاء (عنوانها لا يتغير بعد الفتح)
  title       text not null check (not private.is_blank(title)),
  description text check (description is null or not private.is_blank(description)),
  due_date    date,
  assignee    uuid not null references auth.users(id) on delete restrict,
  status      public.task_status not null default 'new',
  created_by  uuid not null references auth.users(id) on delete restrict,
  created_at  timestamptz not null default now()
);
create index tasks_assignee_idx on public.tasks (assignee);
create index tasks_job_idx on public.tasks (job_number);
alter table public.tasks enable row level security;

create table public.task_log (
  id            bigint generated always as identity primary key,
  task_id       bigint not null references public.tasks(id) on delete restrict,
  kind          public.task_log_kind not null,
  from_status   public.task_status,
  to_status     public.task_status,
  from_assignee uuid references auth.users(id) on delete restrict,
  to_assignee   uuid references auth.users(id) on delete restrict,
  note          text,
  by_user       uuid not null references auth.users(id) on delete restrict,
  by_name       text not null,                     -- اسم الفاعل لحظتها: الموظف يقرأ سجل مهمته ولا يقرأ جدول الأسماء
  at            timestamptz not null default clock_timestamp()
);
create index task_log_task_idx on public.task_log (task_id, id);
alter table public.task_log enable row level security;

revoke all on public.tasks, public.task_log from public, anon, authenticated, service_role;
revoke all on all sequences in schema public from public, anon, authenticated, service_role;
grant select on public.tasks, public.task_log to authenticated;

-- الشريك والمدير: كل المهام. غيرهما: المهام المكلَّف بها الآن فقط (سحبها يخفيها فورًا — I2)
create policy tasks_read on public.tasks for select to authenticated
  using (public.is_partner() or public.is_manager() or assignee = auth.uid());
-- السجل يتبع المهمة: الاستعلام الفرعي يخضع لسياسة tasks نفسها بهوية القارئ
create policy task_log_read on public.task_log for select to authenticated
  using (exists (select 1 from public.tasks t where t.id = task_id));

-- ===== حارس المهام: الخريطة والهوية والحقول الثابتة — يسري على المالك أيضًا =====
create function private.tasks_guard() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_stage public.job_stage;
  v_title text;
  v_note  text := current_setting('wasm.task_note', true);
begin
  if tg_op = 'INSERT' then
    if v_uid is null then raise exception 'no_actor'; end if;
    select j.stage, j.title into v_stage, v_title from public.jobs j where j.job_number = new.job_number;
    if not found then raise exception 'job_not_found'; end if;
    if v_stage in ('delivered', 'cancelled') then raise exception 'job_closed'; end if;
    if new.status <> 'new' then raise exception 'invalid_transition'; end if;
    if new.created_by is distinct from v_uid then raise exception 'actor_mismatch'; end if;
    if private.role_of(new.assignee) is null then raise exception 'invalid_assignee'; end if;
    new.job_title := v_title;
    new.created_at := now();
    return new;
  end if;

  if (new.id, new.job_number, new.job_title, new.created_by, new.created_at)
     is distinct from (old.id, old.job_number, old.job_title, old.created_by, old.created_at) then
    raise exception 'immutable_field';
  end if;
  if (new.status, new.assignee, new.title, new.description, new.due_date)
     is not distinct from (old.status, old.assignee, old.title, old.description, old.due_date) then
    return new;
  end if;
  if v_uid is null then raise exception 'no_actor'; end if;
  if old.status in ('done', 'cancelled') then raise exception 'final_status'; end if;

  if new.status <> old.status then
    if new.status = 'cancelled' then
      if private.is_blank(v_note) then raise exception 'reason_required'; end if;
    elsif old.status = 'ready_for_review' and new.status = 'in_progress' then
      if private.is_blank(v_note) then raise exception 'note_required'; end if;
    elsif not ((old.status = 'new' and new.status = 'in_progress')
            or (old.status = 'in_progress' and new.status = 'ready_for_review')
            or (old.status = 'ready_for_review' and new.status = 'done')) then
      raise exception 'invalid_transition';
    end if;
  end if;
  if new.assignee <> old.assignee and private.role_of(new.assignee) is null then raise exception 'invalid_assignee'; end if;
  return new;
end $$;
create trigger tasks_guard before insert or update on public.tasks for each row execute function private.tasks_guard();

-- السجل: سطر لكل نوع تغيير (إنشاء، حالة، تكليف، تعديل)، بعد نجاح الحارس
create function private.tasks_log() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_name text;
  v_note text := current_setting('wasm.task_note', true);
begin
  select p.display_name into v_name from public.people p where p.user_id = v_uid;
  v_name := coalesce(v_name, 'مستخدم غير معروف');
  if tg_op = 'INSERT' then
    insert into public.task_log (task_id, kind, to_status, to_assignee, by_user, by_name)
    values (new.id, 'create', new.status, new.assignee, v_uid, v_name);
    return null;
  end if;
  if new.status <> old.status then
    insert into public.task_log (task_id, kind, from_status, to_status, note, by_user, by_name)
    values (new.id, 'status', old.status, new.status,
            case when new.status = 'cancelled' or old.status = 'ready_for_review' and new.status = 'in_progress' then btrim(v_note) end,
            v_uid, v_name);
  end if;
  if new.assignee <> old.assignee then
    insert into public.task_log (task_id, kind, from_assignee, to_assignee, by_user, by_name)
    values (new.id, 'assign', old.assignee, new.assignee, v_uid, v_name);
  end if;
  if (new.title, new.description, new.due_date) is distinct from (old.title, old.description, old.due_date) then
    insert into public.task_log (task_id, kind, by_user, by_name) values (new.id, 'edit', v_uid, v_name);
  end if;
  return null;
end $$;
create trigger tasks_log after insert or update on public.tasks for each row execute function private.tasks_log();

-- السجل لا يُعدَّل، ولا يُكتب إلا من حارس المهام
create function private.task_log_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then raise exception 'log_immutable'; end if;
  if pg_trigger_depth() < 2 then raise exception 'log_direct_insert'; end if;
  return new;
end $$;
create trigger task_log_guard before insert or update on public.task_log for each row execute function private.task_log_guard();

-- I8
create trigger tasks_no_delete before delete on public.tasks for each row execute function private.forbid_delete();
create trigger task_log_no_delete before delete on public.task_log for each row execute function private.forbid_delete();
create trigger tasks_no_truncate before truncate on public.tasks for each statement execute function private.forbid_delete();
create trigger task_log_no_truncate before truncate on public.task_log for each statement execute function private.forbid_delete();

-- ===== D27-2: الشغلة ومهامها =====
-- التسليم مرفوض ما دامت مهمة غير نهائية (يسري على move_job وعلى تعديل المالك المباشر)
create function private.jobs_open_tasks() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.stage = 'delivered' and old.stage <> 'delivered'
     and exists (select 1 from public.tasks t where t.job_number = new.job_number and t.status not in ('done', 'cancelled')) then
    raise exception 'open_tasks';
  end if;
  return new;
end $$;
create trigger jobs_open_tasks before update on public.jobs for each row execute function private.jobs_open_tasks();

-- إلغاء الشغلة يلغي مهامها المفتوحة بسبب الإلغاء نفسه (سطر سجل لكل مهمة بهوية من ألغى)
create function private.jobs_cancel_tasks() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.stage = 'cancelled' and old.stage <> 'cancelled' then
    perform set_config('wasm.task_note', 'ألغيت الشغلة: ' || btrim(coalesce(current_setting('wasm.cancel_reason', true), '')), true);
    update public.tasks set status = 'cancelled' where job_number = new.job_number and status not in ('done', 'cancelled');
    perform set_config('wasm.task_note', '', true);
  end if;
  return null;
end $$;
create trigger jobs_cancel_tasks after update on public.jobs for each row execute function private.jobs_cancel_tasks();

revoke execute on function private.tasks_guard(), private.tasks_log(), private.task_log_guard(),
  private.jobs_open_tasks(), private.jobs_cancel_tasks() from public;

-- ===== الدوال =====
-- المكلَّف: له دور؛ والمدير لا يكلّف شريكًا (D28)
create function private.check_assignee(p_caller public.app_role, p_assignee uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
declare r public.app_role := private.role_of(p_assignee);
begin
  if r is null or (p_caller = 'manager' and r = 'partner') then raise exception 'invalid_assignee'; end if;
end $$;
revoke execute on function private.check_assignee(public.app_role, uuid) from public;

create function public.assignable_people() returns table (user_id uuid, display_name text, role text)
language plpgsql stable security definer set search_path = '' as $$
declare v_role public.app_role := private.role_of(auth.uid());
begin
  if v_role is null or v_role not in ('partner', 'manager') then raise exception 'not_allowed'; end if;
  return query
    select r.user_id, coalesce(p.display_name, 'بلا اسم'), r.role::text
      from public.user_roles r left join public.people p on p.user_id = r.user_id
     where v_role = 'partner' or r.role in ('employee', 'manager')
     order by r.role, p.display_name;
end $$;

create function public.create_task(p_job integer, p_title text, p_assignee uuid, p_due date default null, p_description text default null)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_role  public.app_role := private.role_of(auth.uid());
  v_stage public.job_stage;
  v_id    bigint;
begin
  if v_role is null or v_role not in ('partner', 'manager') then raise exception 'not_allowed'; end if;
  if private.is_blank(p_title) then raise exception 'title_required'; end if;
  select stage into v_stage from public.jobs where job_number = p_job for share;   -- لا يسبقه إلغاء أو تسليم متزامن
  if not found then raise exception 'job_not_found'; end if;
  if v_stage in ('delivered', 'cancelled') then raise exception 'job_closed'; end if;
  perform private.check_assignee(v_role, p_assignee);
  insert into public.tasks (job_number, job_title, title, description, due_date, assignee, created_by)
  values (p_job, '', btrim(p_title), case when private.is_blank(p_description) then null else btrim(p_description) end,
          p_due, p_assignee, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- يقفل المهمة ويعيدها إن كان للمستخدم أن يراها (غيرها = غير موجودة — لا يكشف وجود مهمة غيره)
create function private.lock_task(p_task bigint, p_role public.app_role) returns public.tasks
language plpgsql security definer set search_path = '' as $$
declare t public.tasks;
begin
  select * into t from public.tasks where id = p_task for update;
  if not found or not (p_role in ('partner', 'manager') or t.assignee = auth.uid()) then raise exception 'task_not_found'; end if;
  return t;
end $$;
revoke execute on function private.lock_task(bigint, public.app_role) from public;

create function public.edit_task(p_task bigint, p_title text, p_due date, p_description text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_role public.app_role := private.role_of(auth.uid()); t public.tasks;
begin
  if v_role is null or v_role not in ('partner', 'manager') then raise exception 'not_allowed'; end if;
  t := private.lock_task(p_task, v_role);
  if t.status in ('done', 'cancelled') then raise exception 'final_status'; end if;
  if private.is_blank(p_title) then raise exception 'title_required'; end if;
  update public.tasks set title = btrim(p_title), due_date = p_due,
         description = case when private.is_blank(p_description) then null else btrim(p_description) end
   where id = p_task;
end $$;

create function public.assign_task(p_task bigint, p_assignee uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_role public.app_role := private.role_of(auth.uid()); t public.tasks;
begin
  if v_role is null or v_role not in ('partner', 'manager') then raise exception 'not_allowed'; end if;
  t := private.lock_task(p_task, v_role);
  if t.status in ('done', 'cancelled') then raise exception 'final_status'; end if;
  perform private.check_assignee(v_role, p_assignee);
  if t.assignee = p_assignee then raise exception 'invalid_assignee'; end if;
  update public.tasks set assignee = p_assignee where id = p_task;
end $$;

create function public.set_task_status(p_task bigint, p_from text, p_to text, p_note text default null) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_role public.app_role := private.role_of(v_uid);
  t      public.tasks;
  v_ret  boolean;
begin
  if v_role is null then raise exception 'not_allowed'; end if;
  if p_from is null or p_to is null
     or not (p_from = any (enum_range(null::public.task_status)::text[]))
     or not (p_to   = any (enum_range(null::public.task_status)::text[])) then
    raise exception 'invalid_status';
  end if;
  t := private.lock_task(p_task, v_role);
  if t.status in ('done', 'cancelled') then raise exception 'final_status'; end if;
  if t.status::text <> p_from then raise exception 'stale_status'; end if;
  v_ret := p_from = 'ready_for_review' and p_to = 'in_progress';
  if (p_from = 'new' and p_to = 'in_progress') or (p_from = 'in_progress' and p_to = 'ready_for_review') then
    if t.assignee <> v_uid then raise exception 'not_allowed'; end if;             -- المكلَّف وحده يبدأ ويسلّم
    if not private.is_blank(p_note) then raise exception 'invalid_transition'; end if;
  elsif p_from = 'ready_for_review' and p_to in ('done', 'in_progress') then
    if v_role not in ('partner', 'manager') then raise exception 'not_allowed'; end if;
    if v_role = 'manager' and t.assignee = v_uid then raise exception 'own_review'; end if;
    if v_ret and private.is_blank(p_note) then raise exception 'note_required'; end if;
    if not v_ret and not private.is_blank(p_note) then raise exception 'invalid_transition'; end if;
  else
    raise exception 'invalid_transition';                                          -- «ملغاة» لها دالتها
  end if;
  perform set_config('wasm.task_note', coalesce(p_note, ''), true);
  update public.tasks set status = p_to::public.task_status where id = p_task;     -- الحارس يفحص والسجل يُكتب
  perform set_config('wasm.task_note', '', true);
  return p_to;
end $$;

create function public.cancel_task(p_task bigint, p_from text, p_reason text) returns text
language plpgsql security definer set search_path = '' as $$
declare v_role public.app_role := private.role_of(auth.uid()); t public.tasks;
begin
  if v_role is null or v_role not in ('partner', 'manager') then raise exception 'not_allowed'; end if;
  t := private.lock_task(p_task, v_role);
  if t.status in ('done', 'cancelled') then raise exception 'final_status'; end if;
  if p_from is null or t.status::text <> p_from then raise exception 'stale_status'; end if;
  if private.is_blank(p_reason) then raise exception 'reason_required'; end if;
  perform set_config('wasm.task_note', p_reason, true);
  update public.tasks set status = 'cancelled' where id = p_task;
  perform set_config('wasm.task_note', '', true);
  return 'cancelled';
end $$;

revoke execute on function public.is_manager(), public.whoami(), public.assignable_people(),
  public.create_task(integer, text, uuid, date, text), public.edit_task(bigint, text, date, text),
  public.assign_task(bigint, uuid), public.set_task_status(bigint, text, text, text), public.cancel_task(bigint, text, text)
  from public, anon;
grant execute on function public.is_manager(), public.whoami(), public.assignable_people(),
  public.create_task(integer, text, uuid, date, text), public.edit_task(bigint, text, date, text),
  public.assign_task(bigint, uuid), public.set_task_status(bigint, text, text, text), public.cancel_task(bigint, text, text)
  to authenticated;
