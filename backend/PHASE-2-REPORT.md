# PHASE-2-REPORT.md — Menu Template Engine + Customer Menu + NFC Ordering

> **⚠️ تاريخي — يصف معمارية Node/Express/Vercel القديمة، لم تعد قائمة.**
> المرجع الحالي والدقيق: [`../MIGRATION-SUMMARY.md`](../MIGRATION-SUMMARY.md) بجذر المشروع.


> اقرأ هذا التقرير كامل قبل أي تعديل مستقبلي. هذا التقرير + PHASE-1-REPORT.md
> (لسا موجود، ما انلمس) هما مصدر الحقيقة لحالة المشروع.

## 0) خلاصة تنفيذية

Phase 1 بنى: منصّة SaaS متعددة المطاعم (Super Admin → Restaurant → Products/Tables →
Orders أساسي)، بمصادقة JWT، RLS محكمة على `orders`، وaudit log. **ما كان ناقص بالكامل**:
Customer Menu، NFC URL resolution، Public API، إنشاء الطلبات من الزبون، Template Engine،
ولوحة تحكم لصاحب المطعم (Products/Tables/Branding ما كان إلها UI إطلاقًا — بس API).

Phase 2 بنى كل هذا **فوق** الأساس الموجود، بلا حذف أو إعادة بناء أي شي من Phase 1:

- **Customer Menu حقيقي شغّال** (mobile-first, RTL/LTR, cart, order, polling status) —
  `frontend_pages/customer-menu/index.html`.
- **Public API آمن** تحت `/api/public/*` — بلا كشف أي بيانات إدارية.
- **NFC URL resolution** كامل بخطوات التحقق المطلوبة + حالات خطأ واضحة.
- **إنشاء طلبات آمن** — الـbackend يحسب كل شي، Order Token خاص لكل طلب.
- **Template Engine كامل**: رفع ZIP، فحص أمني صارم، تنصيب، تفعيل/إلغاء، rollback،
  إعدادات whitelist، قالب افتراضي مدمج يشتغل من أول يوم بلا رفع أي شي.
- **لوحة تحكم جديدة لصاحب المطعج** (`restaurant-admin.html`) — كانت غير موجودة إطلاقًا.
- **تبويب قوالب جديد** بلوحة السوبر أدمن الموجودة (`admin-panel.html`) — إضافة، مش إعادة بناء.
- **رفع صور** (شعار/منتجات) عبر Supabase Storage.

---

## 1) الملفات

### ملفات جديدة (Backend)
```
backend/db/phase2.sql                          — migration: menu_templates, template_versions, restaurant_menu_templates
backend/src/utils/templatePathSafety.js         — فحوصات مسار آمنة، صفر dependencies (مختبرة فعليًا، شوف §6)
backend/src/utils/templateValidator.js          — فحص ZIP كامل (adm-zip + zod) فوق templatePathSafety
backend/src/utils/storage.js                    — Supabase Storage REST wrapper (fetch المدمج، بلا SDK إضافي)
backend/src/controllers/publicMenu.controller.js
backend/src/controllers/publicOrders.controller.js
backend/src/controllers/templates.controller.js
backend/src/controllers/restaurantMenu.controller.js
backend/src/controllers/uploads.controller.js
backend/src/routes/public.routes.js
backend/src/routes/templates.routes.js
backend/src/public/menu-sdk.js                  — MenuSDK الموحّد (مصدر واحد، يُخدَم static من الـbackend)
backend/scripts/test-template-path-safety.js    — اختبار وحدة شغّال فورًا بلا npm install (26 حالة، كلها PASS)
```

### ملفات معدّلة (Backend) — إضافات فقط، ولا سطر انحذف من منطق Phase 1
```
backend/package.json           — + adm-zip, + multer, + npm script test:template-path-safety
backend/.env.example           — + SUPABASE_URL, + SUPABASE_SERVICE_ROLE_KEY (موثّقة، اختيارية حتى تحتاجها)
backend/src/app.js             — + mount /api/public و /templates، + static /api/public/sdk (مع CORP header)
backend/src/validators/schemas.js — + templateSettingsSchema (.strict())، + selectMenuTemplateSchema،
                                    + updateMenuTemplateSettingsSchema، + createOrderSchema
backend/src/routes/restaurants.routes.js — + مسارات menu-template (GET/PUT/PATCH)، + رفع شعار/صورة منتج
backend/src/middleware/rateLimit.js — + orderCreationLimiter (12 طلب/دقيقة لإنشاء الطلبات العامة)
backend/scripts/smoke-test.js  — + 4 فحوصات إضافية (بس يلي ما بتلمس DB، بنفس فلسفة الملف الأصلي)
```

