# TEMPLATE-SDK.md — محرك القوالب

> **⚠️ محدّث بعد هجرة Supabase الكاملة (راجع `../MIGRATION-SUMMARY.md`).** كل ما
> بهذا الملف يصف الوضع **الحالي** (Supabase مباشرة، بلا Node backend). المرجع
> الأصلي كان `backend/src/utils/templateValidator.js`, `templatePathSafety.js`,
> `controllers/templates.controller.js` (Node، محذوفة الآن) — منطقها بالكامل
> منقول حرفيًا إلى `supabase/functions/upload-template/index.ts` (Deno)، ومنطق
> `src/public/menu-sdk.js` القديم منقول إلى `frontend/assets/menu-sdk.js`.

## 1. بنية ملف القالب (ZIP)

يجب أن يحتوي جذر الـZIP (أو مجلد جذر واحد مشترك يُكتشف تلقائيًا) على `manifest.json` بالشكل:

```json
{
  "name": "اسم القالب",
  "slug": "template-slug",
  "version": "1.0.0",
  "type": "customer-menu",
  "entry": "index.html",
  "supports": ["branding", "categories", "products", "cart", "orders", "order-status"]
}
```
- `slug`: أحرف صغيرة/أرقام/شرطات فقط (regex `^[a-z0-9-]+$`).
- `version`: semver إجباري (`x.y.z`).
- `supports`: اختياري، القيم المسموحة محصورة بما يدعمه `menu-sdk.js` فعليًا.

## 2. الحدود المفروضة عند الرفع (`LIMITS` بالكود)

| الحد | القيمة |
|---|---|
| حجم ملف ZIP نفسه | 15MB |
| الحجم الإجمالي بعد الفك | 40MB |
| عدد الملفات | 500 |
| حجم الملف الواحد | 5MB |

نفس الأرقام بالضبط بالنسخة الجديدة (`supabase/functions/upload-template/index.ts`) —
بلا أي تغيير بالحدود نفسها، فقط تغيّر مكان تنفيذها (Deno Edge Function بدل Node).

## 3. الفحوصات الأمنية (منقولة حرفيًا، بلا أي تخفيف)

يُرفض الرفع إذا وُجد أي من:
- مسار خارج الجذر (`../`)، مسار مطلق (يونكس/ويندوز)، أو UNC path (`\\server\share`)
- null byte داخل اسم الملف
- ملفات حساسة بالاسم: `.env` وامتداداته، `.git/*`, `id_rsa`, `private.pem`, `serviceAccount.json`, `node_modules/*`, `package.json`
- امتدادات غير مسموحة (القائمة البيضاء فقط: html/css/js/json/صور/خطوط/نصوص، راجع `ALLOWED_EXTENSIONS`)

## 4. دورة الحياة (محدّثة)

```
Super Admin يرفع ZIP من frontend/admin (يبعت البايتات الخام كـBlob)
   ↓ Edge Function upload-template: تحقق is_super_admin() ثم validateTemplateZipBuffer
     (نفس فحص أمني + بنيوي 1:1)
   ↓ الملفات تُرفع لـSupabase Storage bucket "templates" تحت مسار خاص بالنسخة
     (service-role — bucket مقفول كليًا عن anon/authenticated)
   ↓ سطر جديد بجدول template_versions بحالة "installed" (غير معروض بعد للمطاعم)
   ↓ Super Admin يعاين (Preview) القالب عبر رابط Storage العام قبل التفعيل
   ↓ rpc_activate_template_version(template_id, version_id) → status='active'،
     يصبح متاحًا لاختيار المطاعم (RLS "staff reads active or builtin versions")
   ↓ Restaurant Admin (owner) يختاره عبر rpc_select_menu_template(restaurant_id, version_id)
   ↓ Customer Menu (frontend/menu) يحمّل النسخة النشطة الخاصة بمطعمه عبر
     rpc_menu_bootstrap ثم menu-sdk.js
```

**Rollback**: استدعاء `rpc_select_menu_template` مرة تانية بـ`template_version_id` قديم
يجعلها هي النشطة؛ النسخة الحالية تتحول تلقائيًا لغير حالية (`is_current=false`,
`deactivated_at=now()`). لا حذف فعلي لأي نسخة أو ملفاتها بـStorage عند rollback —
فقط سطر تاريخ جديد بجدول `restaurant_menu_templates`، وهذا يسمح بالتراجع مرة أخرى
للأمام بأي وقت. **بلا أي تغيير عن السلوك الأصلي.**

