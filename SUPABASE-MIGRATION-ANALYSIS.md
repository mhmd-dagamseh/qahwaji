# SUPABASE-MIGRATION-ANALYSIS.md
## من Backend/Vercel/Node إلى GitHub Pages + Supabase

هذا التحليل مبني على قراءة كل controller/middleware/route/trigger موجود فعليًا
بالمشروع، وعلى تنفيذ واختبار حقيقي لكل جزء قاعدة البيانات (قسم 2) على نسخة محلية
من PostgreSQL 16 محاكية لبيئة Supabase (auth.users, auth.uid/role/jwt, storage.objects,
أدوار anon/authenticated/service_role) — مو افتراضات نظرية.

---

## 1) خريطة الانتقال — كل وظيفة Backend حالية ووجهتها الجديدة

### Auth (`auth.controller.js`, `middleware/auth.js`)
| اليوم (Node) | الوجهة الجديدة |
|---|---|
| `POST /auth/super-admin/login` (bcrypt + JWT مخصص) | **Supabase Auth** (`supabase.auth.signInWithPassword`) — يحتاج ربط `super_admins.user_id` بمستخدم Auth حقيقي (Phase 2). لحد هيك: يبقى الجسر الحالي شغّال، الجدول جاهز (`user_id` عمود مضاف). |
| `POST /auth/restaurant-admin/login` (نفس الشيء + توليد `supabaseToken` جسر) | **Supabase Auth** كمان (Phase 2). الجسر الحالي (JWT بـ`restaurant_id`/`staff_role`) يضل شغّال بالتوازي — دوال `current_staff_restaurant_id()`/`current_staff_role()` الجديدة بتتعرف عليه **تلقائيًا** (dual-mode، مُختبر فعليًا) لحد ما ينتقل تسجيل الدخول فعليًا. |
| `requireAuth` / `requireSuperAdmin` / `requireRestaurantAccess` / `requireRole` (middleware) | **RLS + دوال مساعدة**: `is_super_admin()`, `current_staff_restaurant_id()`, `current_staff_role()` (منفّذة وموجودة بـ`phase3-supabase-native.sql` §2) — هاي فعليًا بديل middleware كامل، منفّذة داخل قاعدة البيانات فلا حاجة لأي كود وسيط. |
| Rate limiting على login (`rateLimit.js`) | **لا بديل DB-native حاليًا.** Supabase عنده rate limiting مدمج على Auth endpoints نفسها (إعداد بلوحة التحكم)، لكنه مختلف عن rate limit مخصص per-IP/per-email كان بالكود. يُترك كقيد معروف (Phase 2/3). |

### Restaurants / Plans / Subscriptions (`restaurants.controller.js`, `subscriptions.controller.js`, `plans.controller.js`)
| اليوم | الوجهة |
|---|---|
| `createRestaurant` (Node transaction: مطعم + اشتراك + أدمن بكلمة سر واحدة) | **RPC**: `rpc_create_restaurant` (مطعم+اشتراك، ذرّي، مُختبر) + `rpc_attach_restaurant_admin` (ربط مستخدم Auth تم إنشاؤه مسبقًا). **مو خطوة واحدة بعد اليوم** — إنشاء مستخدم Supabase Auth فعلي لازم يصير عبر Admin API (Edge Function/service-role)، مستحيل من دالة SQL بحتة (راجع §3). |
| `changeSubscriptionPlan` (يتحقق من حد الطاولات، يلغي القديم، يفتح جديد) | **RPC**: `rpc_change_subscription_plan` — ذرّي، مُختبر (يرفض لو عدد الطاولات الفعّالة أكتر من حد الباقة الجديدة). |
| `updateRestaurantStatus` | **RPC**: `rpc_update_restaurant_status` — سوبر أدمن فقط. |
| `updateBranding` | **RPC**: `rpc_update_restaurant_branding` — owner لمطعمه فقط. (ليش RPC مو RLS+GRANT عمودي: راجع §4، خطأ حقيقي وقعت فيه وصلّحته أثناء الاختبار). |
| `listRestaurants` / `getRestaurant` / `listPlans` | **RLS مباشر** (Supabase REST/`select()`) — لا حاجة لأي endpoint وسيط، الصلاحيات محكومة بـpolicies جديدة على `restaurants`/`plans`/`subscriptions`. |
| Audit تسجيل يدوي (`recordAudit()` بكل controller) | **Trigger عام** `fn_audit_log()` مربوط تلقائيًا على `restaurants, products, restaurant_tables, subscriptions, plans, restaurant_menu_templates` — ما بقى ممكن ينسى مبرمج يسجّل audit، لأنه صار مستوى قاعدة بيانات. |

