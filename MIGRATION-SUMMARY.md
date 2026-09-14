# MIGRATION-SUMMARY.md — من Backend/Vercel/Node إلى GitHub Pages → Supabase

هذا الملف هو المرجع النهائي والدقيق لحالة المشروع بعد الهجرة الكاملة. يغطي: ماذا
تغيّر، أين ذهبت كل وظيفة قديمة، كيف تُعِدّ المشروع من الصفر، وما هي القيود
المعروفة المتبقية.

---

## 1) الخلاصة بجملة واحدة

كل ما كان يعمل بـ**Node/Express/Vercel** (توجيه، تحكم، مصادقة مخصصة، اتصال pg
مباشر) أُلغي بالكامل. مكانه الآن:

- **قراءات/كتابات بسيطة** → `supabase-js` مباشرة من الـFrontend، محكومة بـRLS.
- **عمليات حساسة أو تحتاج transaction** (حساب سعر الطلب، إنشاء مطعم+اشتراك+أدمن،
  تفعيل قالب) → PostgreSQL Functions (`RPC`) بصلاحية `SECURITY DEFINER`.
- **عزل بيانات كل مطعم عن الآخر** → Row Level Security حقيقية على مستوى قاعدة
  البيانات، **وليس** تحققًا بالـFrontend.
- **تسجيل الدخول والجلسات** → Supabase Auth حقيقي (`supabase.auth.signInWithPassword`)
  بدل JWT مخصص + bcrypt.
- **الحالات القليلة التي تحتاج فعليًا `service_role`** (إنشاء مستخدم Auth جديد،
  فحص/رفع ملف ZIP) → **Edge Functions فقط**، أبدًا من الـFrontend.
- **صفحة المنيو والطلب من الزبون** → لا تتغيّر شكلًا أو UX إطلاقًا؛ فقط `menu-sdk.js`
  صار يتصل بـSupabase (PostgREST) بدل الباكند القديم، بنفس الـPublic API تمامًا.

**لا يوجد أي Node server يُشغَّل بعد الآن. لا Express. لا `pg` من الفرونت إند. لا
bcrypt بالفرونت إند. لا Vercel API routes.**

---

## 2) خريطة كاملة: كل مسار Express قديم → بديله الحالي

### مصادقة (`auth.routes.js`)
| القديم | الجديد |
|---|---|
| `POST /auth/super-admin/login` | `supabase.auth.signInWithPassword()` + قراءة `super_admins` (RLS "يقرأ سطره فقط") |
| `POST /auth/restaurant-admin/login` | نفس الشي + قراءة `restaurant_admins` (owner/cashier) + فحص حالة المطعم بالفرونت إند |
| bcrypt hash + JWT مخصص + "bridge" لـSupabase Realtime | جلسة Supabase Auth واحدة تخدم REST + RPC + Realtime تلقائيًا (بلا أي "جسر") |
| Rate limiting على تسجيل الدخول (`rateLimit.js`) | **لا بديل DB-native** — فعّل Rate Limiting من إعدادات Supabase Auth (Dashboard) بدل الاعتماد على middleware مخصص. *(قيد معروف، راجع §6)* |

### المطاعم/الاشتراكات/الباقات (`restaurants.routes.js`, `plans.routes.js`)
| القديم | الجديد |
|---|---|
| `GET /restaurants` (سوبر أدمن) | `rpc_admin_list_restaurants()` — قراءة مجمّعة (restaurant+plan+subscription+عدد طاولات) بنداء واحد |
| `POST /restaurants` (إنشاء مطعم+أدمن، transaction واحدة بالـNode) | Edge Function `onboard-restaurant` → `rpc_create_restaurant` (ذرّية DB) + `auth.admin.createUser` (service-role) + `rpc_attach_restaurant_admin`، مع rollback تلقائي عند فشل أي خطوة |
| `PATCH /restaurants/:id/status` | `rpc_update_restaurant_status(p_restaurant_id, p_status)` |
| `POST /restaurants/:id/subscriptions` (تغيير باقة) | `rpc_change_subscription_plan(p_restaurant_id, p_plan_id)` |
| `PATCH /restaurants/:id/branding` | `rpc_update_restaurant_branding(p_restaurant_id, p_brand_colors)` |
| `POST /restaurants/:id/branding/logo` | رفع مباشر لـ`Supabase Storage` (bucket `restaurant-assets`، owner فقط عبر RLS) ثم `rpc_update_restaurant_branding(p_logo_url=...)` |
| `GET /restaurants/:id` | قراءة RLS مباشرة: `.from('restaurants').select('*').eq('id', id)` |
| `GET /plans` | قراءة RLS مباشرة (سوبر أدمن يشوف الكل، الباقي يشوف `active=true` فقط) |
| `POST /plans`, `PATCH /plans/:id` | إدراج/تحديث RLS مباشر (`super admin writes/updates plans`) — بلا RPC |

