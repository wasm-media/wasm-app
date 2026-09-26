-- الحزمة 2، 2د (D29): زرع حسابات الموظفين الأربعة — بصمة البريد الداخلي staff.<اسم الدخول>@wasmmedia.net + الاسم + الدور.
-- الحسابات يُنشئها release.yml (.github/ops/staff_accounts.sh) فيزرعها الـtrigger عند إنشائها.
insert into private.partner_seed(email_sha256, display_name, role) values ('37cde3674b4d38a5e8e0b926685a4435526ac398c69ed2973b9423d335cd8aed', 'عهد الجبالي', 'manager');   -- ahd.jabali
insert into private.partner_seed(email_sha256, display_name, role) values ('6605eb3e359c4f2e1d699c6cf0376313529ede7648dde67b5be7698a74bb7972', 'إيمان القدوة', 'employee');   -- eman.qudwa
insert into private.partner_seed(email_sha256, display_name, role) values ('d626425a3b3086ed45899e4f354e31a25ddcb7791ced3e8f3105eede46e5465f', 'ريم القطناني', 'employee');   -- reem.qattanani
insert into private.partner_seed(email_sha256, display_name, role) values ('33ac22c230bfe3c3da4ac4cfbcce7b2f6afdefb531ab826f0827c401aed2492b', 'أحمد العشي', 'employee');   -- ahmad.ashi
