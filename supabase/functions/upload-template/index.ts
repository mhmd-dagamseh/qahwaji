// supabase/functions/upload-template/index.ts
//
// بديل POST /templates (uploadTemplateVersion) بالـNode القديم.
//
// ليش Edge Function ومش RPC عادي؟ لأن هذا يحتاج:
//   (أ) فك ضغط ZIP فعلي وفحص كل ملف بداخله (مسارات آمنة، امتدادات مسموحة، أحجام) —
//       منطق إجرائي (procedural) معقّد، مش شي معقول تنفيذه بلغة SQL/plpgsql.
//   (ب) كتابة عشرات الملفات الفعلية لـSupabase Storage — يحتاج صلاحية service-role
//       (bucket "templates" مقفول من anon/authenticated بالكامل حسب تصميم phase3،
//       الرفع فيه محصور بالباكند فقط — راجع TEMPLATE-SDK.md § "من يرفع/يقرأ").
// هذا بالضبط نفس منطق backend/src/utils/templatePathSafety.js +
// backend/src/utils/templateValidator.js + controllers/templates.controller.js
// (uploadTemplateVersion) بالـNode القديم، منقول حرفيًا لـDeno.
//
// الطلب: POST بجسم = بايتات ملف الـZIP الخام مباشرة (Content-Type: application/zip
// أو application/octet-stream) — بدون multipart، تبسيطًا (لا يوجد أي حقل نصي آخر
// مطلوب، كل شي بمانفيست القالب نفسه).

import { createClient } from "npm:@supabase/supabase-js@2";
import AdmZip from "npm:adm-zip@0.5.10";
import { z } from "npm:zod@3.23.8";
import { Buffer } from "node:buffer";
import { corsHeaders, handleOptions, jsonResponse, errorResponse } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ============================================================================
// منقول حرفيًا عن backend/src/utils/templatePathSafety.js — بلا أي تغيير منطقي.
// ============================================================================
function isSafeEntryPath(rawName: string): boolean {
  if (typeof rawName !== "string" || rawName.length === 0) return false;
  if (rawName.includes("\0")) return false;
  if (rawName.startsWith("/") || rawName.startsWith("\\")) return false;
  if (/^[a-zA-Z]:[\\/]/.test(rawName)) return false;

  const normalized = rawName.replace(/\\/g, "/");
  const segments = normalized.split("/");
  if (segments.some((seg) => seg === "..")) return false;

  return true;
}

const BLOCKED_EXACT_NAMES = new Set([
  ".env",
  ".env.local",
  ".env.production",
  ".env.development",
  "package.json",
  "package-lock.json",
  "yarn.lock",
  "pnpm-lock.yaml",
  "dockerfile",
  "docker-compose.yml",
  ".npmrc",
  ".gitignore",
]);

const BLOCKED_NAME_PATTERNS = [
  /(^|\/)\.env(\..*)?$/i,
  /(^|\/)\.git(\/|$)/i,
  /(^|\/)node_modules(\/|$)/i,
  /(^|\/)__macosx(\/|$)/i,
  /(^|\/)\.ds_store$/i,
  /id_rsa/i,
  /\.pem$/i,
  /\.key$/i,
  /\.p12$/i,
  /\.pfx$/i,
  /serviceaccount.*\.json$/i,
  /credentials.*\.json$/i,
];

function isBlockedName(normalizedPath: string): boolean {
  const base = normalizedPath.split("/").pop()!.toLowerCase();
  if (BLOCKED_EXACT_NAMES.has(base)) return true;
  return BLOCKED_NAME_PATTERNS.some((re) => re.test(normalizedPath));
}

const BLOCKED_EXTENSIONS = new Set([
  "sh", "bash", "bat", "cmd", "ps1", "exe", "dll", "so", "dylib", "jar",
  "php", "py", "rb", "pl", "cgi", "asp", "aspx", "jsp", "com", "msi", "apk", "scr",
]);

const ALLOWED_EXTENSIONS = new Set([
  "html", "htm", "css", "js", "mjs", "json",
  "png", "jpg", "jpeg", "gif", "svg", "webp", "ico",
  "woff", "woff2", "ttf", "otf",
  "txt", "md",
]);

