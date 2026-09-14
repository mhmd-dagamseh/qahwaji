/**
 * MenuSDK — العقد الموحّد بين "منصّة" (Platform) و"قالب" (Template).
 *
 * هذا الملف يحل محل backend/src/public/menu-sdk.js القديم (اللي كان يُخدَّم من
 * الـNode backend عبر GET /api/public/sdk/menu-sdk.js). بعد إلغاء الـNode backend
 * بالكامل، صار هذا الملف أصل ثابت (static asset) يُخدَّم من نفس مكان الـFrontend
 * (GitHub Pages)، ويتصل مباشرة بـSupabase (PostgREST) بدل خادم Node.
 *
 * === مهم جدًا لمؤلفي القوالب ===
 * الـ Public API الخارجي (كل الدوال تحت `global.MenuSDK`) **لم يتغيّر إطلاقًا** —
 * نفس الأسماء، نفس المعاملات، نفس شكل البيانات المُرجعة تمامًا (bootstrap بنفس
 * البنية: restaurant / table / template / menu.categories[].products[]). أي قالب
 * كان مبني فوق النسخة القديمة يستمر يشتغل بلا أي تعديل بمنطقه، طالما بس حدّث سطر
 * تحميل هذا الملف + استدعاء init() (راجع القسم التالي).
 *
 * الفرق الوحيد المطلوب من مؤلف القالب: طريقة التهيئة (init) تغيّرت من
 * `{ apiBase }` (عنوان خادم Node) إلى `{ supabaseUrl, supabaseAnonKey }` (بيانات
 * اتصال Supabase العامة). لو ما مررتهم صراحة، الملف بيقرأهم تلقائيًا من
 * `window.SUPABASE_URL` / `window.SUPABASE_ANON_KEY` — يعني لو القالب حمّل
 * assets/supabase-config.js قبل هذا الملف، ما يحتاج يمرر شي إطلاقًا:
 *
 *   <script src=".../assets/supabase-config.js"></script>
 *   <script src=".../assets/menu-sdk.js"></script>
 *   <script>
 *     MenuSDK.init({ demo: false }); // اختياري تمامًا لو الاثنين أعلاه موجودين
 *     const bootstrap = await MenuSDK.getBootstrap();
 *   </script>
 *
 * أمان (بلا أي تغيير عن الفلسفة الأصلية): هذا الملف ما بيلمس أبدًا service_role key
 * ولا أي سر — فقط anon key (عام أصلًا، محمي بـRLS) + slug/token من الرابط + access_token
 * خاص بكل طلب. أقصى ضرر ممكن من قالب خبيث هو استهلاك REST العام نفسه، المحكوم أصلًا
 * بصلاحيات RLS ضيّقة جدًا (لا يمكنه قراءة/تعديل بيانات مطعم آخر ولا تغيير سعر —
 * راجع phase3-supabase-native.sql § RLS).
 */
