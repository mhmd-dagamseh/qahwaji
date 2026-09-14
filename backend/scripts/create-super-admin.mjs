#!/usr/bin/env node
/**
 * scripts/create-super-admin.mjs
 *
 * بديل backend/scripts/create-super-admin.js القديم (اللي كان يعمل bcrypt.hash()
 * ويدرج مباشرة بجدول super_admins عبر اتصال pg خام).
 *
 * ليش تغيّر الأسلوب بالكامل: المصادقة صارت Supabase Auth حصرًا، فـ"إنشاء سوبر أدمن"
 * يعني الآن خطوتين لازم تصيرا معًا:
 *   1) مستخدم Supabase Auth حقيقي (auth.users) — عبر Admin API (service-role فقط،
 *      لهيك هذا سكربت operator يشتغل محليًا، وممنوع نشره أو رفعه لأي مكان عام).
 *   2) سطر بجدول super_admins مربوط بـuser_id هذا المستخدم (بدون هذا الربط، تسجيل
 *      الدخول ينجح بـSupabase Auth لكن لوحة السوبر أدمن ترفضه — راجع RLS
 *      "super admin reads own row" بملف phase3-supabase-native.sql).
 *
 * الاستخدام:
 *   SUPABASE_URL=https://xxxx.supabase.co \
 *   SUPABASE_SERVICE_ROLE_KEY=xxxx \
 *   node scripts/create-super-admin.mjs --email owner@example.com --password "Str0ngP@ss" --name "اسم المدير"
 *
 * ملاحظات أمان:
 *   - SUPABASE_SERVICE_ROLE_KEY لا يُستخدم إلا هون، محليًا، ولا يوضع أبدًا بأي ملف
 *     Frontend ولا Edge Function عام. لا ترفع هذا المفتاح لأي مستودع Git.
 *   - لو المستخدم بـauth.users موجود أصلًا بنفس البريد، السكربت بيكتفي بربطه
 *     (upsert) بدل ما يفشل.
 */
import { createClient } from "@supabase/supabase-js";

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]?.replace(/^--/, "");
    out[key] = argv[i + 1];
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const email = (args.email || "").trim().toLowerCase();
  const password = args.password || "";
  const fullName = args.name || null;

  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    console.error("لازم تعرّف SUPABASE_URL و SUPABASE_SERVICE_ROLE_KEY كمتغيرات بيئة قبل التشغيل.");
    process.exit(1);
  }
  if (!email || !password) {
    console.error('الاستخدام: node scripts/create-super-admin.mjs --email you@example.com --password "..." [--name "الاسم"]');
    process.exit(1);
  }
  if (password.length < 8) {
    console.error("كلمة المرور يجب أن تكون 8 أحرف على الأقل.");
    process.exit(1);
  }

  const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // 1) مستخدم Supabase Auth — لو موجود أصلًا بنفس البريد، نجيب id بتاعه بدل الفشل.
  let userId;
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { role: "super_admin" },
  });

  if (createError) {
    const alreadyExists = /already registered|already exists/i.test(createError.message || "");
    if (!alreadyExists) {
      console.error("فشل إنشاء مستخدم Auth:", createError.message);
      process.exit(1);
    }
    console.log("المستخدم موجود مسبقًا بـSupabase Auth — جاري البحث عنه بدل إنشائه من جديد...");
    // Admin API ما فيها "get by email" مباشر بكل نسخ supabase-js، فنمشي بالصفحات.
    let page = 1;
    while (!userId) {
      const { data: list, error: listError } = await admin.auth.admin.listUsers({ page, perPage: 200 });
      if (listError) {
        console.error("فشل البحث عن المستخدم:", listError.message);
        process.exit(1);
      }
      const found = list.users.find((u) => u.email?.toLowerCase() === email);
      if (found) userId = found.id;
      if (list.users.length < 200) break;
      page += 1;
    }
    if (!userId) {
      console.error("تعذر العثور على المستخدم رغم رسالة \"موجود مسبقًا\" — راجع لوحة Supabase يدويًا.");
      process.exit(1);
    }
  } else {
    userId = created.user.id;
    console.log("تم إنشاء مستخدم Auth جديد:", userId);
  }

  // 2) سطر super_admins مربوط بـuser_id — upsert على email حتى تقدر تعيد تشغيل
  //    السكربت بأمان (idempotent) لو انقطع بمنتصف الطريق أول مرة.
  const { data: row, error: upsertError } = await admin
    .from("super_admins")
    .upsert(
      { email, full_name: fullName, user_id: userId, password_hash: "managed-by-supabase-auth" },
      { onConflict: "email" }
    )
    .select()
    .single();

  if (upsertError) {
    console.error("فشل ربط السطر بجدول super_admins:", upsertError.message);
    process.exit(1);
  }

  console.log("\n✅ تم إنشاء/تحديث السوبر أدمن بنجاح:");
  console.log("   email:", row.email);
  console.log("   super_admins.id:", row.id);
  console.log("   auth.users.id (user_id):", row.user_id);
  console.log("\nيقدر يسجّل دخول الآن من frontend/admin/index.html بنفس البريد وكلمة المرور.");
}

main().catch((err) => {
  console.error("خطأ غير متوقع:", err);
  process.exit(1);
});
