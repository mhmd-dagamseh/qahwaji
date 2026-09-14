# Hardening v1 — ملخص التغييرات

> **⚠️ تاريخي — يصف معمارية Node/Express/Vercel القديمة، لم تعد قائمة.**
> المرجع الحالي والدقيق: [`../MIGRATION-SUMMARY.md`](../MIGRATION-SUMMARY.md) بجذر المشروع.


تنفيذ كامل لبنود `Cafe_SaaS_Core_Technical_Audit_Report.docx`. كل بند اتأكد أولاً من الكود الفعلي قبل الإصلاح (مو نسخ توصيات عامة).

## حرجة (تم إصلاحها)

| البند | الإصلاح |
|---|---|
| **3.1** بريد أدمن مطعم مكرر بين مطاعم | `unique(email)` عالمي على `restaurant_admins` (`db/hardening-v1.sql`). استعلام تسجيل الدخول أصلاً بيرجع صف واحد الآن مضمون. **لازم تشغّلوا الملف وتحلّوا أي تكرار موجود يدويًا أولاً — الملف بيرفض يكمل لو لقى تكرار.** |
| **3.2** cashier = owner بكل الصلاحيات | `requireRole("owner")` جديدة بـ`middleware/auth.js`، مطبّقة على: branding, tables (create/bulk/delete), products (create/update/delete). القراءة والإحصائيات ضلت متاحة لـowner وcashier معًا. |
| **3.3** حالة المطعم مو مفروضة بتسجيل الدخول | `restaurantAdminLogin` صار يعمل join على `restaurants` ويرفض `suspended`/`cancelled` بـ403. |
| **3.4** RLS الطلبات مفتوحة بالكامل (`using(true)`) — **الأخطر فعليًا لأنها مكشوفة الآن بدون أي مصادقة** | راجع قسم "تحدي مصادقة الطلبات" أدناه — الحل بجزئين (access_token للزبون + Supabase JWT حقيقي للطاقم). |
| **3.5** انتهاء الاشتراك (`current_period_end`) مو مفروض | تريغر `enforce_table_limit` صار يتحقق `current_period_end > now()` مو بس `status='active'`. |
| **3.6** Race condition بحساب عدد الطاولات | `pg_advisory_xact_lock` بالتريغر يسلسل الإدراجات المتزامنة لنفس المطعم. |

## متوسطة (تم إصلاحها)

- **4.1** bulkCreateTables: validation عبر zod (حد أقصى 300، أرقام موجبة).
- **4.2** `table_number > 0` CHECK بقاعدة البيانات.
- **4.3** `products.price >= 0` CHECK بقاعدة البيانات.
- **4.4** zod schema لكل endpoint كتابة (`src/validators/schemas.js` + `middleware/validate.js`).
- **4.5** CORS: صارم إجباريًا بـ`NODE_ENV=production` (لازم `CORS_ORIGIN`)، مفتوح بالتطوير فقط.
- **4.6** مدة JWT اختصرت من 7 أيام لـ12 ساعة افتراضيًا (`JWT_EXPIRES_IN`). **ملاحظة صريحة:** ما بنيت نظام refresh token كامل — هاي بس تقليل نافذة الخطر، مو حل نهائي. لو بدكم rotation حقيقي هاي مهمة منفصلة.
- **4.7** `express-rate-limit` على مسارات تسجيل الدخول (20 محاولة/15 دقيقة لكل IP) + حد عام أخف على باقي الـAPI.
- **4.8** جدول `audit_logs` + `src/utils/audit.js`، مسجّل على: إنشاء/تعليق مطعم، تغيير branding، تغيير باقة، إنشاء/حذف طاولة (فردي وbulk)، إنشاء/تعديل/حذف منتج، إنشاء/تعديل باقة.

## قسم 5 — Order Snapshot

`validate_order_before_insert` صار يعيد بناء `items` كـsnapshot حقيقي (`product_id, name, unit_price, qty, subtotal`) من جدول `products` وقت الإدراج، مش يعتمد على القيم اللي بعتها العميل. هاد كمان صحّح باگ جانبي كان موجود: `getTopProducts` كانت تقرأ `item->>'price'` وهو رقم خام من العميل نفسه، مو السعر الحقيقي — صار يقرأ `unit_price` من الـsnapshot.

