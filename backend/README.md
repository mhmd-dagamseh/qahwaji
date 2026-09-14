# Backend — بعد الهجرة لـSupabase (لا يوجد Node server)

> **⚠️ هذا المجلد لم يعد يحوي أي سيرفر يُشغَّل.** بعد الهجرة الكاملة الموثّقة بـ
> [`../MIGRATION-SUMMARY.md`](../MIGRATION-SUMMARY.md)، كل منطق الـ backend القديم
> (Express + pg + JWT مخصص) انتقل بالكامل إلى:
> - **Supabase Database** — جداول + RLS + Functions/RPC (مجلد `db/`)
> - **Supabase Edge Functions** — العمليات القليلة التي تحتاج `service_role` فعليًا
>   (مجلد `../supabase/functions/`)
> - **Supabase Auth** — بدل تسجيل الدخول المخصص القديم
>
> `PHASE-1-REPORT.md` و`PHASE-2-REPORT.md` و`CHANGES.md` بهذا المجلد توثّق تاريخ
> تطوير الـ backend القديم (Express) قبل هذه الهجرة — محفوظة كسجل تاريخي فقط،
> ولم تعد تصف النظام الحالي.

## محتوى هذا المجلد الآن

```
backend/
  db/                                  ← شغّلها بالترتيب على مشروع Supabase جديد
    schema.sql
    hardening-v1.sql
    phase2.sql
    phase3-supabase-native.sql         ← المرحلة 1: schema/RLS/RPC الأساسية
    phase4-frontend-migration.sql      ← المرحلة 2/3: RPCs إضافية + rpc_menu_bootstrap محدّثة
    migrate-existing-cafe.sql          ← اختياري، فقط لو عندك بيانات مطعم واحد قديم قبل تعدد المستأجرين
  scripts/
    create-super-admin.mjs             ← إنشاء أول سوبر أدمن (Supabase Auth + جدول super_admins)
    migrate-existing-admins-to-auth.mjs← ربط حسابات restaurant_admins/super_admins قديمة (bcrypt) بـSupabase Auth
```

## الإعداد على مشروع Supabase جديد

1. أنشئ مشروع على [supabase.com](https://supabase.com).
2. بـ SQL Editor على لوحة تحكم Supabase، شغّل ملفات `db/` **بالترتيب المكتوب أعلاه بالضبط** (كل ملف يعتمد على اللي قبله).
3. أنشئ اثنين Storage buckets (Storage → New bucket)، كلاهما **Public**:
   - `restaurant-assets`
   - `templates`
   (الـpolicies الفعلية على `storage.objects` موجودة أصلًا داخل `phase3-supabase-native.sql § 6` — إنشاء الـbucket نفسه فقط ما بينعمل من SQL).
4. انشر الـ Edge Functions:
   ```bash
   supabase functions deploy onboard-restaurant
   supabase functions deploy upload-template
   ```
5. أنشئ أول سوبر أدمن:
   ```bash
   export SUPABASE_URL=https://YOUR-PROJECT.supabase.co
   export SUPABASE_SERVICE_ROLE_KEY=YOUR-SERVICE-ROLE-KEY   # من Project Settings → API
   cd scripts && npm install && cd ..
   node scripts/create-super-admin.mjs --email you@yourcompany.com --password "StrongPass123!" --name "اسمك"
   ```
6. عبّي `frontend/assets/supabase-config.js` بـ `SUPABASE_URL` و anon key مشروعك، وانشر مجلد `frontend/` على GitHub Pages (أو أي static hosting).

## عندك بيانات إنتاج قديمة من قبل هذه الهجرة؟

كلمات مرور `restaurant_admins`/`super_admins` القديمة كانت bcrypt hash — **لا يمكن استرجاعها
لكلمة مرور أصلية بأي شكل** (هذا هو الغرض من bcrypt، وليس نقصًا بهذه الهجرة). شغّل:

```bash
node scripts/migrate-existing-admins-to-auth.mjs --dry-run   # عاين أولًا بلا أي تعديل
node scripts/migrate-existing-admins-to-auth.mjs             # التنفيذ الفعلي
```

بيربط كل حساب قديم بمستخدم Supabase Auth جديد بكلمة مرور عشوائية مؤقتة، ويطبع لك رابط
"تعيين كلمة مرور" (recovery link) لكل مستخدم — أرسله يدويًا لصاحبه قبل أول تسجيل دخول.

## لماذا لم يعد هناك Node server؟

راجع [`../MIGRATION-SUMMARY.md`](../MIGRATION-SUMMARY.md) للتفصيل الكامل: كل مسار Express
القديم إما تحوّل إلى قراءة/كتابة مباشرة من الـFrontend محكومة بـRLS، أو إلى دالة
PostgreSQL (RPC) للعمليات الحساسة/الذرّية، أو إلى Edge Function للحالات القليلة التي
تحتاج فعليًا صلاحية `service_role` (إنشاء مستخدم Auth، فحص/رفع ملفات ZIP).
