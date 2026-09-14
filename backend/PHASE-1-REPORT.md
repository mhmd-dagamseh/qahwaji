# PHASE 1 REPORT — Cafe SaaS Core (قهوجي)

> **⚠️ تاريخي — يصف معمارية Node/Express/Vercel القديمة، لم تعد قائمة.**
> المرجع الحالي والدقيق: [`../MIGRATION-SUMMARY.md`](../MIGRATION-SUMMARY.md) بجذر المشروع.


> مرجع لأي AI/مطوّر رح يشتغل على **Phase 2** (Customer Menu + Templates). هاد التقرير بيوثّق وضع
> المشروع كما هو بعد Phase 1، القرارات المهمة، والمتبقي فعليًا.

---

## 0) ملاحظة مهمة قبل كل شي

هاد المشروع **مش نقطة بداية فاضية**. لما فحصته لقيت إنو فيه جولة "Hardening v1" سابقة موثقة بالكامل
بملف [`CHANGES.md`](./CHANGES.md) — عالجت أغلب البنود الحرجة (RLS، auth، race conditions، order
snapshot، audit logs...). Phase 1 هاد **ما أعاد بناء ولا كسر أي شي من هيك** — ركّز فقط على الفجوات
المتبقية الفعلية بمقابل الـ prompt الأصلي (بنية النشر، شكل الأخطاء، dependency على localhost).

---

## 1) Architecture after Phase 1

```
backend/
├── api/
│   └── index.js          # نقطة دخول Vercel — بيصدّر src/app.js مباشرة
├── src/
│   ├── app.js             # Express app نفسه (بدون listen) — جديد بـPhase 1
│   ├── server.js          # تشغيل محلي فقط (app.listen) — أُعيد كتابته ليصير رقيق
│   ├── config/db.js
│   ├── controllers/
│   ├── middleware/
│   ├── routes/
│   ├── utils/
│   └── validators/
├── db/
│   ├── schema.sql
│   ├── hardening-v1.sql
│   └── migrate-existing-cafe.sql
├── scripts/
│   ├── create-super-admin.js
│   └── smoke-test.js      # جديد بـPhase 1
├── vercel.json             # جديد بـPhase 1
├── .gitignore               # جديد بـPhase 1 (ما كان موجود إطلاقاً)
├── package.json
└── .env.example

frontend_pages/ (خارج backend/، زي ما كانت)
├── main-Page.html      # صفحة تسويقية ثابتة — لا تتكلم مع أي API، ما لمستها
├── admin-panel.html    # لوحة تحكم أدمن المطعم/سوبر أدمن — عدّلت API_BASE + قراءة الأخطاء
└── cashier-panel.html  # خارج النطاق الأساسي (بقرار الـ prompt) — نفس التعديلين البسيطين بس
```

**القرار الأهم:** ما فيه `orders.routes.js` / `tables.routes.js` / `products.routes.js` منفصلة —
وهاد **مش نقص**. كل هالمسارات موجودة ومربوطة فعليًا كـsub-resources جوا `restaurants.routes.js`
(مثلاً `POST /restaurants/:id/products`)، لأنها كلها محكومة بنفس منطق `requireRestaurantAccess` +
`requireRole`. فحصتها سطر سطر وتأكدت إنها كلها مربوطة بـ Express فعليًا (مش مجرد controllers معلّقة
بدون route) — هاد كان أول شي تحقق منه الـ prompt الأصلي بالتحديد.

---

## 2) Files created

| الملف | الغرض |
|---|---|
| `backend/src/app.js` | Express app قابل للتصدير (بدون `.listen()`) — يُستخدم محليًا وعلى Vercel |
| `backend/api/index.js` | نقطة دخول Vercel serverless — يصدّر `app.js` |
| `backend/vercel.json` | يوجّه كل الطلبات لنفس الـfunction عشان كل المسارات (`/auth/*`, `/restaurants/*`...) تضل شغالة بنفس الشكل |
| `backend/scripts/smoke-test.js` | اختبار دخان يشغّل الـapp بالذاكرة (بدون DB حقيقي) ويتحقق من `/health`، شكل الأخطاء، وحماية المسارات |
| `backend/.gitignore` | ما كان موجود إطلاقاً — `node_modules/`, `.env`, `.vercel` |
| `backend/PHASE-1-REPORT.md` | هاد الملف |

## 3) Files modified

