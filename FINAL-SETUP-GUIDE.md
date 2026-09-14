# FINAL-SETUP-GUIDE.md

> **⚠️ تاريخي — يصف معمارية Node/Express/Vercel القديمة، لم تعد قائمة.**
> المرجع الحالي والدقيق: [`MIGRATION-SUMMARY.md`](MIGRATION-SUMMARY.md) بجذر المشروع.


لديك المشروع على جهازك (فك ضغط `qahwaji-saas.zip`). هذا الدليل يشغّله محليًا من الصفر، ثم ينشره على الإنتاج.

## محليًا

**Step 1 — Node.js**: تأكد من تثبيت Node 18 أو أحدث (`node -v`).

**Step 2 — المستودع**: أنت بالفعل داخل المجلد بعد فك الضغط. لو رفعته لـGitHub لاحقًا: `git clone`.

**Step 3 — تثبيت مكتبات الباكند**:
```bash
cd backend
npm install
```

**Step 4 — إنشاء مشروع Supabase**: راجع `DEPLOYMENT.md` → PART A، خطوات 1-4 (النسخ فقط، بدون النشر بعد).

**Step 5 — تشغيل migrations**: `DEPLOYMENT.md` → PART A، خطوة 5 (نفّذها بالترتيب على مشروع Supabase الذي أنشأته).

**Step 6 — Storage**: `DEPLOYMENT.md` → PART A، خطوة 8 (إنشاء bucket `templates` و`restaurant-assets`، كلاهما public).

**Step 7 — RLS**: تحقق كما بخطوة 7 من PART A أن RLS مفعّل على `orders` و`audit_logs`.

**Step 8 — إنشاء `.env`**:
```bash
cp .env.example .env
```
ثم افتح `.env` واملأ: `DATABASE_URL`, `JWT_SECRET` (قيمة عشوائية طويلة)، `SUPABASE_JWT_SECRET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`. اترك `NODE_ENV=development` و`CORS_ORIGIN` بقيمته الافتراضية للتطوير المحلي.

**Step 9 — تشغيل الباكند محليًا** (طرفية أولى):
```bash
npm run dev
```
يجب أن تشاهد: `شغال على http://localhost:4000`. تحقق: افتح `http://localhost:4000/health`.

**Step 10 — تشغيل الفرونت إند محليًا**: ملفات HTML ثابتة بالكامل، لا تحتاج build. من مجلد `frontend` (طرفية ثانية):
```bash
npx serve . -l 5173
```
(أو أي static server آخر؛ المهم أن يفتح على منفذ ثابت لأن `CORS_ORIGIN` الافتراضي بـ`.env.example` يشمل `localhost:5173` و`5174`.)

**Step 11 — ربط الفرونت إند بالباكند محليًا**: كل ملفات HTML تكتشف `localhost` تلقائيًا وتستخدم `http://localhost:4000` — لا حاجة لأي تعديل يدوي محليًا.

**Step 12 — إنشاء أول سوبر أدمن**:
```bash
node scripts/create-super-admin.js you@yourcompany.com "StrongPass123!" "اسمك"
```

**Step 13 — تسجيل الدخول**: افتح `http://localhost:5173/admin/` وسجّل دخول بالبريد وكلمة المرور أعلاه.

**Step 14 — إنشاء باقة (Plan)**: من لوحة السوبر أدمن، أنشئ باقة (حد الطاولات، السعر...).

**Step 15 — إنشاء مطعم**: أنشئ مطعمًا واربطه بالباقة.

**Step 16 — إنشاء أدمن مطعم**: أثناء إنشاء المطعم أو بعده، أنشئ حساب أدمن (owner) لهذا المطعم.

**Step 17 — إنشاء طاولات**: سجّل دخول على `http://localhost:5173/restaurant-admin/` بحساب أدمن المطعم، أنشئ طاولة أو مجموعة طاولات (bulk).

**Step 18 — توليد روابط NFC**: كل طاولة تحصل على `token` فريد؛ الرابط الناتج بالشكل `http://localhost:5173/menu/{slug}/{token}` — هذا ما يُكتب على بطاقة/ملصق NFC فعليًا لاحقًا.

**Step 19 — إضافة منتجات**: من نفس لوحة أدمن المطعم، أضف فئات ومنتجات وأسعار.

**Step 20 — اختيار قالب**: من "menu-template"، اختر القالب المدمج الافتراضي أو أي قالب رفعه السوبر أدمن مسبقًا (راجع `TEMPLATE-SDK.md`).

**Step 21 — تخصيص العلامة (Branding)**: ارفع شعار المطعم وخصص الألوان إن وُجدت بالقالب.

**Step 22 — محاكاة مسح NFC**: افتح رابط الطاولة من Step 18 بمتصفح (أو موبايل على نفس الشبكة).

**Step 23 — إنشاء طلب تجريبي**: أضف منتجات للسلة وأرسل الطلب من صفحة المنيو.

**Step 24 — تأكيد الطلب**: افتح `http://localhost:5173/cashier/`، يجب أن يظهر الطلب فورًا (realtime عبر Supabase).

**Step 25 — إتمام الطلب**: من شاشة الكاشير، أكّد الطلب وأغلقه.

---

## النشر على الإنتاج

راجع `DEPLOYMENT.md` بالكامل (الأجزاء A إلى G) — يشرح Supabase الحقيقي، رفع GitHub، نشر Vercel للباكند، نشر الفرونت إند (Vercel أو GitHub Pages)، ضبط `PROD_API_BASE` و`CORS_ORIGIN`، والاختبار النهائي بنفس تسلسل الخطوات 22-25 أعلاه لكن على الروابط الحقيقية.