### Tables/NFC (`tables.controller.js`)
| اليوم | الوجهة |
|---|---|
| `createTable` / `bulkCreateTables` / `deactivateTable` | **RPC**: `rpc_create_table`, `rpc_bulk_create_tables` (حتى 300 دفعة واحدة، ذرّي)، `rpc_deactivate_table`. التريغر `trg_enforce_table_limit` الموجود أصلًا يشتغل تلقائيًا بغض النظر عن مصدر الـinsert (دفاع بعمق). |
| `listTables` (owner/cashier) | **RLS مباشر** على `restaurant_tables` (staff يشوف مطعمه فقط). |
| قراءة عامة لطاولة عبر `card_token` (كانت policy واسعة `using(true)`-النمط) | **أُزيلت كليًا** واستُبدلت بـ`rpc_resolve_table(slug, card_token)` — راجع §4، أخطر إصلاح بهذا التقرير. |

### Products (`products.controller.js`)
| اليوم | الوجهة |
|---|---|
| `createProduct` / `updateProduct` / `deleteProduct` | **RPC**: `rpc_upsert_product`, `rpc_delete_product` — owner لمطعمه فقط. |
| `listProducts` (staff) | **RLS مباشر**. |
| `getPublicMenu` (زبون، متاح فقط) | **RLS مباشر** (policy عامة موجودة أصلًا: `available=true` + مطعم فعّال) — تبقى كما هي، لا تغيير. |

### Customer Menu / Orders (`publicMenu.controller.js`, `publicOrders.controller.js`, `orders.controller.js`)
| اليوم | الوجهة |
|---|---|
| `resolveActiveRestaurant` + `resolveActiveTable` (تحقق سلسلة) | **RPC**: `rpc_resolve_table` (فقط table_number، بدون كشف `card_token`) |
| `getBootstrap` (مطعم+طاولة+قالب+منتجات بنداء واحد) | **RPC**: `rpc_menu_bootstrap` — نفس فكرة تجميع النداء للأداء، مُختبرة وترجع JSON مطابق. |
| `createOrder` (**الأهم أمنيًا**: يتجاهل أي سعر/total من العميل) | **RPC**: `rpc_create_order` — يقبل فقط `product_id`+`qty` (أي حقل زائد كـ`price` يُتجاهل قبل حتى الوصول للـinsert)، والـtrigger الموجود أصلًا `trg_validate_order` (`validate_order_before_insert`) يعيد بناء `items`/`total` الحقيقيين من جدول `products` وقت الإدراج. **اختبرته فعليًا**: طلب بسعر مزوّر `0.01` نتج عنه total حقيقي محسوب من الأسعار الفعلية، مش من المُدخل. الإدراج المباشر على `orders` من anon/authenticated أُلغي كليًا (كان `with check(true)` — راجع §4). |
| `getOrderStatus` (بـaccess_token) | **RLS مباشر** — السياسة موجودة أصلًا بـ`hardening-v1.sql` ("read order by token or staff")، لم تُعدَّل، تحققت أنها تعمل تمامًا عبر ترويسة `x-order-token` (نفس آلية PostgREST الحقيقية). |
| تحديث حالة الطلب (كاشير) | **RLS مباشر** — سياسة "staff update orders" موجودة أصلًا، لم تُعدَّل، والـtrigger `validate_order_status_transition` يضبط الانتقالات المسموحة كما هو. |
| **Realtime** (الكاشير يشوف الطلب الجديد فورًا) | **Supabase Realtime جاهز أصلًا** — الجدول `orders` منشور على `supabase_realtime` (schema.sql). لا تغيير مطلوب؛ الكاشير (owner/cashier) يشترك مباشرة عبر `supabase-js` بجلسة الجسر الحالية (JWT فيها `restaurant_id`/`staff_role`)، ونفس RLS تحكم مين يشوف شو Realtime أيضًا (Supabase Realtime يفرض RLS تلقائيًا على broadcast). |
| `getOrderStats` / `getTopProducts` | **RPC**: `rpc_order_stats`, `rpc_top_products` — نفس منطق SQL بالضبط، بس بفحص صلاحية داخلي (owner/cashier لمطعمهم، سوبر أدمن للكل). |

