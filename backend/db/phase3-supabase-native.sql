-- ============================================================
-- Cafe SaaS Core — Phase 3: Supabase-Native (GitHub Pages + Supabase)
-- شغّلوه بعد schema.sql, hardening-v1.sql, phase2.sql
-- إضافات فقط — ما بيحذف ولا يكسر أي جدول/سياسة موجودة، آمن لإعادة التشغيل (idempotent)
--
-- هذا الملف لا يفترض أن Node/Vercel backend انقفل بعد — كل شيء هون إضافي وغير مدمّر،
-- فالـbackend الحالي يضل شغّال بالتوازي (متصل بـDATABASE_URL مباشر بصلاحيات كاملة
-- تتجاوز RLS أصلًا) لحد ما يصير القرار الفعلي بإيقافه (راجع SUPABASE-MIGRATION-ANALYSIS.md).
-- ============================================================

-- ------------------------------------------------------------
-- 1) ربط حسابات الأدمن بـ Supabase Auth (إضافي، nullable، ما يكسر تسجيل الدخول
--    الحالي عبر bcrypt/JWT المخصص). يُملأ لاحقًا (Phase 3.2) عند إنشاء مستخدم
--    Supabase Auth فعلي لكل super_admin/restaurant_admin موجود.
-- ------------------------------------------------------------
alter table super_admins
  add column if not exists user_id uuid unique references auth.users(id) on delete set null;

alter table restaurant_admins
  add column if not exists user_id uuid unique references auth.users(id) on delete set null;

-- ------------------------------------------------------------
-- 2) دوال مساعدة (helper functions) تُستخدم داخل كل RLS policies لاحقًا.
--    security definer + set search_path = public: تتجاوز RLS بجدولي
--    super_admins/restaurant_admins نفسيهما (وإلا صار تعارض دائري: لتحديد هوية
--    المستخدم لازم نقرأ الجدول، لكن قراءة الجدول محكومة بـRLS يلي بيحتاج نفس الهوية).
--    كل دالة بترجع فقط بيانات المستخدم الحالي (auth.uid()) — ما في أي احتمال تسريب.
-- ------------------------------------------------------------
create or replace function is_super_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from super_admins where user_id = auth.uid()
  );
$$;

-- ملاحظة مهمة اكتشفتها أثناء الاختبار الفعلي: النظام الحالي (Node) أصلاً بيصدر توكن
-- "جسر" متوافق مع Supabase لجلسة الكاشير/أونر (supabaseAuth.js) — بيحمل claims:
-- role=authenticated, restaurant_id=<bigint>, staff_role=<owner|cashier>, sub غير مرتبط
-- بـauth.users إطلاقًا (نص مثل "restaurant_admin:5"، مش uuid حقيقي). سياسات orders
-- بـhardening-v1.sql مبنية على هاي الـclaims حصرًا (auth.jwt()->>'restaurant_id').
-- عشان ما نكسر هاد الجسر الشغّال حاليًا بالإنتاج، ودوالنا الجديدة تشتغل فورًا بدون
-- انتظار نقل تسجيل الدخول الفعلي لـSupabase Auth (Phase 2)، بنخلي current_staff_*
-- تفحص أولاً الربط الحقيقي (auth.uid() → restaurant_admins.user_id)، وإذا ما لقت
-- شي، ترجع لقراءة نفس الـclaims يلي يصدرها الجسر الحالي. لما ينتقل تسجيل الدخول
-- لـSupabase Auth فعليًا (Phase 2/3)، المسار الأول بيتفعّل تلقائيًا والمسار الثاني
-- (الجسر) بيصير كود ميت يُحذف حينها.
create or replace function current_staff_restaurant_id()
returns bigint
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select restaurant_id from restaurant_admins where user_id = auth.uid()),
    (auth.jwt() ->> 'restaurant_id')::bigint
  );
$$;

create or replace function current_staff_role()
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select role from restaurant_admins where user_id = auth.uid()),
    auth.jwt() ->> 'staff_role'
  );
$$;

grant execute on function is_super_admin() to anon, authenticated;
grant execute on function current_staff_restaurant_id() to anon, authenticated;
grant execute on function current_staff_role() to anon, authenticated;

-- ============================================================
-- 3) مراجعة RLS الحالي وإعادة تصميم أي policy واسعة/غير آمنة
-- ============================================================

-- ------------------------------------------------------------
-- 3.1 — orders: "public insert orders" الحالية using(true)/with check(true)
-- كانت مقبولة سابقًا لأن Node كان الوحيد يكتب فعليًا (service-role، RLS ما بتنطبق عليه
-- أصلًا). بمعمارية Supabase-only، هاي الـpolicy تسمح لأي حامل anon key يعمل insert
-- مباشر بأي restaurant_id/table_id بيتخيّله — حتى لو التريغر بيصحح total/items، السطر
-- التالي (رقم 3.2) بيوضح ليش هاد لسا خطر (تخمين IDs). الحل: امنع الـinsert المباشر
-- كليًا، واجعله حصرًا عبر rpc_create_order (قسم 6) اللي بيتحقق من slug+card_token
-- الحقيقيين قبل أي إدراج — نفس الضمان يلي كان موجود بـpublicOrders.controller.js.
-- ------------------------------------------------------------
drop policy if exists "public insert orders" on orders;
revoke insert on orders from anon;
revoke insert on orders from authenticated;
-- rpc_create_order (security definer) هي الطريقة الوحيدة للإدراج بعد اليوم.

-- ------------------------------------------------------------
-- 3.2 — restaurant_tables: "public read active tables" الحالية (schema.sql) بترجع
-- *كل* الأعمدة لأي صف يطابق الشرط — يعني بترجع card_token نفسه (سر الطاولة/NFC) لأي
-- حدا يسوي select عام بمفتاح anon بدون حتى ما يعرف التوكن مسبقًا (تعداد/enumeration
-- لكل طاولات كل مطعم فعّال). هاي بالضبط نوع الـpolicy الواسعة المطلوب مراجعتها.
-- الحل: نلغي القراءة العامة المباشرة للجدول كليًا، ونعوّضها بـrpc_resolve_table /
-- rpc_menu_bootstrap (قسم 6) يلي بيتطلب تمرير card_token الصحيح أصلًا كمعامل،
-- ويرجّع بس table_number (بدون أي عمود حساس) — نفس المنطق تمامًا يلي كان
-- بـpublicMenu.controller.js (resolveActiveTable).
-- ------------------------------------------------------------
drop policy if exists "public read active tables" on restaurant_tables;
revoke select on restaurant_tables from anon;