### المنتجات/الطاولات (`restaurants.routes.js` فروعها)
| القديم | الجديد |
|---|---|
| `GET /restaurants/:id/products` | قراءة RLS مباشرة |
| `POST/PATCH /restaurants/:id/products` | `rpc_upsert_product(...)` — يحسب من جديد، لا يثق بأي سعر قادم من العميل |
| `DELETE /restaurants/:id/products/:pid` | `rpc_delete_product(p_restaurant_id, p_product_id)` |
| `POST /restaurants/:id/products/:pid/image` | رفع مباشر لـStorage ثم `rpc_upsert_product(p_image_url=...)` |
| `GET /restaurants/:id/tables` | قراءة RLS مباشرة |
| `POST /restaurants/:id/tables` | `rpc_create_table(p_restaurant_id, p_table_number)` |
| `POST /restaurants/:id/tables/bulk` | `rpc_bulk_create_tables(p_restaurant_id, p_table_numbers int[])` — نفس دلالة "count" الأصلية (أرقام 1..count) |
| `DELETE /restaurants/:id/tables/:tid` | `rpc_deactivate_table(p_restaurant_id, p_table_id)` |

### القوالب (`templates.routes.js`)
| القديم | الجديد |
|---|---|
| `GET /templates` | قراءة RLS مباشرة (nested select) — RLS نفسها تفرّق بين ما يراه سوبر أدمن (الكل) وما يراه أدمن مطعم (active + مدمج) |
| `POST /templates` (رفع ZIP) | Edge Function `upload-template` (فحص أمني كامل + رفع Storage + إدراج DB، service-role) |
| `POST /templates/:id/versions/:vid/activate` | `rpc_activate_template_version(p_template_id, p_version_id)` *(جديد بهذه المرحلة)* |
| `POST /templates/:id/versions/:vid/deactivate` | `rpc_deactivate_template_version(p_template_id, p_version_id)` *(جديد بهذه المرحلة)* |
| `PUT /restaurants/:id/menu-template` (اختيار/rollback) | `rpc_select_menu_template(p_restaurant_id, p_template_version_id)` |
| `PATCH /restaurants/:id/menu-template/settings` | `rpc_update_menu_template_settings(p_restaurant_id, p_settings)` *(جديد بهذه المرحلة)* |
| `GET /restaurants/:id/menu-template` (حالي+تاريخ) | قراءة RLS مباشرة (nested select على `restaurant_menu_templates`) |

### العام/الزبون (`public.routes.js`)
| القديم | الجديد |
|---|---|
| `GET /api/public/restaurants/:slug/tables/:token` (bootstrap) | `rpc_menu_bootstrap(p_slug, p_card_token)` — الآن يرمي رموز خطأ ثابتة (`RESTAURANT_NOT_FOUND` إلخ) بدل نص عربي، لتبقى رسائل i18n بصفحة المنيو تعمل بلا أي تغيير فيها |
| `GET /api/public/demo/bootstrap` | مُحاكى بالكامل داخل `menu-sdk.js` (بلا أي نداء شبكة) |
| `POST /api/public/orders` | `rpc_create_order(p_slug, p_card_token, p_items)` — **لا يثق بالسعر/الاسم القادم من المتصفح إطلاقًا**؛ يعيد حسابهم من جدول `products` وقت الإدراج عبر trigger |
| `GET /api/public/orders/:id` (بحالة الطلب) | قراءة REST مباشرة بهيدر `x-order-token` مخصص (نفس آلية RLS الأصلية بالضبط)، **بـpolling وليس Realtime** — Realtime لا يقرأ custom headers |
| `GET /api/public/sdk/menu-sdk.js` | ملف ثابت `frontend/assets/menu-sdk.js`، بنفس الـPublic API تمامًا |