| الملف | التعديل |
|---|---|
| `backend/src/server.js` | صار رقيق جدًا — بس `require("./app")` + `app.listen()`. كل منطق الـmiddleware/routes انتقل لـ`app.js` |
| `backend/src/utils/ApiError.js` | صار ياخد `code` اختياري (مع افتراضي محسوب من الـstatus: `NOT_FOUND`, `UNAUTHORIZED`, `FORBIDDEN`, `CONFLICT`...) |
| `backend/src/middleware/errorHandler.js` | كل الأخطاء صارت ترجع بشكل موحّد: `{ success: false, error: { code, message } }` — بند 10 بالـprompt الأصلي |
| `backend/package.json` | `main` صار `src/app.js`، أضفت `engines.node`، أضفت سكربت `smoke` |
| `backend/README.md` | أضفت قسم "النشر على Vercel" و"اختبار محلي سريع" |
| `frontend_pages/admin-panel.html` | `API_BASE` صار يكتشف تلقائيًا localhost مقابل إنتاج (بدل ثابت localhost فقط)؛ قراءة رسالة الخطأ صارت `data.error.message` بدل `data.error` |
| `frontend_pages/cashier-panel.html` | نفس تعديل `API_BASE` وقراءة الخطأ. **لم يُعاد بناء أي شي تاني بهالملف** — بقي خارج النطاق كما طُلب |

## 4) Files deleted

لا شي. ما انحذف أي ملف أو functionality موجودة.

## 5) Database migrations

**لا فيه migration SQL جديد بهالجولة.** فحصت `schema.sql` و`hardening-v1.sql` و`migrate-existing-cafe.sql`
بالتفصيل — الـschema سليم ومكتمل لأهداف Phase 1: foreign keys، unique constraints (`card_token`،
`(restaurant_id, table_number)`، اشتراك فعّال واحد بس)، check constraints (`table_number > 0`،
`price >= 0`)، indexes على الاستعلامات الشائعة (`idx_orders_restaurant_status`,
`idx_products_restaurant_available`)، وRLS مفعّل بشكل صحيح على كل الجداول العامة.

**ترتيب التشغيل يبقى نفسه:**
```bash
# 1) إذا أول مرة:
schema.sql
# 2) دائمًا بعده:
hardening-v1.sql
# 3) اختياري، بس إذا فيه بيانات كافيه قديمة فعلية بالإنتاج (اقرأ التعليمات بأعلى الملف):
migrate-existing-cafe.sql
```

## 6) Routes

ما تغيّر ولا مسار واحد من ناحية الـpath أو الصلاحيات المطلوبة. كل المسارات القديمة تشتغل بالضبط
متل ما كانت — التغيير الوحيد هو **شكل جسم الخطأ** (انظر قسم 8).

مرجع سريع (كامل بملف `README.md`):

- `POST /auth/super-admin/login`, `POST /auth/restaurant-admin/login`
- `GET /plans` (عام), `POST /plans`, `PATCH /plans/:id` (سوبر أدمن)
- `GET|POST /restaurants`, `PATCH /restaurants/:id/status`, `POST /restaurants/:id/subscriptions` (سوبر أدمن)
- `GET /restaurants/:id`, `PATCH /restaurants/:id/branding` (owner/سوبر أدمن)
- `GET|POST /restaurants/:id/tables`, `POST /restaurants/:id/tables/bulk`, `DELETE /restaurants/:id/tables/:tableId`
- `GET|POST /restaurants/:id/products`, `PATCH|DELETE /restaurants/:id/products/:productId`
- `GET /restaurants/:id/orders/stats`, `GET /restaurants/:id/orders/top-products`
- `GET /health` — بدون تغيير بالشكل، لسا `{ ok: true }`

## 7) Environment variables

نفس المتغيرات الموجودة بـ`.env.example` سابقًا — **ما احتجنا نضيف ولا نشيل أي متغير**، الملف كان
مكتمل أصلاً:

```
DATABASE_URL
JWT_SECRET
JWT_EXPIRES_IN
SUPABASE_JWT_SECRET
SUPABASE_TOKEN_EXPIRES_IN
PORT
NODE_ENV
CORS_ORIGIN
```

بالإضافة، على Vercel تحديدًا: نفس المتغيرات هاي تُعبّى بلوحة تحكم Vercel (Project Settings →
Environment Variables) — لا حاجة لملف `.env` هناك، و`PORT` غير مستخدم أصلاً على Vercel (serverless).

**بالفرونت إند** (خارج هالـ backend): لسا فيه ثابت `PROD_API_BASE` لازم يتعدّل يدويًا بـ
`admin-panel.html` و`cashier-panel.html` بعد ما ينشر الـbackend فعليًا على Vercel — هاد مقصود، لأنو
عنوان الـbackend النهائي مش معروف قبل أول deploy.

