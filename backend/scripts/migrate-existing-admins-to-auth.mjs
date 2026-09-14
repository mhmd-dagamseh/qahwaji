#!/usr/bin/env node
/**
 * scripts/migrate-existing-admins-to-auth.mjs
 *
 * سكربت تشغيل مرة واحدة (one-time) وقت الانتقال الفعلي للإنتاج، لأي بيانات كانت
 * موجودة مسبقًا بالمعمارية القديمة (bcrypt + JWT مخصص) قبل هذه الهجرة.
 *
 * === قيد حقيقي لازم يُقال بصراحة ===
 * bcrypt hash لا يمكن عكسه لكلمة مرور أصلية بأي شكل — هذا مو تقصير بهذا السكربت،
 * هذا بالتحديد الغرض من bcrypt. يعني: **لا يوجد أي طريقة تقنية** لنقل كلمات مرور
 * المستخدمين الحاليين حرفيًا لـSupabase Auth. أي أداة تدّعي عكس ذلك تكذب.
 *
 * الحل العملي الوحيد (وهو المتبع هون، ومطابق لممارسات الصناعة القياسية بهاي الحالة):
 *   1) ننشئ مستخدم Supabase Auth جديد لكل admin/super_admin بكلمة مرور عشوائية
 *      مؤقتة (ما حد بيعرفها، ولا حتى هذا السكربت بعد ما يخلص).
 *   2) نربطه فورًا بـuser_id الصحيح بجدول restaurant_admins/super_admins.
 *   3) نولّد رابط "تعيين كلمة مرور" (recovery link) لكل حساب ونطبعه — لازم يُرسل
 *      يدويًا (إيميل/واتساب/إلخ) لكل مستخدم قبل أول تسجيل دخول له بالنظام الجديد.
 *
 * الاستخدام:
 *   SUPABASE_URL=https://xxxx.supabase.co \
 *   SUPABASE_SERVICE_ROLE_KEY=xxxx \
 *   node scripts/migrate-existing-admins-to-auth.mjs [--dry-run]
 *
 * آمن للتشغيل أكثر من مرة (idempotent): أي سطر عنده user_id أصلًا يتم تخطيه.
 */
import { createClient } from "@supabase/supabase-js";
import crypto from "node:crypto";

const DRY_RUN = process.argv.includes("--dry-run");

function randomTempPassword() {
  return crypto.randomBytes(24).toString("base64url"); // 32 حرف تقريبًا، لا أحد يحتاج يحفظه
}

async function migrateTable(admin, tableName, roleLabel) {
  const { data: rows, error } = await admin.from(tableName).select("id, email, full_name").is("user_id", null);
  if (error) {
    console.error(`فشل قراءة ${tableName}:`, error.message);
    process.exit(1);
  }

  if (rows.length === 0) {
    console.log(`[${tableName}] لا يوجد حسابات قديمة بحاجة ربط — كل شي محدّث أصلًا. ✅`);
    return [];
  }

  console.log(`[${tableName}] وجدت ${rows.length} حساب (${roleLabel}) بحاجة ربط بـSupabase Auth...`);
  const results = [];

  for (const row of rows) {
    const email = row.email?.trim().toLowerCase();
    if (!email) {
      console.warn(`  ⚠ سطر id=${row.id} بلا بريد إلكتروني — تخطّيته، راجعه يدويًا.`);
      continue;
    }

    if (DRY_RUN) {
      console.log(`  [DRY RUN] كان رح يُنشأ مستخدم Auth لـ ${email} ويُربط بـ${tableName}.id=${row.id}`);
      continue;
    }

    const tempPassword = randomTempPassword();
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password: tempPassword,
      email_confirm: true,
      user_metadata: { role: roleLabel, migrated_from: tableName },
    });

    let userId = created?.user?.id;
    if (createError) {
      if (!/already registered|already exists/i.test(createError.message || "")) {
        console.error(`  ✗ فشل إنشاء مستخدم لـ ${email}:`, createError.message);
        continue;
      }
      // موجود أصلًا (ربما ربطناه من جدول تاني بنفس البريد) — نجيبه بدل ما نفشل.
      const { data: list } = await admin.auth.admin.listUsers({ perPage: 200 });
      const found = list?.users.find((u) => u.email?.toLowerCase() === email);
      if (!found) {
        console.error(`  ✗ ${email} موجود بـAuth حسب الرسالة، لكن ما قدرت ألاقيه — راجعه يدويًا.`);
        continue;
      }
      userId = found.id;
    }

    const { error: updateError } = await admin.from(tableName).update({ user_id: userId }).eq("id", row.id);
    if (updateError) {
      console.error(`  ✗ فشل ربط ${email} بـ${tableName}.id=${row.id}:`, updateError.message);
      continue;
    }

    // رابط تعيين كلمة مرور — صالح لمدة محدودة حسب إعدادات مشروعك بـSupabase Auth.
    // أرسله يدويًا للمستخدم؛ لا تشاركه بأي قناة عامة.
    const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({
      type: "recovery",
      email,
    });

    results.push({
      email,
      table: tableName,
      id: row.id,
      user_id: userId,
      recovery_link: linkError ? `تعذر توليد الرابط: ${linkError.message}` : linkData.properties?.action_link,
    });
    console.log(`  ✓ ${email} → user_id=${userId}`);
  }

  return results;
}

async function main() {
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    console.error("لازم تعرّف SUPABASE_URL و SUPABASE_SERVICE_ROLE_KEY كمتغيرات بيئة قبل التشغيل.");
    process.exit(1);
  }

  const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  if (DRY_RUN) console.log("=== وضع المعاينة (--dry-run) — بلا أي تعديل فعلي ===\n");

  const superAdminResults = await migrateTable(admin, "super_admins", "super_admin");
  const restaurantAdminResults = await migrateTable(admin, "restaurant_admins", "restaurant_admin");
  const all = [...superAdminResults, ...restaurantAdminResults];

  if (all.length > 0) {
    console.log("\n=== روابط تعيين كلمة المرور — أرسلها يدويًا لكل مستخدم ===");
    for (const r of all) {
      console.log(`\n${r.email} (${r.table}#${r.id}):\n  ${r.recovery_link}`);
    }
    console.log(
      "\n⚠ هذه الروابط تعطي وصول كامل للحساب — أرسل كل رابط لصاحبه فقط عبر قناة موثوقة (بريده الشخصي)، ولا تخزّنها بأي مكان مشترك."
    );
  }

  console.log("\nانتهى.");
}

main().catch((err) => {
  console.error("خطأ غير متوقع:", err);
  process.exit(1);
});