### الكاشير
| القديم | الجديد |
|---|---|
| قراءة/تحديث الطلبات + Realtime (كانت تستخدم supabase-js أصلًا، لكن بجلسة "bridge" JWT موقّعة من الباكند) | نفس الكود بالضبط، لكن بجلسة Supabase Auth حقيقية — أُلغيت آلية "الجسر" (`sb.realtime.setAuth()`) بالكامل لأنها لم تعد لازمة |

---

## 3) ما الذي تغيّر في الأمان (وكيف يمكن التحقق)

- **عزل حقيقي بين المطاعم**: كل RLS تعتمد على `current_staff_restaurant_id()`
  (مبنية على `auth.uid()` الحقيقي بعد هذه المرحلة، وليس أي حقل يرسله العميل).
  لا يوجد أي `using (true)` على جدول يحوي بيانات خاصة بمطعم — راجع
  `phase3-supabase-native.sql § RLS` لكل سياسة وسبب صياغتها.
- **لا ثقة بسعر الطلب القادم من العميل**: `rpc_create_order` يعيد حساب `items`/`total`
  من جدول `products` الفعلي وقت الإدراج (trigger `trg_validate_order`)، بغض النظر
  عمّا أرسله المتصفح.
- **لا أسرار بالفرونت إند إطلاقًا**: `frontend/assets/supabase-config.js` يحوي فقط
  `SUPABASE_URL` + anon key (عامان بتصميم Supabase نفسه). `service_role` وكل أسرار
  Edge Functions تعيش فقط بمتغيرات بيئة Supabase، ولا تصل للمتصفح أبدًا — تحقق بنفسك:
  `grep -r "service_role\|SERVICE_ROLE" frontend/` يجب أن يرجع فارغًا.
- **رفع ملفات القوالب محصور بـEdge Function** (`upload-template`) لأنه الوحيد القادر
  على حمل `service_role`؛ bucket `templates` مقفول كليًا عن أي كتابة من
  `anon`/`authenticated` مباشرة.
- **تحسين لم يكن موجودًا بالأصل**: سوبر أدمن يقدر الآن يشوف الباقات المعطّلة أيضًا
  (`plans`)، وليس الفعّالة فقط كما كان بالـNode القديم — بدون أي تعديل إضافي مطلوب،
  ناتج طبيعي عن تصميم RLS.

---

## 4) الإعداد من الصفر (خطوة بخطوة)

### أ) قاعدة البيانات
على مشروع Supabase جديد، بـ SQL Editor، شغّل **بالترتيب بالضبط**:
```
backend/db/schema.sql
backend/db/hardening-v1.sql
backend/db/phase2.sql
backend/db/phase3-supabase-native.sql
backend/db/phase4-frontend-migration.sql
```
(`backend/db/migrate-existing-cafe.sql` اختياري — فقط لو عندك بيانات مطعم واحد
قديم من قبل تعدد المستأجرين).

### ب) Storage
أنشئ (Storage → New bucket) اثنين، كلاهما **Public**:
- `restaurant-assets`
- `templates`

(الـpolicies الفعلية موجودة أصلًا داخل `phase3-supabase-native.sql § 6` — إنشاء
الـbucket نفسه فقط لا يمكن تنفيذه من SQL، يُعمل يدويًا من اللوحة أو عبر
`supabase storage create-bucket`).

### ج) Edge Functions
```bash
supabase functions deploy onboard-restaurant
supabase functions deploy upload-template
```
لا حاجة لضبط أي `secrets` يدويًا — `SUPABASE_URL`/`SUPABASE_ANON_KEY`/
`SUPABASE_SERVICE_ROLE_KEY` تُحقن تلقائيًا بكل Edge Function على مشروعك.

