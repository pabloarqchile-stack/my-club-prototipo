-- Ingresos por club, deporte o categoría; ingresos del entrenador; mensajes masivos por deporte y categoría;
-- cuenta bancaria del club y pago en línea con la cuenta de Mercado Pago de cada club.

-- ---------------------------------------------------------------------------
-- Tipos de dato nuevos: cargos propios del club (incomeCats) y su cuenta para transferencias (clubPay).
-- Ambos los leen quienes se relacionan con el club, por la regla general de can_read_record.
-- ---------------------------------------------------------------------------
create or replace function public._kind_ok(k text) returns boolean
language sql immutable as $$
  select k = any (array['events', 'charges', 'receipts', 'credentials', 'separations', 'claims', 'transfers', 'loans', 'movements',
    'incomeItems', 'discounts', 'proposals', 'assemblies', 'polls', 'posts', 'chats', 'broadcasts', 'routines', 'staff', 'quotes',
    'communiques', 'fedCharges', 'clubUploads', 'tournaments', 'reports', 'docs', 'providers', 'settings', 'expenseCats',
    'fedConfig', 'fichaFields', 'prefs', 'incomeCats', 'clubPay'])
$$;

-- Los conceptos de cobro los ven también los entrenadores, y cada entrenador ve los cobros que creó.
create or replace function public.can_read_record(k text, c uuid[], p uuid, o uuid, d jsonb) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when k in ('tournaments', 'communiques', 'fedCharges', 'providers', 'fedConfig', 'fichaFields') then true
    when k = 'docs' then o = auth.uid()
    when k = 'chats' then exists (select 1 from jsonb_array_elements_text(coalesce(d -> 'members', '[]')) m where m = any (public._my_ids()))
    when k in ('movements', 'discounts', 'settings', 'expenseCats') then public._owns_any(c)
    when k = 'incomeItems' then public._staff_any(c)
    when k in ('staff', 'reports', 'proposals', 'clubUploads') then public._staff_any(c)
    when k = 'quotes' then public._owns_any(c) or d ->> 'providerId' = any (public._my_ids())
    when k in ('charges', 'receipts', 'credentials', 'separations', 'claims', 'transfers', 'loans') then
      public._owns_any(c) or (p is not null and public.is_my_player(p))
      or (k = 'charges' and o = auth.uid() and public._staff_any(c))
    when k = 'prefs' then o = auth.uid()
    else public._related_any(c)
  end
$$;

