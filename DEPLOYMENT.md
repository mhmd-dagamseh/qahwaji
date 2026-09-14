# DEPLOYMENT.md — نشر الإنتاج

> **⚠️ تاريخي — يصف معمارية Node/Express/Vercel القديمة، لم تعد قائمة.**
> المرجع الحالي والدقيق: [`MIGRATION-SUMMARY.md`](MIGRATION-SUMMARY.md) بجذر المشروع.


## القرار الهندسي: أين يستضاف الفرونت إند؟

**Vercel وليس GitHub Pages** — لسببين فعليين بالكود:
1. صفحات `admin/`, `restaurant-admin/`, `cashier/` تحتاج تعديل `PROD_API_BASE` بعد كل نشر باكند جديد. Vercel يسمح بـ environment variable وقت الـ build لضبط هذا تلقائيًا؛ GitHub Pages يخدم ملفات ثابتة فقط بدون أي build step، فيبقى `PROD_API_BASE` يدويًا داخل كل ملف HTML — قابل للنسيان ومصدر أخطاء.
2. لو أردت لاحقًا CORS_ORIGIN دقيق (نطاق واحد فقط)، Vercel يعطيك نطاقًا ثابتًا (`your-frontend.vercel.app`) أو custom domain بسهولة أكبر من ضبط DNS لـ GitHub Pages.

**البديل المقبول:** إذا فضّلت GitHub Pages فعلًا لتبسيط لاحق (استضافة مجانية بدون حساب Vercel ثانٍ)، هذا ممكن حرفيًا لأن الملفات HTML/CSS/JS ثابتة بالكامل ولا تحتاج build — فقط عدّل يدويًا قيمة `PROD_API_BASE` في كل من: `frontend/admin/index.html`, `frontend/restaurant-admin/index.html`, `frontend/cashier/index.html`, `frontend/menu/index.html` بعد أول نشر باكند، وتأكد أن `CORS_ORIGIN` بالباكند يحوي نطاق GitHub Pages (`https://USERNAME.github.io`).

---

## PART A — Supabase

1. اذهب إلى https://supabase.com → New Project. اختر اسمًا وكلمة مرور قاعدة بيانات قوية (احفظها — تدخل في `DATABASE_URL`).
2. **Project Settings → Database → Connection string** → اختر "Session pooler" → انسخه، هذا هو `DATABASE_URL` (استبدل `[YOUR-PASSWORD]` بكلمة المرور الحقيقية).
3. **Project Settings → API** → انسخ:
   - `Project URL` → هذا `SUPABASE_URL`
   - `anon public` key → يُستخدم فقط داخل ملفات الفرونت إند (`SUPABASE_ANON_KEY`)، آمن أن يكون علنيًا
   - `service_role` key → هذا `SUPABASE_SERVICE_ROLE_KEY`، **لا يوضع في الفرونت إند إطلاقًا**، فقط في متغيرات بيئة الباكند على Vercel
4. **Project Settings → API → JWT Settings → JWT Secret** → هذا `SUPABASE_JWT_SECRET` (يدخل بيئة الباكند فقط).
5. **SQL Editor** → نفّذ الملفات بهذا **الترتيب بالضبط**، كل ملف كاملًا بضغطة "Run":
   1. `backend/db/schema.sql`
   2. `backend/db/hardening-v1.sql`
   3. (اختياري، فقط إذا كان هناك بيانات كافيه قديمة فعلية) `backend/db/migrate-existing-cafe.sql` — اقرأ التعليقات أعلى الملف أولًا
   4. `backend/db/phase2.sql`
6. تحقق من الجداول: **Table Editor** يجب أن تظهر فيه `restaurants, plans, subscriptions, restaurant_tables, products, orders, audit_logs` وغيرها من جداول القوالب.
7. تحقق من RLS: **Authentication → Policies** (أو Table Editor → جدول `orders` → أيقونة القفل) يجب أن يظهر "RLS enabled" مع سياستين: "read order by token or staff" و"staff update orders". نفس الشيء لجدول `audit_logs`.
8. **Storage → New bucket** → أنشئ اسمين بالضبط: `templates` و`restaurant-assets`. اجعل كليهما **Public** (public read) — هذا مطلوب لأن الفرونت إند يحمّل هذه الملفات مباشرة بدون توقيع روابط.

## PART B — GitHub