-- ------------------------------------------------------------
-- 3.3 — الجداول التالية عندها RLS مفعّل لكن بلا أي policy إطلاقًا (مقفولة كليًا) —
-- هذا كان مقبولًا وقت أن الوصول الوحيد كان عبر service-role. الآن الفرونت إند
-- (owner/cashier مسجّلين دخول عبر Supabase Auth) لازم يقرأ/يكتب مباشرة، فلازم
-- policies حقيقية معزولة بـrestaurant_id — مش "using(true)"، ومش فتح الجدول كامل.
-- ------------------------------------------------------------

-- super_admins: كل سوبر أدمن يشوف سطره الخاص بس (لتأكيد هويته بالفرونت إند)
drop policy if exists "super admin reads own row" on super_admins;
create policy "super admin reads own row" on super_admins
  for select to authenticated
  using (user_id = auth.uid());

-- restaurant_admins: كل أدمن مطعم يشوف سطره الخاص، والسوبر أدمن يشوف الكل (إدارة)
drop policy if exists "staff reads own row" on restaurant_admins;
create policy "staff reads own row" on restaurant_admins
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "super admin reads all staff" on restaurant_admins;
create policy "super admin reads all staff" on restaurant_admins
  for select to authenticated
  using (is_super_admin());

-- plans: القراءة العامة للباقات الفعّالة (نفس سلوك GET /plans العام حاليًا)
drop policy if exists "public read active plans" on plans;
create policy "public read active plans" on plans
  for select to anon, authenticated
  using (active = true);

drop policy if exists "super admin reads all plans" on plans;
create policy "super admin reads all plans" on plans
  for select to authenticated
  using (is_super_admin());

drop policy if exists "super admin writes plans" on plans;
create policy "super admin writes plans" on plans
  for insert to authenticated
  with check (is_super_admin());

drop policy if exists "super admin updates plans" on plans;
create policy "super admin updates plans" on plans
  for update to authenticated
  using (is_super_admin())
  with check (is_super_admin());

-- subscriptions: staff يشوف اشتراك مطعمه بس، سوبر أدمن يشوف الكل. الكتابة عبر RPC فقط
-- (rpc_create_restaurant / rpc_change_subscription_plan) بسبب منطق العمل المعقّد
-- (التحقق من حد الطاولات، إلغاء الاشتراك القديم...) — لا insert/update policies هون.
drop policy if exists "staff reads own subscription" on subscriptions;
create policy "staff reads own subscription" on subscriptions
  for select to authenticated
  using (restaurant_id = current_staff_restaurant_id());

drop policy if exists "super admin reads all subscriptions" on subscriptions;
create policy "super admin reads all subscriptions" on subscriptions
  for select to authenticated
  using (is_super_admin());

-- restaurants: القراءة العامة الحالية (status in trial/active) تبقى كما هي — لا تكشف
-- أسرارًا (فقط name/slug/logo/brand_colors/status)، وموجودة أصلًا من schema.sql.
-- نضيف: staff يشوف مطعمه الخاص بكل حالاته (حتى لو suspended، ليعرف السبب)، سوبر أدمن يشوف الكل.
drop policy if exists "staff reads own restaurant" on restaurants;
create policy "staff reads own restaurant" on restaurants
  for select to authenticated
  using (id = current_staff_restaurant_id());

drop policy if exists "super admin reads all restaurants" on restaurants;
create policy "super admin reads all restaurants" on restaurants
  for select to authenticated
  using (is_super_admin());

-- إنشاء مطعم: سوبر أدمن فقط، وحصرًا عبر rpc_create_restaurant (قسم 6) لأنو عملية
-- متعددة الجداول (restaurant + subscription). ما منسمح بـinsert مباشر حتى لسوبر أدمن،
-- تفاديًا لمطعم بلا اشتراك.
--
-- ملاحظة تصميم مهمة (لماذا لا يوجد UPDATE مباشر على restaurants إطلاقًا):
-- كل من "owner" و"super_admin" يتصلان بـPostgREST بنفس دور Postgres الواحد
-- "authenticated" — الفرق بينهم فقط auth.uid() داخل RLS، مش دور DB مختلف.
-- GRANT UPDATE (col1, col2) TO authenticated يقيّد الدور كله بلا استثناء، فما
-- فيه طريقة نعطي owner صلاحية أعمدة أضيق من super_admin بنفس الوقت عبر GRANT عادي،
-- وWITH CHECK وحدها ما بتقدر تمنع تغيير عمود معيّن (بتتحقق من الصف الناتج بالكامل،
-- مش من "شو تغيّر" مقارنة بالقديم). الحل الصحيح: **لا UPDATE مباشر على restaurants
-- إطلاقًا من authenticated** — كل تعديل (علامة تجارية أو حالة) يمر حصرًا عبر RPC
-- (قسم 6) بيتحقق داخليًا من الدور والملكية قبل التنفيذ. هذا أيضًا أكثر أمانًا من
-- تصميم GRANT/RLS مركّب، ويطابق فلسفة المشروع الأصلية (كل شي حساس عبر endpoint
-- صريح بيتحقق أولاً، مش عبر REST عام).
revoke update on restaurants from anon, authenticated;
-- rpc_update_restaurant_branding و rpc_update_restaurant_status (قسم 6) هما الطريقة الوحيدة.

-- ------------------------------------------------------------
-- 3.4 — restaurant_tables: القراءة العامة أُزيلت (§3.2). الآن فقط staff/super_admin
-- يقرأون الجدول مباشرة (لوحة تحكم المطعم: قائمة الطاولات). الكتابة (إنشاء/حذف)
-- حصرًا عبر RPC (rpc_create_table / rpc_bulk_create_tables / rpc_deactivate_table)
-- لنفس سبب restaurants أعلاه (owner فقط، وrole check لازم يصير قبل أي DB mutation
-- بشكل موثوق بغض النظر عن دور Postgres المشترك).
-- ------------------------------------------------------------
drop policy if exists "staff reads own tables" on restaurant_tables;
create policy "staff reads own tables" on restaurant_tables
  for select to authenticated
  using (restaurant_id = current_staff_restaurant_id());

