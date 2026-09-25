-- الشريحة 1أ — تصحيحات الجولة 1 من المراجعة المستقلة (B1، B2، B4، B6)
-- B1: الفراغ = أي مسافة أو محرف تنسيق Unicode، في الدوال وفي قيود الجداول.
-- B2: القواعد تُفرض في القاعدة نفسها (triggers) لا في الدوال وحدها. حتى المالك (محرر SQL أو لوحة Supabase)
--     لا يغيّر مرحلة بلا هوية ولا بلا سطر سجل، ولا يعدّل حقلًا بعد الفتح، ولا يعدّل السجل، ولا يقفز بالعدّاد.
-- B4: أسماء العرض (people) تُزرع بالترحيل ويقرؤها الشريكان فقط.
-- B6: الدوال الداخلية تنتقل إلى مخطط private الذي لا يصله أي دور من التطبيق.

-- ===== مخطط داخلي غير مكشوف =====
create schema private;
revoke all on schema private from public, anon, authenticated, service_role;

-- فراغ؟ null، أو لا شيء غير مسافات ومحارف تحكم وتنسيق (tab، أسطر، NBSP، ZWSP/ZWJ، LRM/RLM، ALM، مسافات عريضة، BOM…)
create function private.is_blank(t text) returns boolean
language sql immutable set search_path = '' as $$
  select t is null or t ~ '^[\s\u0001-\u001F\u007F-\u009F ­؜ᅟᅠ ᠎ -‏ -  -⁤⁦-⁯　ㅤ﻿ﾠ]*$'
$$;
revoke execute on function private.is_blank(text) from public;

-- ===== B1: القيود على مستوى الجداول =====
alter table public.jobs drop constraint jobs_client_check, drop constraint jobs_title_check;
alter table public.jobs add constraint jobs_client_not_blank check (not private.is_blank(client)),
                        add constraint jobs_title_not_blank check (not private.is_blank(title));
alter table public.job_notes drop constraint job_notes_body_check;
alter table public.job_notes add constraint job_notes_body_not_blank check (not private.is_blank(body));
alter table public.job_stage_log
  add constraint log_real_change check (from_stage <> to_stage),
  add constraint log_cancel_has_reason check (to_stage <> 'cancelled' or not private.is_blank(reason)),
  add constraint log_reason_only_on_cancel check (to_stage = 'cancelled' or reason is null);

-- ===== B4: أسماء العرض =====
create table public.people (
  user_id      uuid primary key references auth.users(id) on delete restrict,
  display_name text not null check (not private.is_blank(display_name))
);
alter table public.people enable row level security;
revoke all on public.people from public, anon, authenticated, service_role;
grant select on public.people to authenticated;
create policy people_partner_read on public.people for select to authenticated using (public.is_partner());

-- ===== B2: حرّاس القاعدة =====
-- الشغلات: الفتح برقم محجوز وبهوية؛ لا تعديل لأي حقل؛ تغيير المرحلة بهوية وعلى الخريطة، ويكتب سطر السجل بنفسه
create function private.jobs_guard() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_order  text[] := array['intake','quote','client_approval','design','review','execution','delivered'];
  v_uid    uuid := auth.uid();
  v_reason text;
  i int; j int;
begin
  if tg_op = 'INSERT' then
    if v_uid is null then raise exception 'no_actor'; end if;
    if new.job_number is distinct from (select c.last_number from public.job_counter c where c.singleton) then
      raise exception 'number_not_reserved';
    end if;
    if new.stage <> 'intake' then raise exception 'invalid_transition'; end if;
    if new.created_by is distinct from v_uid then raise exception 'actor_mismatch'; end if;
    new.created_at := now();
    return new;
  end if;

  if (new.job_number, new.client, new.title, new.job_type, new.due_date, new.created_by, new.created_at)
     is distinct from (old.job_number, old.client, old.title, old.job_type, old.due_date, old.created_by, old.created_at) then
    raise exception 'immutable_field';
  end if;
  if new.stage = old.stage then return new; end if;
  if v_uid is null then raise exception 'no_actor'; end if;
  if old.stage in ('delivered', 'cancelled') then raise exception 'final_stage'; end if;

  if new.stage = 'cancelled' then
    v_reason := current_setting('wasm.cancel_reason', true);
    if private.is_blank(v_reason) then raise exception 'reason_required'; end if;
    v_reason := btrim(v_reason);
  else
    i := array_position(v_order, old.stage::text);
    j := array_position(v_order, new.stage::text);
    if not (j = i + 1 or (j = i - 1 and i between 2 and 6)) then raise exception 'invalid_transition'; end if;
  end if;

  insert into public.job_stage_log (job_number, from_stage, to_stage, moved_by, moved_at, reason)
  values (new.job_number, old.stage, new.stage, v_uid, clock_timestamp(), v_reason);
  return new;