create or replace function public._can_write(k text, rid text, isnew boolean, c uuid[], p uuid, o uuid, oldd jsonb, d jsonb) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t text; sp text; pub text; mine boolean := p is not null and public.is_my_player(p);
begin
  select type, sport, public_id into t, sp, pub from accounts where user_id = auth.uid();
  if t is null then return false; end if;

  if k = 'communiques' or k = 'fedCharges' then return t = 'federacion' and d ->> 'sport' = sp; end if;
  if k = 'fedConfig' then return t = 'federacion' and rid = sp; end if;
  if k = 'fichaFields' then return t = 'federacion'; end if;
  if k = 'providers' then return t = 'proveedor' and rid = 'pv_' || pub; end if;
  if k = 'prefs' then return rid = pub; end if;
  if k = 'docs' then return isnew; end if;
  if k = 'tournaments' then
    return (isnew and t in ('club', 'entrenador', 'federacion')) or o = auth.uid()
      or (not isnew and public._same_except(oldd, d, array['teams']) and t in ('club', 'entrenador'));
  end if;
  if k = 'quotes' then
    return (isnew and public._owns_any(c)) or public._owns_any(c)
      or (not isnew and d ->> 'providerId' = 'pv_' || pub and oldd ->> 'providerId' = 'pv_' || pub);
  end if;
  if k = 'chats' then
    -- Quien no participa de un chat no puede sobrescribirlo, aunque se agregue en los datos nuevos.
    return exists (select 1 from jsonb_array_elements_text(coalesce(case when isnew then d else oldd end -> 'members', '[]')) m where m = any (public._my_ids()));
  end if;

  -- Un club solo cobra a deportistas que son o fueron parte de él.
  if k = 'charges' and isnew and p is not null and not mine
     and not exists (select 1 from memberships m where m.player_id = p and m.club_id = any (c)) then return false; end if;

  -- El club que corresponde puede registrar todo lo suyo.
  if public._owns_any(c) then return true; end if;

  case k
    when 'events', 'polls', 'broadcasts', 'routines', 'staff', 'proposals', 'clubUploads' then
      if public._staff_any(c) then return true; end if;
      if k = 'events' then return not isnew and public._related_any(c) and public._same_except(oldd, d, array['present', 'attendance']); end if;
      if k = 'polls' then return not isnew and public._related_any(c) and public._same_except(oldd, d, array['votes']); end if;
      return false;
    when 'posts' then
      if isnew then return public._related_any(c); end if;
      return o = auth.uid() or public._staff_any(c) or (public._related_any(c) and public._same_except(oldd, d, array['likes', 'comments']));
    when 'assemblies' then return not isnew and public._related_any(c) and public._same_except(oldd, d, array['attendees', 'motions']);
    when 'reports' then return isnew and public._related_any(c);
    when 'incomeItems', 'incomeCats' then return public._staff_any(c) and (isnew or o = auth.uid());
    when 'charges' then
      if isnew and mine and d ->> 'kind' in ('pase', 'federacion') and d ->> 'status' = 'pendiente' then return true; end if;
      -- El entrenador cobra a deportistas activos de su club. Marcar un cobro pagado sigue siendo solo de apply_payment.
      return isnew and cardinality(c) = 1 and public._staff_any(c) and p is not null
        and d ->> 'status' = 'pendiente' and d ->> 'kind' in ('mensual', 'extraordinaria', 'matricula')
        and coalesce(d ->> 'paidAt', '') = '' and d ->> 'receiptId' is null
        and coalesce(d ->> 'amount', '') ~ '^[0-9]{1,9}$' and (d ->> 'amount')::bigint > 0
        and exists (select 1 from memberships m where m.player_id = p and m.club_id = c[1] and m.status in ('habil', 'suspendido'));
    when 'separations' then
      if isnew then return mine and d ->> 'type' = 'renuncia'; end if;
      return mine and oldd ->> 'type' = 'renuncia' and public._same_except(oldd, d, array['status', 'closedAt', 'closeReason']);
    when 'claims' then return isnew and mine;
    when 'transfers' then return mine and (isnew or public._same_except(oldd, d, array['status', 'chargeId', 'doneAt']));
    else return false;
  end case;
end $$;