## 8) Security changes

- **شكل الأخطاء الموحّد**: كل استجابة خطأ صارت `{ success:false, error:{ code, message } }` بدل
  `{ error: "..." }` الخام. ما زلنا **لا نكشف** أي تفاصيل SQL، stack traces، أو أسرار — نفس السلوك
  القديم بالضبط، بس بشكل أكثر قابلية للاستهلاك برمجيًا من الفرونت إند (بند 10 و11 بالـprompt).
- **إزالة الاعتماد الحصري على localhost**: `API_BASE` بالفرونت إند صار يكتشف البيئة تلقائيًا بدل ما
  يكون `http://localhost:4000` ثابت بغض النظر عن مكان التشغيل.
- **لا تغييرات على auth/authorization/RLS نفسها** — كانت سليمة من الجولة السابقة (Hardening v1) ولم
  ألمسها. تحققت منها فقط (انظر قسم 11 بالتقرير الأصلي أدناه ضمن "Tests performed").

## 9) Tests performed

نفّذتهم فعليًا على الكونتينر (مش خطة نظرية):

1. `npm install` — نجح، 104 حزمة، بدون أخطاء.
2. `node -c` على كل ملفات `src/**/*.js` — لا أخطاء syntax.
3. `npm run smoke` (اختبار جديد) — شغّل `app.js` بالذاكرة وتحقق من:
   - `GET /health` → `200 { ok: true }` ✅
   - `GET /مسار-غير-موجود` → `404` بشكل `{ success:false, error:{ code:"NOT_FOUND", message } }` ✅
   - `POST /auth/super-admin/login` بجسم غير صالح → `400` بنفس شكل الخطأ الموحّد ✅
   - `GET /restaurants` بدون توكن → `401` ✅
4. `npm start` تشغيل حقيقي محلي على `PORT=4000` — `curl http://localhost:4000/health` رجع
   `{"ok":true}` بنجاح.

**لم يُختبر** (يحتاج `DATABASE_URL` حقيقي متصل بـ Supabase فعلي، غير متوفر بهالبيئة): تسجيل دخول
فعلي، إنشاء مطعم/طاولة/منتج فعلي، فرض حد الباقات عبر التريغر الفعلي. المنطق تمت مراجعته يدويًا
(code review) وهو نفسه من جولة Hardening v1 السابقة الموثقة والمُختبرة هناك.

## 10) Known remaining work (لـ Phase 2 ولاحقًا)

هاي كلها موثقة أصلاً بصراحة بـ`CHANGES.md` من الجولة السابقة، بضيف حالتها الحالية:

1. **Realtime حقيقية لتتبع الزبون لطلبه** — حاليًا polling عبر `access_token`، مش Supabase Realtime
   حقيقي (القيد: الـheaders المخصصة ما بتوصل لجلسات الـwebsocket). لسا كما هي — تحتاج Supabase Realtime
   Authorization (broadcast channels موقّعة) كمهمة منفصلة.
2. **Refresh token rotation** — حاليًا بس تقصير مدة access token (12 ساعة)، بدون rotation كاملة.
3. **انتهاء الاشتراك لا يُحدّث `subscriptions.status` تلقائيًا** — الفرض يصير فقط عبر تريغر
   `enforce_table_limit` (بيتحقق من `current_period_end > now()` وقت إضافة طاولة)، بس عمود الحالة
   نفسه بيضل `active` حتى لو الفترة خلصت فعليًا. يحتاج job/cron دوري (أو فحص إضافي بتسجيل الدخول)
   لتحديث الحالة صراحة — لم يُنفَّذ بهالجولة لأنه خارج نطاق "أساس" Phase 1.
4. **Customer Menu كامل + Template UI** — بالتصميم، مؤجّل لـPhase 2 كما طلب الـprompt الأصلي بالضبط.
5. **Integration tests حقيقية بـDB فعلي** — الـsmoke test الحالي يتحقق من البنية والشكل بس، مش من
   منطق الأعمال الفعلي (لأنه ما بيلمس DB). لازم test DB حقيقي (أو Testcontainers) قبل أول عميل حقيقي.
6. **`cashier-panel.html`** — بقي خارج النطاق تمامًا كما طُلب صراحة بالـprompt (`لا تعيد بناء
   Cashier Panel`)، غير تعديل `API_BASE`/قراءة الخطأ البسيطين.

---

**PHASE 1 COMPLETE**