### Templates (`templates.controller.js`, `restaurantMenu.controller.js`, `templateValidator.js`, `templatePathSafety.js`)
| اليوم | الوجهة |
|---|---|
| فحص أمان ZIP (path traversal، امتدادات، أحجام) — كود JS بحت (`adm-zip`) | **لا يمكن نقله لقاعدة البيانات — Postgres ما بيعالج ملفات ZIP.** ينتقل لـ**Supabase Edge Function** (Deno، صلاحية service-role) تستدعى من لوحة السوبر أدمن مباشرة (راجع §3، هذا خارج نطاق "قاعدة البيانات فقط" المطلوب بهذه المرحلة). |
| `uploadTemplateVersion` (رفع لـStorage + سطر بـ`template_versions`) | **جزء من نفس Edge Function** أعلاه — الإدراج بـ`template_versions` بقي **مقفول كليًا** عن anon/authenticated بهذا الـmigration (لا policy إطلاقًا)، فقط `service_role` (اللي الـEdge Function تتصل فيه) يقدر يكتب. |
| `activateVersion` / `deactivateVersion` | يبقى ضمن نفس Edge Function أو RPC منفصلة يشرف عليها service_role — لم أُنفّذها هذه المرحلة لأنها مرتبطة مباشرة بعملية الرفع/الفحص خارج قاعدة البيانات. |
| `listTemplates` (سوبر أدمن كل شيء، staff بس active/builtin) | **RLS مباشر** — سياستان جديدتان مضافتان ومُختبرتان (`staff reads active or builtin versions`, `super admin reads all template versions`). |
| `selectMenuTemplate` (owner يختار/يبدّل قالب، بما فيه rollback) | **RPC**: `rpc_select_menu_template` — ذرّي (إقفال القديم + فتح الجديد + مزامنة `restaurants.theme_template` بنفس العملية)، مُختبر فعليًا بما فيه رفض محاولة owner يعدّل قالب مطعم غيره. |

### Uploads (`uploads.controller.js`, `utils/storage.js`)
| اليوم | الوجهة |
|---|---|
| رفع شعار/صورة منتج (multer + Supabase Storage SDK من طرف Node) | **مباشرة من الفرونت إند لـSupabase Storage** (`supabase.storage.from('restaurant-assets').upload(...)`) — الفرونت إند الحالي يحتاج تعديل بسيط هون تحديدًا (رفع مباشر بدل عبر الـAPI) عندما يصير التنفيذ الفعلي بـPhase 2؛ الحماية جاهزة الآن (RLS على `storage.objects`، owner لمجلده فقط، مُختبرة). |

### Admin عمومًا (لوحة السوبر أدمن ولوحة أدمن المطعم)
لا "endpoint" مخصص للوحات نفسها — كل ما فيها CRUD عادي على الجداول أعلاه، منقول بالكامل حسب الجدول.

---

## 2) ما تم تنفيذه فعليًا بهذه المرحلة (`backend/db/phase3-supabase-native.sql`، 1135 سطر، مُختبر بالكامل)

