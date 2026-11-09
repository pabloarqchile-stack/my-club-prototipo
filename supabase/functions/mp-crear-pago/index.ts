// Crea un cobro en Mercado Pago para cobros pendientes del usuario con sesión.
// El monto sale de la base, nunca del navegador. El dinero va a la cuenta de Mercado Pago del club:
// su Access Token está en club_pay_keys y solo se lee aquí, con la clave de servicio.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const APP_URL = Deno.env.get('APP_URL') ?? 'https://pabloarqchile-stack.github.io/my-club-prototipo/';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (req.method !== 'POST') return json(405, { message: 'Método no permitido.' });
  if (!SERVICE_KEY) return json(503, { message: 'Los pagos en línea aún no están activados.' });

  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.startsWith('Bearer ')) return json(401, { message: 'Debes iniciar sesión.' });

  const { ids, amount } = await req.json().catch(() => ({ ids: null, amount: null }));
  if (!Array.isArray(ids) || !ids.length) return json(400, { message: 'No hay cobros para pagar.' });

  // Corre con la sesión del usuario: la base valida que los cobros sean suyos, de un solo club y que ese club tenga su cuenta conectada.
  const start = await fetch(`${SUPABASE_URL}/rest/v1/rpc/start_payment`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, Authorization: auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_ids: ids, p_amount: Number.isInteger(amount) ? amount : null }),
  });
  const pago = await start.json();
  if (!start.ok) return json(400, { message: pago.message ?? 'No pudimos preparar el pago.' });
  if (!UUID.test(String(pago.club))) return json(400, { message: 'No pudimos identificar al club.' });

  const k = await fetch(`${SUPABASE_URL}/rest/v1/club_pay_keys?club_id=eq.${pago.club}&select=secret`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  });
  const [fila] = k.ok ? await k.json() : [];
  if (!fila?.secret) return json(400, { message: 'Este club aún no activa el pago en línea.' });

  const pref = await fetch('https://api.mercadopago.com/checkout/preferences', {
    method: 'POST',
    headers: { Authorization: `Bearer ${fila.secret}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      items: [{ title: pago.title, quantity: 1, unit_price: pago.amount, currency_id: 'CLP' }],
      external_reference: pago.id,
      notification_url: `${SUPABASE_URL}/functions/v1/mp-webhook?club=${pago.club}`,
      back_urls: { success: `${APP_URL}#/pagos`, failure: `${APP_URL}#/pagos`, pending: `${APP_URL}#/pagos` },
      auto_return: 'approved',
    }),
  });
  const data = await pref.json();
  if (pref.status === 401) return json(502, { message: 'La cuenta de Mercado Pago del club no está bien conectada. Avísale al club.' });
  if (!pref.ok || !data.init_point) return json(502, { message: 'Mercado Pago no pudo iniciar el pago.' });
  return json(200, { url: data.init_point });
});
