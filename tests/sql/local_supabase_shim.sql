-- محاكاة محلية لما يهمّ الصلاحيات في Supabase (للتطوير السريع فقط؛ الحكم على مشروع التطوير الحقيقي)
-- تحاكي: الأدوار anon/authenticated/service_role، auth.users، auth.uid()، والصلاحيات الافتراضية المتساهلة (مقيسة من wasm-app-dev 25/09/2026)
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant anon, authenticated, service_role to postgres;
create schema auth;
create table auth.users(id uuid primary key, email text, aud text, role text, raw_user_meta_data jsonb, is_sso_user boolean not null default false, is_anonymous boolean not null default false);
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