`rpc_deactivate_template_version` (جديد بالمرحلة 2/3) يرجّع نسخة من `active` إلى
`installed` (غير معروضة للاختيار من جديد) — لا يمسّ أي مطعم مستخدمها حاليًا.

## 5. عقد MenuSDK (`frontend/assets/menu-sdk.js`)

أي قالب **يجب** أن يستخدم `MenuSDK` بدل التواصل المباشر مع Supabase:

```html
<script src="https://YOUR-USERNAME.github.io/YOUR-REPO/assets/supabase-config.js"></script>
<script src="https://YOUR-USERNAME.github.io/YOUR-REPO/assets/menu-sdk.js"></script>
<script>
  MenuSDK.init({}); // supabaseUrl/supabaseAnonKey تُقرأ تلقائيًا من الملف أعلاه
  const bootstrap = await MenuSDK.getBootstrap();
</script>
```

**التغيير الوحيد عن النسخة القديمة**: طريقة `init()` صارت تاخذ `{ supabaseUrl,
supabaseAnonKey }` بدل `{ apiBase }` (أو تقرأهم تلقائيًا من `window.SUPABASE_URL` /
`window.SUPABASE_ANON_KEY` لو حمّلت `supabase-config.js` قبله كما بالمثال أعلاه).
**كل الدوال التانية (`getBootstrap`, `getRestaurant`, `getBranding`, `getCategories`,
`getProducts`, `getTable`, `getTemplateSettings`, `createOrder`, `getOrderStatus`,
`pollOrderStatus`) بنفس الاسم، نفس المعاملات، ونفس شكل البيانات المُرجعة تمامًا —
أي قالب مبني فوق النسخة القديمة يشتغل بلا أي تعديل بمنطقه.**

- يكتشف `slug`/`token` تلقائيًا من الرابط (`/menu/{slug}/{token}` أو `?r=&t=`) أو من `?demo=1`.
- **لا يحمل أي سر إطلاقًا** — لا Admin JWT، لا service-role key، فقط anon key العام
  (محمي بـRLS، مصمم أصلًا ليكون مكشوفًا). أقصى ضرر من قالب خبيث هو استهلاك
  الـREST العام نفسه، وهو محكوم أصلًا بصلاحيات RLS ضيّقة جدًا (لا يمكنه قراءة/تعديل
  بيانات مطعم آخر أو تعديل سعر — راجع `phase3-supabase-native.sql § RLS`).
- بلا أي مكتبة خارجية (لا supabase-js حتى) — فقط `fetch()` مباشر لـPostgREST، بقصد:
  أخف حمل ممكن على جهاز الزبون.

## 6. من يرفع/يقرأ/يعدّل/يحذف في Supabase Storage

| Bucket | يرفع | يقرأ | يعدّل | يحذف |
|---|---|---|---|---|
| `templates` | Edge Function `upload-template` فقط (service-role، بعد فحص `is_super_admin()`) | عام (public-read) — القوالب تُحمَّل مباشرة بالمتصفح | لا يوجد مسار تعديل ملفات حاليًا (فقط status بجدول template_versions عبر RPC) | لا يوجد مسار حذف حاليًا؛ الـrollback يبقي كل النسخ |
| `restaurant-assets` | مباشرة من `frontend/restaurant-admin` (owner المطعم فقط، عبر RLS `storage.foldername(name)[1] = current_staff_restaurant_id()::text`) | عام (public-read) | نفس شرط الرفع (owner فقط) | نفس شرط الرفع (owner فقط) |

الفرق الجوهري عن التصميم القديم: رفع شعار/صور المنتجات صار **مباشرًا من
الفرونت إند** (بلا أي وسيط باكند) لأن RLS نفسها كافية لتأمينه؛ بينما رفع
قوالب ZIP يبقى حصرًا عبر Edge Function لأنه يحتاج صلاحية `service_role` فعلية
(bucket `templates` مقفول تمامًا عن أي كتابة من `anon`/`authenticated`).