function getExtension(name: string): string {
  const base = name.split("/").pop()!;
  const idx = base.lastIndexOf(".");
  if (idx === -1 || idx === base.length - 1) return "";
  return base.slice(idx + 1).toLowerCase();
}

function detectCommonRootPrefix(paths: string[]): string {
  if (paths.length === 0) return "";
  const first = paths[0].split("/");
  if (first.length < 2) return "";
  const candidate = first[0] + "/";
  const allShare = paths.every((p) => p.startsWith(candidate));
  return allShare ? candidate : "";
}

// ============================================================================
// منقول حرفيًا عن backend/src/utils/templateValidator.js
// ============================================================================
const LIMITS = {
  MAX_ZIP_SIZE_BYTES: 15 * 1024 * 1024,
  MAX_EXTRACTED_SIZE_BYTES: 40 * 1024 * 1024,
  MAX_FILE_COUNT: 500,
  MAX_INDIVIDUAL_FILE_SIZE_BYTES: 5 * 1024 * 1024,
};

const SUPPORTED_CAPABILITIES = ["branding", "categories", "products", "cart", "orders", "order-status"] as const;

const templateManifestSchema = z.object({
  name: z.string().min(1).max(200),
  slug: z.string().min(1).max(100).regex(/^[a-z0-9-]+$/, "slug: أحرف صغيرة وأرقام وشرطات فقط"),
  version: z.string().regex(/^\d+\.\d+\.\d+$/, "version: لازم يكون semver مثل 1.0.0"),
  type: z.literal("customer-menu"),
  entry: z.string().min(1).max(200),
  supports: z.array(z.enum(SUPPORTED_CAPABILITIES)).optional().default([]),
});

interface ValidatedFile {
  path: string;
  size: number;
  buffer: Uint8Array;
}

class TemplateValidationError extends Error {
  code: string;
  constructor(message: string, code: string) {
    super(message);
    this.code = code;
  }
}

function guessContentType(path: string): string {
  const ext = path.split(".").pop()!.toLowerCase();
  const map: Record<string, string> = {
    html: "text/html; charset=utf-8",
    htm: "text/html; charset=utf-8",
    css: "text/css; charset=utf-8",
    js: "application/javascript; charset=utf-8",
    mjs: "application/javascript; charset=utf-8",
    json: "application/json; charset=utf-8",
    png: "image/png",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    gif: "image/gif",
    svg: "image/svg+xml",
    webp: "image/webp",
    ico: "image/x-icon",
    woff: "font/woff",
    woff2: "font/woff2",
    ttf: "font/ttf",
    otf: "font/otf",
    txt: "text/plain; charset=utf-8",
    md: "text/markdown; charset=utf-8",
  };
  return map[ext] || "application/octet-stream";
}

