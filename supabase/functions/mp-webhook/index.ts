// Recibe avisos de Mercado Pago. No confía en el contenido del aviso: consulta el pago a Mercado Pago
// con la cuenta del club, y la base compara el club y el monto antes de marcar los cobros.
// Debe desplegarse sin verificación de sesión, porque quien llama es Mercado Pago.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const svc = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` };

const ok = () => new Response('ok', { status: 200 });

Deno.serve(async (req) => {
  if (req.method !== 'POST' || !SERVICE_KEY) return ok();

  const url = new URL(req.url);
  const club = url.searchParams.get('club') ?? '';
  if (!UUID.test(club)) return ok();
  const body = await req.json().catch(() => ({}));
  const tipo = body.type ?? body.topic ?? url.searchParams.get('type') ?? url.searchParams.get('topic');
  const id = body?.data?.id ?? url.searchParams.get('data.id') ?? url.searchParams.get('id');
  if (tipo !== 'payment' || !id || !/^\d+$/.test(String(id))) return ok();

  const k = await fetch(`${SUPABASE_URL}/rest/v1/club_pay_keys?club_id=eq.${club}&select=secret`, { headers: svc });
  if (!k.ok) return new Response('reintentar', { status: 502 });
  const [fila] = await k.json();
  if (!fila?.secret) return ok();

  const res = await fetch(`https://api.mercadopago.com/v1/payments/${id}`, {
    headers: { Authorization: `Bearer ${fila.secret}` },
  });
  if (!res.ok) return new Response('reintentar', { status: 502 });
  const pago = await res.json();
  if (pago.status !== 'approved' || pago.currency_id !== 'CLP' || !UUID.test(String(pago.external_reference ?? ''))) return ok();

  const conf = await fetch(`${SUPABASE_URL}/rest/v1/rpc/confirm_payment`, {
    method: 'POST',
    headers: { ...svc, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_id: pago.external_reference, p_amount: Math.round(pago.transaction_amount), p_ref: String(pago.id), p_club: club }),
  });
  // Si falla, Mercado Pago reintenta. Una confirmación repetida no vuelve a aplicar el pago.
  return conf.ok ? ok() : new Response('reintentar', { status: 500 });
});
