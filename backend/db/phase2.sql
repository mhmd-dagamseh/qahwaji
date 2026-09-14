-- ============================================================
-- Cafe SaaS Core — Phase 2: Menu Template Engine
-- شغّلوه بعد schema.sql و hardening-v1.sql (وmigrate-existing-cafe.sql إذا احتجتوه)
-- إضافات فقط — ما بيعدّل ولا يحذف أي جدول/عمود/سياسة من Phase 1
-- آمن لإعادة التشغيل (idempotent)
-- ============================================================

-- ------------------------------------------------------------
-- 1) menu_templates — عائلة القالب (مثال: "Modern Restaurant")
-- ------------------------------------------------------------
create table if not exists menu_templates (
  id bigint generated always as identity primary key,
  name text not null,
  slug text unique not null,
  type text not null default 'customer-menu' check (type = 'customer-menu'),
  is_builtin boolean not null default false,
  created_at timestamptz default now()
);

-- ------------------------------------------------------------
-- 2) template_versions — كل نسخة إلها manifest خاص فيها + مكان تخزين ملفاتها
--    القيم الجوهرية (manifest/entry_file/storage_path) غير قابلة للتعديل بعد الإنشاء —
--    "أنشئ نسخة جديدة" هو الطريقة الوحيدة للتغيير (بند 16 بالبرومبت: النسخ القديمة ما تختفي)
-- ------------------------------------------------------------
create table if not exists template_versions (
  id bigint generated always as identity primary key,
  template_id bigint not null references menu_templates(id) on delete cascade,
  version text not null,
  manifest jsonb not null,
  entry_file text not null,
  storage_path text,                 -- null لو is_builtin = true (مشحون مع كود الـfrontend نفسه)
  is_builtin boolean not null default false,
  status text not null default 'installed' check (status in ('installed', 'active', 'rejected')),
  file_count int,
  total_size_bytes bigint,
  checksum text,
  installed_by_super_admin_id bigint references super_admins(id) on delete set null,
  created_at timestamptz default now(),
  activated_at timestamptz,
  unique (template_id, version)
);

create index if not exists idx_template_versions_template on template_versions (template_id, created_at desc);

create or replace function prevent_template_version_mutation()
returns trigger as $$
begin
  if old.manifest is distinct from new.manifest
     or old.entry_file is distinct from new.entry_file
     or old.storage_path is distinct from new.storage_path
     or old.template_id is distinct from new.template_id
     or old.version is distinct from new.version then
    raise exception 'نسخة القالب (template_version) غير قابلة للتعديل بعد إنشائها — أنشئ نسخة جديدة بدل تعديل هذي';
  end if;
  return new;
end;
$$ language plpgsql set search_path = public;

drop trigger if exists trg_prevent_template_version_mutation on template_versions;
create trigger trg_prevent_template_version_mutation
  before update on template_versions
  for each row execute function prevent_template_version_mutation();

-- ------------------------------------------------------------
-- 3) restaurant_menu_templates — سجل تعيين/تفعيل قالب لكل مطعم
--    صف واحد "حالي" (is_current) بأي وقت لكل مطعم — التبديل/rollback = صف جديد + إقفال القديم
--    (التاريخ الكامل يضل محفوظ، ما في حذف)
-- ------------------------------------------------------------
create table if not exists restaurant_menu_templates (
  id bigint generated always as identity primary key,
  restaurant_id bigint not null references restaurants(id) on delete cascade,
  template_version_id bigint not null references template_versions(id),
  settings jsonb not null default '{}'::jsonb,
  is_current boolean not null default true,
  activated_by_type text check (activated_by_type in ('super_admin', 'restaurant_admin')),
  activated_by_id bigint,
  activated_at timestamptz default now(),
  deactivated_at timestamptz
);

create unique index if not exists uniq_current_menu_template_per_restaurant
  on restaurant_menu_templates (restaurant_id)
  where is_current = true;

create index if not exists idx_restaurant_menu_templates_restaurant
  on restaurant_menu_templates (restaurant_id, activated_at desc);

-- ------------------------------------------------------------
-- 4) RLS — نفس فلسفة audit_logs بالضبط: بدون policies = مقفول تمامًا عن anon/authenticated.
--    ما في داعي لقراءة عامة مباشرة من Supabase لهاي الجداول — كل قراءة القوالب للزبون
--    بتصير عبر الـPublic API (Node) اللي بيرجّع بس entry_file/storage_path كرابط عام جاهز.
-- ------------------------------------------------------------
alter table menu_templates enable row level security;
alter table template_versions enable row level security;
alter table restaurant_menu_templates enable row level security;

-- ------------------------------------------------------------
-- 5) القالب الافتراضي المدمج (Built-in) — يشتغل فورًا بدون رفع أي ZIP.
--    ملفاته الفعلية بـfrontend_pages/customer-menu/ (index.html) — مش مخزّنة بـSupabase Storage.
-- ------------------------------------------------------------
insert into menu_templates (name, slug, type, is_builtin)
values ('Default (Built-in)', 'default', 'customer-menu', true)
on conflict (slug) do nothing;

insert into template_versions (template_id, version, manifest, entry_file, storage_path, is_builtin, status, activated_at)
select
  mt.id,
  '1.0.0',
  jsonb_build_object(
    'name', 'Default (Built-in)',
    'slug', 'default',
    'version', '1.0.0',
    'type', 'customer-menu',
    'entry', 'index.html',
    'supports', jsonb_build_array('branding', 'categories', 'products', 'cart', 'orders', 'order-status')
  ),
  'index.html',
  null,
  true,
  'active',
  now()
from menu_templates mt
where mt.slug = 'default'
on conflict (template_id, version) do nothing;

-- ------------------------------------------------------------
-- 6) Backfill اختياري وآمن: أي مطعم موجود من قبل Phase 2 وما إله تعيين حالي،
--    منربطه صراحة بالقالب الافتراضي (بدل ما نعتمد بس على fallback بمنطق الـAPI).
--    idempotent — ما بيلمس مطعم عنده تعيين حالي أصلًا.
-- ------------------------------------------------------------
insert into restaurant_menu_templates (restaurant_id, template_version_id, is_current)
select r.id, tv.id, true
from restaurants r
cross join (
  select tv.id
  from template_versions tv
  join menu_templates mt on mt.id = tv.template_id
  where mt.slug = 'default' and tv.version = '1.0.0'
) tv
where not exists (
  select 1 from restaurant_menu_templates x
  where x.restaurant_id = r.id and x.is_current = true
);