### ملفات جديدة (Frontend)
```
frontend_pages/customer-menu/index.html   — القالب الافتراضي المدمج (built-in) + resolver للقوالب المخصصة
frontend_pages/restaurant-admin.html      — لوحة تحكم صاحب المطعم/الكاشير (ما كانت موجودة إطلاقًا بـPhase 1)
```

### ملفات معدّلة (Frontend) — إضافات فقط
```
frontend_pages/admin-panel.html — + تبويب "القوالب" (رفع/تفعيل/إلغاء تفعيل/معاينة)،
                                   + دعم FormData بدالة api() الموجودة (backward-compatible)
```

**لم يُحذف أو يُعَد بناؤه أي ملف من Phase 1.** `cashier-panel.html` و `main-Page.html`
لم يُلمسا إطلاقًا.

---

## 2) قاعدة البيانات (`backend/db/phase2.sql`)

شغّلوه بعد `schema.sql` و`hardening-v1.sql` (بنفس الترتيب المذكور بـPHASE-1-REPORT.md).
آمن لإعادة التشغيل (كل شي `if not exists` / `on conflict do nothing`).

| جدول | الغرض |
|---|---|
| `menu_templates` | عائلة القالب (اسم + slug فريد). |
| `template_versions` | كل نسخة: manifest (jsonb)، entry_file، storage_path، status. **غير قابلة للتعديل** بعد الإنشاء (trigger `prevent_template_version_mutation` يمنع تغيير manifest/entry_file/storage_path/template_id/version — بس status/activated_at يضلوا قابلين للتغيير لدعم Activate/Deactivate بلا كسر الثبات). |
| `restaurant_menu_templates` | سجل تعيين قالب لكل مطعم، مع تاريخ كامل (`is_current` + `deactivated_at`) — الأساس لـRollback. Unique partial index يضمن صف "حالي" واحد بس لكل مطعم. |

**القالب الافتراضي المدمج**: يُزرع تلقائيًا (`slug='default'`, `is_builtin=true`) — شغّال فورًا
بلا أي رفع ZIP. ملفاته الفعلية هي `frontend_pages/customer-menu/` نفسها، مش على Supabase
Storage. أي مطعم قديم من Phase 1 بينربط تلقائيًا فيه (backfill idempotent بآخر الملف).

**لا تعديل على أي جدول Phase 1.** الربط الوحيد: عمود `restaurants.theme_template`
(كان نص حر بلا معنى فعلي بـPhase 1) صار يُحدَّث تلقائيًا ليعكس slug القالب الفعلي المفعّل،
بس ما انحذف ولا اتغيّر نوعه.

---

## 3) الـAPI — المسارات الجديدة كاملة

### عام (`/api/public/*`) — بلا تسجيل دخول، rate-limited
```
GET  /api/public/demo/bootstrap                                — بيانات تجريبية ثابتة (بلا DB) للمعاينة
GET  /api/public/restaurants/:slug                              — معلومات المطعم العامة فقط
GET  /api/public/restaurants/:slug/menu                         — الفئات + المنتجات المتاحة
GET  /api/public/restaurants/:slug/tables/:token                — التحقق من الطاولة
GET  /api/public/restaurants/:slug/tables/:token/bootstrap       — كل شي بنداء واحد (أداء — بند 21)
POST /api/public/restaurants/:slug/tables/:token/orders          — إنشاء طلب (rate-limited: 12/دقيقة)
GET  /api/public/orders/:id   (header: x-order-token)            — حالة الطلب
GET  /api/public/sdk/menu-sdk.js                                 — ملف SDK ثابت (static، CORS/CORP مفتوحين عمدًا)
```

### قوالب (`/templates`) — قراءة لأي أدمن، كتابة سوبر أدمن فقط
```
GET  /templates                                                  — سوبر أدمن: كل شي. أدمن مطعم: active + built-in بس
POST /templates                            (multipart, حقل zip)  — سوبر أدمن — Upload+Validate+Install بخطوة وحدة
POST /templates/:templateId/versions/:versionId/activate         — سوبر أدمن
POST /templates/:templateId/versions/:versionId/deactivate       — سوبر أدمن
```

