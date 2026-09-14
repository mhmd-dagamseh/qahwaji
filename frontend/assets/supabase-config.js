/**
 * supabase-config.js — إعدادات الاتصال العامة بمشروع Supabase.
 *
 * ملف واحد مشترك بين كل صفحات الـFrontend (admin, restaurant-admin, cashier, menu)
 * بدل ما كل صفحة تكرر PROD_API_BASE الخاص فيها متل بالمعمارية القديمة (Node/Vercel).
 *
 * مهم — هذا الملف عام ويُنشر مع بقية الـFrontend على GitHub Pages بلا أي مشكلة:
 *   - SUPABASE_URL: عنوان مشروعك، مو سر.
 *   - SUPABASE_ANON_KEY: مفتاح "anon" العام (publishable) — مصمم أصلًا ليكون مكشوفًا
 *     بالمتصفح؛ الحماية الحقيقية دائمًا عبر RLS بقاعدة البيانات (راجع
 *     phase3-supabase-native.sql و phase4-frontend-migration.sql)، وليس عبر إخفاء
 *     هذا المفتاح.
 *
 * ممنوع مطلقًا أن يوضع بهذا الملف (أو بأي ملف Frontend آخر):
 *   - service_role key
 *   - كلمة مرور قاعدة البيانات
 *   - أي JWT secret
 * هذه الثلاثة تعيش فقط داخل متغيرات بيئة Supabase Edge Functions
 * (راجع supabase/functions/*)، ولا تصل إطلاقًا للمتصفح.
 *
 * عدّل القيمتين التاليتين بعد إنشاء مشروعك على Supabase:
 * Project Settings → API → Project URL / anon public key.
 */
window.SUPABASE_URL = "https://YOUR-PROJECT.supabase.co";
window.SUPABASE_ANON_KEY = "YOUR-ANON-KEY";