drop policy if exists "super admin reads all tables" on restaurant_tables;
create policy "super admin reads all tables" on restaurant_tables
  for select to authenticated
  using (is_super_admin());

revoke insert, update, delete on restaurant_tables from anon, authenticated;

-- ------------------------------------------------------------
-- 3.5 — products: القراءة العامة الحالية (available=true + مطعم فعّال) تبقى كما هي.
-- نضيف قراءة staff/super_admin لكل المنتجات (بما فيها غير المتاحة، للوحة التحكم).
-- الكتابة عبر RPC فقط (rpc_upsert_product / rpc_delete_product) — نفس السبب.
-- ------------------------------------------------------------
drop policy if exists "staff reads own products" on products;
create policy "staff reads own products" on products
  for select to authenticated
  using (restaurant_id = current_staff_restaurant_id());

drop policy if exists "super admin reads all products" on products;
create policy "super admin reads all products" on products
  for select to authenticated
  using (is_super_admin());

revoke insert, update, delete on products from anon, authenticated;

-- ------------------------------------------------------------
-- 3.6 — menu_templates / template_versions: لا وجود لأي policy حاليًا (مقفول كليًا).
-- التثبيت الفعلي لنسخة قالب (فحص ZIP، رفع لـStorage) لا يمكن أن يصير بدالة SQL بحتة —
-- يحتاج تنفيذ كود (adm-zip وما شابه) خارج قاعدة البيانات. بمعمارية Supabase-only،
-- هذا ينتقل لـSupabase Edge Function بصلاحية service-role (راجع SUPABASE-MIGRATION-
-- ANALYSIS.md قسم "ما لا يمكن نقله لقاعدة البيانات") — فـinsert على template_versions
-- يبقى بلا policy (مقفول عن anon/authenticated تمامًا)، الكتابة فقط عبر service_role.
-- القراءة: staff (owner/cashier) يشوف بس النسخ active أو المدمجة، سوبر أدمن يشوف الكل.
-- ------------------------------------------------------------
drop policy if exists "staff reads own family templates" on menu_templates;
create policy "staff reads own family templates" on menu_templates
  for select to authenticated
  using (true); -- أسماء/slugs القوالب مو بيانات حساسة أو خاصة بمطعم معيّن

drop policy if exists "staff reads active or builtin versions" on template_versions;
create policy "staff reads active or builtin versions" on template_versions
  for select to authenticated
  using (status = 'active' or is_builtin = true);

drop policy if exists "super admin reads all template versions" on template_versions;
create policy "super admin reads all template versions" on template_versions
  for select to authenticated
  using (is_super_admin());

-- ------------------------------------------------------------
-- 3.7 — restaurant_menu_templates: staff/super_admin يقرأون. التبديل/rollback عبر
-- rpc_select_menu_template فقط (عملية ذرّية: إقفال القديم + فتح الجديد + مزامنة
-- restaurants.theme_template — ثلاث خطوات لازم تنجح كلها سوا أو تفشل كلها سوا).
-- ------------------------------------------------------------
drop policy if exists "staff reads own menu template assignment" on restaurant_menu_templates;
create policy "staff reads own menu template assignment" on restaurant_menu_templates
  for select to authenticated
  using (restaurant_id = current_staff_restaurant_id());

drop policy if exists "super admin reads all menu template assignments" on restaurant_menu_templates;
create policy "super admin reads all menu template assignments" on restaurant_menu_templates
  for select to authenticated
  using (is_super_admin());

revoke insert, update, delete on restaurant_menu_templates from anon, authenticated;

-- ------------------------------------------------------------
-- 3.8 — audit_logs: كانت مقفولة كليًا (لا حتى قراءة). نضيف قراءة لسوبر أدمن فقط —
-- تحسين حقيقي عن الوضع الحالي (Node ما كان أصلًا يعرض audit_logs لأي أحد).
-- الكتابة تصير تلقائيًا عبر trigger عام (قسم 5) بدل استدعاء يدوي من كل controller —
-- ضمان أقوى: ما في طريقة تصير عملية حساسة بدون تسجيلها (كان معتمد على تذكّر
-- المبرمج يستدعي recordAudit() بكل مكان).
-- ------------------------------------------------------------
drop policy if exists "super admin reads audit logs" on audit_logs;
create policy "super admin reads audit logs" on audit_logs
  for select to authenticated
  using (is_super_admin());

-- ------------------------------------------------------------
-- 3.9 — GRANTs الأساسية على مستوى الجدول (صريحة، لا نعتمد على إعدادات
-- افتراضية قد تختلف بين مشاريع Supabase). RLS تحدد "أي الصفوف"، والـGRANT هون
-- يحدد "هل الدور مسموح له أصلًا يحاول SELECT/INSERT/UPDATE/DELETE على الجدول" —
-- الاثنان لازم ينجحا معًا. كل ما يحتاج INSERT/UPDATE/DELETE حقيقي بقي محصورًا
-- بالـRPCs (SECURITY DEFINER) فقط — ما في GRANT مباشر لأي كتابة هون.
-- ------------------------------------------------------------
grant select on super_admins to authenticated;
grant select on restaurant_admins to authenticated;
grant select on plans to anon, authenticated;
grant select on subscriptions to authenticated;
grant select on restaurants to anon, authenticated;
grant select on restaurant_tables to authenticated;
grant select on products to anon, authenticated;
grant select on menu_templates to authenticated;
grant select on template_versions to authenticated;
grant select on restaurant_menu_templates to authenticated;
grant select on audit_logs to authenticated;
-- orders: schema.sql/hardening-v1.sql الأصليان ما احتاجوا GRANT SELECT صريح لأنهم
-- اعتمدوا على grant المشروع الافتراضي بـSupabase (موجود مسبقًا لكل مشروع حقيقي).
-- نضيفه هون صراحة لجعل هذا الملف مكتفيًا بذاته بغض النظر عن أي افتراض منصّة.
grant select on orders to anon, authenticated;

