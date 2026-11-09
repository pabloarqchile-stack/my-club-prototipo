-- Cuerpo técnico con forma de pago y respaldo obligatorio, agenda de recintos, y reglas de cobro:
-- matrícula única, mensualidad mensual con montos por categoría o deportista, becas, cargos por participación y pago parcial.

begin;

create or replace function public._kind_ok(k text) returns boolean
language sql immutable as $$
  select k = any (array['events', 'charges', 'receipts', 'credentials', 'separations', 'claims', 'transfers', 'loans', 'movements',
    'incomeItems', 'discounts', 'proposals', 'assemblies', 'polls', 'posts', 'chats', 'broadcasts', 'routines', 'staff', 'quotes',
    'communiques', 'fedCharges', 'clubUploads', 'tournaments', 'reports', 'docs', 'providers', 'settings', 'expenseCats',
    'fedConfig', 'fichaFields', 'prefs', 'incomeCats', 'clubPay', 'techStaff', 'facilities', 'bookings', 'feeRules'])
$$;

create or replace function public.can_read_record(k text, c uuid[], p uuid, o uuid, d jsonb) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when k in ('tournaments', 'communiques', 'fedCharges', 'providers', 'fedConfig', 'fichaFields') then true
    when k = 'docs' then o = auth.uid()
    when k = 'chats' then exists (select 1 from jsonb_array_elements_text(coalesce(d -> 'members', '[]')) m where m = any (public._my_ids()))
    when k in ('movements', 'discounts', 'settings', 'expenseCats') then public._admin_any(c, k)
    when k = 'incomeItems' then public._staff_any(c)
      or (d ->> 'confirm' = 'true' and exists (select 1 from jsonb_array_elements_text(coalesce(d -> 'playerIds', '[]')) x where x = any (public._my_ids())))
    when k in ('techStaff', 'staffPays') then public._admin_any(c, k)
    when k in ('staff', 'reports', 'proposals', 'clubUploads') then public._staff_any(c)
    when k = 'quotes' then public._admin_any(c, k) or d ->> 'providerId' = any (public._my_ids())
    when k in ('charges', 'receipts', 'credentials', 'separations', 'claims', 'transfers', 'loans', 'feeRules') then
      public._admin_any(c, k) or (p is not null and public.is_my_player(p))
      or (k = 'charges' and o = auth.uid() and public._staff_any(c))
    when k = 'prefs' then o = auth.uid()
    else public._related_any(c)
  end
$$;

-- ---------------------------------------------------------------------------
-- Cuerpo técnico: cada pago exige su liquidación o boleta. Los archivos no viajan en el estado de la app.
-- ---------------------------------------------------------------------------
create table public.staff_docs (
  pay_id text primary key,
  club_id uuid not null references public.clubs (id) on delete cascade,
  name text not null check (length(name) between 1 and 160),
  data text not null check (length(data) <= 620000),
  created_at timestamptz not null default now()
);
alter table public.staff_docs enable row level security;
revoke all on public.staff_docs from public, anon, authenticated;

create function public.pay_staff(p jsonb) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  c uuid := public._my_club(); st records; pid text := 'sp_' || replace(gen_random_uuid()::text, '-', ''); mv text := 'mv_' || replace(gen_random_uuid()::text, '-', '');
  monto text := p ->> 'amount'; doc text := p ->> 'doc'; nom text := left(btrim(coalesce(p ->> 'docName', '')), 160); forma text := p ->> 'form'; tipo text; hoy date := public._today();