### قالب المطعم + صور (تحت `/restaurants/:id/...` الموجود أصلًا)
```
GET   /restaurants/:id/menu-template                             — الحالي + التاريخ الكامل
PUT   /restaurants/:id/menu-template                             — اختيار/تبديل/rollback (owner فقط)
PATCH /restaurants/:id/menu-template/settings                    — تحديث إعدادات العرض (owner فقط)
POST  /restaurants/:id/branding/logo               (multipart)   — رفع شعار (owner فقط)
POST  /restaurants/:id/products/:productId/image   (multipart)   — رفع صورة منتج (owner فقط)
```

---

## 4) Template System — كيف يشتغل فعليًا

**دورة حياة القالب**: `Upload → Validate → Install` (خطوة API وحدة، `POST /templates`) →
`Activate` (يصير متاح لاختيار المطاعم) → المطعم يختاره (`PUT .../menu-template`) →
`Preview` (فتح رابط أي طاولة فعلية — القالب المدمج/المخصص بيعرض بيانات المطعم الحقيقية
مباشرة) → `Rollback` (نفس مسار الاختيار، بس لنسخة أقدم من السجل).

**الفحص الأمني (`templateValidator.js` + `templatePathSafety.js`)** قبل أي تنصيب:
- حجم الـZIP، عدد الملفات، الحجم الإجمالي بعد الفك، حجم كل ملف — حدود صارمة.
- **لا** `../` أو مسارات مطلقة (unix/windows) أو null bytes — أي درجة traversal مرفوضة.
- حظر صريح: `.env*`, `package.json`, `node_modules/`, `.git/`, مفاتيح خاصة (`.pem`/`.key`/`id_rsa`),
  ملفات service account/credentials.
- حظر امتدادات تنفيذية بالكامل: `.sh .php .py .rb .exe .jar` وغيرها.
- Whitelist امتدادات مسموحة فقط (html/css/js/json/صور/خطوط/نصوص).
- `manifest.json` لازم يطابق schema صارم (zod) + `entry` لازم يكون ملف موجود فعليًا بالأرشيف.
- يدعم النمط الشائع (كل الملفات جوا مجلد جذر واحد بالـZIP) تلقائيًا.

**التخزين**: الملفات ترفع فعليًا لـSupabase Storage (`templates/{slug}/{version}/...`)
**قبل** ما ينكتب أي سطر بقاعدة البيانات — لو فشل الرفع بالنص، ما رح يصير سجل "معلّق" بلا ملفات.

**العزل الأمني (بند 13)**: القوالب المخصصة (غير المدمجة) تتحمّل من رابطها العام على
Supabase Storage — origin مختلف تمامًا عن admin/backend، **بلا أي JWT أو سر إطلاقًا**.
الصفحة الافتراضية (`customer-menu/index.html`) تتصرف كـ**resolver**: لو القالب المفعّل
مو المدمج، بتعمل `location.replace()`️ لرابط القالب الفعلي مع تمرير slug/token بالـquery
فقط — عزل document-level حقيقي، مش iframe مع postMessage معقّد بلا داعي (ما في سر
يحتاج bridge أصلًا — MenuSDK كله Public API).

**MenuSDK (بند 12)**: ملف واحد (`backend/src/public/menu-sdk.js`) مصدر حقيقة وحيد،
يُخدَم static من الـbackend نفسه (`/api/public/sdk/menu-sdk.js`) — أي قالب (مدمج أو
مخصص) يحمّله بنفس الرابط. فيه: `getRestaurant/getBranding/getCategories/getProducts/
getTable/createOrder/getOrderStatus/pollOrderStatus` + دعم demo mode مدمج بداخله (يعني
أي قالب تاني بيستخدم SDK بياخد دعم المعاينة التجريبية مجانًا بلا ما يكتب كود إضافي).

---

## 5) الأمان — نقاط مهمة يجب معرفتها

1. **الـNode API يتصل مباشرة بـpg بصلاحيات service-role (بيتجاوز RLS)** — تمامًا متل
   Phase 1. هذا يعني كل قيد "لا تكشف بيانات إدارية" بالـPublic API (بند 3) **مفروض يدويًا
   بكل query** (SELECT محدد الأعمدة، مافي `select *` بـpublicMenu.controller.js) —
   مو معتمد على RLS إطلاقًا لأنها ما تنطبق هون. يهم مين بيراجع الكود لاحقًا يعرف هالفرق.
2. **Order Token**: `orders.access_token` (uuid) موجود أصلًا من `hardening-v1.sql` —
   Phase 2 بس أضافت الـNode endpoints فوقه. عدم تطابق التوكن وعدم وجود الطلب يرجعوا
   **نفس** 404 بالضبط (منع oracle attack لتخمين IDs صحيحة).
