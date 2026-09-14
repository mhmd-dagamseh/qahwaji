// _shared/cors.ts
// ترويسات CORS مشتركة بين كل الـEdge Functions — الـFrontend (GitHub Pages) بيتصل
// بهاي الدوال من origin مختلف تمامًا عن Supabase، فلازم CORS صريح، تمامًا متل ما
// كان app.js يعمل cors({ origin: "*" }) بالباكند القديم.
export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-order-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function handleOptions(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  return null;
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function errorResponse(message: string, status = 400, code?: string): Response {
  return jsonResponse({ error: { message, code: code || null } }, status);
}
