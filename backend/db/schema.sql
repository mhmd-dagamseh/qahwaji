-- ============================================================
-- Cafe/Restaurant Ordering SaaS — Multi-Tenant Schema (v2)
-- يبني على النظام الأصلي (cafe واحد) ويحوّله لنظام متعدد المستأجرين
-- آمن لإعادة التشغيل (idempotent) قدر الإمكان
-- ============================================================

-- ------------------------------------------------------------
-- 1) سوبر أدمن (شركتكم) — يدير كل المطاعم المشتركة
-- ------------------------------------------------------------
create table if not exists super_admins (
  id bigint generated always as identity primary key,
  email text unique not null,
  password_hash text not null,
  full_name text,
  created_at timestamptz default now()
);

-- ------------------------------------------------------------
-- 2) الباقات (Plans) — كل باقة بتحدد أقصى عدد طاولات/بطاقات
-- ------------------------------------------------------------
create table if not exists plans (
  id bigint generated always as identity primary key,
  name text not null,
  slug text unique not null,
  max_tables int not null check (max_tables > 0),
  price_monthly numeric not null default 0,
  features jsonb default '{}'::jsonb,   -- مثال: {"digital_signage": true, "custom_theme": true}
  active boolean default true,
  created_at timestamptz default now()
);

-- ------------------------------------------------------------
-- 3) المطاعم/المتاجر (Tenants)
-- ------------------------------------------------------------
create table if not exists restaurants (
  id bigint generated always as identity primary key,
  name text not null,
  slug text unique not null,             -- يستخدم بالرابط بدل رقم الـ id
  logo_url text,
  theme_template text default 'default', -- اسم القالب (theme) المستخدم بواجهة المنيو
  brand_colors jsonb default '{}'::jsonb, -- {"primary":"#...", "secondary":"#..."}
  status text not null default 'trial' check (status in ('trial','active','suspended','cancelled')),
  created_at timestamptz default now()
);

-- ------------------------------------------------------------
-- 4) أدمن كل مطعم (صاحب المطعم / الكاشير)
-- ------------------------------------------------------------
create table if not exists restaurant_admins (
  id bigint generated always as identity primary key,
  restaurant_id bigint not null references restaurants(id) on delete cascade,
  email text not null,
  password_hash text not null,
  role text not null default 'owner' check (role in ('owner','cashier')),
  created_at timestamptz default now(),
  unique (restaurant_id, email)
);

-- ------------------------------------------------------------
-- 5) الاشتراكات — كل مطعم إله اشتراك حالي (وسجل تاريخي)
-- ------------------------------------------------------------
create table if not exists subscriptions (
  id bigint generated always as identity primary key,
  restaurant_id bigint not null references restaurants(id) on delete cascade,
  plan_id bigint not null references plans(id),
  status text not null default 'active' check (status in ('active','expired','cancelled')),
  started_at timestamptz default now(),
  current_period_end timestamptz,
  created_at timestamptz default now()
);

-- يضمن اشتراك "فعّال" واحد بس بأي وقت لكل مطعم
create unique index if not exists uniq_active_subscription_per_restaurant
  on subscriptions (restaurant_id)
  where status = 'active';

-- ------------------------------------------------------------
-- 6) الطاولات/البطاقات (كل بطاقة NFC = صف هون)
--    عدد الصفوف الفعّالة لكل مطعم محكوم بحد الباقة (max_tables)
-- ------------------------------------------------------------
create table if not exists restaurant_tables (
  id bigint generated always as identity primary key,
  restaurant_id bigint not null references restaurants(id) on delete cascade,
  table_number int not null,
  card_token uuid not null default gen_random_uuid(), -- يُطبع كـ QR/يُكتب على شريحة الـ NFC
  is_active boolean default true,
  created_at timestamptz default now(),
  unique (restaurant_id, table_number),
  unique (card_token)
);

-- تريغر يفرض حد الباقة عند إضافة بطاقة/طاولة جديدة (طبقة حماية إضافية بجانب فحص الـ API)
create or replace function enforce_table_limit()
returns trigger as $$
declare
  current_count int;
  max_allowed int;
begin
  select p.max_tables into max_allowed
  from subscriptions s
  join plans p on p.id = s.plan_id
  where s.restaurant_id = new.restaurant_id
    and s.status = 'active'
  limit 1;

  if max_allowed is null then
    raise exception 'لا يوجد اشتراك فعّال لهذا المطعم';
  end if;

  select count(*) into current_count
  from restaurant_tables
  where restaurant_id = new.restaurant_id
    and is_active = true;

  if current_count >= max_allowed then
    raise exception 'تم الوصول للحد الأقصى لعدد الطاولات/البطاقات المسموح به بالباقة الحالية (%)', max_allowed;
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_enforce_table_limit on restaurant_tables;
create trigger trg_enforce_table_limit
  before insert on restaurant_tables
  for each row execute function enforce_table_limit();

-- ------------------------------------------------------------
-- 7) المنتجات — أصبحت مرتبطة بـ restaurant_id بدل cafe_id
-- ------------------------------------------------------------
create table if not exists products (
  id bigint generated always as identity primary key,
  restaurant_id bigint not null references restaurants(id) on delete cascade,
  name text not null,
  price numeric not null,
  category text default 'عام',
  image_url text,
  available boolean default true,
  created_at timestamptz default now()
);