end $$;
create trigger jobs_guard before insert or update on public.jobs for each row execute function private.jobs_guard();

-- السجل: لا يُعدَّل أبدًا، ولا يُكتب إلا من حارس الشغلات
create function private.log_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then raise exception 'log_immutable'; end if;
  if pg_trigger_depth() < 2 then raise exception 'log_direct_insert'; end if;
  return new;
end $$;
create trigger log_guard before insert or update on public.job_stage_log for each row execute function private.log_guard();

-- الملاحظات: تُكتب لحظة الفتح فقط، ولا تُعدَّل
create function private.notes_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then raise exception 'immutable_field'; end if;
  if current_setting('wasm.opening', true) is distinct from new.job_number::text then raise exception 'notes_after_open'; end if;
  return new;
end $$;
create trigger notes_guard before insert or update on public.job_notes for each row execute function private.notes_guard();

-- العدّاد: خطوة واحدة فقط (لا قفز يصنع فجوة، ولا رجوع يصنع تكرارًا)
create function private.counter_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.last_number <> old.last_number + 1 or new.singleton is distinct from old.singleton then raise exception 'counter_step'; end if;
  return new;
end $$;
create trigger counter_guard before update on public.job_counter for each row execute function private.counter_guard();

-- I8 ينتقل إلى private
create function private.forbid_delete() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'no_delete';
end $$;
drop trigger jobs_no_delete on public.jobs;            drop trigger jobs_no_truncate on public.jobs;
drop trigger notes_no_delete on public.job_notes;      drop trigger notes_no_truncate on public.job_notes;
drop trigger log_no_delete on public.job_stage_log;    drop trigger log_no_truncate on public.job_stage_log;
drop trigger counter_no_delete on public.job_counter;  drop trigger counter_no_truncate on public.job_counter;
drop function public.forbid_delete();
create trigger jobs_no_delete before delete on public.jobs for each row execute function private.forbid_delete();
create trigger notes_no_delete before delete on public.job_notes for each row execute function private.forbid_delete();
create trigger log_no_delete before delete on public.job_stage_log for each row execute function private.forbid_delete();
create trigger counter_no_delete before delete on public.job_counter for each row execute function private.forbid_delete();
create trigger jobs_no_truncate before truncate on public.jobs for each statement execute function private.forbid_delete();
create trigger notes_no_truncate before truncate on public.job_notes for each statement execute function private.forbid_delete();
create trigger log_no_truncate before truncate on public.job_stage_log for each statement execute function private.forbid_delete();
create trigger counter_no_truncate before truncate on public.job_counter for each statement execute function private.forbid_delete();

revoke execute on function private.jobs_guard(), private.log_guard(), private.notes_guard(),
  private.counter_guard(), private.forbid_delete() from public;

-- ===== الدوال: رسائل واضحة للواجهة؛ الفرض النهائي في الحرّاس أعلاه =====
create or replace function public.create_job(p_client text, p_title text, p_type text, p_due date default null, p_notes text default null)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_number integer;
begin
  if not public.is_partner() then raise exception 'not_partner'; end if;
  if private.is_blank(p_client) then raise exception 'client_required'; end if;
  if private.is_blank(p_title) then raise exception 'title_required'; end if;
  if p_type is null or not (p_type = any (enum_range(null::public.job_type)::text[])) then raise exception 'invalid_type'; end if;

  update public.job_counter set last_number = last_number + 1 where singleton returning last_number into v_number;

  insert into public.jobs (job_number, client, title, job_type, due_date, stage, created_by)
  values (v_number, btrim(p_client), btrim(p_title), p_type::public.job_type, p_due, 'intake', auth.uid());

  if not private.is_blank(p_notes) then
    perform set_config('wasm.opening', v_number::text, true);
    insert into public.job_notes (job_number, body) values (v_number, p_notes);
    perform set_config('wasm.opening', '', true);
  end if;
  return v_number;
end $$;

create or replace function public.move_job(p_job integer, p_from text, p_to text)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_cur public.job_stage;
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
  if p_to = 'cancelled' or p_to = p_from then raise exception 'invalid_transition'; end if;   -- «ملغاة» لها دالتها

  update public.jobs set stage = p_to::public.job_stage where job_number = p_job;   -- الحارس يفحص الخريطة ويكتب السطر
  return p_to;
end $$;

create or replace function public.cancel_job(p_job integer, p_from text, p_reason text)
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
  if private.is_blank(p_reason) then raise exception 'reason_required'; end if;

  perform set_config('wasm.cancel_reason', p_reason, true);
  update public.jobs set stage = 'cancelled' where job_number = p_job;   -- الحارس يكتب السطر مع السبب
  perform set_config('wasm.cancel_reason', '', true);
  return 'cancelled';
end $$;
