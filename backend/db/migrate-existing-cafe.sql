-- ============================================================
-- ترحيل بيانات الكافيه التجريبي الحالي إلى النظام الجديد
--
-- تنبيه مهم: schema.sql الجديد بينشئ جداول اسمها products / orders
-- بنفس الاسم القديم بس ببنية مختلفة (restaurant_id بدل cafe_id،
-- table_id بدل table_number). لهيك لازم أول شي نرجّع تسمية
-- الجداول القديمة قبل تشغيل schema.sql، متل هيك بالضبط:
--
--   alter table products rename to products_old;
--   alter table orders rename to orders_old;
--   -- (جدول cafes منيح نخليه لأنه مش رح يتعارض بالاسم)
--
-- بعدين شغّلوا schema.sql، وبعدها هاد الملف.
-- ============================================================

do $$
declare
  v_restaurant_id bigint;
  v_plan_id bigint;
  v_table_id bigint;
begin
  -- 1) إنشاء المطعم من سجل cafes(id=1)
  insert into restaurants (name, slug, status)
  select name, 'demo-cafe', 'trial' from cafes where id = 1
  on conflict (slug) do nothing;

  select id into v_restaurant_id from restaurants where slug = 'demo-cafe';

  -- 2) اشتراك فعّال بباقة Starter
  select id into v_plan_id from plans where slug = 'starter';
  insert into subscriptions (restaurant_id, plan_id, status)
  select v_restaurant_id, v_plan_id, 'active'
  where not exists (select 1 from subscriptions where restaurant_id = v_restaurant_id and status = 'active');

  -- 3) ترحيل المنتجات (من products_old)
  insert into products (restaurant_id, name, price, category, available)
  select v_restaurant_id, name, price, category, available
  from products_old
  where cafe_id = 1;

  -- 4) إنشاء طاولة/بطاقة واحدة لكل رقم طاولة ظهر بجدول orders_old
  --    (النظام القديم ما كان عنده جدول طاولات منفصل، كان بس رقم صحيح)
  for v_table_id in
    select distinct table_number from orders_old where cafe_id = 1
  loop
    insert into restaurant_tables (restaurant_id, table_number)
    values (v_restaurant_id, v_table_id)
    on conflict (restaurant_id, table_number) do nothing;
  end loop;

  -- 5) ترحيل الطلبات القديمة (اختياري — عادة الطلبات القديمة تاريخية فقط)
  insert into orders (restaurant_id, table_id, items, total, status, confirmed_at, ready_at, cash_received, created_at)
  select v_restaurant_id, rt.id, o.items, o.total, o.status, o.confirmed_at, o.ready_at, o.cash_received, o.created_at
  from orders_old o
  join restaurant_tables rt on rt.restaurant_id = v_restaurant_id and rt.table_number = o.table_number
  where o.cafe_id = 1;

end $$;