function validateTemplateZipBuffer(bytes: Uint8Array) {
  if (!bytes || bytes.length === 0) {
    throw new TemplateValidationError("ملف ZIP فارغ أو غير صالح", "TEMPLATE_ZIP_EMPTY");
  }
  if (bytes.length > LIMITS.MAX_ZIP_SIZE_BYTES) {
    throw new TemplateValidationError(
      `حجم ملف ZIP (${Math.round(bytes.length / 1024 / 1024)}MB) أكبر من الحد المسموح (${LIMITS.MAX_ZIP_SIZE_BYTES / 1024 / 1024}MB)`,
      "TEMPLATE_ZIP_TOO_LARGE"
    );
  }

  let zip: AdmZip;
  try {
    zip = new AdmZip(Buffer.from(bytes));
  } catch {
    throw new TemplateValidationError("ملف ZIP تالف أو غير صالح", "TEMPLATE_ZIP_CORRUPT");
  }

  const rawEntries = zip.getEntries();
  if (rawEntries.length === 0) {
    throw new TemplateValidationError("ملف ZIP فارغ", "TEMPLATE_ZIP_EMPTY");
  }
  if (rawEntries.length > LIMITS.MAX_FILE_COUNT) {
    throw new TemplateValidationError(
      `عدد الملفات (${rawEntries.length}) أكبر من الحد المسموح (${LIMITS.MAX_FILE_COUNT})`,
      "TEMPLATE_TOO_MANY_FILES"
    );
  }

  const nonDirPaths = rawEntries.filter((e) => !e.isDirectory).map((e) => e.entryName.replace(/\\/g, "/"));
  const rootPrefix = detectCommonRootPrefix(nonDirPaths);

  let totalSize = 0;
  const files: ValidatedFile[] = [];

  for (const entry of rawEntries) {
    const original = entry.entryName.replace(/\\/g, "/");

    if (!isSafeEntryPath(original)) {
      throw new TemplateValidationError(`مسار غير آمن داخل القالب: ${original}`, "TEMPLATE_UNSAFE_PATH");
    }

    const effective = rootPrefix && original.startsWith(rootPrefix) ? original.slice(rootPrefix.length) : original;

    if (entry.isDirectory || effective === "") continue;

    if (isBlockedName(effective) || isBlockedName(original)) {
      throw new TemplateValidationError(`ملف غير مسموح به داخل القالب: ${effective}`, "TEMPLATE_BLOCKED_FILE");
    }

    const size = entry.header.size;
    if (size > LIMITS.MAX_INDIVIDUAL_FILE_SIZE_BYTES) {
      throw new TemplateValidationError(
        `الملف ${effective} أكبر من الحد المسموح لكل ملف (${LIMITS.MAX_INDIVIDUAL_FILE_SIZE_BYTES / 1024 / 1024}MB)`,
        "TEMPLATE_FILE_TOO_LARGE"
      );
    }

    const ext = getExtension(effective);
    if (BLOCKED_EXTENSIONS.has(ext)) {
      throw new TemplateValidationError(`نوع ملف غير مسموح به إطلاقًا: .${ext} (${effective})`, "TEMPLATE_BLOCKED_EXTENSION");
    }
    if (ext && !ALLOWED_EXTENSIONS.has(ext)) {
      throw new TemplateValidationError(`امتداد غير مدعوم: .${ext} (${effective})`, "TEMPLATE_UNSUPPORTED_EXTENSION");
    }

    totalSize += size;
    if (totalSize > LIMITS.MAX_EXTRACTED_SIZE_BYTES) {
      throw new TemplateValidationError(
        `الحجم الإجمالي بعد الفك أكبر من الحد المسموح (${LIMITS.MAX_EXTRACTED_SIZE_BYTES / 1024 / 1024}MB)`,
        "TEMPLATE_EXTRACTED_TOO_LARGE"
      );
    }

    files.push({ path: effective, size, buffer: entry.getData() });
  }

  const manifestFile = files.find((f) => f.path === "manifest.json");
  if (!manifestFile) {
    throw new TemplateValidationError("manifest.json غير موجود داخل جذر القالب", "TEMPLATE_MANIFEST_MISSING");
  }

  let manifestJson: unknown;
  try {
    manifestJson = JSON.parse(new TextDecoder("utf-8").decode(manifestFile.buffer));
  } catch {
    throw new TemplateValidationError("manifest.json ليس JSON صالح", "TEMPLATE_MANIFEST_INVALID_JSON");
  }

  const parsed = templateManifestSchema.safeParse(manifestJson);
  if (!parsed.success) {
    const msg = parsed.error.issues.map((i) => `${i.path.join(".") || "manifest"}: ${i.message}`).join(" | ");
    throw new TemplateValidationError(`manifest.json غير صالح: ${msg}`, "TEMPLATE_MANIFEST_SCHEMA_INVALID");
  }
  const manifest = parsed.data;

  const hasEntryFile = files.some((f) => f.path === manifest.entry);
  if (!hasEntryFile) {
    throw new TemplateValidationError(
      `ملف الدخول (entry) المحدد بالـmanifest غير موجود فعليًا داخل القالب: ${manifest.entry}`,
      "TEMPLATE_ENTRY_MISSING"
    );
  }

  return { manifest, files, fileCount: files.length, totalSizeBytes: totalSize };
}

