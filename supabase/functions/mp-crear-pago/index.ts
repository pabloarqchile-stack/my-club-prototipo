// Crea un cobro en Mercado Pago para cobros pendientes del usuario con sesión.
// El monto sale de la base, nunca del navegador. Sin MP_ACCESS_TOKEN responde 503.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const MP_TOKEN = Deno.env.get('MP_ACCESS_TOKEN') ?? '';
const APP_URL = Deno.env.get('APP_URL') ?? 'https://pabloarqchile-stack.github.io/my-club-prototipo/';

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
  if (!MP_TOKEN) return json(503, { message: 'Los pagos en línea aún no están activados.' });

  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.startsWith('Bearer ')) return json(401, { message: 'Debes iniciar sesión.' });

  const { ids } = await req.json().catch(() => ({ ids: null }));
  if (!Array.isArray(ids) || !ids.length) return json(400, { message: 'No hay cobros para pagar.' });

  // Corre con la sesión del usuario: la base valida que los cobros sean suyos y estén pendientes.
  const start = await fetch(`${SUPABASE_URL}/rest/v1/rpc/start_payment`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, Authorization: auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_ids: ids }),
  });
  const pago = await start.json();
  if (!start.ok) return json(400, { message: pago.message ?? 'No pudimos preparar el pago.' });

  const pref = await fetch('https://api.mercadopago.com/checkout/preferences', {
    method: 'POST',
    headers: { Authorization: `Bearer ${MP_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      items: [{ title: pago.title, quantity: 1, unit_price: pago.amount, currency_id: 'CLP' }],
      external_reference: pago.id,
      notification_url: `${SUPABASE_URL}/functions/v1/mp-webhook`,
      back_urls: { success: `${APP_URL}#/pagos`, failure: `${APP_URL}#/pagos`, pending: `${APP_URL}#/pagos` },
      auto_return: 'approved',
    }),
  });
  const data = await pref.json();
  if (!pref.ok || !data.init_point) return json(502, { message: 'Mercado Pago no pudo iniciar el pago.' });
  return json(200, { url: data.init_point });
});