-- ============================================================
-- 4) Audit logging تلقائي عبر trigger عام (بدل استدعاء يدوي من كل controller/RPC)
-- ============================================================
create or replace function fn_audit_log()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_actor_type text;
  v_actor_id bigint;
  v_restaurant_id bigint;
  v_resource text;
begin
  if is_super_admin() then
    v_actor_type := 'super_admin';
    select id into v_actor_id from super_admins where user_id = auth.uid();
  elsif current_staff_restaurant_id() is not null then
    v_actor_type := 'restaurant_admin';
    select id into v_actor_id from restaurant_admins where user_id = auth.uid();
  else
    v_actor_type := 'system';
    v_actor_id := null;
  end if;

  v_restaurant_id := coalesce(
    to_jsonb(case when TG_OP = 'DELETE' then old else new end)->>'restaurant_id',
    case when TG_TABLE_NAME = 'restaurants' then (case when TG_OP = 'DELETE' then old.id else new.id end)::text end
  )::bigint;

  v_resource := TG_TABLE_NAME || ':' || coalesce((case when TG_OP = 'DELETE' then old.id else new.id end)::text, '');

  insert into audit_logs (actor_type, actor_id, restaurant_id, action, resource, old_values, new_values)
  values (
    case when v_actor_type = 'system' then 'super_admin' else v_actor_type end,
    v_actor_id,
    v_restaurant_id,
    TG_TABLE_NAME || '.' || lower(TG_OP),
    v_resource,
    case when TG_OP in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when TG_OP in ('UPDATE', 'INSERT') then to_jsonb(new) else null end
  );

  return coalesce(new, old);
exception when others then
  -- نفس فلسفة audit.js الأصلية: فشل تسجيل الـaudit ما لازم يفشّل العملية الأساسية
  raise warning '[audit] فشل تسجيل audit log على %.%: %', TG_TABLE_NAME, TG_OP, SQLERRM;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_audit_restaurants on restaurants;
create trigger trg_audit_restaurants
  after insert or update or delete on restaurants
  for each row execute function fn_audit_log();

drop trigger if exists trg_audit_products on products;
create trigger trg_audit_products
  after insert or update or delete on products
  for each row execute function fn_audit_log();

drop trigger if exists trg_audit_restaurant_tables on restaurant_tables;
create trigger trg_audit_restaurant_tables
  after insert or update or delete on restaurant_tables
  for each row execute function fn_audit_log();

drop trigger if exists trg_audit_subscriptions on subscriptions;
create trigger trg_audit_subscriptions
  after insert or update or delete on subscriptions
  for each row execute function fn_audit_log();

drop trigger if exists trg_audit_plans on plans;
create trigger trg_audit_plans
  after insert or update or delete on plans
  for each row execute function fn_audit_log();

drop trigger if exists trg_audit_restaurant_menu_templates on restaurant_menu_templates;
create trigger trg_audit_restaurant_menu_templates
  after insert or update or delete on restaurant_menu_templates
  for each row execute function fn_audit_log();

-- ============================================================
-- 5) RPC / PostgreSQL Functions — العمليات التي تحتاج Transaction ذرّية
--    أو تفويضًا لا يمكن التعبير عنه بـRLS بحتة (سوبر أدمن ينشئ مطعم مثلاً).
-- ============================================================

-- ------------------------------------------------------------
-- 5.1 — rpc_create_restaurant: إنشاء مطعم + أول اشتراك له، بعملية واحدة ذرّية.
-- سوبر أدمن فقط. لا تُنشئ حساب أدمن المطعم هون — إنشاء مستخدم Supabase Auth فعلي
-- (auth.users) لا يمكن أن يصير داخل دالة SQL عادية؛ يتطلب Supabase Auth Admin API
-- (service-role)، وهذا خارج نطاق قاعدة البيانات بحتة (راجع SUPABASE-MIGRATION-
-- ANALYSIS.md). لذلك onboarding مطعم جديد يصير بخطوتين:
--   1) rpc_create_restaurant هون — ذرّية DB-only (restaurant + subscription)
--   2) بعد إنشاء مستخدم Auth لصاحب المطعم (Edge Function/Admin API، خارج SQL)،
--      استدعاء rpc_attach_restaurant_admin (5.2) لربطه — ذرّية DB-only أيضًا.
-- لو فشلت الخطوة 2 بعد نجاح 1، المطعم يضل موجود بلا أدمن (حالة معروفة يجب معالجتها
-- بمنطق retry/cleanup على مستوى الـEdge Function، وليس بهذه الدالة).
-- ------------------------------------------------------------
create or replace function rpc_create_restaurant(
  p_name text,
  p_slug text,
  p_plan_id bigint,
  p_theme_template text default 'default'
)
returns restaurants
language plpgsql security definer set search_path = public
as $$
declare
  v_restaurant restaurants;
begin
  if not is_super_admin() then
    raise exception 'هذا الإجراء مخصص لإدارة الشركة فقط' using errcode = '42501';
  end if;

  insert into restaurants (name, slug, theme_template, status)
  values (p_name, p_slug, coalesce(p_theme_template, 'default'), 'trial')
  returning * into v_restaurant;

  insert into subscriptions (restaurant_id, plan_id, status)
  values (v_restaurant.id, p_plan_id, 'active');

  return v_restaurant;
exception
  when unique_violation then
    raise exception 'اسم المطعم (slug) مستخدم مسبقاً' using errcode = '23505';
  when foreign_key_violation then
    raise exception 'الباقة (plan_id) غير موجودة' using errcode = '23503';
end;
$$;

grant execute on function rpc_create_restaurant(text, text, bigint, text) to authenticated;

-- ------------------------------------------------------------
-- 5.2 — rpc_attach_restaurant_admin: ربط مستخدم Supabase Auth تم إنشاؤه مسبقًا
-- (عبر Edge Function/Admin API) كأدمن (owner/cashier) لمطعم معيّن. سوبر أدمن فقط.
-- ------------------------------------------------------------
create or replace function rpc_attach_restaurant_admin(
  p_restaurant_id bigint,
  p_user_id uuid,
  p_email text,
  p_role text default 'owner'
)
returns restaurant_admins
language plpgsql security definer set search_path = public
as $$
declare
  v_admin restaurant_admins;
