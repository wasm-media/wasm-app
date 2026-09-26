-- الحزمة 1، الخطوة 6 (P18): زرع الشريكين.
-- حساب جديد في auth.users يأخذ دور partner واسم العرض إن طابقت بصمة بريده صفًّا في private.partner_seed.
-- البصمة = sha256 (hex) للبريد بحروف صغيرة بلا مسافات أطراف. البريد نفسه لا يُكتب في المستودع العام:
-- صفوف البصمات تأتي بترحيل مستقل. الأدوار لا تُمنح إلا من هنا (service_role لا يكتب user_roles ولا people).
-- الزرع عند الإنشاء فقط: تغيير البريد لاحقًا إلى بريد مزروع لا يمنح شيئًا.

create table private.partner_seed (
  email_sha256 text primary key check (email_sha256 ~ '^[0-9a-f]{64}$'),
  display_name text not null check (not private.is_blank(display_name))
);
alter table private.partner_seed enable row level security;
revoke all on private.partner_seed from public, anon, authenticated, service_role;

create function private.seed_partner() returns trigger
language plpgsql security definer set search_path = '' as $$
declare nm text;
begin
  select s.display_name into nm from private.partner_seed s
   where s.email_sha256 = pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(pg_catalog.lower(pg_catalog.btrim(new.email)), 'UTF8')), 'hex');
  if nm is not null then
    insert into public.user_roles(user_id, role) values (new.id, 'partner') on conflict (user_id) do nothing;
    insert into public.people(user_id, display_name) values (new.id, nm) on conflict (user_id) do nothing;
  end if;
  return new;
end $$;
revoke execute on function private.seed_partner() from public, anon, authenticated, service_role;

create trigger wasm_seed_partner after insert on auth.users for each row execute function private.seed_partner();
