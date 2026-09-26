-- P18: صفّا زرع الشريكين (بصمة sha256 للبريد بحروف صغيرة + اسم العرض). البريد نفسه ليس هنا.
-- حساب موجود مسبقًا ببريد مطابق (إن وُجد) يُزرع هنا أيضًا؛ الجديد يزرعه الـtrigger عند إنشائه.
insert into private.partner_seed(email_sha256, display_name) values ('f77ecc76e2ecabe657977672b2b6ad5dda5f5ca79ae25414c31f45e1a620a6c3', 'عيسى الجبالي');
insert into private.partner_seed(email_sha256, display_name) values ('2b66dd9dfc952a6cffe9a718ce623a11ddd1a2ffab92209c3e59b7c743115755', 'أحمد أبو حصيرة');
insert into public.user_roles(user_id, role)
  select u.id, 'partner' from auth.users u join private.partner_seed s
    on s.email_sha256 = encode(sha256(convert_to(lower(btrim(u.email)), 'UTF8')), 'hex')
  on conflict (user_id) do nothing;
insert into public.people(user_id, display_name)
  select u.id, s.display_name from auth.users u join private.partner_seed s
    on s.email_sha256 = encode(sha256(convert_to(lower(btrim(u.email)), 'UTF8')), 'hex')
  on conflict (user_id) do nothing;