begin
  if not is_super_admin() then
    raise exception 'هذا الإجراء مخصص لإدارة الشركة فقط' using errcode = '42501';
  end if;
  if p_role not in ('owner', 'cashier') then
    raise exception 'دور غير صالح — owner أو cashier فقط';
  end if;

  insert into restaurant_admins (restaurant_id, user_id, email, password_hash, role)
  values (p_restaurant_id, p_user_id, p_email, 'managed-by-supabase-auth', p_role)
  returning * into v_admin;

  return v_admin;
exception
  when unique_violation then
    raise exception 'هذا البريد أو المستخدم مرتبط بالفعل بحساب أدمن آخر' using errcode = '23505';
  when foreign_key_violation then
    raise exception 'المطعم غير موجود' using errcode = '23503';
end;
$$;

grant execute on function rpc_attach_restaurant_admin(bigint, uuid, text, text) to authenticated;

-- ------------------------------------------------------------
-- 5.3 — rpc_update_restaurant_status: تعليق/تفعيل مطعم. سوبر أدمن فقط.
-- ------------------------------------------------------------
create or replace function rpc_update_restaurant_status(
  p_restaurant_id bigint,
  p_status text
)
returns restaurants
language plpgsql security definer set search_path = public
as $$
declare
  v_restaurant restaurants;
begin
  if not is_super_admin() then
    raise exception 'هذا الإجراء مخصص لإدارة الشركة فقط' using errcode = '42501';
  end if;
  if p_status not in ('trial', 'active', 'suspended', 'cancelled') then
    raise exception 'حالة غير صالحة';
  end if;

  update restaurants set status = p_status where id = p_restaurant_id returning * into v_restaurant;
  if v_restaurant.id is null then
    raise exception 'المطعم غير موجود' using errcode = 'P0002';
  end if;
  return v_restaurant;
end;
$$;

grant execute on function rpc_update_restaurant_status(bigint, text) to authenticated;

-- ------------------------------------------------------------
-- 5.4 — rpc_update_restaurant_branding: شعار/ألوان/قالب نصّي. owner لمطعمه فقط
-- (أو سوبر أدمن لأي مطعم). راجع §3.3 لتفسير ليش هذا RPC بدل GRANT عمودي.
-- ------------------------------------------------------------
create or replace function rpc_update_restaurant_branding(
  p_restaurant_id bigint,
  p_logo_url text default null,
  p_brand_colors jsonb default null,
  p_theme_template text default null
)
returns restaurants
language plpgsql security definer set search_path = public
as $$
declare
  v_restaurant restaurants;
begin
  if not (
    is_super_admin()
    or (current_staff_restaurant_id() = p_restaurant_id and current_staff_role() = 'owner')
  ) then
    raise exception 'لا تملك صلاحية تعديل هذا المطعم' using errcode = '42501';
  end if;

  update restaurants set
    logo_url = coalesce(p_logo_url, logo_url),
    brand_colors = coalesce(p_brand_colors, brand_colors),
    theme_template = coalesce(p_theme_template, theme_template)
  where id = p_restaurant_id
  returning * into v_restaurant;

  if v_restaurant.id is null then
    raise exception 'المطعم غير موجود' using errcode = 'P0002';
  end if;
  return v_restaurant;
end;
$$;

grant execute on function rpc_update_restaurant_branding(bigint, text, jsonb, text) to authenticated;

-- ------------------------------------------------------------
-- 5.5 — rpc_change_subscription_plan: تغيير باقة مطعم (ذرّي: يتحقق من حد الطاولات،
-- يلغي الاشتراك القديم، يفتح جديد). سوبر أدمن فقط.
-- ------------------------------------------------------------
create or replace function rpc_change_subscription_plan(
  p_restaurant_id bigint,
  p_plan_id bigint
)
returns subscriptions
language plpgsql security definer set search_path = public
as $$
declare
  v_plan plans;
  v_current_tables int;
  v_new_sub subscriptions;
begin
  if not is_super_admin() then
    raise exception 'هذا الإجراء مخصص لإدارة الشركة فقط' using errcode = '42501';
  end if;

  select * into v_plan from plans where id = p_plan_id;
  if v_plan.id is null then
    raise exception 'الباقة غير موجودة' using errcode = 'P0002';
  end if;

  select count(*) into v_current_tables
  from restaurant_tables
  where restaurant_id = p_restaurant_id and is_active = true;

  if v_current_tables > v_plan.max_tables then
    raise exception 'المطعم عنده % طاولة/بطاقة فعّالة، أكتر من حد الباقة الجديدة (%). لازم يلغّي بطاقات زيادة أولاً',
      v_current_tables, v_plan.max_tables;
  end if;

  update subscriptions set status = 'cancelled'
  where restaurant_id = p_restaurant_id and status = 'active';

  insert into subscriptions (restaurant_id, plan_id, status)
  values (p_restaurant_id, p_plan_id, 'active')
  returning * into v_new_sub;

  return v_new_sub;
end;
$$;

grant execute on function rpc_change_subscription_plan(bigint, bigint) to authenticated;

-- ------------------------------------------------------------
-- 5.6 — rpc_create_table / rpc_bulk_create_tables / rpc_deactivate_table
-- owner لمطعمه فقط (أو سوبر أدمن). التريغر trg_enforce_table_limit يبقى فاعلاً
-- كما هو تمامًا (يشتغل على أي insert بغض النظر عن مصدره) — دفاع بعمق.
-- ------------------------------------------------------------
create or replace function rpc_create_table(
  p_restaurant_id bigint,
  p_table_number int
)
returns restaurant_tables
language plpgsql security definer set search_path = public
as $$
declare
  v_table restaurant_tables;
begin
  if not (
    is_super_admin()
    or (current_staff_restaurant_id() = p_restaurant_id and current_staff_role() = 'owner')
  ) then
    raise exception 'لا تملك صلاحية إضافة طاولات لهذا المطعم' using errcode = '42501';
  end if;

  insert into restaurant_tables (restaurant_id, table_number)
  values (p_restaurant_id, p_table_number)
  returning * into v_table;

  return v_table;
exception
  when unique_violation then
    raise exception 'رقم الطاولة مستخدم مسبقاً لهذا المطعم' using errcode = '23505';
end;
$$;

grant execute on function rpc_create_table(bigint, int) to authenticated;

