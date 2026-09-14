// supabase/functions/onboard-restaurant/index.ts
//
// بديل POST /restaurants (createRestaurant) بالـNode القديم.
//
// ليش Edge Function ومش RPC عادي؟ لأن إنشاء "أول أدمن" لمطعم جديد يعني إنشاء مستخدم
// Supabase Auth حقيقي (auth.users) — وهذا يتطلب Supabase Auth Admin API (service-role)،
// وهذا غير ممكن من دالة SQL عادية (raw SQL ما بيقدر ينده Admin API)، وممنوع تنفيذه من
// الـFrontend لأن ذلك يتطلب service_role key بالمتصفح (ممنوع صراحة بالبرومبت).
//
// التسلسل (موثّق أيضًا بتعليق rpc_create_restaurant بملف phase3-supabase-native.sql):
//   1) rpc_create_restaurant  — عبر عميل يحمل جلسة المستخدم المتصل (super admin) —
//      restaurant + subscription بعملية DB واحدة ذرّية.
//   2) auth.admin.createUser  — عبر عميل service-role (الوحيد القادر على هذا).
//   3) rpc_attach_restaurant_admin — عبر نفس عميل المستخدم بالخطوة 1، لربط
//      user_id الجديد كـ owner لهذا المطعم.
//
// لو فشلت الخطوة 2 أو 3 بعد نجاح الخطوة 1: المطعم موجود بلا أدمن (نفس الحالة الموثّقة
// بتعليق rpc_create_restaurant نفسه). هذه الدالة تحاول تنظيف الحالة (تحذف المستخدم لو
// انخلق ثم فشلت الخطوة 3، أو تحذف المطعم لو فشلت الخطوة 2) قبل ما ترجع خطأ للمتصل،
// حتى ما يضل "مطعم يتيم" بدون تدخل يدوي إلا في أسوأ الحالات (فشل الحذف نفسه).
//
// الأمان: service_role key موجود فقط بمتغيرات بيئة هذه الدالة على سيرفرات Supabase —
// لا يصل إطلاقًا للمتصفح. الـFrontend يستدعي هذه الدالة بجلسته العادية (anon + JWT
// المستخدم)، ونحن هون نتحقق إنه فعلاً super_admin قبل أي عملية حساسة.

import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, handleOptions, jsonResponse, errorResponse } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SLUG_RE = /^[a-z0-9-]+$/;

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse("Method not allowed", 405);
  }

  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader) {
    return errorResponse("مطلوب تسجيل الدخول", 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return errorResponse("جسم الطلب غير صالح (JSON متوقع)", 400);
  }

  const name = String(body.name || "").trim();
  const slug = String(body.slug || "").trim().toLowerCase();
  const plan_id = Number(body.plan_id);
  const owner_email = String(body.owner_email || "").trim().toLowerCase();
  const owner_password = String(body.owner_password || "");
  const theme_template = body.theme_template ? String(body.theme_template) : "default";

  // ---- نفس تحققات createRestaurantSchema (zod) بالـNode القديم بالضبط ----
  if (!name || name.length > 200) {
    return errorResponse("اسم المطعم مطلوب (حتى 200 حرف)", 400);
  }
  if (!SLUG_RE.test(slug) || slug.length > 100) {
    return errorResponse("الرابط المختصر (slug) لازم يكون أحرف صغيرة وأرقام وشرطات فقط", 400);
  }
  if (!Number.isInteger(plan_id) || plan_id <= 0) {
    return errorResponse("الباقة (plan_id) مطلوبة", 400);
  }
  if (!isValidEmail(owner_email) || owner_email.length > 255) {
    return errorResponse("بريد صاحب المطعم غير صالح", 400);
  }
  if (owner_password.length < 8 || owner_password.length > 200) {
    return errorResponse("كلمة مرور صاحب المطعم يجب أن تكون 8 أحرف على الأقل", 400);
  }

  // عميل بجلسة المستخدم المتصل (يحافظ على auth.uid() = السوبر أدمن نفسه داخل RLS/RPC)
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });

  // عميل service-role — فقط للعملية الوحيدة التي تحتاجه فعليًا: إنشاء مستخدم Auth
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // خطوة 0: تحقق صريح إن المتصل فعلاً super_admin قبل أي عملية — رسالة خطأ واضحة
  // بدل ما نعتمد فقط على رفض rpc_create_restaurant الداخلي.
  const { data: isSuperAdmin, error: roleError } = await userClient.rpc("is_super_admin");
  if (roleError) {
    return errorResponse("تعذر التحقق من الصلاحية: " + roleError.message, 401);
  }
  if (!isSuperAdmin) {
    return errorResponse("هذا الإجراء مخصص لإدارة الشركة فقط", 403);
  }

  // ---- خطوة 1: المطعم + الاشتراك (RPC ذرّية DB-only، موجودة أصلًا من phase3) ----
  const { data: restaurant, error: restaurantError } = await userClient.rpc(
    "rpc_create_restaurant",
    {
      p_name: name,
      p_slug: slug,
      p_plan_id: plan_id,
      p_theme_template: theme_template,
    }
  );
  if (restaurantError) {
    return errorResponse(restaurantError.message, 409);
  }

  // ---- خطوة 2: إنشاء مستخدم Supabase Auth فعلي لصاحب المطعم ----
  const { data: authUser, error: authError } = await adminClient.auth.admin.createUser({
    email: owner_email,
    password: owner_password,
    email_confirm: true,
    user_metadata: { role: "restaurant_owner", restaurant_id: restaurant.id },
  });

  if (authError || !authUser?.user) {
    // تنظيف: احذف المطعم اليتيم بما إنه ما انربط فيه أي أدمن أصلًا
    await userClient.rpc("rpc_update_restaurant_status", {
      p_restaurant_id: restaurant.id,
      p_status: "cancelled",
    }).catch(() => {});
    return errorResponse(
      "تعذر إنشاء حساب صاحب المطعم: " + (authError?.message || "خطأ غير معروف") +
        " — تم تعليق المطعم الجديد كـ(ملغي)، يمكن حذفه يدويًا أو إعادة المحاولة ببريد آخر.",
      409
    );
  }

  // ---- خطوة 3: ربط المستخدم كـowner لهذا المطعم ----
  const { data: admin, error: attachError } = await userClient.rpc(
    "rpc_attach_restaurant_admin",
    {
      p_restaurant_id: restaurant.id,
      p_user_id: authUser.user.id,
      p_email: owner_email,
      p_role: "owner",
    }
  );

  if (attachError) {
    // تنظيف: احذف مستخدم الـAuth اليتيم وعلّق المطعم، بدل ما نسيب حساب دخول بلا صلاحيات
    await adminClient.auth.admin.deleteUser(authUser.user.id).catch(() => {});
    await userClient.rpc("rpc_update_restaurant_status", {
      p_restaurant_id: restaurant.id,
      p_status: "cancelled",
    }).catch(() => {});
    return errorResponse(
      "تعذر ربط حساب صاحب المطعم بالمطعم: " + attachError.message +
        " — تم التراجع عن إنشاء المستخدم وتعليق المطعم الجديد.",
      409
    );
  }

  return jsonResponse({ restaurant, admin }, 201);
});