1. عمود `user_id` (nullable) على `super_admins`/`restaurant_admins` — جاهز لربط Supabase Auth لاحقًا، إضافي وغير كاسر.
2. دوال مساعدة: `is_super_admin()`, `current_staff_restaurant_id()`, `current_staff_role()` — **dual-mode**: تتحقق أولاً من ربط Supabase Auth الحقيقي (`user_id = auth.uid()`)، وإن ما لقت شي، ترجع لقراءة JWT claims الجسر الحالي (`restaurant_id`/`staff_role`) اللي يصدره Node اليوم فعليًا (`supabaseAuth.js`) — اكتشاف مهم أثناء الاختبار: لولا هذا التصميم المزدوج كانت كل RPCs الجديدة رح تفشل مع أي حدا مسجل دخول بالنظام الحالي.
3. مراجعة شاملة لكل RLS (تفصيل كامل بقسم 4 تحت).
4. Trigger عام للـaudit logging (`fn_audit_log`) بدل نداء يدوي بكل controller.
5. 15 RPC function (كلها مُختبرة بأمثلة حقيقية: نجاح + رفض عبور صلاحيات):
   `rpc_create_restaurant, rpc_attach_restaurant_admin, rpc_update_restaurant_status, rpc_update_restaurant_branding, rpc_change_subscription_plan, rpc_create_table, rpc_bulk_create_tables, rpc_deactivate_table, rpc_upsert_product, rpc_delete_product, rpc_resolve_table, rpc_menu_bootstrap, rpc_create_order, rpc_select_menu_template, rpc_order_stats, rpc_top_products`
6. Storage policies على `storage.objects` لـbucket `restaurant-assets` (كتابة owner لمجلده فقط) و`templates` (قراءة عامة، كتابة service_role فقط).

**طريقة الاختبار**: ثبّتّت PostgreSQL 16 محليًا فعليًا، بنيت محاكاة مصغّرة لِـ`auth`/`storage` schemas وأدوار Supabase (anon/authenticated/service_role)، حمّلت `schema.sql`→`hardening-v1.sql`→`phase2.sql` الحاليين فعليًا (نجحوا بدون أي تعديل — هذا كمان تأكيد إضافي إنهم متوافقين تمامًا مع Supabase الحقيقي)، ثم بنيت `phase3-supabase-native.sql` تدريجيًا مع تنفيذ حقيقي بعد كل قسم. وجدت وصلّحت 4 أخطاء حقيقية أثناء هذا الاختبار (تفصيل بقسم 4)، والملف الآن idempotent بالكامل (جرّبته على قاعدة بيانات فاضية، ثم شغّلته مرتين متتاليتين بدون أي خطأ).

---

## 3) ما لا يمكن نقله لقاعدة البيانات (يبقى Backend/Edge Function بشكل ما)

| الوظيفة | ليش مستحيلة بـSQL بحت | البديل |
|---|---|---|
| فحص/فك ضغط ملفات القوالب (ZIP) | Postgres ما عنده معالجة ZIP أصيلة، ولا يوجد extension قياسي موثوق لهذا | **Supabase Edge Function** (Deno) بصلاحية service-role — تحتوي نفس منطق `templateValidator.js`/`templatePathSafety.js` بالضبط (فحص path traversal، امتدادات، أحجام) لكن بـDeno بدل Node |
| إنشاء مستخدم Supabase Auth فعلي (owner/cashier جديد) | إدراج مباشر بجدول `auth.users` غير مدعوم رسميًا ويتجاوز آلية Supabase الداخلية (hashing، email confirmation، إلخ) | **Supabase Auth Admin API** (`supabase.auth.admin.createUser`) — يُستدعى من Edge Function بصلاحية service-role، ثم يُستدعى `rpc_attach_restaurant_admin` بعدها لربط النتيجة (عملية بخطوتين، ليست transaction واحدة حرفيًا عبر الشبكة، لكن كل خطوة ذرّية بمفردها) |
| Rate limiting دقيق per-IP/per-email على محاولات تسجيل الدخول | يحتاج تخزين حالة عبر الزمن بمنطق تطبيقي (أو middleware) لا يوجد مكافئ SQL نظيف له | Supabase Auth rate limiting المدمج (إعداد لوحة التحكم) كبديل جزئي، أو Edge Function وسيطة إذا احتجنا دقة أعلى (Phase 2/3) |

---

## 4) أخطر البنود: policies واسعة/غير آمنة وُجدت وأُعيد تصميمها