create or replace function rpc_bulk_create_tables(
  p_restaurant_id bigint,
  p_table_numbers int[]
)
returns setof restaurant_tables
language plpgsql security definer set search_path = public
as $$
declare
  v_num int;
  v_row restaurant_tables;
begin
  if not (
    is_super_admin()
    or (current_staff_restaurant_id() = p_restaurant_id and current_staff_role() = 'owner')
  ) then
    raise exception 'لا تملك صلاحية إضافة طاولات لهذا المطعم' using errcode = '42501';
  end if;
  if array_length(p_table_numbers, 1) is null or array_length(p_table_numbers, 1) = 0 then
    raise exception 'لازم قائمة أرقام طاولات غير فارغة';
  end if;
  if array_length(p_table_numbers, 1) > 300 then
    raise exception 'الحد الأقصى 300 طاولة بكل عملية';
  end if;

  foreach v_num in array p_table_numbers loop
    if v_num <= 0 then
      raise exception 'رقم طاولة غير صالح: %', v_num;
    end if;
    insert into restaurant_tables (restaurant_id, table_number)
    values (p_restaurant_id, v_num)
    on conflict (restaurant_id, table_number) do nothing
    returning * into v_row;
    if v_row.id is not null then
      return next v_row;
    end if;
  end loop;
  return;
end;
$$;

grant execute on function rpc_bulk_create_tables(bigint, int[]) to authenticated;

create or replace function rpc_deactivate_table(
  p_restaurant_id bigint,
  p_table_id bigint
)
returns restaurant_tables
language plpgsql security definer set search_path = public
as $$
declare
  v_table restaurant_tables;
begin
  if not (
    is_super_admin()
    or (current_staff_restaurant_id() = p_restaurant_id and current_staff_role() = 'owner')
  ) then
    raise exception 'لا تملك صلاحية تعديل طاولات هذا المطعم' using errcode = '42501';
  end if;

  update restaurant_tables set is_active = false
  where id = p_table_id and restaurant_id = p_restaurant_id
  returning * into v_table;

  if v_table.id is null then
    raise exception 'البطاقة غير موجودة' using errcode = 'P0002';
  end if;
  return v_table;
end;
$$;

grant execute on function rpc_deactivate_table(bigint, bigint) to authenticated;

-- ------------------------------------------------------------
-- 5.7 — rpc_upsert_product / rpc_delete_product: owner لمطعمه فقط (أو سوبر أدمن).
-- ------------------------------------------------------------
create or replace function rpc_upsert_product(
  p_restaurant_id bigint,
  p_product_id bigint default null,  -- null = إنشاء جديد
  p_name text default null,
  p_price numeric default null,
  p_category text default null,
  p_image_url text default null,
  p_available boolean default null
)
returns products
language plpgsql security definer set search_path = public
as $$
declare
  v_product products;
begin
  if not (
    is_super_admin()
    or (current_staff_restaurant_id() = p_restaurant_id and current_staff_role() = 'owner')
  ) then
    raise exception 'لا تملك صلاحية تعديل منتجات هذا المطعم' using errcode = '42501';
  end if;

  if p_product_id is null then
    if p_name is null or p_price is null then
      raise exception 'name وprice مطلوبان لإنشاء منتج جديد';
    end if;
    insert into products (restaurant_id, name, price, category, image_url, available)
    values (p_restaurant_id, p_name, p_price, coalesce(p_category, 'عام'), p_image_url, coalesce(p_available, true))
    returning * into v_product;
  else
    update products set
      name = coalesce(p_name, name),
      price = coalesce(p_price, price),
      category = coalesce(p_category, category),
      image_url = coalesce(p_image_url, image_url),
      available = coalesce(p_available, available)
    where id = p_product_id and restaurant_id = p_restaurant_id
    returning * into v_product;

    if v_product.id is null then
      raise exception 'المنتج غير موجود' using errcode = 'P0002';
    end if;
  end if;

  return v_product;
end;
$$;

grant execute on function rpc_upsert_product(bigint, bigint, text, numeric, text, text, boolean) to authenticated;