begin
  if c is null or not public._club_can(c, 'cuerpo') then raise exception 'No tienes permiso para registrar este pago.'; end if;
  select * into st from records where kind = 'techStaff' and id = p ->> 'staffId' and c = any (club_ids);
  if not found then raise exception 'No encontramos a esa persona.'; end if;
  if forma is null or forma not in ('entrenamiento', 'sesion', 'mensual', 'viatico_comuna', 'viatico_fuera', 'viatico_aloj') then raise exception 'Forma de pago no válida.'; end if;
  if coalesce(monto, '') !~ '^[1-9][0-9]{0,8}$' then raise exception 'Indica un monto válido.'; end if;
  tipo := case when st.data ->> 'contract' = 'contratado' then 'Liquidación de sueldo' else 'Boleta de honorarios' end;
  if nom = '' or doc is null or doc !~ '^data:(application/pdf|image/jpeg|image/png);base64,[A-Za-z0-9+/=]+$' then raise exception 'Debes subir la % para registrar el pago.', lower(tipo); end if;
  if length(doc) > 620000 then raise exception 'El archivo es demasiado grande.'; end if;
  insert into records (kind, id, club_ids, owner_id, data) values ('staffPays', pid, array[c], auth.uid(), jsonb_build_object(
    'id', pid, 'clubId', c, 'staffId', st.id, 'name', st.data ->> 'name', 'form', forma, 'qty', greatest(coalesce(nullif(p ->> 'qty', '')::int, 1), 1), 'amount', monto::bigint,
    'period', left(coalesce(p ->> 'period', ''), 60), 'date', hoy, 'docType', tipo, 'docName', nom));
  insert into staff_docs (pay_id, club_id, name, data) values (pid, c, nom, doc);
  insert into records (kind, id, club_ids, data) values ('movements', mv, array[c], jsonb_build_object(
    'id', mv, 'clubId', c, 'type', 'egreso', 'category', 'Cuerpo técnico', 'concept', (st.data ->> 'name') || ' · ' || tipo, 'amount', monto::bigint, 'date', hoy));
  perform public._audit('staff.pay', c);
  return pid;
end $$;