يُرفع:
```
backend/          (بدون node_modules و.env)
frontend/
vercel.json (إن وُجد بجذر المشروع؛ حاليًا موجود داخل backend/ ويُستخدم من هناك مباشرة عند استيراد backend/ كجذر على Vercel)
README.md, DEPLOYMENT.md, API.md, TEMPLATE-SDK.md, ARCHITECTURE.md, FINAL-SETUP-GUIDE.md
.gitignore
```
لا يُرفع: `.env`, `node_modules/`, أي ملف يحوي كلمات مرور أو مفاتيح حقيقية.

```bash
git init
git add .
git commit -m "Phase 3: production-ready structure"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/qahwaji-saas.git
git push -u origin main
```

## PART C — Vercel (Backend)

1. https://vercel.com → Add New → Project → استورد مستودع GitHub.
2. **Root Directory**: اضبطه على `backend` (وليس جذر المستودع) — لأن `vercel.json` و`api/index.js` موجودان داخل `backend/`.
3. **Framework Preset**: Other (لا حاجة لـbuild step؛ Node/Express عادي).
4. **Build Command**: اتركه فارغًا (لا يوجد build حقيقي — `npm install` يكفي وVercel يشغّله تلقائيًا).
5. **Install Command**: `npm install` (افتراضي، لا تغيير).
6. **Output Directory**: لا يوجد (Serverless Functions، ليس static output).
7. **Environment Variables** أضف كل المتغيرات من `backend/.env.example` بقيمها الحقيقية:
   `DATABASE_URL, JWT_SECRET, JWT_EXPIRES_IN, SUPABASE_JWT_SECRET, SUPABASE_TOKEN_EXPIRES_IN, NODE_ENV=production, CORS_ORIGIN, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY`
8. اضغط Deploy. بعد الانتهاء، ستحصل على رابط مثل `https://qahwaji-backend.vercel.app`.
9. **Health check**: افتح `https://qahwaji-backend.vercel.app/health` — يجب أن يرجع `{"ok": true}`.

## PART D — Frontend

**إذا Vercel (الموصى به):**
1. مشروع Vercel ثانٍ منفصل → Root Directory: `frontend`.
2. Framework Preset: Other. لا build command (ملفات HTML ثابتة).
3. Deploy → ستحصل على `https://qahwaji-frontend.vercel.app`.

**إذا GitHub Pages:**
1. GitHub repo → **Settings → Pages**.
2. **Source**: Deploy from a branch. **Branch**: `main`. **Folder**: `/frontend` (إن كان الخيار متاحًا) أو انقل محتوى `frontend/` لفرع منفصل `gh-pages`.
3. الرابط الناتج: `https://YOUR-USERNAME.github.io/qahwaji-saas/`.

## PART E — ربط الفرونت إند بالباكند

في كل من الملفات الأربعة:
`frontend/admin/index.html`, `frontend/restaurant-admin/index.html`, `frontend/cashier/index.html`, `frontend/menu/index.html`

ابحث عن السطر:
```js
const PROD_API_BASE = "https://YOUR-BACKEND.vercel.app";
```
واستبدله برابط الباكند الحقيقي من PART C خطوة 8 (بدون `/` بالنهاية). أعد رفع الملفات (git commit + push، أو إعادة نشر يدوي إذا GitHub Pages).

## PART F — CORS

في متغيرات بيئة الباكند على Vercel، اضبط:
```
CORS_ORIGIN=https://qahwaji-frontend.vercel.app,https://YOUR-USERNAME.github.io
```
(اكتب كل نطاق فرونت إند حقيقي ستستضيف عليه، مفصولة بفواصل بدون مسافات إضافية). أعد نشر الباكند (Redeploy) بعد أي تعديل على متغيرات البيئة — Vercel لا يطبّقها تلقائيًا على deployment قائم.

## PART G — الاختبار النهائي

1. افتح رابط الفرونت إند الرئيسي.
2. سجّل دخول كسوبر أدمن (بعد إنشائه — راجع FINAL-SETUP-GUIDE.md الخطوة 12) على `/admin`.
3. أنشئ مطعمًا وباقة، ثم سجّل دخول كأدمن مطعم على `/restaurant-admin`.
4. أنشئ طاولة، افتح رابط NFC الناتج على `/menu/...`، تأكد من ظهور المنتجات.
5. أنشئ طلب تجريبي من صفحة المنيو، وتأكد من ظهوره فورًا على `/cashier` (realtime).