create or replace function rpc_delete_product(
  p_restaurant_id bigint,
  p_product_id bigint
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not (
    is_super_admin()
    or (current_staff_restaurant_id() = p_restaurant_id and current_staff_role() = 'owner')
  ) then
    raise exception 'لا تملك صلاحية حذف منتجات هذا المطعم' using errcode = '42501';
  end if;

  delete from products where id = p_product_id and restaurant_id = p_restaurant_id;
  if not found then
    raise exception 'المنتج غير موجود' using errcode = 'P0002';
  end if;
end;
$$;

grant execute on function rpc_delete_product(bigint, bigint) to authenticated;

-- ------------------------------------------------------------
-- 5.8 — دوال عامة (anon) لتدفق NFC/المنيو. security definer لأنو anon ما إله
-- GRANT SELECT مباشر على restaurant_tables (§3.2/§3.4) — الدالة نفسها هي البوابة
-- الوحيدة، وبترجع فقط الحقول الآمنة (بدون card_token نفسه أو أي شي إداري).
-- ------------------------------------------------------------
create or replace function rpc_resolve_table(
  p_slug text,
  p_card_token uuid
)
returns table (table_number int)
language plpgsql security definer set search_path = public
as $$
declare
  v_restaurant_id bigint;
  v_restaurant_status text;
  v_table restaurant_tables;
begin
  select id, status into v_restaurant_id, v_restaurant_status
  from restaurants where slug = p_slug;

  if v_restaurant_id is null then
    raise exception 'المطعم غير موجود' using errcode = 'P0002';
  end if;
  if v_restaurant_status not in ('trial', 'active') then
    raise exception 'هذا المطعم غير متاح حاليًا' using errcode = 'P0003';
  end if;

  select * into v_table
  from restaurant_tables
  where restaurant_id = v_restaurant_id and card_token = p_card_token;

  if v_table.id is null then
    raise exception 'الطاولة غير موجودة' using errcode = 'P0002';
  end if;
  if not v_table.is_active then
    raise exception 'هذه الطاولة غير مفعّلة حاليًا' using errcode = 'P0003';
  end if;

  return query select v_table.table_number;
end;
$$;

grant execute on function rpc_resolve_table(text, uuid) to anon, authenticated;

-- rpc_menu_bootstrap: نداء واحد مجمّع (مطعم + طاولة + قالب مفعّل + منتجات) —
-- نفس فكرة getBootstrap بـpublicMenu.controller.js (أداء: أقل round-trips للموبايل).
create or replace function rpc_menu_bootstrap(
  p_slug text,
  p_card_token uuid
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_restaurant restaurants;
  v_table restaurant_tables;
  v_template jsonb;
  v_products jsonb;
begin
  select * into v_restaurant from restaurants where slug = p_slug;
  if v_restaurant.id is null then
    raise exception 'المطعم غير موجود' using errcode = 'P0002';
  end if;
  if v_restaurant.status not in ('trial', 'active') then
    raise exception 'هذا المطعم غير متاح حاليًا' using errcode = 'P0003';
  end if;

  select * into v_table
  from restaurant_tables
  where restaurant_id = v_restaurant.id and card_token = p_card_token;
  if v_table.id is null then
    raise exception 'الطاولة غير موجودة' using errcode = 'P0002';
  end if;
  if not v_table.is_active then
    raise exception 'هذه الطاولة غير مفعّلة حاليًا' using errcode = 'P0003';
  end if;

  select case
    when tv.is_builtin then jsonb_build_object('is_builtin', true, 'entry_url', null, 'settings', rmt.settings, 'supports', tv.manifest->'supports')
    else jsonb_build_object('is_builtin', false, 'storage_path', tv.storage_path, 'entry_file', tv.entry_file, 'settings', rmt.settings, 'supports', tv.manifest->'supports')
  end into v_template
  from restaurant_menu_templates rmt
  join template_versions tv on tv.id = rmt.template_version_id
  where rmt.restaurant_id = v_restaurant.id and rmt.is_current = true;

  if v_template is null then
    v_template := jsonb_build_object('is_builtin', true, 'entry_url', null, 'settings', '{}'::jsonb, 'supports', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'price', p.price, 'category', p.category, 'image_url', p.image_url)), '[]'::jsonb)
  into v_products
  from products p
  where p.restaurant_id = v_restaurant.id and p.available = true;

  return jsonb_build_object(
    'restaurant', jsonb_build_object('name', v_restaurant.name, 'slug', v_restaurant.slug, 'logo_url', v_restaurant.logo_url, 'brand_colors', v_restaurant.brand_colors),
    'table', jsonb_build_object('table_number', v_table.table_number),
    'template', v_template,
    'products', v_products
  );
end;
$$;

