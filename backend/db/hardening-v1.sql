-- ============================================================
-- Cafe SaaS Core — Hardening v1
-- يطبّق بنود المراجعة التقنية (Cafe_SaaS_Core_Technical_Audit_Report)
-- شغّلوه بعد schema.sql (وبعد migrate-existing-cafe.sql إذا احتجتوه)
-- ============================================================

-- ------------------------------------------------------------
-- 3.1 — بريد أدمن المطعم لازم يكون فريد globally مش بس (restaurant_id, email)
-- تسجيل الدخول الحالي يبحث بالبريد وحده، فلازم يرجع صف واحد مضمون دائمًا.
-- ------------------------------------------------------------
do $$
declare
  dup record;
  dup_count int := 0;
begin
  for dup in
    select email, count(*) c from restaurant_admins group by email having count(*) > 1
  loop
    dup_count := dup_count + 1;
    raise notice 'بريد مكرر بين أكثر من مطعم: % (% حسابات) — لازم تدمج/تعدّل الحسابات يدويًا قبل تفعيل القيد أدناه', dup.email, dup.c;
  end loop;

  if dup_count > 0 then
    raise exception 'يوجد % بريد مكرر بجدول restaurant_admins. عالجوها ثم أعيدوا تشغيل هذا الملف — القيد unique(email) ما رح ينضاف تلقائيًا لتفادي فقدان بيانات', dup_count;
  end if;
end $$;

alter table restaurant_admins
  add constraint restaurant_admins_email_key unique (email);

-- ------------------------------------------------------------
-- 4.2 / 4.3 — قيود قيم موجبة على مستوى DB (مو بس على مستوى الـAPI)
-- ------------------------------------------------------------
alter table restaurant_tables
  add constraint chk_table_number_positive check (table_number > 0);

alter table products
  add constraint chk_price_nonnegative check (price >= 0);

-- ------------------------------------------------------------
-- 3.5 / 3.6 — enforce_table_limit: فرض current_period_end + قفل ضد Race Condition
-- pg_advisory_xact_lock بيسلسل كل محاولات الإدراج لنفس المطعم داخل نفس الترانزاكشن،
-- وينحل تلقائيًا عند commit/rollback — ما بيحتاج تنظيف يدوي.
-- ------------------------------------------------------------
create or replace function enforce_table_limit()
returns trigger as $$
declare
  current_count int;
  max_allowed int;
begin
  perform pg_advisory_xact_lock(hashtextextended('table_limit:' || new.restaurant_id::text, 0));

  select p.max_tables into max_allowed
  from subscriptions s
  join plans p on p.id = s.plan_id
  where s.restaurant_id = new.restaurant_id
    and s.status = 'active'
    and (s.current_period_end is null or s.current_period_end > now())
  limit 1;

  if max_allowed is null then
    raise exception 'لا يوجد اشتراك فعّال (أو منتهي الفترة) لهذا المطعم';
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

-- ------------------------------------------------------------
-- قسم 5 — snapshot للطلب: نخزن اسم/سعر المنتج وقت البيع، مش مرجع حي بس
-- (وبنصلح كمان باگ جانبي: top-products كانت تقرأ item->>'price' اللي المستخدم
--  نفسه بعت قيمته الأصلية، بدل السعر الحقيقي من الجدول)
-- ------------------------------------------------------------
create or replace function validate_order_before_insert()
returns trigger as $$
declare
  computed_total numeric := 0;
  item jsonb;
  snapshot_items jsonb := '[]'::jsonb;
  prod record;
  qty int;
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
    qty := (item->>'qty')::int;
    if qty is null or qty <= 0 then
      raise exception 'كمية غير صالحة ضمن الطلب';
    end if;

    select id, name, price into prod
    from products
    where id = (item->>'product_id')::bigint
      and restaurant_id = new.restaurant_id
      and available = true;

    if prod.id is null then
      raise exception 'منتج غير موجود أو غير متاح ضمن الطلب';
    end if;

    computed_total := computed_total + (prod.price * qty);
    snapshot_items := snapshot_items || jsonb_build_object(
      'product_id', prod.id,
      'name', prod.name,
      'unit_price', prod.price,
      'qty', qty,
      'subtotal', prod.price * qty
    );
  end loop;

  if jsonb_array_length(snapshot_items) = 0 then
    raise exception 'الطلب لازم يحتوي على منتج واحد على الأقل';
  end if;

  new.items := snapshot_items;
  new.total := computed_total;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

-- ------------------------------------------------------------
-- 3.4 — RLS الطلبات: أخطر بند بالتقرير (مكشوف الآن، مش "قبل الإنتاج" بس)
--
-- الوضع الجديد:
--   • إنشاء الطلب (insert): يضل عام — الزبون بينشئ طلبه من صفحة المنيو بلا تسجيل دخول.
--   • قراءة الطلب (select): إما بـ access_token (رجع وقت الإنشاء، الزبون يستخدمه
--     لتتبع طلبه بنفسه عبر REST — مو Realtime، لأن Realtime ما بتقرأ custom headers)،
--     أو staff عندهم Supabase JWT مصادق عليه (authenticated) مع restaurant_id مطابق.
--   • تحديث الطلب (update): staff بس (owner/cashier) عبر JWT مصادق مع restaurant_id مطابق.
--     الزبون العادي (anon) ما عاد يقدر يعدّل أي طلب حتى لو عرف الـid.
-- ------------------------------------------------------------
alter table orders add column if not exists access_token uuid not null default gen_random_uuid();
create unique index if not exists uniq_orders_access_token on orders (access_token);

drop policy if exists "public read orders" on orders;
drop policy if exists "public update orders" on orders;

create policy "read order by token or staff" on orders
for select using (
  access_token::text = coalesce(
    (current_setting('request.headers', true)::json ->> 'x-order-token'), ''
  )
  or (
    auth.role() = 'authenticated'
    and coalesce((auth.jwt() ->> 'restaurant_id')::bigint, -1) = restaurant_id
  )
);

create policy "staff update orders" on orders
for update using (
  auth.role() = 'authenticated'
  and coalesce((auth.jwt() ->> 'restaurant_id')::bigint, -1) = restaurant_id
  and coalesce(auth.jwt() ->> 'staff_role', '') in ('owner', 'cashier')
);

-- الزبون (anon) ما عاد يقدر يعدّل الطلب إطلاقًا — بس الطاقم authenticated
revoke update on orders from anon;
revoke update on orders from authenticated;
grant update (status, confirmed_at, ready_at, cash_received) on orders to authenticated;

-- ------------------------------------------------------------
-- 4.8 — Audit Logs (من غيّر شو، وإمتى)
-- التسجيل يصير من طبقة الـAPI (Node) مش من تريغرز DB، لأن هوية الفاعل
-- (super_admin/restaurant_admin) معروفة بس عند طبقة التطبيق بعد فك الـJWT.
-- ------------------------------------------------------------
create table if not exists audit_logs (
  id bigint generated always as identity primary key,
  actor_type text not null check (actor_type in ('super_admin', 'restaurant_admin')),
  actor_id bigint,
  restaurant_id bigint references restaurants(id) on delete set null,
  action text not null,
  resource text,
  old_values jsonb,
  new_values jsonb,
  created_at timestamptz default now()
);

create index if not exists idx_audit_logs_restaurant on audit_logs (restaurant_id, created_at desc);
create index if not exists idx_audit_logs_action on audit_logs (action, created_at desc);

alter table audit_logs enable row level security;
-- بدون policies = مقفول تمامًا عن anon/authenticated، الوصول حصرًا عبر service-role (Node)
