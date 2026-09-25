-- هويات اختبار اللوحة (محلي فقط): شريكان وموظف، بأدوارهم وأسمائهم كما يزرعها الترحيل
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login password 'authpass' noinherit;
  end if;
end $$;
grant anon, authenticated to authenticator;
insert into auth.users(id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'partner1@wasm.test', 'authenticated', 'authenticated'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'partner2@wasm.test', 'authenticated', 'authenticated'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'employee@wasm.test', 'authenticated', 'authenticated');
insert into public.user_roles(user_id, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'partner'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'partner'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'employee');
insert into public.people(user_id, display_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'الشريك الأول'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'الشريك الثاني'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'موظف');