## تحدي مصادقة الطلبات (3.4) — الحل بالتفصيل، وحدوده بصراحة

المشكلة الأصلية: `orders` RLS كانت `using(true)` لكل من select وupdate، ومسار الطلب اللحظي (منيو + كاشير) يروح مباشرة لـSupabase بمفتاح anon — يعني أي حدا معه الـanon key (موجود بأي صفحة منيو عامة) يقدر يقرأ ويعدّل طلبات كل المطاعم.

**الحل المطبّق بـ`db/hardening-v1.sql`:**

1. **الزبون (بدون تسجيل دخول):** كل طلب بياخد `access_token` (uuid عشوائي) وقت الإنشاء. القراءة تصير بس لو الطلب بعت هيدر `x-order-token` مطابق. التحديث (تغيير حالة الطلب) صار ممنوع بالكامل عن `anon` — الزبون ما عاد يقدر يعدّل أي طلب حتى لو عرف رقمه.

2. **الطاقم (owner/cashier):** تسجيل الدخول عبر Node صار يرجع `supabaseToken` إضافي (JWT موقّع بـ`SUPABASE_JWT_SECRET` نفسه المستخدم بمشروع Supabase)، فيه `restaurant_id` و`staff_role`. الفرونت إند يفتح بيه جلسة Supabase authenticated حقيقية بدل الاعتماد على anon key، وRLS تفرض تطابق `restaurant_id` تلقائيًا عبر `auth.jwt()`.

**⚠️ حد صريح ما لحله بهالجولة:** تقنية الـ`x-order-token` بالهيدر شغالة لقراءة REST عادية، **لكن مو شغالة لاشتراكات Supabase Realtime** (الـwebsocket بياخد هويته من الـJWT المتصل فيه، مش من هيدرز مخصصة على كل query). يعني:
- **جانب الكاشير:** Realtime تبقى شغالة بشكل صحيح ومقيّد فعليًا، لأنه معتمد على `supabaseToken` الـauthenticated الجديد.
- **جانب الزبون (تتبع حالة طلبه بعد ما يبعته):** لازم يتحول من Realtime subscribe لـ**polling** كل بضع ثوانٍ عبر REST مع هيدر `x-order-token` (تجربة شبه لحظية، مش لحظية 100%). حل Realtime حقيقي هون بده Supabase Realtime Authorization (broadcast channels موقّعة لكل طلب) — مهمة منفصلة أكبر لو بدكم Realtime كاملة للزبون كمان.

**تغيير مطلوب بالفرونت إند (menu.html/cashier.html — مو جزء من هاد الريبو):**
- menu.html: يحفظ `access_token` الراجع من الـinsert، ويبعته كـheader `x-order-token` بكل قراءة لاحقة، وما يعتمد على realtime subscribe للطلب.
- cashier.html: يستخدم `supabaseToken` من `/auth/restaurant-admin/login` لفتح جلسة Supabase authenticated (مو anon key مباشرة).

## خطوات التشغيل

```bash
npm install
# شغّلوا db/schema.sql (لو أول مرة)، وبعدين db/hardening-v1.sql
# لو schema.sql موجود من قبل: شغّلوا db/hardening-v1.sql بس
# راجعوا رسائل NOTICE/EXCEPTION لأي بريد مكرر بـrestaurant_admins قبل ما يكمل القيد
cp .env.example .env
# عبّوا DATABASE_URL, JWT_SECRET, SUPABASE_JWT_SECRET (من Supabase: Project Settings → API → JWT Secret)
npm run dev
```

## مش متضمن بهالجولة (بصراحة)

- Refresh token rotation كاملة (بس قصّرنا مدة الـaccess token كحل مؤقت).
- Realtime حقيقية لتتبع الزبون لطلبه (بدّلناها بـpolling عبر access_token — انظر أعلاه).
- Integration tests (بند 10 بخطة التنفيذ المقترحة بالتقرير) — لسا مطلوبة قبل أول عميل حقيقي.