1. **`orders` — `"public insert orders" ... with check (true)`**: أي حامل anon key كان يقدر يُدرج طلبًا مباشرًا بأي `restaurant_id`/`table_id` يتخيّله (التريغر كان بيصحح السعر، لكن ما كان في تحقق من إنو الطاولة فعلًا تخص هيك مطعم وهي فعّالة قبل الإدراج نفسه). **الحل**: أُلغي الـinsert المباشر كليًا (`revoke insert ... from anon, authenticated`)، الإنشاء حصرًا عبر `rpc_create_order` اللي بيتحقق من slug+card_token الحقيقيين أولًا.
2. **`restaurant_tables` — `"public read active tables"`**: كانت ترجع *كل* الأعمدة، بما فيها `card_token` نفسه (سر NFC)، لأي طلب select عام بمفتاح anon — يعني تعداد (enumeration) لكل بطاقات كل المطاعم الفعّالة بنداء واحد. **الحل**: إلغاء القراءة العامة كليًا، استبدالها بـ`rpc_resolve_table`/`rpc_menu_bootstrap` اللي يتطلبان تمرير التوكن الصحيح أصلًا كمعامل، ويرجّعان table_number فقط.
3. **خطأ اكتشفته بنفسي أثناء الكتابة (وصلّحته قبل التسليم)**: حاولت أول مرة أسمح لـ"owner" يعدّل بس أعمدة العلامة التجارية بـ`restaurants` عبر `GRANT UPDATE (logo_url, brand_colors, theme_template)` + RLS policy — هذا **غير آمن فعليًا**: owner وsuper_admin كلاهما بيتصلا بنفس دور Postgres الواحد "authenticated"، فـPostgres ما بيقدر يفرّق صلاحيات أعمدة بين "نوعين" من authenticated. اختبرت هذا فعليًا ووجدت إنو `WITH CHECK` ما كان رح يمنع owner من تغيير `status` لو كتب الـUPDATE يدويًا. **الحل**: منع أي UPDATE مباشر على `restaurants` كليًا، كل تعديل (علامة تجارية أو حالة) عبر RPC مخصصة بتتحقق من الدور داخليًا قبل التنفيذ.
4. **جداول كانت مقفولة كليًا بلا أي policy** (`super_admins, restaurant_admins, plans (insert/update), subscriptions, restaurant_tables, products (insert/update/delete), menu_templates, template_versions, restaurant_menu_templates, audit_logs`) — كانت مقبولة وقت الوصول الوحيد كان service-role. أُضيفت policies حقيقية معزولة بـ`restaurant_id`/`is_super_admin()`، مو فتح عام.

---

## 5) ملخص واضح لما سينتقل بالمرحلتين الثانية والثالثة

### Phase 2 (القادمة) — Edge Functions + بداية ربط Supabase Auth
- بناء Supabase Edge Function لفحص/رفع ZIP القوالب (تحل محل `templates.controller.js` uploadTemplateVersion بالكامل).
- بناء Edge Function لإنشاء مستخدم Supabase Auth فعلي لصاحب مطعم جديد (owner) وربطه عبر `rpc_attach_restaurant_admin`، بدل تدفق Node الحالي.
- تعديل الفرونت إند (بحد أدنى، حسب طلبكم — ما بيصير بهذه المرحلة): استبدال نداءات `fetch('/api/...')` بنداءات `supabase-js` مباشرة (`.from().select()/.rpc()`)، ورفع الصور مباشرة لـStorage بدل عبر Node.
- تسجيل الدخول: التحويل الفعلي لـ`supabase.auth.signInWithPassword()` بدل `/auth/*` — عندها الجسر الحالي (JWT المخصص) يصير كود ميت.

### Phase 3 (النهائية) — إيقاف Node/Vercel كليًا
- حذف عمود `password_hash` من `super_admins`/`restaurant_admins` (بقي غير مستخدم بعد اكتمال الربط بـSupabase Auth).
- حذف/تعطيل `backend/` بالكامل (Node/Express/Vercel) — قاعدة البيانات + Edge Functions + الفرونت إند الثابت على GitHub Pages يكفون وحدهم.
- إزالة مسار الـfallback بدوال `current_staff_restaurant_id()`/`current_staff_role()` (الاعتماد على JWT claims المخصصة) بعد التأكد إن كل الحسابات انتقلت فعليًا لـSupabase Auth ولا أحد يستخدم الجسر القديم.
- مراجعة أمنية أخيرة كاملة على الوضع الجديد (نفس روح PHASE-2-REPORT.md لكن لبنية بلا backend إطلاقًا).
- تفعيل rate limiting الحقيقي على Supabase Auth (إعدادات لوحة التحكم) كبديل نهائي لما كان بـ`rateLimit.js`.