3. **دفاع بعمق على السعر**: `publicOrders.controller.js` يتحقق من توفر المنتجات قبل
   الإدراج (رسالة خطأ واضحة للزبون)، **و** trigger `validate_order_before_insert`
   (Phase 1، ما انلمس) يعيد حساب `total`/`items` فعليًا وقت الإدراج بغض النظر عمّا
   أُرسل. حتى لو تجاوز أحدهم الفحص الأول، الثاني ما بينخدع.
4. **إعدادات القالب (`templateSettingsSchema`)**: `.strict()` بـzod — أي مفتاح غير
   موجود بالـwhitelist (show_search/show_categories/show_images/layout/card_style)
   يترفض بالكامل. ما في طريقة تحقن قيمة تنفيذية.
5. **CORS/CORP على menu-sdk.js**: عمدًا مفتوح (`Cross-Origin-Resource-Policy: cross-origin`)
   لأنو أي قالب مخصص مستضاف بعنوان تاني لازم يحمّله بـ`<script src>`. باقي الـAPI يضل
   محكوم بـ`CORS_ORIGIN` الموجود أصلًا من Phase 1 — **لازم تضيفوا عنوان استضافة
   customer-menu/restaurant-admin لهالمتغيّر بالإنتاج**.
6. **رفع الصور**: فحص MIME من قائمة صور فقط + حد 5MB، بلا تخزين binary بقاعدة البيانات
   (بند 18) — الملف يترفع لـStorage ويترجع بس الرابط العام.
7. **Rate limiting إضافي**: `orderCreationLimiter` (12/دقيقة) فوق الحد العام الموجود —
   طبقة إضافية فوق `uniq_active_order_per_table` (Phase 1) لتصعيب السبام.

---

## 6) الاختبار — شو فعليًا اشتغل بهالبيئة، وشو ينتظر `npm install`

**⚠️ هالبيئة (sandbox) ما فيها اتصال إنترنت ولا `node_modules` أصلًا (حتى قبل Phase 2).**
يعني ما قدرت أشغّل الـserver الفعلي ولا `npm run smoke` هون. اللي قدرت أعمله فعليًا
وأثبت إنو شغّال:

✅ **شغّلته فعليًا وطلع PASS بالكامل** (`node scripts/test-template-path-safety.js`,
بلا أي dependency): **26/26 فحص أمني** لمنع path traversal، مسارات مطلقة، ملفات محظورة
(`.env`, `package.json`, `node_modules`, `.git`, مفاتيح خاصة)، امتدادات، واكتشاف مجلد
جذر مشترك.

✅ **فحصت syntax لكل ملف JS جديد/معدّل** بـ`node -c` (35 ملف) — كلهم OK، بما فيهم كل
ملفات Phase 1 الأصلية (تأكيد إضافي إنو ولا شي انكسر).

✅ **فحصت توازن الوسوم + صحة الـJavaScript الداخلي** لكل صفحة HTML جديدة/معدّلة
(customer-menu/index.html، restaurant-admin.html، admin-panel.html المعدّل).

⏳ **يحتاج `npm install` (بيئة عندها إنترنت) قبل ما يشتغل أي شي فعليًا**: أضفنا
`adm-zip` و`multer` كـdependencies جديدة — الـbackend **ما رح يقلع أساسًا** بدون
تثبيتهم (نفس الشي كان صحيح لو Phase 1 ضافت أي dependency جديدة — مو خلل، بس لازم
تنتبهوله). بعد `npm install`:
```
npm run test:template-path-safety   # لازم يضل PASS (نفس الملف، بس أكيد بعد install)
npm run smoke                        # فيه 4 فحوصات جديدة إضافية لمسارات Phase 2
```

⏳ **لازم تعملوه يدويًا قبل الاستخدام الفعلي**:
1. شغّلوا `backend/db/phase2.sql` على قاعدة البيانات (بعد schema.sql + hardening-v1.sql).
2. أنشئوا بـSupabase Storage: bucket `templates` وbucket `restaurant-assets` (كلاهما
   **public read**).
3. أضيفوا `SUPABASE_URL` و`SUPABASE_SERVICE_ROLE_KEY` لمتغيرات بيئة الـbackend.
4. بدّلوا `PROD_API_BASE` (بكل صفحة frontend جديدة/معدّلة) و`CUSTOMER_MENU_BASE`
   (بـ`restaurant-admin.html`) لعناوينكم الفعلية بعد النشر.
