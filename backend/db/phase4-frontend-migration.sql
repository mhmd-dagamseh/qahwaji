-- ============================================================================
-- phase4-frontend-migration.sql
-- المرحلة 2/3: نقل الـFrontend الفعلي إلى Supabase + سد الفجوات التي ظهرت أثناء
-- إعادة كتابة صفحات الـFrontend الأربع (admin / restaurant-admin / cashier / menu)
-- لتستخدم Supabase مباشرة بدل الـNode backend.
--
-- هذا الملف إضافي فقط (additive) فوق:
--   schema.sql -> hardening-v1.sql -> phase2.sql -> phase3-supabase-native.sql
-- شغّله بعدهم بالترتيب، أو بعد تشغيل كامل السلسلة مرة وحدة على مشروع جديد.
-- كل شي هنا idempotent (create or replace / drop-if-exists) وآمن للتشغيل أكثر من مرة.
--
-- الفجوات التي يسدّها هذا الملف بالتحديد:
--   1) rpc_update_menu_template_settings  — تعديل إعدادات القالب الحالي بدون
--      إنشاء سطر جديد بسجل التاريخ (كان PATCH /menu-template/settings بالـNode القديم).
--   2) rpc_activate_template_version /
--      rpc_deactivate_template_version    — كانتا مسارين بالـNode
--      (POST .../activate و .../deactivate) بدون أي RPC مقابل بمرحلة 1.
--   3) rpc_admin_list_restaurants         — استعلام القائمة المجمّع (مطعم + باقته
--      الفعّالة + عدد الطاولات المستخدمة) اللي كان الـNode يبنيه بجملة SQL واحدة؛
--      RLS المباشر ما بيقدر يعبّر عنه بأمان وبدون N+1 request من الـFrontend.
--   4) rpc_menu_bootstrap (تحديث)          — نفس المنطق تمامًا، لكن بدل ما يرمي
--      رسائل نصية عربية لحالات "غير موجود/غير مفعّل"، صار يرمي رموز قصيرة ثابتة
--      (RESTAURANT_NOT_FOUND, RESTAURANT_INACTIVE, TABLE_NOT_FOUND, TABLE_INACTIVE)
--      بالضبط متل أكواد ApiError بالـNode القديم. هيك menu-sdk.js الجديد يقدر يميّز
--      الحالات ويعرض نفس رسائل i18n (عربي/إنجليزي) الموجودة أصلًا بصفحة المنيو، من
--      غير ما نلمس صفحة المنيو نفسها ولا جدول الترجمة فيها إطلاقًا.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) rpc_update_menu_template_settings
--    تحديث settings فقط على النسخة الحالية (is_current = true) بدون تغيير
--    template_version_id وبدون إنشاء سطر تاريخ جديد. بديل PATCH .../menu-template/settings.
-- ----------------------------------------------------------------------------
create or replace function rpc_update_menu_template_settings(
  p_restaurant_id bigint,
  p_settings jsonb
)
returns restaurant_menu_templates
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row restaurant_menu_templates;
begin
  if p_restaurant_id is null then
    raise exception 'restaurant_id مطلوب' using errcode = '22023';
  end if;

  if not (
    is_super_admin()
    or (current_staff_restaurant_id() = p_restaurant_id and current_staff_role() = 'owner')
  ) then
    raise exception 'لا تملك صلاحية تعديل إعدادات قالب هذا المطعم' using errcode = '42501';
  end if;

  update restaurant_menu_templates
  set settings = coalesce(p_settings, '{}'::jsonb)
  where restaurant_id = p_restaurant_id
    and is_current = true
  returning * into v_row;

  if v_row.id is null then
    raise exception 'لا يوجد قالب مفعّل حاليًا لهذا المطعم' using errcode = 'P0002';
  end if;

  return v_row;
end;
$$;

revoke all on function rpc_update_menu_template_settings(bigint, jsonb) from public;
grant execute on function rpc_update_menu_template_settings(bigint, jsonb) to authenticated;

-- ----------------------------------------------------------------------------
-- 2) rpc_activate_template_version / rpc_deactivate_template_version
--    سوبر أدمن فقط. تفعيل نسخة = تصير status='active' (تظهر لاختيار المطاعم).
--    إلغاء التفعيل = ترجع status='installed' (منصّبة لكن غير معروضة للاختيار).
--    القالب المدمج (is_builtin) ما إله معنى "تفعيل/إلغاء تفعيل" — يُرفض صراحة.
--    ملاحظة: هذا لا يمسّ restaurant_menu_templates — أي مطعم مختار نسخة تم إلغاء
--    تفعيلها يستمر شغّال عليها (نفس سلوك الـNode القديم: لا rollback قسري).
-- ----------------------------------------------------------------------------
create or replace function rpc_activate_template_version(
  p_template_id bigint,
  p_version_id bigint
)
returns template_versions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row template_versions;
begin
  if not is_super_admin() then
    raise exception 'هذا الإجراء مخصص لإدارة الشركة فقط' using errcode = '42501';
  end if;

  update template_versions
  set status = 'active',
      activated_at = now()
  where id = p_version_id
    and template_id = p_template_id
    and is_builtin = false
    and status <> 'rejected'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'النسخة غير موجودة أو لا يمكن تفعيلها' using errcode = 'P0002';
  end if;

  return v_row;
