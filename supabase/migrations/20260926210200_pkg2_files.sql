-- الحزمة 2 — الشريحة 2ب (الملفات). D27-4: 50MB للملف؛ PDF, JPG, PNG, WEBP, MP4, ZIP؛ لا SVG.
-- الحاوية خاصة. الرفع بهوية المستخدم إلى مسار حجزه قبل 15 دقيقة على الأكثر (سياسة insert)؛ القراءة لمن يرى المهمة الآن
-- (سياسة select). لا سياسة update ولا delete لأي دور، وحارس يمنع الحذف وإعادة التسمية حتى من المالك (I8).
-- التنزيل بهوية المستخدم مباشرة؛ التطبيق لا يصنع روابط (انحراف موثّق عن الجولة صفر في تعريف الشريحة).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('task-files', 'task-files', false, 52428800,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'application/zip', 'application/x-zip-compressed'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create type public.task_file_kind as enum ('draft', 'review', 'final');

create table public.task_files (
  id          bigint generated always as identity primary key,
  task_id     bigint not null references public.tasks(id) on delete restrict,
  object_path text not null unique,
  file_name   text not null check (not private.is_blank(file_name)),
  mime        text not null,
  size_bytes  bigint not null check (size_bytes > 0),
  kind        public.task_file_kind not null,
  uploaded_by uuid not null references auth.users(id) on delete restrict,
  reserved_at timestamptz not null default now(),
  finished_at timestamptz,
  approved_by uuid references auth.users(id) on delete restrict,
  approved_at timestamptz,
  check ((approved_by is null) = (approved_at is null))
);
create index task_files_task_idx on public.task_files (task_id, id);
alter table public.task_files enable row level security;
revoke all on public.task_files from public, anon, authenticated, service_role;
revoke all on all sequences in schema public from public, anon, authenticated, service_role;
grant select on public.task_files to authenticated;
-- الملف يتبع مهمته (سياسة tasks بهوية القارئ)؛ المحجوز غير المكتمل يراه رافعه وحده
create policy task_files_read on public.task_files for select to authenticated
  using ((finished_at is not null or uploaded_by = auth.uid()) and exists (select 1 from public.tasks t where t.id = task_id));

-- الحارس: الهوية والمسار والنوع ثابتة؛ الاكتمال مرة واحدة؛ الاعتماد مرة واحدة
create function private.task_files_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (new.id, new.task_id, new.object_path, new.file_name, new.kind, new.uploaded_by)
     is distinct from (old.id, old.task_id, old.object_path, old.file_name, old.kind, old.uploaded_by)
     or (old.finished_at is not null and (new.finished_at, new.mime, new.size_bytes) is distinct from (old.finished_at, old.mime, old.size_bytes))
     or (old.approved_at is not null and (new.approved_at, new.approved_by) is distinct from (old.approved_at, old.approved_by)) then
    raise exception 'immutable_field';
  end if;
  return new;
end $$;
create trigger task_files_guard before update on public.task_files for each row execute function private.task_files_guard();
create trigger task_files_no_delete before delete on public.task_files for each row execute function private.forbid_delete();
create trigger task_files_no_truncate before truncate on public.task_files for each statement execute function private.forbid_delete();

-- Storage: لا حذف ولا نقل ولا إعادة تسمية لملف في الحاوية، حتى من المالك أو لوحة Supabase (I8)
create function private.task_objects_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if old.bucket_id = 'task-files' then raise exception 'no_delete'; end if;
    return old;
  end if;
  if old.bucket_id = 'task-files' and (new.bucket_id, new.name) is distinct from (old.bucket_id, old.name) then
    raise exception 'immutable_field';
  end if;
  return new;
end $$;
create trigger wasm_task_objects_guard before update or delete on storage.objects for each row execute function private.task_objects_guard();
revoke execute on function private.task_files_guard(), private.task_objects_guard() from public;

-- ===== سياسات Storage (بهوية المستخدم؛ الدالتان invoker فتخضعان لسياسات tasks وtask_files) =====
create function public.can_get_task_object(p_name text) returns boolean
language sql stable security invoker set search_path = '' as $$
  select exists (select 1 from public.task_files f where f.object_path = p_name)
$$;
create function public.can_put_task_object(p_name text) returns boolean
language sql stable security invoker set search_path = '' as $$
  select exists (select 1 from public.task_files f join public.tasks t on t.id = f.task_id
                  where f.object_path = p_name and f.uploaded_by = auth.uid() and f.finished_at is null
                    and f.reserved_at > now() - interval '15 minutes' and t.status not in ('done', 'cancelled'))
     and not exists (select 1 from storage.objects o where o.bucket_id = 'task-files' and o.name = p_name)
$$;
create policy wasm_task_files_read on storage.objects for select to authenticated
  using (bucket_id = 'task-files' and public.can_get_task_object(name));
create policy wasm_task_files_put on storage.objects for insert to authenticated
  with check (bucket_id = 'task-files' and public.can_put_task_object(name));

-- ===== الدوال =====
create function public.begin_task_upload(p_task bigint, p_name text, p_mime text, p_size bigint, p_kind text)
returns table (file_id bigint, object_path text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_role public.app_role := private.role_of(auth.uid());
  t      public.tasks;
  v_ext  text;
  v_path text;
  v_id   bigint;
begin
  if v_role is null then raise exception 'not_allowed'; end if;
  select * into t from public.tasks where id = p_task for share;
  if not found or not (v_role in ('partner', 'manager') or t.assignee = auth.uid()) then raise exception 'task_not_found'; end if;
  if t.status in ('done', 'cancelled') then raise exception 'final_status'; end if;
  if private.is_blank(p_name) then raise exception 'file_name_required'; end if;
  if p_kind is null or not (p_kind = any (enum_range(null::public.task_file_kind)::text[])) then raise exception 'invalid_kind'; end if;
  v_ext := case p_mime when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg' when 'image/png' then 'png'
                       when 'image/webp' then 'webp' when 'video/mp4' then 'mp4'
                       when 'application/zip' then 'zip' when 'application/x-zip-compressed' then 'zip' end;
  if v_ext is null then raise exception 'file_type'; end if;
  if p_size is null or p_size <= 0 then raise exception 'file_empty'; end if;
  if p_size > 52428800 then raise exception 'file_too_large'; end if;
  v_path := 't' || t.id || '/' || gen_random_uuid() || '.' || v_ext;
  insert into public.task_files (task_id, object_path, file_name, mime, size_bytes, kind, uploaded_by)
  values (t.id, v_path, btrim(p_name), p_mime, p_size, p_kind::public.task_file_kind, auth.uid())
  returning id into v_id;
  return query select v_id, v_path;
end $$;

-- الاكتمال: رافعه وحده، والحجم والنوع الفعليان من Storage لا من المتصفح
create function public.finish_task_upload(p_file bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare f public.task_files; m jsonb; v_size bigint; v_mime text;
begin
  select * into f from public.task_files where id = p_file for update;
  if not found or f.uploaded_by is distinct from auth.uid() then raise exception 'file_not_found'; end if;
  if f.finished_at is not null then return; end if;
  select o.metadata into m from storage.objects o where o.bucket_id = 'task-files' and o.name = f.object_path;
  if not found then raise exception 'upload_missing'; end if;
  v_size := (m ->> 'size')::bigint; v_mime := m ->> 'mimetype';
  if v_mime is distinct from f.mime then raise exception 'file_type'; end if;
  if v_size is null or v_size <= 0 then raise exception 'file_empty'; end if;
  if v_size > 52428800 then raise exception 'file_too_large'; end if;
  update public.task_files set finished_at = now(), size_bytes = v_size, mime = v_mime where id = p_file;
end $$;

create function public.approve_task_file(p_file bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v_role public.app_role := private.role_of(auth.uid()); f public.task_files;
begin
  if v_role is null or v_role not in ('partner', 'manager') then raise exception 'not_allowed'; end if;
  select * into f from public.task_files where id = p_file for update;
  if not found or f.finished_at is null then raise exception 'file_not_found'; end if;
  if f.approved_at is not null then raise exception 'already_approved'; end if;
  update public.task_files set approved_by = auth.uid(), approved_at = now() where id = p_file;
end $$;

revoke execute on function public.can_get_task_object(text), public.can_put_task_object(text),
  public.begin_task_upload(bigint, text, text, bigint, text), public.finish_task_upload(bigint), public.approve_task_file(bigint)
  from public, anon;
grant execute on function public.can_get_task_object(text), public.can_put_task_object(text),
  public.begin_task_upload(bigint, text, text, bigint, text), public.finish_task_upload(bigint), public.approve_task_file(bigint)
  to authenticated;
