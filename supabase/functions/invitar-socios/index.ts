// Envía las invitaciones por correo de los socios que inscribió el club (club_invites).
// Quien llama debe tener sesión; la base decide qué invitaciones puede enviar (invites_to_send).
// El correo lo manda Supabase Auth con su plantilla "Invite user" y el SMTP configurado en el proyecto.
// El enlace trae una sesión a la app, que muestra #/activar: crear clave y confirmar la vinculación.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const APP_URL = Deno.env.get('APP_URL') ?? 'https://demo.app-myclub.cl/';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const admin = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' };
const rpc = (fn: string, body: unknown) =>
  fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: admin, body: JSON.stringify(body) });

type Fila = { id: string; email: string; name: string; club: string; kind: string; old_user: string | null };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (req.method !== 'POST') return json(405, { message: 'Método no permitido.' });
  if (!SERVICE_KEY) return json(503, { message: 'El envío de invitaciones aún no está activado.' });

  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.startsWith('Bearer ')) return json(401, { message: 'Debes iniciar sesión.' });
  const who = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_KEY, Authorization: auth } });
  const user = who.ok ? await who.json() : null;
  if (!user?.id) return json(401, { message: 'Tu sesión expiró. Vuelve a ingresar.' });

  const { ids } = await req.json().catch(() => ({ ids: null }));
  if (!Array.isArray(ids) || !ids.length || ids.length > 1000 || !ids.every((x) => UUID.test(String(x)))) {
    return json(400, { message: 'No hay invitaciones para enviar.' });
  }

  // Solo las invitaciones de clubes que esta persona administra (o donde es entrenador con vínculo aceptado).
  const r = await rpc('invites_to_send', { p_uid: user.id, p_ids: ids });
  const filas: Fila[] = r.ok ? await r.json() : [];
  if (!r.ok) return json(500, { message: 'No pudimos preparar las invitaciones.' });

  let sent = 0;
  const failed: { email: string; message: string }[] = [];
  for (const f of filas) {
    // Reenvío: el usuario de Auth anterior nunca creó su cuenta; se reemplaza por uno nuevo con un enlace nuevo.
    if (f.old_user) await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${f.old_user}`, { method: 'DELETE', headers: admin });
    const inv = await fetch(`${SUPABASE_URL}/auth/v1/invite?redirect_to=${encodeURIComponent(APP_URL)}`, {
      method: 'POST',
      headers: admin,
      body: JSON.stringify({ email: f.email, data: { invite: f.id, name: f.name, club: f.club, kind: f.kind } }),
    });
    const d = await inv.json().catch(() => ({}));
    let error: string | null = null;
    if (!inv.ok) {
      const code = d.error_code ?? d.code ?? '';
      error = code === 'email_exists' || inv.status === 422 ? 'Ese email ya tiene cuenta en My Club.'
        : code === 'over_email_send_rate_limit' || inv.status === 429 ? 'Se alcanzó el límite de correos por hora. Reenvía más tarde.'
        : 'No se pudo enviar el correo.';
      failed.push({ email: f.email, message: error });
    } else sent++;
    await rpc('invite_sent', { p_id: f.id, p_user: inv.ok ? (d.id ?? d.user?.id ?? null) : null, p_error: error });
  }
  return json(200, { sent, failed });
});
