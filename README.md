# Qahwaji — NFC Restaurant SaaS

منصة طلبات مطاعم عبر NFC: سوبر أدمن يدير مطاعم/باقات، أدمن مطعم يدير منتجات/طاولات/فروع، الزبون يمسح NFC على طاولته فيفتح المنيو ويطلب، الكاشير يستقبل الطلب لحظيًا.

## 🚀 المعمارية الحالية: GitHub Pages → Supabase (بلا أي Node backend)

هذا المستودع مرّ بأربع مراحل تطوير. **المرحلتان 1-2 (Express/Node/Vercel) انتهت
صلاحيتهما بالكامل** بعد المرحلتين 3-4 اللي حوّلتا المشروع كليًا إلى معمارية
Frontend-only + Supabase. المرجع الوحيد المحدَّث والدقيق لحالة المشروع الآن هو:

# 👉 [`MIGRATION-SUMMARY.md`](MIGRATION-SUMMARY.md)

يشرح: خريطة كل مسار Express قديم → بديله الجديد (RLS مباشر / RPC / Edge Function)،
تعليمات الإعداد والنشر الكاملة، القيود المعروفة، وما تبقّى كعمل مستقبلي.

### سجل تاريخي (Phase 1-2، Express — لم يعد قائمًا)
- **Phase 1** — بنية النشر (فصل `app.js` عن `server.js` لتوافق Vercel serverless).
- **Phase 2** — محرك القوالب، رفع الصور، Hardening v1.
- التفاصيل (تاريخية فقط): [`backend/PHASE-1-REPORT.md`](backend/PHASE-1-REPORT.md), [`backend/PHASE-2-REPORT.md`](backend/PHASE-2-REPORT.md), [`backend/CHANGES.md`](backend/CHANGES.md)
- `ARCHITECTURE.md`, `DEPLOYMENT.md`, `API.md`, `FINAL-REPORT.md`, `FINAL-SETUP-GUIDE.md`
  بجذر المشروع تصف **المعمارية القديمة (Node/Vercel)** ولم تعد مُحدَّثة — أُبقيت كسجل
  تاريخي فقط، تجاهلها لأي إعداد فعلي.

### Phase 3-4 (الحالية) — Supabase مباشرة
- **Phase 3** — تحليل + Supabase Database كاملة (schema/RLS/RPC). التفاصيل: [`SUPABASE-MIGRATION-ANALYSIS.md`](SUPABASE-MIGRATION-ANALYSIS.md)
- **Phase 4** (هذا التسليم) — نقل الـFrontend فعليًا لاستخدام Supabase مباشرة، وحذف الـNode backend بالكامل. التفاصيل والنتائج الفعلية: [`MIGRATION-SUMMARY.md`](MIGRATION-SUMMARY.md)

## البنية الحالية

```
qahwaji-saas/
├── backend/
│   ├── db/                          ملفات SQL (schema, RLS, RPC) — شغّلها بالترتيب على Supabase
│   └── scripts/                     سكربتات تشغيل يدوية (إنشاء سوبر أدمن، ترحيل حسابات قديمة)
├── supabase/functions/              Edge Functions (onboard-restaurant, upload-template)
├── frontend/                        صفحات ثابتة (admin, restaurant-admin, cashier, menu) — تُنشر على GitHub Pages
│   └── assets/                      supabase-config.js + menu-sdk.js (مشتركة بين كل الصفحات)
├── MIGRATION-SUMMARY.md             👈 المرجع الحالي — اقرأه أولًا
├── TEMPLATE-SDK.md                  عقد MenuSDK المحدَّث + دورة حياة القوالب
└── (ملفات .md أخرى بالجذر)          تاريخية، تصف معمارية Node القديمة
```

## البدء السريع

1. اقرأ [`MIGRATION-SUMMARY.md`](MIGRATION-SUMMARY.md) — يشرح كل خطوات الإعداد من الصفر.
2. أو مختصرًا: [`backend/README.md`](backend/README.md) لإعداد قاعدة البيانات + Edge Functions + أول سوبر أدمن.
3. لفهم كيف يُبنى ويُنصَّب قالب منيو جديد (محدّث): [`TEMPLATE-SDK.md`](TEMPLATE-SDK.md)