-- ------------------------------------------------------------
-- 8) الطلبات — مرتبطة بـ restaurant_id و table_id (بدل table_number الخام)
-- ------------------------------------------------------------
create table if not exists orders (
  id bigint generated always as identity primary key,
  restaurant_id bigint not null references restaurants(id) on delete cascade,
  table_id bigint not null references restaurant_tables(id),
  items jsonb not null,
  total numeric not null,
  status text not null default 'pending' check (status in ('pending','confirmed','done')),
  confirmed_at timestamptz,
  ready_at timestamptz,
  cash_received numeric,
  created_at timestamptz default now()
);

create unique index if not exists uniq_active_order_per_table
  on orders (table_id)
  where status <> 'done';

create index if not exists idx_orders_restaurant_status on orders (restaurant_id, status);
create index if not exists idx_products_restaurant_available on products (restaurant_id, available);

-- ------------------------------------------------------------
-- 9) حساب الإجمالي والتحقق من الأسعار من السيرفر (نفس فكرة fixes.sql الأصلية)
-- ------------------------------------------------------------
create or replace function validate_order_before_insert()
returns trigger as $$
declare
  computed_total numeric := 0;
  item jsonb;
  real_price numeric;
  tbl_restaurant_id bigint;
begin
  select restaurant_id into tbl_restaurant_id from restaurant_tables where id = new.table_id;
  if tbl_restaurant_id is null or tbl_restaurant_id <> new.restaurant_id then
    raise exception 'الطاولة غير تابعة لهذا المطعم';
  end if;

  if new.status is distinct from 'pending' then
    raise exception 'الطلبات الجديدة لازم تبدأ بحالة pending';
  end if;

  for item in select * from jsonb_array_elements(new.items)
  loop
    select price into real_price
    from products
    where id = (item->>'product_id')::bigint
      and restaurant_id = new.restaurant_id
      and available = true;

    if real_price is null then
      raise exception 'منتج غير موجود أو غير متاح ضمن الطلب';
    end if;

    computed_total := computed_total + (real_price * (item->>'qty')::int);
  end loop;

  new.total := computed_total;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_validate_order on orders;
create trigger trg_validate_order
  before insert on orders
  for each row execute function validate_order_before_insert();

create or replace function validate_order_status_transition()
returns trigger as $$
begin
  if old.status = 'done' then
    raise exception 'ما فيك تعدل على طلب خلص (done)';
  end if;
  if old.status = 'pending' and new.status not in ('pending','confirmed') then
    raise exception 'انتقال غير صحيح لحالة الطلب';
  end if;
  if old.status = 'confirmed' and new.status not in ('confirmed','done') then
    raise exception 'انتقال غير صحيح لحالة الطلب';
  end if;
  return new;
end;
$$ language plpgsql set search_path = public;

drop trigger if exists trg_order_status_transition on orders;
create trigger trg_order_status_transition
  before update on orders
  for each row execute function validate_order_status_transition();

-- ------------------------------------------------------------
-- 10) RLS — الوصول العام (menu/cashier) محصور بمطاعم فعّالة فقط
-- ------------------------------------------------------------
alter table restaurants enable row level security;
alter table restaurant_tables enable row level security;
alter table products enable row level security;
alter table orders enable row level security;

drop policy if exists "public read active restaurants" on restaurants;
create policy "public read active restaurants" on restaurants
  for select using (status in ('trial','active'));

drop policy if exists "public read active tables" on restaurant_tables;
create policy "public read active tables" on restaurant_tables
  for select using (
    is_active = true
    and exists (select 1 from restaurants r where r.id = restaurant_id and r.status in ('trial','active'))
  );

drop policy if exists "public read available products" on products;
create policy "public read available products" on products
  for select using (
    exists (select 1 from restaurants r where r.id = restaurant_id and r.status in ('trial','active'))
  );

drop policy if exists "public insert orders" on orders;
create policy "public insert orders" on orders for insert with check (true);
drop policy if exists "public read orders" on orders;
create policy "public read orders" on orders for select using (true);
drop policy if exists "public update orders" on orders;
create policy "public update orders" on orders for update using (true);

-- تقييد الأعمدة اللي ممكن تتعدل عن طريق anon (نفس فكرة fixes.sql)
revoke update on orders from anon;
grant update (status, confirmed_at, ready_at, cash_received) on orders to anon;
revoke update on orders from authenticated;
grant update (status, confirmed_at, ready_at, cash_received) on orders to authenticated;

-- restaurants/plans/subscriptions/restaurant_admins/super_admins ما إلها public policies —
-- الوصول إلها بيصير حصرياً من الـ API الخلفي (service role) يلي بيفرض صلاحيات السوبر أدمن/أدمن المطعم
alter table plans enable row level security;
alter table subscriptions enable row level security;
alter table restaurant_admins enable row level security;
alter table super_admins enable row level security;

-- ------------------------------------------------------------
-- 11) تفعيل Realtime على orders (لازم لصفحة المنيو والكاشير)
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table orders;
  end if;
end $$;

-- ------------------------------------------------------------
-- 12) بيانات أولية — باقات مقترحة (عدّلوها حسب نموذج التسعير)
-- ------------------------------------------------------------
insert into plans (name, slug, max_tables, price_monthly, features)
values
  ('Starter', 'starter', 10, 25, '{"digital_signage": false, "custom_theme": false}'),
  ('Growth', 'growth', 30, 60, '{"digital_signage": true, "custom_theme": true}'),
  ('Enterprise', 'enterprise', 100, 150, '{"digital_signage": true, "custom_theme": true, "priority_support": true}')
on conflict (slug) do nothing;