end;
$$;

revoke all on function rpc_activate_template_version(bigint, bigint) from public;
grant execute on function rpc_activate_template_version(bigint, bigint) to authenticated;

create or replace function rpc_deactivate_template_version(
  p_template_id bigint,
  p_version_id bigint
)
returns template_versions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row template_versions;
begin
  if not is_super_admin() then
    raise exception 'هذا الإجراء مخصص لإدارة الشركة فقط' using errcode = '42501';
  end if;

  update template_versions
  set status = 'installed'
  where id = p_version_id
    and template_id = p_template_id
    and is_builtin = false
    and status = 'active'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'النسخة غير موجودة أو ليست مفعّلة أصلًا' using errcode = 'P0002';
  end if;

  return v_row;
end;
$$;

revoke all on function rpc_deactivate_template_version(bigint, bigint) from public;
grant execute on function rpc_deactivate_template_version(bigint, bigint) to authenticated;

-- ----------------------------------------------------------------------------
-- 3) rpc_admin_list_restaurants
--    استعلام قراءة مجمّع (security invoker — بالضبط متل rpc_order_stats/rpc_top_products
--    بملف phase3): كل صلاحيات القراءة أصلًا موجودة عبر RLS لسوبر أدمن على الجداول
--    الأربعة (restaurants, subscriptions, plans, restaurant_tables)، وهاي الدالة
--    فقط بتجمعهم بنداء واحد بدل ما الـFrontend يسوي N+1 نداء ويجمّع بالـJS.
-- ----------------------------------------------------------------------------
create or replace function rpc_admin_list_restaurants()
returns table (
  id bigint,
  name text,
  slug text,
  logo_url text,
  theme_template text,
  brand_colors jsonb,
  status text,
  created_at timestamptz,
  plan_id bigint,
  plan_name text,
  max_tables int,
  subscription_status text,
  current_period_end timestamptz,
  tables_used bigint
)
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not is_super_admin() then
    raise exception 'هذا الإجراء مخصص لإدارة الشركة فقط' using errcode = '42501';
  end if;

  return query
  select
    r.id,
    r.name,
    r.slug,
    r.logo_url,
    r.theme_template,
    r.brand_colors,
    r.status,
    r.created_at,
    p.id as plan_id,
    p.name as plan_name,
    p.max_tables,
    s.status as subscription_status,
    s.current_period_end,
    (
      select count(*)
      from restaurant_tables t
      where t.restaurant_id = r.id
        and t.is_active
    ) as tables_used
  from restaurants r
  left join subscriptions s on s.restaurant_id = r.id and s.status = 'active'
  left join plans p on p.id = s.plan_id
  order by r.created_at desc;
end;
$$;

revoke all on function rpc_admin_list_restaurants() from public;
grant execute on function rpc_admin_list_restaurants() to authenticated;

-- ----------------------------------------------------------------------------
-- 4) rpc_menu_bootstrap (تحديث) — نفس منطق phase3 بالضبط، فقط استبدال رسائل
--    "غير موجود/غير مفعّل" برموز قصيرة ثابتة يفهمها menu-sdk.js الجديد.
--    باقي الدالة (بناء jsonb المنتجات/القالب/الفئات) بلا أي تغيير.
-- ----------------------------------------------------------------------------
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
    raise exception 'RESTAURANT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_restaurant.status not in ('trial', 'active') then
    raise exception 'RESTAURANT_INACTIVE' using errcode = 'P0003';
  end if;

  select * into v_table
  from restaurant_tables
  where restaurant_id = v_restaurant.id and card_token = p_card_token;
  if v_table.id is null then
    raise exception 'TABLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not v_table.is_active then
    raise exception 'TABLE_INACTIVE' using errcode = 'P0003';
  end if;

  -- بلا أي تغيير عن phase3: نفس بنية jsonb للقالب بالضبط (entry_url دائمًا null هون —
  -- menu-sdk.js بالفرونت إند هو من يبني الرابط الفعلي من storage_path/entry_file
  -- باستخدام SUPABASE_URL العام، لأن الدالة ما إلها داعي تعرف عنوان الـFrontend).
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

  -- إضافة "order by" فقط (كانت ناقصة بـphase3) لضمان ترتيب ثابت للفئات/المنتجات
  -- مطابق تمامًا لـ"order by category, name" اللي كان بالـNode الأصلي.
  select coalesce(jsonb_agg(
    jsonb_build_object('id', p.id, 'name', p.name, 'price', p.price, 'category', p.category, 'image_url', p.image_url)
    order by p.category, p.name
  ), '[]'::jsonb)
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

revoke all on function rpc_menu_bootstrap(text, uuid) from public;
grant execute on function rpc_menu_bootstrap(text, uuid) to anon, authenticated;

-- ============================================================================
-- نهاية phase4-frontend-migration.sql
-- ============================================================================
