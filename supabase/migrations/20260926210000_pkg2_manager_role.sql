-- الحزمة 2، الجزء 2ج (D28): دور ثالث «مدير». في ترحيل مستقل لأن قيمة enum جديدة لا تُستعمل في المعاملة التي أضافتها.
alter type public.app_role add value if not exists 'manager';