grant execute on function rpc_menu_bootstrap(text, uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 5.9 — rpc_create_order: الطريقة الوحيدة لإنشاء طلب (راجع §3.1). تعيد بالضبط نفس
-- تحققات publicOrders.controller.js (مطعم فعّال، طاولة فعّالة تخص هذا المطعم)، ثم
-- تُدرج بـtotal=0/items خام — تريغر trg_validate_order (موجود أصلًا، غير معدّل)
-- يعيد حساب items/total الحقيقيين من جدول products وقت الإدراج، بغض النظر عمّا
-- أرسله العميل. لا نثق بأي سعر قادم من الطرف الآخر في أي خطوة من هذه الدالة.
-- ------------------------------------------------------------
create or replace function rpc_create_order(
  p_slug text,
  p_card_token uuid,
  p_items jsonb  -- [{ "product_id": 1, "qty": 2 }, ...] فقط — لا سعر ولا اسم
)
returns orders
language plpgsql security definer set search_path = public
as $$
declare
  v_restaurant restaurants;
  v_table restaurant_tables;
  v_order orders;
  v_item jsonb;
begin
  select * into v_restaurant from restaurants where slug = p_slug;
  if v_restaurant.id is null then
    raise exception 'المطعم غير موجود' using errcode = 'P0002';
  end if;
  if v_restaurant.status not in ('trial', 'active') then
    raise exception 'هذا المطعم غير متاح حاليًا' using errcode = 'P0003';
  end if;

  select * into v_table
  from restaurant_tables
  where restaurant_id = v_restaurant.id and card_token = p_card_token;
  if v_table.id is null then
    raise exception 'الطاولة غير موجودة' using errcode = 'P0002';
  end if;
  if not v_table.is_active then
    raise exception 'هذه الطاولة غير مفعّلة حاليًا' using errcode = 'P0003';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'الطلب لازم يحتوي على منتج واحد على الأقل';
  end if;
  if jsonb_array_length(p_items) > 50 then
    raise exception 'الحد الأقصى 50 صنف بالطلب الواحد';
  end if;

  -- نمرر فقط product_id/qty للتريغر — أي حقل إضافي (سعر/اسم مزوّر) يُتجاهل هون
  -- تمامًا قبل حتى ما يوصل للـinsert، فما إله أي تأثير على total المحسوب.
  for v_item in select * from jsonb_array_elements(p_items) loop
    if not (v_item ? 'product_id' and v_item ? 'qty') then
      raise exception 'كل صنف لازم يحتوي product_id وqty';
    end if;
  end loop;

  insert into orders (restaurant_id, table_id, items, total)
  values (
    v_restaurant.id,
    v_table.id,
    (select jsonb_agg(jsonb_build_object('product_id', (i->>'product_id')::bigint, 'qty', (i->>'qty')::int))
     from jsonb_array_elements(p_items) i),
    0
  )
  returning * into v_order;

  return v_order;
exception
  when unique_violation then
    raise exception 'يوجد طلب سابق لهذه الطاولة لسا ما خلص — لازم ينتهي أو الكاشير يقفله قبل طلب جديد' using errcode = '23505';
end;
$$;

grant execute on function rpc_create_order(text, uuid, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- 5.10 — rpc_select_menu_template: اختيار/تبديل/rollback قالب المنيو لمطعم.
-- ذرّي: إقفال is_current القديم + فتح الجديد + مزامنة restaurants.theme_template —
-- الثلاثة لازم ينجحوا سوا أو يفشلوا سوا (نفس الترانزاكشن اللي كان بـ
-- restaurantMenu.controller.js). owner لمطعمه فقط، أو سوبر أدمن.
-- ------------------------------------------------------------
create or replace function rpc_select_menu_template(
  p_restaurant_id bigint,
  p_template_version_id bigint,
  p_settings jsonb default '{}'::jsonb
)
returns restaurant_menu_templates
language plpgsql security definer set search_path = public
as $$
declare
  v_version template_versions;
  v_slug text;
  v_assignment restaurant_menu_templates;
begin
  if not (
    is_super_admin()
    or (current_staff_restaurant_id() = p_restaurant_id and current_staff_role() = 'owner')
  ) then
    raise exception 'لا تملك صلاحية تعديل قالب هذا المطعم' using errcode = '42501';
  end if;

  select * into v_version
  from template_versions
  where id = p_template_version_id;

  if v_version.id is null then
    raise exception 'نسخة القالب غير موجودة' using errcode = 'P0002';
  end if;

  select slug into v_slug from menu_templates where id = v_version.template_id;
  if v_version.status = 'rejected' then
    raise exception 'لا يمكن استخدام نسخة مرفوضة أمنيًا';
  end if;

  update restaurant_menu_templates set is_current = false, deactivated_at = now()
  where restaurant_id = p_restaurant_id and is_current = true;

  insert into restaurant_menu_templates
    (restaurant_id, template_version_id, settings, is_current, activated_by_type, activated_by_id)
  values (
    p_restaurant_id,
    p_template_version_id,
    coalesce(p_settings, '{}'::jsonb),
    true,
    case when is_super_admin() then 'super_admin' else 'restaurant_admin' end,
    case
      when is_super_admin() then (select id from super_admins where user_id = auth.uid())
      else (select id from restaurant_admins where user_id = auth.uid())
    end
  )
  returning * into v_assignment;

  update restaurants set theme_template = v_slug where id = p_restaurant_id;

  return v_assignment;
end;
$$;

grant execute on function rpc_select_menu_template(bigint, bigint, jsonb) to authenticated;

-- ------------------------------------------------------------
-- 5.11 — rpc_order_stats / rpc_top_products: إحصائيات لوحة تحكم المطعم.
-- security invoker يكفي هون (القراءة أصلًا مسموحة عبر RLS الحالي لـstaff/super_admin
-- على جدول orders — نضيف فقط رسالة خطأ واضحة بدل رجوع صفوف فاضية بصمت).
-- ------------------------------------------------------------
create or replace function rpc_order_stats(
  p_restaurant_id bigint,
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns table (completed_orders bigint, total_revenue numeric, avg_order_value numeric)
language plpgsql security invoker set search_path = public
as $$
begin
  if not (
    is_super_admin()
    or current_staff_restaurant_id() = p_restaurant_id
  ) then
    raise exception 'لا تملك صلاحية الاطلاع على إحصائيات هذا المطعم' using errcode = '42501';
  end if;

  return query
  select
    count(*) filter (where status = 'done'),
    coalesce(sum(total) filter (where status = 'done'), 0),
    coalesce(avg(total) filter (where status = 'done'), 0)
  from orders
  where restaurant_id = p_restaurant_id
    and created_at >= coalesce(p_from, now() - interval '30 days')
    and created_at <= coalesce(p_to, now());
end;
$$;

grant execute on function rpc_order_stats(bigint, timestamptz, timestamptz) to authenticated;

create or replace function rpc_top_products(
  p_restaurant_id bigint,
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns table (product_name text, total_qty bigint, total_revenue numeric)
language plpgsql security invoker set search_path = public
as $$
begin
  if not (
    is_super_admin()
    or current_staff_restaurant_id() = p_restaurant_id
  ) then
    raise exception 'لا تملك صلاحية الاطلاع على إحصائيات هذا المطعم' using errcode = '42501';
  end if;

  return query
  select
    item->>'name' as product_name,
    sum((item->>'qty')::int) as total_qty,
    sum((item->>'unit_price')::numeric * (item->>'qty')::int) as total_revenue
  from orders, jsonb_array_elements(orders.items) as item
  where orders.restaurant_id = p_restaurant_id
    and orders.status = 'done'
    and orders.created_at >= coalesce(p_from, now() - interval '30 days')
    and orders.created_at <= coalesce(p_to, now())
  group by product_name
  order by total_qty desc
  limit 10;
end;
$$;

grant execute on function rpc_top_products(bigint, timestamptz, timestamptz) to authenticated;

-- ============================================================
-- 6) Supabase Storage — policies على storage.objects
-- bucket واحد لكل غرض، كلاهما public-read (كما بالإعداد الحالي)، والكتابة محصورة
-- بمسار يبدأ برقم/معرّف المطعم صاحب العلاقة، owner فقط (أو سوبر أدمن لـtemplates).
-- الافتراض: مسار الملف داخل الـbucket يبدأ دائمًا بـ"<restaurant_id>/..." لـ
-- restaurant-assets، وبـ"<template_id>/<version>/..." لـtemplates (نفس تسمية
-- storage.js الحالي uploadRestaurantAsset/uploadTemplateFiles).
-- ============================================================

drop policy if exists "public read restaurant-assets" on storage.objects;
create policy "public read restaurant-assets" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'restaurant-assets');

drop policy if exists "owner writes own restaurant-assets" on storage.objects;
create policy "owner writes own restaurant-assets" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'restaurant-assets'
    and (storage.foldername(name))[1] = current_staff_restaurant_id()::text
    and current_staff_role() = 'owner'
  );

drop policy if exists "owner updates own restaurant-assets" on storage.objects;
create policy "owner updates own restaurant-assets" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'restaurant-assets'
    and (storage.foldername(name))[1] = current_staff_restaurant_id()::text
    and current_staff_role() = 'owner'
  );

drop policy if exists "owner deletes own restaurant-assets" on storage.objects;
create policy "owner deletes own restaurant-assets" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'restaurant-assets'
    and (storage.foldername(name))[1] = current_staff_restaurant_id()::text
    and current_staff_role() = 'owner'
  );

-- templates bucket: قراءة عامة (القالب المرفوع لازم يتحمّل بمتصفح الزبون مباشرة)،
-- الكتابة مقفولة كليًا عن anon/authenticated — فقط service_role (عبر Edge Function
-- بعد فحص ZIP خارج قاعدة البيانات، راجع القسم المخصص بملف التحليل).
drop policy if exists "public read templates" on storage.objects;
create policy "public read templates" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'templates');
-- لا insert/update/delete policies لـanon/authenticated على bucket templates إطلاقًا.