-- ---------------------------------------------------------------------------
-- Avisos segmentados
-- ---------------------------------------------------------------------------
create or replace function public.send_notifs(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb; cl uuid; pl uuid; roles text[]; msg text; ref text; mine accounts; ok boolean; tids uuid[]; sp text;
begin
  select * into mine from accounts where user_id = auth.uid();
  if not found then raise exception 'Debes iniciar sesión.'; end if;
  if jsonb_array_length(coalesce(p, '[]')) > 30 then raise exception 'Demasiados avisos a la vez.'; end if;
  for r in select * from jsonb_array_elements(coalesce(p, '[]')) loop
    cl := public._uuid_or_null(r ->> 'clubId'); pl := public._uuid_or_null(r ->> 'playerId');
    msg := left(r ->> 'text', 400); ref := left(coalesce(r ->> 'href', '/inicio'), 80);
    -- Un aviso puede ir a categorías o a un deporte del club.
    select array_agg(public._uuid_or_null(x)) filter (where public._uuid_or_null(x) is not null) into tids
      from jsonb_array_elements_text(case when jsonb_typeof(r -> 'teams') = 'array' then r -> 'teams' else '[]' end) x;
    sp := nullif(left(r ->> 'sport', 40), '');
    select coalesce(array_agg(x), '{}') into roles from jsonb_array_elements_text(coalesce(r -> 'to', '[]')) x;
    if msg is null or msg = '' then continue; end if;
    ok := mine.type = 'federacion' or (cl is not null and public.is_club_related(cl)) or (pl is not null and (public.is_my_player(pl) or public.club_sees_player(pl)));
    if not ok then continue; end if;

    if pl is not null then
      insert into notifications (account_id, club_id, text, href)
      select distinct t.a, cl, msg, ref from (
        select account_id as a from players where id = pl and account_id is not null and 'jugador' = any (roles)
        union select guardian_id from players where id = pl and guardian_id is not null and 'apoderado' = any (roles)
        union select guardian_id from guardian_links where player_id = pl and status = 'aceptada' and 'apoderado' = any (roles)
      ) t where t.a <> auth.uid();
    elsif cl is not null then
      insert into notifications (account_id, club_id, text, href)
      select distinct t.a, cl, msg, ref from (
        select p2.account_id as a from memberships m join players p2 on p2.id = m.player_id where m.club_id = cl and m.status in ('habil', 'suspendido') and (tids is null or m.team_id = any (tids)) and (sp is null or m.sport = sp) and p2.account_id is not null and 'jugador' = any (roles)
        union select p2.guardian_id from memberships m join players p2 on p2.id = m.player_id where m.club_id = cl and m.status in ('habil', 'suspendido') and (tids is null or m.team_id = any (tids)) and (sp is null or m.sport = sp) and p2.guardian_id is not null and 'apoderado' = any (roles)
        union select g.guardian_id from memberships m join guardian_links g on g.player_id = m.player_id where m.club_id = cl and m.status in ('habil', 'suspendido') and (tids is null or m.team_id = any (tids)) and (sp is null or m.sport = sp) and g.status = 'aceptada' and 'apoderado' = any (roles)
        union select l.account_id from links l join accounts a2 on a2.user_id = l.account_id where l.club_id = cl and l.status = 'aceptada' and a2.type = 'entrenador' and 'entrenador' = any (roles)
      ) t where t.a <> auth.uid();
    end if;
    if cl is not null and 'directivo' = any (roles) then
      insert into notifications (account_id, club_id, text, href)
      select owner_id, cl, msg, ref from clubs where id = cl and owner_id is not null and owner_id <> auth.uid();
    end if;
    if r ->> 'providerId' is not null and 'proveedor' = any (roles) and public._owns_any(array[cl]) then
      insert into notifications (account_id, club_id, text, href)
      select user_id, cl, msg, ref from accounts where 'pv_' || public_id = r ->> 'providerId';
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- La categoría del ingreso (Torneo, Viaje, Camiseta...) llega a las finanzas al pagarse.
-- ---------------------------------------------------------------------------
create or replace function public.apply_payment(p_ids text[], p_method text, p_ref text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ch records; d jsonb; rid text := 'rc_' || replace(gen_random_uuid()::text, '-', ''); code text; total bigint := 0;
  items jsonb := '[]'; first_c uuid; first_p uuid; hoy date := public._today(); pname text; cname text; tr records; om memberships; nt uuid; n int := 0;
begin
  code := 'MC-' || upper(substr(md5(rid), 1, 4)) || '-' || upper(substr(md5(rid), 5, 4));
  for ch in select * from records where kind = 'charges' and id = any (p_ids) and data ->> 'status' = 'pendiente' for update loop
    d := ch.data; n := n + 1;
    total := total + (d ->> 'amount')::bigint;
    items := items || jsonb_build_array(jsonb_build_object('concept', d ->> 'concept', 'amount', (d ->> 'amount')::bigint));
    first_c := coalesce(first_c, ch.club_ids[1]); first_p := coalesce(first_p, ch.player_id);
    update records set data = data || jsonb_build_object('status', 'pagado', 'paidAt', hoy, 'receiptId', rid), updated_at = now() where kind = 'charges' and id = ch.id;

    if d ->> 'kind' in ('mensual', 'extraordinaria', 'matricula') then
      insert into records (kind, id, club_ids, data) select 'movements', mv, ch.club_ids, jsonb_build_object('id', mv, 'clubId', ch.club_ids[1], 'type', 'ingreso',
        'category', case d ->> 'kind' when 'matricula' then 'Matrículas' when 'mensual' then 'Cuotas mensuales' else coalesce(nullif(left(d ->> 'cat', 40), ''), 'Inscripciones') end, 'concept', d ->> 'concept', 'amount', (d ->> 'amount')::bigint, 'date', hoy)
        from (select 'mv_' || replace(gen_random_uuid()::text, '-', '') as mv) x;
    elsif d ->> 'kind' = 'pase' then
      select * into tr from records where kind = 'transfers' and id = d #>> '{meta,transferId}' for update;
      if found then
        select * into om from memberships where player_id = ch.player_id and sport = tr.data ->> 'sport' and status in ('habil', 'suspendido') limit 1;
        if found then update memberships set status = 'desvinculado', until = hoy, resolved_at = now() where id = om.id; end if;
        select id into nt from teams where club_id = (tr.data ->> 'toClub')::uuid and sport = tr.data ->> 'sport' order by created_at limit 1;
        insert into memberships (player_id, club_id, team_id, sport, status, number, federated, resolved_at)
        values (ch.player_id, (tr.data ->> 'toClub')::uuid, nt, tr.data ->> 'sport', 'habil', om.number, coalesce(om.federated, false), now());
        update records set data = data || jsonb_build_object('status', 'completada', 'doneAt', hoy), updated_at = now() where kind = 'transfers' and id = tr.id;
      end if;
    elsif d ->> 'kind' = 'federacion' then
      insert into records (kind, id, club_ids, player_id, data)
      select 'credentials', cr, ch.club_ids, ch.player_id, jsonb_build_object('id', cr, 'playerId', ch.player_id, 'sport', d #>> '{meta,sport}', 'clubId', ch.club_ids[1],
        'season', extract(year from hoy)::int, 'date', hoy, 'code', 'MC-' || upper(substr(md5(cr), 1, 4)) || '-' || upper(substr(md5(cr), 5, 4)))
      from (select 'cr_' || replace(gen_random_uuid()::text, '-', '') as cr) x;
      update memberships set federated = true where player_id = ch.player_id and sport = d #>> '{meta,sport}' and status in ('habil', 'suspendido');
    elsif d ->> 'kind' = 'prestamo' then
      update records set data = data || jsonb_build_object('paidAt', hoy), updated_at = now() where kind = 'loans' and id = d #>> '{meta,loanId}';
    end if;
  end loop;
  if n = 0 then return null; end if;

  select name into pname from players where id = first_p;
  select name into cname from clubs where id = first_c;
  insert into records (kind, id, club_ids, player_id, data) values ('receipts', rid, array[first_c], first_p, jsonb_build_object(
    'id', rid, 'number', nextval('public.receipt_number'), 'date', hoy, 'method', p_method, 'amount', total, 'items', items,
    'payer', coalesce(pname, cname), 'payee', cname, 'code', code, 'clubId', first_c, 'playerId', first_p, 'ref', p_ref));
  insert into records (kind, id, data) values ('docs', code, jsonb_build_object('code', code, 'type', 'Comprobante de pago', 'title', p_method, 'holder', coalesce(pname, cname), 'date', hoy));

  perform public._notify(p2.account_id, first_c, 'Pago registrado por ' || total || ' pesos.', '/comprobante/' || rid) from players p2 where p2.id = first_p;
  perform public._notify(p2.guardian_id, first_c, 'Pago registrado por ' || total || ' pesos.', '/comprobante/' || rid) from players p2 where p2.id = first_p and p2.guardian_id is not null;
  perform public._audit('payment.apply', null);
  return rid;
end $$;

-- ---------------------------------------------------------------------------
-- Pago en línea por club. El Access Token queda en una tabla sin acceso para la app:
-- solo lo leen las funciones de pago con la clave de servicio.
-- ---------------------------------------------------------------------------
alter table public.clubs add column pay_provider text check (pay_provider in ('mercadopago'));
alter table public.payments add column club_id uuid references public.clubs (id) on delete set null;

create table public.club_pay_keys (
  club_id uuid primary key references public.clubs (id) on delete cascade,
  provider text not null check (provider in ('mercadopago')),
  secret text not null check (length(secret) between 20 and 300),
  updated_at timestamptz not null default now()
);
alter table public.club_pay_keys enable row level security;
revoke all on public.club_pay_keys from public, anon, authenticated;
grant select on public.club_pay_keys to service_role;

create function public.set_club_pay_key(p_provider text, p_secret text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid;
begin
  select id into c from clubs where owner_id = auth.uid() order by created_at limit 1;
  if c is null then raise exception 'Solo la cuenta del club puede conectar pagos.'; end if;
  if p_provider is distinct from 'mercadopago' then raise exception 'Ese proveedor aún no está disponible.'; end if;
  if coalesce(p_secret, '') !~ '^(APP_USR|TEST)-[A-Za-z0-9_-]{20,}$' or length(p_secret) > 300 then raise exception 'El Access Token no es válido.'; end if;
  insert into club_pay_keys (club_id, provider, secret) values (c, p_provider, p_secret)
    on conflict (club_id) do update set provider = excluded.provider, secret = excluded.secret, updated_at = now();
  update clubs set pay_provider = p_provider where id = c;
  perform public._audit('club.pay_key', c);
end $$;

create function public.remove_club_pay_key() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid;
begin
  select id into c from clubs where owner_id = auth.uid() order by created_at limit 1;
  if c is null then raise exception 'Solo la cuenta del club puede desconectar pagos.'; end if;
  delete from club_pay_keys where club_id = c;
  update clubs set pay_provider = null where id = c;
  perform public._audit('club.pay_key_removed', c);
end $$;

-- Un pago en línea va a un solo club, y ese club debe tener su cuenta conectada.
create or replace function public.start_payment(p_ids text[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; total bigint; n int; titulo text; cl uuid; nc int;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  select coalesce(sum((data ->> 'amount')::bigint), 0), count(*), min(data ->> 'concept'), min(club_ids[1]::text)::uuid, count(distinct club_ids[1])
    into total, n, titulo, cl, nc
    from records where kind = 'charges' and id = any (p_ids) and data ->> 'status' = 'pendiente' and player_id is not null and public.is_my_player(player_id);
  if n = 0 or n <> cardinality(p_ids) or total <= 0 then raise exception 'Estos cobros no están disponibles para pago.'; end if;
  if nc <> 1 then raise exception 'Paga a cada club por separado.'; end if;
  if not exists (select 1 from club_pay_keys where club_id = cl) then raise exception 'Este club aún no activa el pago en línea.'; end if;
  insert into payments (user_id, charge_ids, amount, club_id) values (auth.uid(), p_ids, total, cl) returning id into pid;
  return jsonb_build_object('id', pid, 'amount', total, 'club', cl, 'title', case when n = 1 then titulo else n || ' cobros de My Club' end);
end $$;

-- El webhook confirma con la cuenta del club: el pago debe ser de ese club.
drop function public.confirm_payment(uuid, bigint, text);
create function public.confirm_payment(p_id uuid, p_amount bigint, p_ref text, p_club uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare pay payments; rid text;
begin
  select * into pay from payments where id = p_id for update;
  if not found or pay.status <> 'pendiente' then return null; end if;
  if pay.club_id is distinct from p_club then raise exception 'El pago no corresponde a este club.'; end if;
  if pay.amount <> p_amount then raise exception 'El monto confirmado no coincide.'; end if;
  rid := public.apply_payment(pay.charge_ids, 'Mercado Pago', p_ref);
  update payments set status = 'aprobado', provider_ref = p_ref, resolved_at = now() where id = p_id;
  return rid;
end $$;

revoke execute on function public.set_club_pay_key(text, text), public.remove_club_pay_key(),
  public.confirm_payment(uuid, bigint, text, uuid) from public, anon, authenticated;
grant execute on function public.set_club_pay_key(text, text), public.remove_club_pay_key() to authenticated;
grant execute on function public.confirm_payment(uuid, bigint, text, uuid) to service_role;