(function (global) {
  "use strict";

  const state = {
    supabaseUrl: "",
    supabaseAnonKey: "",
    slug: null,
    token: null,
    demo: false,
    _bootstrapCache: null,
  };

  function detectFromLocation() {
    // 1) نمط المسار: /menu/{slug}/{token}
    const pathMatch = global.location.pathname.match(/\/menu\/([^/]+)\/([^/]+)\/?$/);
    if (pathMatch) {
      return { slug: decodeURIComponent(pathMatch[1]), token: decodeURIComponent(pathMatch[2]) };
    }
    // 2) fallback: query string ?r=slug&t=token
    const params = new URLSearchParams(global.location.search);
    const r = params.get("r");
    const t = params.get("t");
    if (r && t) return { slug: r, token: t };
    return { slug: null, token: null };
  }

  function init(opts) {
    opts = opts || {};
    const params = new URLSearchParams(global.location.search);
    const fromUrl = detectFromLocation();

    state.supabaseUrl = opts.supabaseUrl || state.supabaseUrl || global.SUPABASE_URL || "";
    state.supabaseAnonKey = opts.supabaseAnonKey || state.supabaseAnonKey || global.SUPABASE_ANON_KEY || "";
    state.slug = opts.slug || fromUrl.slug;
    state.token = opts.token || fromUrl.token;
    state.demo = Boolean(opts.demo || params.get("demo") === "1");
    state._bootstrapCache = null;
  }

  function requireResolvedTarget() {
    if (state.demo) return;
    if (!state.slug || !state.token) {
      const err = new Error("رابط المنيو غير صالح — لا يوجد رمز مطعم/طاولة بالرابط");
      err.code = "INVALID_MENU_URL";
      throw err;
    }
  }

  function requireSupabaseConfig() {
    if (!state.supabaseUrl || !state.supabaseAnonKey) {
      const err = new Error(
        "MenuSDK غير مهيّأ — مرّر supabaseUrl/supabaseAnonKey لـ MenuSDK.init(), أو حمّل assets/supabase-config.js قبل هذا الملف"
      );
      err.code = "UNKNOWN";
      throw err;
    }
  }

  // ---- نداء PostgREST عام (RPC أو REST عادي) — بلا أي مكتبة خارجية عن قصد ----
  async function postgrestFetch(path, options) {
    options = options || {};
    requireSupabaseConfig();
    const res = await fetch(state.supabaseUrl + path, {
      ...options,
      headers: {
        "Content-Type": "application/json",
        apikey: state.supabaseAnonKey,
        Authorization: "Bearer " + state.supabaseAnonKey,
        ...(options.headers || {}),
      },
    });
    let body = null;
    try {
      body = await res.json();
    } catch (e) {
      /* استجابة بلا body (نادر) */
    }
    if (!res.ok) {
      // شكل خطأ PostgREST: { message, details, hint, code } — مختلف عن شكل
      // { error: { code, message } } القديم، فمنبنيه هون بنفس الواجهة المتوقعة
      // من باقي هذا الملف (err.message / err.code).
      const message = (body && body.message) || `طلب فشل (${res.status})`;
      const err = new Error(message);
      err.status = res.status;
      err.details = body && body.details;
      throw err;
    }
    return body;
  }

  // ---- بيانات المعاينة التجريبية (demo) — بلا أي اتصال شبكة، مطابقة تمامًا لما
  //      كان GET /api/public/demo/bootstrap يرجعه بالـNode القديم ----
  function demoBootstrap() {
    return {
      demo: true,
      restaurant: {
        name: "مطعم تجريبي (Demo)",
        slug: "__demo__",
        logo_url: null,
        brand_colors: { primary: "#ff431a", secondary: "#1c1006", accent: "#ffc229" },
      },
      table: { table_number: 7 },
      template: { is_builtin: true, entry_url: null, settings: {}, supports: [] },
      menu: {
        categories: [
          {
            name: "مقبلات",
            products: [
              { id: -1, name: "حمص", price: 3.5, image_url: null },
              { id: -2, name: "متبل", price: 3.5, image_url: null },
            ],
          },
          {
            name: "أطباق رئيسية",
            products: [
              { id: -3, name: "مشاوي مشكلة", price: 12, image_url: null },
              { id: -4, name: "فتة", price: 8, image_url: null },
            ],
          },
        ],
      },
    };
  }

  // نفس groupProductsByCategory تمامًا من publicMenu.controller.js القديم —
  // بيحافظ على ترتيب أول ظهور لكل فئة (Map)، والمنتجات داخلها بترتيب الوصول
  // (rpc_menu_bootstrap الآن يرجعهم مرتبين أصلًا حسب category, name).
  function groupProductsByCategory(products) {
    const grouped = new Map();
    for (const p of products) {
      if (!grouped.has(p.category)) grouped.set(p.category, []);
      grouped.get(p.category).push({ id: p.id, name: p.name, price: p.price, image_url: p.image_url });
    }
    return [...grouped.entries()].map(([name, items]) => ({ name, products: items }));
  }

  // rpc_menu_bootstrap يرجّع template.storage_path/entry_file للقوالب المخصصة
  // (بدل entry_url جاهز) — لأن الدالة بقاعدة البيانات ما إلها داعي تعرف عنوان
  // الـFrontend. هون منبني الرابط الفعلي من SUPABASE_URL العام، بنفس منطق
  // storage.getPublicUrl("templates", ...) القديم بالباكند.
  function resolveTemplateEntryUrl(template) {
    if (!template || template.is_builtin || !template.storage_path || !template.entry_file) {
      return template;
    }
    return {
      ...template,
      entry_url: `${state.supabaseUrl}/storage/v1/object/public/templates/${template.storage_path}/${template.entry_file}`,
    };
  }

  // ---- نداء مجمّع واحد (مطعم + طاولة + قالب + منتجات) — الأساس لكل شي تاني ----
  async function getBootstrap({ forceRefresh } = {}) {
    if (state._bootstrapCache && !forceRefresh) return state._bootstrapCache;

    let data;
    if (state.demo) {
      data = demoBootstrap();
    } else {
      requireResolvedTarget();
      let raw;
      try {
        raw = await postgrestFetch("/rest/v1/rpc/rpc_menu_bootstrap", {
          method: "POST",
          body: JSON.stringify({ p_slug: state.slug, p_card_token: state.token }),
        });
      } catch (err) {
        // rpc_menu_bootstrap يرمي أكواد قصيرة ثابتة (راجع phase4-frontend-migration.sql)
        // بدل رسائل نصية عربية، تحديدًا عشان نقدر نميّز الحالات هون ونطابق نفس
        // رسائل i18n العربي/الإنجليزي الموجودة أصلًا بصفحة المنيو، بلا أي تغيير فيها.
        const KNOWN_CODES = ["RESTAURANT_NOT_FOUND", "RESTAURANT_INACTIVE", "TABLE_NOT_FOUND", "TABLE_INACTIVE"];
        err.code = KNOWN_CODES.includes(err.message) ? err.message : "UNKNOWN";
        throw err;
      }

      data = {
        restaurant: raw.restaurant,
        table: raw.table,
        template: resolveTemplateEntryUrl(raw.template),
        menu: { categories: groupProductsByCategory(raw.products || []) },
      };
    }

    state._bootstrapCache = data;
    return data;
  }

  async function getRestaurant() {
    const data = await getBootstrap();
    return data.restaurant;
  }

  async function getBranding() {
    const data = await getBootstrap();
    return { logo_url: data.restaurant.logo_url, brand_colors: data.restaurant.brand_colors };
  }

  async function getCategories() {
    const data = await getBootstrap();
    return data.menu.categories.map((c) => c.name);
  }

  async function getProducts(categoryName) {
    const data = await getBootstrap();
    if (!categoryName) {
      return data.menu.categories.flatMap((c) => c.products.map((p) => ({ ...p, category: c.name })));
    }
    const cat = data.menu.categories.find((c) => c.name === categoryName);
    return cat ? cat.products : [];
  }

  async function getTable() {
    const data = await getBootstrap();
    return data.table;
  }

  async function getTemplateSettings() {
    const data = await getBootstrap();
    return data.template?.settings || {};
  }

  // ---- الطلب ----
  // items: [{ product_id, qty }] — بلا سعر/اسم إطلاقًا، rpc_create_order هو من يحسب
  // كل شي (يستدعي trg_validate_order اللي يعيد حساب items/total من جدول products
  // الفعلي وقت الإدراج، بغض النظر عمّا أرسله المتصفح).
  async function createOrder(items) {
    if (state.demo) {
      // Preview فقط — ما بيلمس أي production state إطلاقًا
      return {
        id: "demo-" + Date.now(),
        status: "pending",
        items,
        total: null,
        access_token: "demo-token",
        created_at: new Date().toISOString(),
        _demo: true,
      };
    }
    requireResolvedTarget();
    return postgrestFetch("/rest/v1/rpc/rpc_create_order", {
      method: "POST",
      body: JSON.stringify({ p_slug: state.slug, p_card_token: state.token, p_items: items }),
    });
  }

  async function getOrderStatus(orderId, accessToken) {
    if (state.demo || String(orderId).startsWith("demo-")) {
      // محاكاة تقدّم بسيطة بالوضع التجريبي بس (pending -> confirmed -> done تلقائيًا مع الوقت)
      const createdMs = Number(String(orderId).replace("demo-", "")) || Date.now();
      const elapsed = Date.now() - createdMs;
      const status = elapsed > 12000 ? "done" : elapsed > 5000 ? "confirmed" : "pending";
      return { id: orderId, status, _demo: true };
    }

    // قراءة مباشرة بـREST (بدون RPC) بهيدر x-order-token مخصص — هذا بالضبط ما
    // تعتمد عليه RLS policy "read order by token or staff" بـphase3-supabase-native.sql
    // (current_setting('request.headers')). لا Realtime هون بتصميم — القنوات
    // اللحظية ما بتحمل custom headers متل REST، فتتبع حالة الطلب من طرف الزبون
    // نفسه يبقى بـpolling (نفس فلسفة الـNode الأصلي بالضبط).
    const rows = await postgrestFetch(
      `/rest/v1/orders?id=eq.${encodeURIComponent(orderId)}&select=id,status,items,total,created_at,confirmed_at,ready_at`,
      { method: "GET", headers: { "x-order-token": accessToken } }
    );
    if (!rows || !rows[0]) {
      throw new Error("تعذر العثور على الطلب — تحقق من الرابط");
    }
    return rows[0];
  }

  // مساعد جاهز للـpolling (كل 3-5 ثواني، بلا Supabase Realtime للزبون — راجع التعليق أعلاه)
  function pollOrderStatus(orderId, accessToken, onUpdate, intervalMs) {
    intervalMs = intervalMs || 4000;
    let stopped = false;
    let lastStatus = null;

    async function tick() {
      if (stopped) return;
      try {
        const order = await getOrderStatus(orderId, accessToken);
        if (order.status !== lastStatus) {
          lastStatus = order.status;
          onUpdate(order, null);
        }
        if (order.status === "done") {
          stopped = true;
          return;
        }
      } catch (err) {
        onUpdate(null, err);
      }
      if (!stopped) setTimeout(tick, intervalMs);
    }

    tick();
    return function stop() {
      stopped = true;
    };
  }

  global.MenuSDK = {
    init,
    getBootstrap,
    getRestaurant,
    getBranding,
    getCategories,
    getProducts,
    getTable,
    getTemplateSettings,
    createOrder,
    getOrderStatus,
    pollOrderStatus,
    // مكشوفة لأغراض debugging بالقوالب المخصصة، مش جزء رسمي من العقد
    _state: state,
  };
})(window);
