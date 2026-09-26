-- الشريحة 1أ — الشغلة ومراحلها (السيرفر)
-- المبدأ: التطبيق لا يكتب في أي جدول مباشرة. كل كتابة تمر من دالة تفحص الدور والحالة،
-- وتكتب سطر السجل في المعاملة نفسها. القراءة للشريكين فقط. لا حذف لأي دور.

-- ===== الأنواع =====
create type public.app_role as enum ('partner', 'employee');
create type public.job_type as enum ('design', 'print', 'video', 'event', 'other');
create type public.job_stage as enum ('intake', 'quote', 'client_approval', 'design', 'review', 'execution', 'delivered', 'cancelled');

-- ===== الأدوار: تُزرع بترحيل فقط، ولا يقرؤها ولا يكتبها أي دور من التطبيق =====
create table public.user_roles (
  user_id    uuid primary key references auth.users(id) on delete restrict,
  role       public.app_role not null,
  created_at timestamptz not null default now()
);
alter table public.user_roles enable row level security;

-- ===== عدّاد الأرقام: صف واحد، يُقفل عند كل فتح ← أرقام متتالية بلا فجوات (الفشل يرجع الرقم) =====
create table public.job_counter (
  singleton   boolean primary key default true check (singleton),
  last_number integer not null check (last_number >= 9000)
);
alter table public.job_counter enable row level security;
insert into public.job_counter (singleton, last_number) values (true, 9000);

-- ===== الشغلات =====
create table public.jobs (
  job_number integer primary key check (job_number >= 9001),
  client     text not null check (length(btrim(client)) > 0),
  title      text not null check (length(btrim(title)) > 0),
  job_type   public.job_type not null,
  due_date   date,
  stage      public.job_stage not null default 'intake',
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
alter table public.jobs enable row level security;

-- الملاحظات منفصلة: للشريكين فقط، ولن تُفتح للموظف حتى لو فُتحت له الشغلة لاحقًا (I1)
create table public.job_notes (
  job_number integer primary key references public.jobs(job_number) on delete restrict,
  body       text not null check (length(btrim(body)) > 0)
);
alter table public.job_notes enable row level security;

-- سجل المراحل: لا يكتبه إلا move_job وcancel_job، و«من» و«متى» من السيرفر
create table public.job_stage_log (
  id         bigint generated always as identity primary key,
  job_number integer not null references public.jobs(job_number) on delete restrict,
  from_stage public.job_stage not null,
  to_stage   public.job_stage not null,
  moved_by   uuid not null references auth.users(id) on delete restrict,
  moved_at   timestamptz not null default clock_timestamp(),
  reason     text
);
create index job_stage_log_job_idx on public.job_stage_log (job_number, id);
alter table public.job_stage_log enable row level security;

-- ===== الصلاحيات: إلغاء الافتراضي المتساهل في Supabase ثم منح القراءة فقط =====
revoke all on public.user_roles, public.job_counter, public.jobs, public.job_notes, public.job_stage_log
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema public from public, anon, authenticated, service_role;
grant select on public.jobs, public.job_notes, public.job_stage_log to authenticated;

-- ===== هل المستخدم الحالي شريك؟ (من جدول الأدوار وحده؛ user_metadata وapp_metadata لا تُقرأ) =====
create function public.is_partner() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles r where r.user_id = auth.uid() and r.role = 'partner')
$$;

create policy jobs_partner_read on public.jobs for select to authenticated using (public.is_partner());
create policy notes_partner_read on public.job_notes for select to authenticated using (public.is_partner());
create policy log_partner_read on public.job_stage_log for select to authenticated using (public.is_partner());

-- ===== فتح شغلة =====
create function public.create_job(p_client text, p_title text, p_type text, p_due date default null, p_notes text default null)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_number integer;
begin
  if not public.is_partner() then raise exception 'not_partner'; end if;
  if p_client is null or length(btrim(p_client)) = 0 then raise exception 'client_required'; end if;
  if p_title is null or length(btrim(p_title)) = 0 then raise exception 'title_required'; end if;
  if p_type is null or not (p_type = any (enum_range(null::public.job_type)::text[])) then raise exception 'invalid_type'; end if;

  update public.job_counter set last_number = last_number + 1 where singleton returning last_number into v_number;

  insert into public.jobs (job_number, client, title, job_type, due_date, stage, created_by)
  values (v_number, btrim(p_client), btrim(p_title), p_type::public.job_type, p_due, 'intake', auth.uid());

  if p_notes is not null and length(btrim(p_notes)) > 0 then
    insert into public.job_notes (job_number, body) values (v_number, p_notes);
  end if;
  return v_number;