### د) أول سوبر أدمن
```bash
export SUPABASE_URL=https://YOUR-PROJECT.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=YOUR-SERVICE-ROLE-KEY
cd backend/scripts && npm install && cd ../..
node backend/scripts/create-super-admin.mjs --email you@yourcompany.com --password "StrongPass123!" --name "اسمك"
```

### هـ) الفرونت إند
1. عبّي `frontend/assets/supabase-config.js` بـ `SUPABASE_URL` و anon key مشروعك.
2. (اختياري) عبّي `CUSTOMER_MENU_BASE` بـ `frontend/restaurant-admin/index.html`
   بعنوان صفحة `frontend/menu/` الفعلي بعد النشر — يُستخدم فقط لبناء روابط الطاولات.
3. انشر مجلد `frontend/` كاملًا على GitHub Pages (أو أي static hosting).
4. سجّل دخول من `frontend/admin/` بحساب السوبر أدمن، أنشئ باقة، ثم أنشئ مطعمك الأول.

### و) عندك بيانات إنتاج قديمة (bcrypt) من قبل هذه الهجرة؟
```bash
node backend/scripts/migrate-existing-admins-to-auth.mjs --dry-run   # عاين أولًا
node backend/scripts/migrate-existing-admins-to-auth.mjs             # نفّذ فعليًا
```
**ملاحظة تقنية غير قابلة للتفادي**: bcrypt hash لا يمكن عكسه لكلمة مرور أصلية —
هذا هو الغرض من bcrypt نفسه. السكربت ينشئ مستخدم Supabase Auth جديد لكل حساب
قديم بكلمة مرور عشوائية مؤقتة، ويطبع رابط "تعيين كلمة مرور" لكل مستخدم — لازم
يُرسل يدويًا لصاحبه قبل أول تسجيل دخول بالنظام الجديد.

---

## 5) قيود معروفة (لم تُحل، موثّقة بصراحة)

1. **Rate limiting على تسجيل الدخول**: لا يوجد بديل DB-native لـ`loginLimiter`
   القديم. فعّله من إعدادات Supabase Auth (Dashboard → Authentication → Rate Limits)
   بدل الاعتماد على middleware مخصص.
2. **دور "cashier" لا يقدر يرفع شعار/صور منتجات**: RLS الخاصة بـbucket
   `restaurant-assets` تشترط `current_staff_role() = 'owner'` صراحة (راجع
   `phase3-supabase-native.sql § 6`). لو كان هذا مقصودًا أصلًا فلا داعي لأي تعديل؛
   لو تحتاج كاشير يرفع صور، وسّع شرط الـpolicy ليشمل `'cashier'` أيضًا.
3. **لا يوجد مسار لإنشاء حساب "cashier" إضافي لمطعم قائم** — هذا لم يكن موجودًا
   أصلًا بالـNode القديم أيضًا (فقط owner واحد يُنشأ وقت إنشاء المطعم)، فلم تُضَف
   هذه الميزة بهذه الهجرة لتجنّب توسيع النطاق. يمكن إضافتها لاحقًا بنفس نمط
   Edge Function `onboard-restaurant` (إنشاء مستخدم Auth + `rpc_attach_restaurant_admin`
   بـ`p_role='cashier'`).
4. **كلمات مرور الحسابات القديمة (bcrypt) غير قابلة للنقل** — راجع §4-و أعلاه.
5. **`upload-template` Edge Function يعتمد على `npm:adm-zip` و`npm:zod` عبر توافق
   npm بـDeno** — هذا مدعوم رسميًا بـSupabase Edge Functions، لكن لم يُختبر فعليًا
   على مشروع Supabase حي ضمن هذا التسليم (بيئة العمل هون بلا اتصال إنترنت خارجي
   لنشر/تجربة Edge Functions فعليًا). رَاجع سلوكه على أول رفع قالب حقيقي، وأخبرني
   لو ظهر أي خطأ تشغيلي غير متوقع لتعديله.

---

## 6) ملفات محذوفة (مع تأكيد البديل لكل وظيفة)