5. أضيفوا عنوان استضافة الصفحات الجديدة لـ`CORS_ORIGIN`.

**اختبارات أمنية يدوية موصى فيها بعد الـdeploy** (بند 23 بالبرومبت — ما قدرت أشغّلها
هون بلا DB/شبكة حقيقية، بس صممت الكود عشانها تنجح):
- مطعم A ما يقدر يوصل لبيانات مطعم B (كل query بالـPublic API مقيّد بـslug/restaurant_id).
- زبون ما يقدر يقرأ طلب تاني بلا التوكن الصحيح (نفس 404).
- زبون ما يقدر يعدّل حالة/سعر/مطعم/طاولة الطلب (Public API ما فيها endpoint تعديل أصلًا).
- قالب فيه `../../../etc/passwd` أو `.env` أو `.php` ينرفض قبل أي تنصيب (مثبت بـ§ فوق).
- قالب manifest ناقص/غلط ينرفض برسالة واضحة.

---

## 7) قرارات هندسية مهمة (عشان ما تصير مفاجأة لاحقًا)

- **Restaurant Admin Dashboard صفحة جديدة منفصلة (`restaurant-admin.html`)**، مش حشر
  Products/Tables/Branding داخل `admin-panel.html` (اللي هو أصلًا خاص بالسوبر أدمن حصرًا
  ويتعامل مع كل المطاعم دفعة وحدة، مش سياق مطعم واحد). هذا نفس فصل الأدوار الموجود
  أصلًا بين `admin-panel.html` (سوبر أدمن) و`cashier-panel.html` (owner/cashier) —
  الصفحة الجديدة بتكمّل نفس المنطق بدل ما تكسره.
- **"Preview" على مستوى المطعم = اختيار فعلي + فتح الرابط الحي.** الاختيار رخيص وقابل
  للعكس فورًا (Rollback بنفس المسار)، فما في داعي حقيقي لبناء "معاينة بلا التزام" معقّدة.
  أما على مستوى السوبر أدمن (بلا سياق مطعم)، في `demo mode` كامل بيانات وهمية بلا لمس
  أي DB إطلاقًا — يغطي حالة "بدي أشوف شكل القالب قبل ما أفعّله للكل".
- **`theme_template` (عمود قديم بـPhase 1)** صار يُحدَّث تلقائيًا ليعكس القالب الفعلي
  بدل ما يضل نص حر بلا معنى — قرار متعمّد للحفاظ على قيمته بدل حذفه.

---

## 8) الباقي لـPhase 3 (مو ناقص عن قصور، بس خارج نطاق واقعي لمرحلة وحدة)

1. **تنظيف الملفات اليتيمة**: لو فشل إدراج `template_versions` بعد ما نجح رفع الملفات
   لـStorage (نادر، بس ممكن)، الملفات تضل بالـStorage بلا سجل DB. محتاج job دوري
   ينضف based on storage paths يلي ما إلها template_version مطابق.
2. **معاينة "حقيقية بلا التزام" لصاحب المطعم**: endpoint معاين محمي (`requireAuth`)
   يرجّع bootstrap-shaped payload لنسخة مرشّحة بلا ما يكتب `restaurant_menu_templates` —
   حاليًا الحل البديل (اختيار فوري + rollback فوري) يغطي نفس الحاجة عمليًا.
3. **توليد QR فعلي** لروابط الطاولات (حاليًا رابط نصي + زر نسخ — كافي لكتابة NFC،
   بس QR بصري إضافة UX لطيفة).
4. **صفحة Vercel/hosting rewrite جاهزة** لـ`/menu/:slug/:token` كمسار نظيف (الكود
   يدعمه فعليًا عبر `location.pathname` matching، بس محتاج ملف `vercel.json`/إعداد
   استضافة فعلي حسب وين رح تستضيفوا `frontend_pages` بالتحديد — غير معروف لي من الكود).
5. **اختبارات تكامل حقيقية** (integration tests) ضد DB فعلية + Supabase Storage حقيقي —
   الـsandbox هون ما فيه شبكة/DB، فأقصى شي قدرت أعمله هو اختبار المنطق النقي +
   syntax checks شاملة (موثّقة بالتفصيل بـ§6).
6. **Refresh tokens / إبطال جلسات** — نفس الملاحظة كانت موجودة أصلًا بـPHASE-1-REPORT.md
   كعمل متبقي، لسا صحيحة، ما تغيّرت بـPhase 2.

---

**PHASE 2 COMPLETE**