create function public.staff_doc(p_pay text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d staff_docs;
begin
  select * into d from staff_docs where pay_id = p_pay;
  if not found or not public._club_can(d.club_id, 'cuerpo') then raise exception 'No tienes permiso para ver este documento.'; end if;
  return jsonb_build_object('name', d.name, 'data', d.data);
end $$;

-- ---------------------------------------------------------------------------
-- Matrícula: un solo cobro por deportista en cada club, sin vencimiento.
-- ---------------------------------------------------------------------------
create or replace function public._charge_matricula(t teams, pl uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare cid text := 'mat_' || t.club_id || '_' || pl;
begin
  if t.matricula <= 0 then return; end if;
  if exists (select 1 from records where kind = 'charges' and player_id = pl and t.club_id = any (club_ids) and data ->> 'kind' = 'matricula') then return; end if;
  insert into records (kind, id, club_ids, player_id, data) values ('charges', cid, array[t.club_id], pl, jsonb_build_object(
    'id', cid, 'playerId', pl, 'clubId', t.club_id, 'teamId', t.id, 'concept', 'Matrícula · ' || t.name, 'kind', 'matricula', 'cat', 'Matrícula', 'amount', t.matricula,
    'due', null, 'status', 'pendiente', 'paidAt', null));
end $$;

-- ---------------------------------------------------------------------------
-- Mensualidad: monto por categoría, monto propio por deportista y beca, descuento o convenio.
-- ---------------------------------------------------------------------------
alter table public.teams add column mensualidad bigint not null default 0 check (mensualidad >= 0);

update public.records set data = data || '{"due": null}'::jsonb, updated_at = now()
 where kind = 'charges' and data ->> 'status' = 'pendiente' and data ->> 'kind' in ('matricula', 'mensual');

create function public._month_fee(t teams, pl uuid) returns bigint
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r jsonb; base bigint := t.mensualidad; v numeric;
begin
  select data into r from records where kind = 'feeRules' and id = 'fee_' || t.club_id || '_' || pl;
  if r is null then return base; end if;
  if coalesce(r ->> 'amount', '') ~ '^[0-9]{1,9}$' then base := (r ->> 'amount')::bigint; end if;
  v := coalesce(nullif(r ->> 'value', '')::numeric, 0);
  if r ->> 'benefit' in ('Beca', 'Descuento', 'Convenio') then
    base := case when r ->> 'mode' = 'pct' then base - round(base * least(v, 100) / 100) else base - v end;
  end if;
  return greatest(base, 0);
end $$;

-- Se puede repetir sin duplicar: una cuota por deportista, categoría y mes. Actualiza las cuotas pendientes del mes.
create function public._gen_monthly(c uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  m record; hoy date := public._today(); per text := to_char(hoy, 'YYYY-MM'); rid text; amt bigint;
  mes text := (array['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'])[extract(month from hoy)::int];
begin
  for m in select ms.player_id, t as tm from memberships ms join teams t on t.id = ms.team_id where ms.club_id = c and ms.status in ('habil', 'suspendido') and (t.mensualidad > 0 or exists (select 1 from records r where r.kind = 'feeRules' and r.id = 'fee_' || c || '_' || ms.player_id)) loop
    rid := 'men_' || (m.tm).id || '_' || m.player_id || '_' || per;
    amt := public._month_fee(m.tm, m.player_id);
    if amt > 0 then
      insert into records (kind, id, club_ids, player_id, data) values ('charges', rid, array[c], m.player_id, jsonb_build_object(
        'id', rid, 'playerId', m.player_id, 'clubId', c, 'teamId', (m.tm).id, 'concept', 'Mensualidad ' || mes || ' ' || left(per, 4) || ' · ' || (m.tm).name, 'kind', 'mensual', 'cat', 'Mensualidad', 'amount', amt, 'due', null, 'status', 'pendiente', 'paidAt', null, 'period', per))
      on conflict (kind, id) do update set data = records.data || jsonb_build_object('amount', amt), updated_at = now() where records.data ->> 'status' = 'pendiente';
    else
      delete from records where kind = 'charges' and id = rid and data ->> 'status' = 'pendiente';
    end if;
  end loop;
end $$;

-- Cada ingreso de alguien del club genera lo que falte del mes: no depende de una tarea programada.
create function public.run_monthly() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid;
begin
  for c in select id from clubs where public.is_club_related(id) loop perform public._gen_monthly(c); end loop;
end $$;

create function public.set_team_fee(p_teams uuid[], p_amount bigint) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid;
begin
  if p_amount is null or p_amount < 0 or p_amount > 999999999 then raise exception 'El monto no es válido.'; end if;
  if coalesce(cardinality(p_teams), 0) = 0 then raise exception 'Elige una categoría.'; end if;
  if exists (select 1 from unnest(p_teams) x left join teams t on t.id = x where t.id is null or not public._club_can(t.club_id, 'finanzas')) then raise exception 'No tienes permiso para cambiar este monto.'; end if;
  update teams set mensualidad = p_amount where id = any (p_teams);
  for c in select distinct club_id from teams where id = any (p_teams) loop perform public._gen_monthly(c); end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Partido, viaje o torneo: el cobro nace cuando el deportista o su apoderado confirma.
-- ---------------------------------------------------------------------------
create function public.confirm_participation(p_item text, p_player uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare it records; d jsonb; ch records; rid text := 'part_' || p_item || '_' || p_player; cl uuid; tid uuid;
begin
  select * into it from records where kind = 'incomeItems' and id = p_item for update;
  if not found or it.data ->> 'confirm' is distinct from 'true' then raise exception 'Esta convocatoria no existe.'; end if;
  d := it.data; cl := it.club_ids[1];
  if not public.is_my_player(p_player) or not coalesce(d -> 'playerIds', '[]') ? p_player::text then raise exception 'No tienes permiso para responder esta convocatoria.'; end if;
  select * into ch from records where kind = 'charges' and id = rid for update;
  if p_ok then
    if nullif(d ->> 'due', '') is not null and (d ->> 'due')::date < public._today() then raise exception 'El plazo de esta convocatoria ya terminó.'; end if;
    select team_id into tid from memberships where player_id = p_player and club_id = cl and status in ('habil', 'suspendido') order by created_at limit 1;
    if not found then raise exception 'El deportista no está activo en este club.'; end if;
    if ch.id is null then
      insert into records (kind, id, club_ids, player_id, data) values ('charges', rid, array[cl], p_player, jsonb_build_object(
        'id', rid, 'playerId', p_player, 'clubId', cl, 'teamId', tid, 'concept', d ->> 'name', 'kind', 'extraordinaria', 'cat', d ->> 'kind', 'amount', (d ->> 'amount')::bigint,
        'due', nullif(d ->> 'due', ''), 'status', 'pendiente', 'paidAt', null, 'by', d ->> 'by', 'partial', true, 'meta', jsonb_build_object('itemId', p_item)));
    end if;
  else
    if ch.id is not null and (ch.data ->> 'status' <> 'pendiente' or ch.data ->> 'original' is not null) then raise exception 'Ya registra pagos: habla con el club para cancelar.'; end if;
    delete from records where kind = 'charges' and id = rid;
  end if;
  update records set data = jsonb_set(data, '{answers}', coalesce(data -> 'answers', '{}') || jsonb_build_object(p_player::text, case when p_ok then 'si' else 'no' end)), updated_at = now()
   where kind = 'incomeItems' and id = p_item;
end $$;

-- ---------------------------------------------------------------------------
-- Pago parcial: baja el saldo del cobro y entrega su comprobante.
-- ---------------------------------------------------------------------------
alter table public.payments add column partial boolean not null default false;

create function public._apply_partial(p_id text, p_amount bigint, p_method text, p_ref text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare ch records; d jsonb; rid text := 'rc_' || replace(gen_random_uuid()::text, '-', ''); mv text := 'mv_' || replace(gen_random_uuid()::text, '-', ''); code text; saldo bigint; hoy date := public._today(); pname text; cname text;
begin
  select * into ch from records where kind = 'charges' and id = p_id and data ->> 'status' = 'pendiente' for update;
  if not found then return null; end if;
  d := ch.data; saldo := (d ->> 'amount')::bigint;
  if p_amount >= saldo then return public.apply_payment(array[p_id], p_method, p_ref); end if;
  code := 'MC-' || upper(substr(md5(rid), 1, 4)) || '-' || upper(substr(md5(rid), 5, 4));
  update records set data = data || jsonb_build_object('amount', saldo - p_amount, 'original', coalesce((d ->> 'original')::bigint, saldo)), updated_at = now() where kind = 'charges' and id = p_id;
  insert into records (kind, id, club_ids, data) values ('movements', mv, ch.club_ids, jsonb_build_object('id', mv, 'clubId', ch.club_ids[1], 'type', 'ingreso',
    'category', coalesce(nullif(left(d ->> 'cat', 40), ''), 'Inscripciones'), 'concept', 'Abono: ' || (d ->> 'concept'), 'amount', p_amount, 'date', hoy));
  select name into pname from players where id = ch.player_id;
  select name into cname from clubs where id = ch.club_ids[1];
  insert into records (kind, id, club_ids, player_id, data) values ('receipts', rid, array[ch.club_ids[1]], ch.player_id, jsonb_build_object(
    'id', rid, 'number', nextval('public.receipt_number'), 'date', hoy, 'method', p_method, 'amount', p_amount, 'items', jsonb_build_array(jsonb_build_object('concept', 'Abono: ' || (d ->> 'concept'), 'amount', p_amount)),
    'payer', coalesce(pname, cname), 'payee', cname, 'code', code, 'clubId', ch.club_ids[1], 'playerId', ch.player_id, 'ref', p_ref));
  insert into records (kind, id, data) values ('docs', code, jsonb_build_object('code', code, 'type', 'Comprobante de pago', 'title', p_method, 'holder', coalesce(pname, cname), 'date', hoy));
  perform public._notify(p2.account_id, ch.club_ids[1], 'Abono registrado por ' || p_amount || ' pesos.', '/comprobante/' || rid) from players p2 where p2.id = ch.player_id;
  perform public._notify(p2.guardian_id, ch.club_ids[1], 'Abono registrado por ' || p_amount || ' pesos.', '/comprobante/' || rid) from players p2 where p2.id = ch.player_id and p2.guardian_id is not null;
  perform public._audit('payment.partial', null);
  return rid;
end $$;

drop function public.record_manual_payment(text[], text);
create function public.record_manual_payment(p_ids text[], p_method text, p_amount bigint default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare m text := coalesce(nullif(btrim(p_method), ''), 'Pago manual');
begin
  if exists (select 1 from records where kind = 'charges' and id = any (p_ids) and not public._can_any(club_ids, 'finanzas')) or not exists (select 1 from records where kind = 'charges' and id = any (p_ids)) then
    raise exception 'Solo el club puede registrar este pago.';
  end if;
  if p_amount is null then return public.apply_payment(p_ids, m, 'manual'); end if;
  if cardinality(p_ids) <> 1 or p_amount <= 0 or not exists (select 1 from records where kind = 'charges' and id = p_ids[1] and data ->> 'partial' = 'true') then raise exception 'Este cobro no admite pago parcial.'; end if;
  return public._apply_partial(p_ids[1], p_amount, m, 'manual');
end $$;

drop function public.start_payment(text[]);
create function public.start_payment(p_ids text[], p_amount bigint default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; total bigint; n int; titulo text; cl uuid; nc int; parcial boolean := false;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  select coalesce(sum((data ->> 'amount')::bigint), 0), count(*), min(data ->> 'concept'), min(club_ids[1]::text)::uuid, count(distinct club_ids[1])
    into total, n, titulo, cl, nc
    from records where kind = 'charges' and id = any (p_ids) and data ->> 'status' = 'pendiente' and player_id is not null and public.is_my_player(player_id);
  if n = 0 or n <> cardinality(p_ids) or total <= 0 then raise exception 'Estos cobros no están disponibles para pago.'; end if;
  if nc <> 1 then raise exception 'Paga a cada club por separado.'; end if;
  if not exists (select 1 from club_pay_keys where club_id = cl) then raise exception 'Este club aún no activa el pago en línea.'; end if;
  if p_amount is not null and p_amount <> total then
    if n <> 1 or not exists (select 1 from records where kind = 'charges' and id = p_ids[1] and data ->> 'partial' = 'true') then raise exception 'Este cobro no admite pago parcial.'; end if;
    if p_amount <= 0 or p_amount > total then raise exception 'El monto debe ser mayor que cero y no superar el saldo.'; end if;
    total := p_amount; parcial := true; titulo := 'Abono: ' || titulo;
  end if;
  insert into payments (user_id, charge_ids, amount, club_id, partial) values (auth.uid(), p_ids, total, cl, parcial) returning id into pid;
  return jsonb_build_object('id', pid, 'amount', total, 'club', cl, 'title', case when n = 1 then titulo else n || ' cobros de My Club' end);
end $$;

create or replace function public.confirm_payment(p_id uuid, p_amount bigint, p_ref text, p_club uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare pay payments; rid text;
begin
  select * into pay from payments where id = p_id for update;
  if not found or pay.status <> 'pendiente' then return null; end if;
  if pay.club_id is distinct from p_club then raise exception 'El pago no corresponde a este club.'; end if;
  if pay.amount <> p_amount then raise exception 'El monto confirmado no coincide.'; end if;
  rid := case when pay.partial then public._apply_partial(pay.charge_ids[1], pay.amount, 'Mercado Pago', p_ref) else public.apply_payment(pay.charge_ids, 'Mercado Pago', p_ref) end;
  update payments set status = 'aprobado', provider_ref = p_ref, resolved_at = now() where id = p_id;
  return rid;
end $$;

revoke execute on function public.pay_staff(jsonb), public.staff_doc(text), public._month_fee(public.teams, uuid), public._gen_monthly(uuid), public.run_monthly(),
  public.set_team_fee(uuid[], bigint), public.confirm_participation(text, uuid, boolean), public._apply_partial(text, bigint, text, text),
  public.record_manual_payment(text[], text, bigint), public.start_payment(text[], bigint) from public, anon, authenticated;
grant execute on function public.pay_staff(jsonb), public.staff_doc(text), public.run_monthly(), public.set_team_fee(uuid[], bigint),
  public.confirm_participation(text, uuid, boolean), public.record_manual_payment(text[], text, bigint), public.start_payment(text[], bigint) to authenticated;

commit;