// ============================================================================
// معالج الطلب
// ============================================================================
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

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });

  const { data: isSuperAdmin, error: roleError } = await userClient.rpc("is_super_admin");
  if (roleError) {
    return errorResponse("تعذر التحقق من الصلاحية: " + roleError.message, 401);
  }
  if (!isSuperAdmin) {
    return errorResponse("هذا الإجراء مخصص لإدارة الشركة فقط", 403);
  }

  // هوية المتصل (super_admins.id) لعمود installed_by_super_admin_id
  const { data: userInfo } = await userClient.auth.getUser();
  const { data: superAdminRow } = await userClient
    .from("super_admins")
    .select("id")
    .eq("user_id", userInfo?.user?.id)
    .maybeSingle();

  const bodyBytes = new Uint8Array(await req.arrayBuffer());

  let validated: ReturnType<typeof validateTemplateZipBuffer>;
  try {
    validated = validateTemplateZipBuffer(bodyBytes);
  } catch (err) {
    if (err instanceof TemplateValidationError) {
      return errorResponse(err.message, 400, err.code);
    }
    return errorResponse("فشل فحص ملف القالب: " + (err as Error).message, 400);
  }

  const { manifest, files, fileCount, totalSizeBytes } = validated;

  // service-role فقط من هون تحت — للرفع الفعلي على Storage والكتابة بجداول القوالب
  // (bucket "templates" وجدولا menu_templates/template_versions مقفولين عن authenticated
  // تمامًا حسب تصميم phase3، بالضبط متل ما كان الوصول محصور بالباكند فقط قبل الهجرة).
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const { data: existingTemplateBySlug } = await adminClient
    .from("menu_templates")
    .select("id")
    .eq("slug", manifest.slug)
    .maybeSingle();

  if (existingTemplateBySlug) {
    const { data: existingVersion } = await adminClient
      .from("template_versions")
      .select("id")
      .eq("template_id", existingTemplateBySlug.id)
      .eq("version", manifest.version)
      .maybeSingle();
    if (existingVersion) {
      return errorResponse(`النسخة ${manifest.version} موجودة مسبقًا لقالب "${manifest.slug}"`, 409, "VERSION_EXISTS");
    }
  }

  const storagePath = `${manifest.slug}/${manifest.version}`;

  // ارفع كل الملفات فعليًا لـStorage قبل أي كتابة بقاعدة البيانات — بنفس ترتيب
  // الـNode القديم بالضبط، لتفادي سطر "معلّق" بلا ملفات حقيقية وراءه.
  for (const file of files) {
    const { error: uploadError } = await adminClient.storage
      .from("templates")
      .upload(`${storagePath}/${file.path}`, file.buffer, {
        contentType: guessContentType(file.path),
        upsert: false,
      });
    if (uploadError) {
      return errorResponse(`تعذر رفع الملف ${file.path}: ${uploadError.message}`, 500);
    }
  }

  const { data: templateRow, error: templateUpsertError } = await adminClient
    .from("menu_templates")
    .upsert({ name: manifest.name, slug: manifest.slug, type: "customer-menu" }, { onConflict: "slug" })
    .select("id")
    .single();

  if (templateUpsertError || !templateRow) {
    return errorResponse(
      "تعذر إنشاء/تحديث القالب: " + (templateUpsertError?.message || "خطأ غير معروف") +
        " — الملفات انرفعت على Storage لكن بلا سطر قاعدة بيانات؛ راجع bucket templates يدويًا عند الحاجة.",
      500
    );
  }

  const { data: versionRow, error: versionInsertError } = await adminClient
    .from("template_versions")
    .insert({
      template_id: templateRow.id,
      version: manifest.version,
      manifest,
      entry_file: manifest.entry,
      storage_path: storagePath,
      is_builtin: false,
      status: "installed",
      file_count: fileCount,
      total_size_bytes: totalSizeBytes,
      installed_by_super_admin_id: superAdminRow?.id ?? null,
    })
    .select("*")
    .single();

  if (versionInsertError || !versionRow) {
    if ((versionInsertError as { code?: string } | null)?.code === "23505") {
      return errorResponse(`النسخة ${manifest.version} موجودة مسبقًا لقالب "${manifest.slug}"`, 409, "VERSION_EXISTS");
    }
    return errorResponse(
      "تعذر تسجيل نسخة القالب: " + (versionInsertError?.message || "خطأ غير معروف") +
        " — الملفات انرفعت على Storage لكن بلا سطر قاعدة بيانات؛ راجع bucket templates يدويًا عند الحاجة.",
      500
    );
  }

  const { data: publicUrlData } = adminClient.storage
    .from("templates")
    .getPublicUrl(`${storagePath}/${manifest.entry}`);

  return jsonResponse(
    {
      template_id: templateRow.id,
      version: versionRow,
      preview_url: publicUrlData?.publicUrl || null,
    },
    201
  );
});