end $$;

-- ===== نقل خطوة للأمام، أو للخلف ما دامت بين «عرض سعر» و«تنفيذ» =====
create function public.move_job(p_job integer, p_from text, p_to text)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_order text[] := array['intake','quote','client_approval','design','review','execution','delivered'];
  v_cur   public.job_stage;
  i int; j int;
begin
  if not public.is_partner() then raise exception 'not_partner'; end if;
  if p_from is null or p_to is null
     or not (p_from = any (enum_range(null::public.job_stage)::text[]))
     or not (p_to   = any (enum_range(null::public.job_stage)::text[])) then
    raise exception 'invalid_stage';
  end if;

  select stage into v_cur from public.jobs where job_number = p_job for update;
  if not found then raise exception 'job_not_found'; end if;
  if v_cur in ('delivered', 'cancelled') then raise exception 'final_stage'; end if;
  if v_cur::text <> p_from then raise exception 'stale_stage'; end if;

  i := array_position(v_order, p_from);
  j := array_position(v_order, p_to);
  if j is null then raise exception 'invalid_transition'; end if;          -- «ملغاة» لها دالتها
  if not (j = i + 1 or (j = i - 1 and i between 2 and 6)) then
    raise exception 'invalid_transition';
  end if;

  update public.jobs set stage = p_to::public.job_stage where job_number = p_job;
  insert into public.job_stage_log (job_number, from_stage, to_stage, moved_by)
  values (p_job, v_cur, p_to::public.job_stage, auth.uid());
  return p_to;
end $$;

-- ===== إلغاء من أي مرحلة قبل «تسليم»، بسبب مكتوب =====
create function public.cancel_job(p_job integer, p_from text, p_reason text)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_cur public.job_stage;
begin
  if not public.is_partner() then raise exception 'not_partner'; end if;
  if p_from is null or not (p_from = any (enum_range(null::public.job_stage)::text[])) then raise exception 'invalid_stage'; end if;

  select stage into v_cur from public.jobs where job_number = p_job for update;
  if not found then raise exception 'job_not_found'; end if;
  if v_cur in ('delivered', 'cancelled') then raise exception 'final_stage'; end if;
  if v_cur::text <> p_from then raise exception 'stale_stage'; end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then raise exception 'reason_required'; end if;

  update public.jobs set stage = 'cancelled' where job_number = p_job;
  insert into public.job_stage_log (job_number, from_stage, to_stage, moved_by, reason)
  values (p_job, v_cur, 'cancelled', auth.uid(), btrim(p_reason));
  return 'cancelled';
end $$;

-- ===== الدوال: لا تنفيذ لغير المسجّل؛ المسجّل ينفّذ والدالة نفسها تفحص الدور =====
revoke execute on function public.is_partner(), public.create_job(text, text, text, date, text),
  public.move_job(integer, text, text), public.cancel_job(integer, text, text)
  from public, anon;
grant execute on function public.is_partner(), public.create_job(text, text, text, date, text),
  public.move_job(integer, text, text), public.cancel_job(integer, text, text)
  to authenticated;

-- ===== I8: لا حذف ولا تفريغ، حتى من الأدمن =====
create function public.forbid_delete() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'no_delete';
end $$;
revoke execute on function public.forbid_delete() from public, anon, authenticated;

create trigger jobs_no_delete before delete on public.jobs for each row execute function public.forbid_delete();
create trigger notes_no_delete before delete on public.job_notes for each row execute function public.forbid_delete();
create trigger log_no_delete before delete on public.job_stage_log for each row execute function public.forbid_delete();
create trigger counter_no_delete before delete on public.job_counter for each row execute function public.forbid_delete();
create trigger jobs_no_truncate before truncate on public.jobs for each statement execute function public.forbid_delete();
create trigger notes_no_truncate before truncate on public.job_notes for each statement execute function public.forbid_delete();
create trigger log_no_truncate before truncate on public.job_stage_log for each statement execute function public.forbid_delete();
create trigger counter_no_truncate before truncate on public.job_counter for each statement execute function public.forbid_delete();