| المحذوف | البديل |
|---|---|
| `backend/src/app.js`, `server.js`, `api/index.js`, `vercel.json` | لا حاجة لأي سيرفر — كل شي RLS/RPC/Edge Function |
| `backend/src/routes/*`, `controllers/*`, `middleware/*`, `validators/*` | راجع الجدول بالقسم 2 أعلاه لكل مسار على حدة |
| `backend/src/utils/ApiError.js`, `asyncHandler.js` | لا حاجة — الأخطاء تُرمى وتُعرض مباشرة من رسالة PostgREST/RPC |
| `backend/src/utils/audit.js` | trigger `fn_audit_log()` بقاعدة البيانات (موجود أصلًا من `phase2.sql`) |
| `backend/src/utils/supabaseAuth.js` (بناء "bridge" JWT) | Supabase Auth حقيقي — الجلسة نفسها تخدم REST+RPC+Realtime |
| `backend/src/utils/storage.js` | استدعاءات `supabase.storage` مباشرة (من الفرونت إند أو الـEdge Function حسب الحساسية) |
| `backend/src/utils/templateValidator.js`, `templatePathSafety.js` | منقولة حرفيًا داخل `supabase/functions/upload-template/index.ts` |
| `backend/src/config/db.js` (pg Pool) | لا اتصال pg مباشر من أي مكان بعد الآن |
| `backend/src/public/menu-sdk.js` | `frontend/assets/menu-sdk.js` (نفس العقد العام تمامًا) |
| `backend/scripts/create-super-admin.js` (bcrypt+pg) | `backend/scripts/create-super-admin.mjs` (Supabase Auth+service-role) |
| `backend/scripts/smoke-test.js` | كان يختبر سيرفر Express المحذوف؛ لا بديل مباشر مطلوب |
| `backend/scripts/test-template-path-safety.js` | المنطق نفسه منقول للـEdge Function؛ يُختبر عمليًا برفع قالب تجريبي |
| `backend/package.json`, `package-lock.json` (Express deps) | `backend/scripts/package.json` (اعتماد وحيد: `@supabase/supabase-js`) |

---

## 7) ملفات جديدة بهذه المرحلة

```
backend/db/phase4-frontend-migration.sql
backend/scripts/create-super-admin.mjs
backend/scripts/migrate-existing-admins-to-auth.mjs
backend/scripts/package.json
supabase/functions/_shared/cors.ts
supabase/functions/onboard-restaurant/index.ts
supabase/functions/upload-template/index.ts
frontend/assets/supabase-config.js
frontend/assets/menu-sdk.js
MIGRATION-SUMMARY.md   (هذا الملف)
```

## 8) ملفات فرونت إند مُعدَّلة (نفس التصميم/الصفحات/الـworkflows بالكامل)

- `frontend/menu/index.html` — سطرين فقط: مصدر تحميل `menu-sdk.js` + معاملات `init()`
- `frontend/cashier/index.html` — تسجيل الدخول فقط (Supabase Auth حقيقي بدل bridge JWT)
- `frontend/restaurant-admin/index.html` — طبقة البيانات كاملة (Supabase بدل `fetch`)، + إصلاح رابط "شاشة الطلبات" المكسور أصلًا (`./cashier-panel.html` → `../cashier/`)
- `frontend/admin/index.html` — طبقة البيانات كاملة (Supabase + RPC + Edge Functions بدل `fetch`)
- `frontend/index.html` — **بلا أي تغيير** (صفحة تسويقية ثابتة، لا تتصل بأي backend أصلًا)

## 9) قائمة تحقق سريعة بعد النشر

- [ ] تسجيل دخول سوبر أدمن ينجح ويعرض لوحة فارغة بلا أخطاء console
- [ ] إنشاء باقة → إنشاء مطعم (يستدعي Edge Function) → تسجيل دخول بحساب المطعم الجديد
- [ ] إضافة منتج + رفع صورته → يظهر بصفحة المنيو للطاولة الأولى
- [ ] فتح رابط طاولة على هاتفين مختلفين، تقديم طلب، ورؤيته لحظيًا بشاشة الكاشير (Realtime)
- [ ] تجربة `?demo=1` على صفحة المنيو تعمل بلا أي اتصال شبكة فعلي
- [ ] محاولة قراءة بيانات مطعم آخر بنفس حساب الأدمن (من console المتصفح) وتفشل — دليل عملي على عزل RLS
