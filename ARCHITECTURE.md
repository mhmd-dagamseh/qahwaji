# ARCHITECTURE.md — Qahwaji NFC Restaurant SaaS

> **⚠️ تاريخي — يصف معمارية Node/Express/Vercel القديمة، لم تعد قائمة.**
> المرجع الحالي والدقيق: [`MIGRATION-SUMMARY.md`](MIGRATION-SUMMARY.md) بجذر المشروع.


هذا التوثيق يعكس الكود الفعلي بعد فحصه سطرًا سطرًا (Phase 3 audit) — مش قالب عام.

## 1. الفكرة العامة

Super Admin → Restaurants → Plans → Subscriptions → Restaurant Admin → Products/Categories/Tables → NFC → Customer Menu → Cart → Orders

النظام مبني على **طبقتين منفصلتين عن قصد** (قرار هندسي موجود من Phase 1، وليس نقصًا):

| الطبقة | المسؤولية | كيف تتصل بالبيانات |
|---|---|---|
| **Node/Express API** (`backend/`) | onboarding المطاعم، الباقات، الاشتراكات، لوحة السوبر أدمن، لوحة أدمن المطعم (منتجات/طاولات/فروع/إحصائيات)، محرك القوالب (upload/validate/version/activate/rollback) | اتصال مباشر بـ Postgres عبر `DATABASE_URL` (service-role/pg)، **بدون المرور بـ RLS** — التفويض كله مفروض يدويًا بالكود (`middleware/auth.js`) |
| **Supabase مباشرة (من المتصفح)** | تدفق الطلبات اللحظي بين صفحة المنيو والكاشير (realtime)، تخزين ملفات القوالب والصور | `anon key` + **RLS حقيقي مفعّل** على جدولي `orders` و`audit_logs` (`db/hardening-v1.sql`) |

السبب: الاستفادة من Supabase Realtime الجاهز لتدفق الطلبات اللحظي دون إعادة بناء WebSocket layer، مع إبقاء منطق الأعمال الحساس (تسعير، صلاحيات، اشتراكات) في طبقة Node مغلقة تمامًا عن الوصول العام.

## 2. من يُشغّل ماذا (Who Runs What)

**المتصفح (Browser) يُشغّل:**
- `frontend/index.html` — الصفحة الرئيسية
- `frontend/admin/` — لوحة السوبر أدمن
- `frontend/restaurant-admin/` — لوحة أدمن المطعم
- `frontend/cashier/` — شاشة الكاشير (تتصل بـSupabase مباشرة عبر JS SDK)
- `frontend/menu/` — منيو الزبون (NFC)
- كل template مرفوع (Supabase Storage) يُحمَّل ويُنفَّذ داخل متصفح الزبون أيضًا

**Vercel (Serverless Functions) يُشغّل:**
- `backend/api/index.js` → يستورد `backend/src/app.js` (Express app) — هذا هو كل شيء تحت `/auth`, `/plans`, `/restaurants`, `/templates`, `/api/public`
- لا يوجد `app.listen()` في مسار الإنتاج؛ Vercel يغلّف الـ Express app تلقائيًا كـ handler لكل request — **تأكدت من هذا فعليًا بتشغيل `require('./src/app')` بدون أي اتصال DB نشط وتحميله بنجاح.**

**Supabase يُشغّل:**
- PostgreSQL (الجداول التشغيلية: `restaurants, plans, subscriptions, restaurant_tables, products, orders, audit_logs`...)
- RLS على `orders` و`audit_logs` فقط (البقية تُدار حصرًا عبر الـ API بمفتاح service-role/DATABASE_URL المباشر، فلا داعي لـ RLS عليها طالما لا مسار يصل إليها إلا عبر Node)
- Storage: bucket `templates` (ملفات القوالب المرفوعة) و`restaurant-assets` (شعارات/صور منتجات) — كلاهما public-read بحسب `.env.example`

**GitHub يُشغّل:**
- مستودع الكود المصدري فقط (لا يستضيف تشغيلًا حيًا لأي جزء في هذا الإعداد؛ راجع DEPLOYMENT.md لماذا لم نستخدم GitHub Pages)

## 3. المصادقة والتفويض (فعليًا في الكود)

- `middleware/auth.js`: `requireAuth` (يتحقق JWT موقّع بـ`JWT_SECRET`) → `requireSuperAdmin` / `requireRestaurantAccess` (يقارن `restaurantId` بالتوكن مع `:id` بالمسار) / `requireRole("owner")` لتقييد إجراءات حساسة (branding، حذف طاولات/منتجات) عن دور cashier.
- تسجيل دخول أدمن المطعم يرفض المطاعم `suspended`/`cancelled` (403) ويتحقق من `current_period_end` عبر trigger بقاعدة البيانات، وليس فقط `status='active'`.
- طلبات الزبون (`orders`) تُقرأ عبر `access_token` عشوائي (uuid) لكل طلب — لا تسجيل دخول للزبون، ولا يمكنه تعديل حالة الطلب مهما عرف رقمه (RLS يمنع update من `anon` كليًا).
- الطاقم (owner/cashier) يحصل بعد تسجيل الدخول على `supabaseToken` إضافي موقّع بـ`SUPABASE_JWT_SECRET` نفسه المُعرَّف بمشروع Supabase، ليفتح جلسة Supabase حقيقية (`auth.jwt()`) بدل الاعتماد فقط على anon key — وبهذا RLS يفرض تطابق `restaurant_id` تلقائيًا.
- الأسعار: `validate_order_before_insert` (trigger) يعيد بناء `items` من جدول `products` وقت الإدراج (server-side snapshot) — لا يعتمد على السعر المرسل من المتصفح، فيمنع "price manipulation".
- رفع القوالب: `utils/templatePathSafety.js` يرفض path traversal, absolute paths, UNC paths, null bytes, و ملفات حساسة (`.env`, `id_rsa`, `.git/config`, إلخ) — تحققت من هذا بتشغيل `scripts/test-template-path-safety.js` فعليًا: **27/27 اختبار ناجح.**

## 4. القيود المعروفة (بصراحة، لا تجميل)

- لا يوجد نظام refresh token كامل لـJWT الخاص بالـAPI — فقط تقصير مدة الصلاحية (`JWT_EXPIRES_IN`, افتراضي 12 ساعة). هذا تخفيف للمخاطرة وليس حلًا نهائيًا (موثّق أصلًا في `CHANGES.md`).
- `multer@1.4.5` تصدر تحذير ثغرات معروفة عند `npm install` (moderate severity في نظام 1.x بشكل عام) — الترقية لـ2.x تغيّر الـ API (busboy-based) وتحتاج مراجعة كود الرفع في `uploads.controller.js` و`templates.controller.js` قبل التطبيق؛ لم أطبّقها في هذه المرحلة لتجنّب كسر تدفق رفع القوالب بدون اختبار حقيقي على بيئة فعلية.
- لا يوجد اتصال فعلي بمشروع Supabase حقيقي في بيئة هذا التدقيق — كل ما ورد أعلاه تحقق منه عبر: فحص الكود، `npm install` ناجح، فحص syntax لكل ملف، تحميل `app.js` بنجاح بدون DB، وتشغيل اختبار path-safety. لم يُشغَّل smoke-test.js أو migrations فعليًا على قاعدة بيانات حقيقية (يحتاج `DATABASE_URL` حقيقي لا أملكه).
