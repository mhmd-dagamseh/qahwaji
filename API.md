# API.md — مرجع الـ API

> **⚠️ تاريخي — يصف معمارية Node/Express/Vercel القديمة، لم تعد قائمة.**
> المرجع الحالي والدقيق: [`MIGRATION-SUMMARY.md`](MIGRATION-SUMMARY.md) بجذر المشروع.


Base URL (إنتاج): `https://YOUR-BACKEND.vercel.app`
Base URL (محلي): `http://localhost:4000`

كل هذه المسارات مأخوذة حرفيًا من `backend/src/routes/*.js` بعد الفحص — لا افتراضات.

المصادقة: `Authorization: Bearer <token>` (JWT صادر من `/auth/*`).

## Auth (`/auth`)
| Method | Path | Auth | ملاحظات |
|---|---|---|---|
| POST | `/auth/super-admin/login` | عام (rate-limited) | يرجع JWT بنوع `super_admin` |
| POST | `/auth/restaurant-admin/login` | عام (rate-limited) | يرفض 403 لو المطعم `suspended`/`cancelled`؛ يرجع JWT بنوع `restaurant_admin` + `restaurantId` + `role` (owner/cashier) + `supabaseToken` |

## Plans (`/plans`)
| Method | Path | Auth |
|---|---|---|
| GET | `/plans` | عام |
| POST | `/plans` | super_admin |
| PATCH | `/plans/:id` | super_admin |

## Restaurants (`/restaurants`) — سوبر أدمن فقط
| Method | Path |
|---|---|
| GET | `/restaurants` |
| POST | `/restaurants` |
| PATCH | `/restaurants/:id/status` |
| POST | `/restaurants/:id/subscriptions` (تغيير الباقة) |

## Restaurants — أدمن المطعم (owner/cashier) أو سوبر أدمن، مقيّد بـ`restaurantId` الخاص بهم
| Method | Path | Role المطلوب |
|---|---|---|
| GET | `/restaurants/:id` | owner أو cashier |
| GET | `/restaurants/:id/tables` | owner أو cashier |
| GET | `/restaurants/:id/products` | owner أو cashier |
| GET | `/restaurants/:id/orders/stats` | owner أو cashier |
| GET | `/restaurants/:id/orders/top-products` | owner أو cashier |
| PATCH | `/restaurants/:id/branding` | **owner فقط** |
| POST | `/restaurants/:id/tables` | **owner فقط** |
| POST | `/restaurants/:id/tables/bulk` | **owner فقط** (حد أقصى 300) |
| DELETE | `/restaurants/:id/tables/:tableId` | **owner فقط** |
| POST | `/restaurants/:id/products` | **owner فقط** |
| PATCH | `/restaurants/:id/products/:productId` | **owner فقط** |
| DELETE | `/restaurants/:id/products/:productId` | **owner فقط** |
| GET | `/restaurants/:id/menu-template` | owner أو cashier |
| PUT | `/restaurants/:id/menu-template` (اختيار/تفعيل نسخة قالب) | **owner فقط** |
| PATCH | `/restaurants/:id/menu-template/settings` | **owner فقط** |
| POST | `/restaurants/:id/branding/logo` (multipart, حقل `image`, حد 5MB) | **owner فقط** |
| POST | `/restaurants/:id/products/:productId/image` (multipart, حقل `image`, حد 5MB) | **owner فقط** |

## Templates (`/templates`)
| Method | Path | Auth |
|---|---|---|
| GET | `/templates` | أي أدمن مسجّل دخول (المحتوى المرتجع يختلف حسب الدور داخل الـcontroller) |
| POST | `/templates` (multipart, حقل `zip`) | **super_admin فقط** |
| POST | `/templates/:templateId/versions/:versionId/activate` | **super_admin فقط** |
| POST | `/templates/:templateId/versions/:versionId/deactivate` | **super_admin فقط** |

## Public / NFC Flow (`/api/public`) — بلا مصادقة
| Method | Path | الوظيفة |
|---|---|---|
| GET | `/api/public/demo/bootstrap` | معاينة تجريبية بلا DB (بند demo) |
| GET | `/api/public/restaurants/:slug` | حل بيانات المطعم من الـslug |
| GET | `/api/public/restaurants/:slug/menu` | قائمة المنتجات/الفئات |
| GET | `/api/public/restaurants/:slug/tables/:token` | التحقق من طاولة/رمز NFC |
| GET | `/api/public/restaurants/:slug/tables/:token/bootstrap` | كل بيانات إقلاع صفحة المنيو دفعة واحدة (مطعم + قالب + منتجات) |
| POST | `/api/public/restaurants/:slug/tables/:token/orders` (rate-limited) | إنشاء طلب — الأسعار تُعاد بناؤها من `products` بالسيرفر، ليست من body الطلب |
| GET | `/api/public/orders/:id` | حالة الطلب — يتطلب رأس `x-order-token` مطابق للـ`access_token` الصادر عند الإنشاء |

## Misc
| Method | Path | ملاحظات |
|---|---|---|
| GET | `/health` | `{ ok: true }` — استخدمه للتحقق بعد كل نشر |
| GET | `/api/public/sdk/*` | ملفات SDK ثابتة (`src/public/menu-sdk.js`) — CORP مفتوح عمدًا ليعمل من أي origin (القوالب المستضافة على Supabase Storage) |

## أخطاء
كل الأخطاء تمر عبر `middleware/errorHandler.js` وترجع شكلًا موحّدًا `{ error: { message, code? } }` مع HTTP status code مناسب (400 validation, 401 auth, 403 authorization, 404, 429 rate-limit, 500).
