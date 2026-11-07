-- My Club · Etapa 2: todos los módulos, categorías, matrícula y pagos.
--
-- Los módulos se guardan en `records`, un registro por dato. Cada tipo (`kind`)
-- tiene sus reglas de lectura y escritura aquí, en el servidor: el navegador nunca
-- decide. Un cobro solo se marca pagado por el club o por la confirmación de pago.

begin;

-- ---------------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------------
create table public.records (
  kind text not null,
  id text not null,
  club_ids uuid[] not null default '{}',
  player_id uuid references public.players (id) on delete cascade,
  owner_id uuid references public.accounts (user_id) on delete set null,
  data jsonb not null check (pg_column_size(data) < 400000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (kind, id)
);
create index on public.records using gin (club_ids);
create index on public.records (player_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.accounts (user_id) on delete set null,
  charge_ids text[] not null,
  amount bigint not null check (amount > 0),
  status text not null default 'pendiente' check (status in ('pendiente', 'aprobado', 'rechazado')),
  provider_ref text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create sequence public.receipt_number start 1;

alter table public.teams add column matricula bigint not null default 0 check (matricula >= 0);
alter table public.memberships add column number int, add column federated boolean not null default false, add column until date;

alter table public.records enable row level security;
alter table public.payments enable row level security;

-- ---------------------------------------------------------------------------
-- Identidad y pertenencia
-- ---------------------------------------------------------------------------
create function public._today() returns date
language sql stable as $$ select (now() at time zone 'America/Santiago')::date $$;

create function public._my_ids() returns text[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(x), '{}') from (
    select public_id as x from accounts where user_id = auth.uid()
    union select 'g_' || public_id from accounts where user_id = auth.uid()
    union select 'pv_' || public_id from accounts where user_id = auth.uid()
    union select id::text from players where account_id = auth.uid() or guardian_id = auth.uid()
    union select player_id::text from guardian_links where guardian_id = auth.uid() and status = 'aceptada'
  ) t
$$;

create function public._owns_any(c uuid[]) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from clubs where id = any (c) and owner_id = auth.uid())
$$;

create function public._staff_any(c uuid[]) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from unnest(c) x where public.is_club_staff(x))
$$;

create function public._related_any(c uuid[]) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from unnest(c) x where public.is_club_related(x))
$$;

-- Un club conserva la historia de quienes pasaron por él.
create or replace function public.club_sees_player(p uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from memberships m where m.player_id = p and m.status <> 'rechazada' and public.is_club_staff(m.club_id))
$$;

-- ---------------------------------------------------------------------------
-- Quién lee cada tipo de dato
-- ---------------------------------------------------------------------------
create function public.can_read_record(k text, c uuid[], p uuid, o uuid, d jsonb) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when k in ('tournaments', 'communiques', 'fedCharges', 'providers', 'fedConfig', 'fichaFields') then true
    when k = 'docs' then o = auth.uid()
    when k = 'chats' then exists (select 1 from jsonb_array_elements_text(coalesce(d -> 'members', '[]')) m where m = any (public._my_ids()))
    when k in ('movements', 'incomeItems', 'discounts', 'settings', 'expenseCats') then public._owns_any(c)
    when k in ('staff', 'reports', 'proposals', 'clubUploads') then public._staff_any(c)
    when k = 'quotes' then public._owns_any(c) or d ->> 'providerId' = any (public._my_ids())
    when k in ('charges', 'receipts', 'credentials', 'separations', 'claims', 'transfers', 'loans') then
      public._owns_any(c) or (p is not null and public.is_my_player(p))
    when k = 'prefs' then o = auth.uid()
    else public._related_any(c)
  end
$$;

create policy record_read on public.records for select to authenticated
  using (public.can_read_record(kind, club_ids, player_id, owner_id, data));

-- ---------------------------------------------------------------------------
-- Quién escribe cada tipo de dato
-- ---------------------------------------------------------------------------
create function public._same_except(a jsonb, b jsonb, keys text[]) returns boolean
language sql immutable as $$ select (a - keys) = (b - keys) $$;

create function public._can_write(k text, rid text, isnew boolean, c uuid[], p uuid, o uuid, oldd jsonb, d jsonb) returns boolean
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
    when 'charges' then return isnew and mine and d ->> 'kind' in ('pase', 'federacion') and d ->> 'status' = 'pendiente';
    when 'separations' then
      if isnew then return mine and d ->> 'type' = 'renuncia'; end if;
      return mine and oldd ->> 'type' = 'renuncia' and public._same_except(oldd, d, array['status', 'closedAt', 'closeReason']);
    when 'claims' then return isnew and mine;
    when 'transfers' then return mine and (isnew or public._same_except(oldd, d, array['status', 'chargeId', 'doneAt']));
    else return false;
  end case;
end $$;

create function public._kind_ok(k text) returns boolean
language sql immutable as $$
  select k = any (array['events', 'charges', 'receipts', 'credentials', 'separations', 'claims', 'transfers', 'loans', 'movements',
    'incomeItems', 'discounts', 'proposals', 'assemblies', 'polls', 'posts', 'chats', 'broadcasts', 'routines', 'staff', 'quotes',
    'communiques', 'fedCharges', 'clubUploads', 'tournaments', 'reports', 'docs', 'providers', 'settings', 'expenseCats',
    'fedConfig', 'fichaFields', 'prefs'])
$$;

create function public._uuid_or_null(t text) returns uuid
language plpgsql immutable as $$
begin
  return t::uuid;
exception when others then return null;
end $$;

-- Los clubes y el deportista salen del contenido: el navegador no puede declarar otros.
create function public._clubs_of(d jsonb) returns uuid[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(distinct x) filter (where x is not null), '{}') from (
    select public._uuid_or_null(d ->> 'clubId') as x
    union all select public._uuid_or_null(d ->> 'fromClub')
    union all select public._uuid_or_null(d ->> 'toClub')
    union all select club_id from teams where id = public._uuid_or_null(d ->> 'teamId')
  ) t
$$;

create function public.save_records(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; k text; rid text; d jsonb; c uuid[]; pl uuid; prev records; pre boolean;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  if jsonb_array_length(coalesce(p -> 'up', '[]')) + jsonb_array_length(coalesce(p -> 'del', '[]')) > 600 then
    raise exception 'Demasiados cambios a la vez.';
  end if;
  for r in select * from jsonb_array_elements(coalesce(p -> 'up', '[]')) loop
    k := r ->> 'kind'; rid := r ->> 'id'; d := r -> 'data';
    if not public._kind_ok(k) or coalesce(rid, '') = '' or d is null then raise exception 'Dato no válido.'; end if;
    select * into prev from records where kind = k and id = rid for update;
    pre := found;
    c := public._clubs_of(d);
    pl := public._uuid_or_null(d ->> 'playerId');
    if pl is not null and not exists (select 1 from players where id = pl) then pl := null; end if;
    if pre then
      -- Un dato no se mueve a otro club ni a otro deportista.
      if not (c <@ prev.club_ids and prev.club_ids <@ c) and not public._owns_any(prev.club_ids) then raise exception 'No tienes permiso para guardar este dato.'; end if;
      if not public._can_write(k, rid, false, prev.club_ids, prev.player_id, prev.owner_id, prev.data, d) then raise exception 'No tienes permiso para guardar este dato.'; end if;
      update records set data = d, club_ids = c, player_id = pl, updated_at = now() where kind = k and id = rid;
    else
      if not public._can_write(k, rid, true, c, pl, auth.uid(), null, d) then raise exception 'No tienes permiso para guardar este dato.'; end if;
      insert into records (kind, id, club_ids, player_id, owner_id, data) values (k, rid, c, pl, auth.uid(), d);
    end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p -> 'del', '[]')) loop
    select * into prev from records where kind = r ->> 'kind' and id = r ->> 'id' for update;
    if found then
      if not (public._owns_any(prev.club_ids) or prev.owner_id = auth.uid()) or prev.kind in ('charges', 'receipts', 'movements') and not public._owns_any(prev.club_ids) then
        raise exception 'No tienes permiso para eliminar este dato.';
      end if;
      delete from records where kind = prev.kind and id = prev.id;
    end if;
  end loop;
end $$;

-- Cambios de estado de un deportista: el club, o el propio deportista al renunciar o transferirse.
create function public.save_memberships(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb; m memberships; st text; mid uuid; pl uuid; cl uuid;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  for r in select * from jsonb_array_elements(coalesce(p, '[]')) loop
    mid := public._uuid_or_null(r ->> 'id'); st := r ->> 'status';
    if st not in ('pendiente', 'habil', 'suspendido', 'rechazada', 'desvinculado') then raise exception 'Estado no válido.'; end if;
    select * into m from memberships where id = mid for update;
    if found then
      if not (public.is_club_owner(m.club_id) or (public.is_my_player(m.player_id) and m.status = 'habil' and st = 'suspendido')) then
        raise exception 'No tienes permiso para cambiar este estado.';
      end if;
      update memberships set status = st, team_id = public._uuid_or_null(r ->> 'teamId'), number = nullif(r ->> 'number', '')::int,
             federated = coalesce((r ->> 'federated')::boolean, false), until = nullif(r ->> 'until', '')::date, resolved_at = now()
       where id = mid;
    else
      pl := public._uuid_or_null(r ->> 'playerId'); cl := public._uuid_or_null(r ->> 'clubId');
      if not public.is_club_owner(cl) and not (public.is_my_player(pl) and exists (
        select 1 from records t where t.kind = 'transfers' and t.player_id = pl and t.data ->> 'toClub' = cl::text and t.data ->> 'status' <> 'rechazada')) then
        raise exception 'No tienes permiso para cambiar este estado.';
      end if;
      insert into memberships (id, player_id, club_id, team_id, sport, status, number, federated, resolved_at)
      values (coalesce(mid, gen_random_uuid()), pl, cl, public._uuid_or_null(r ->> 'teamId'), r ->> 'sport', st, nullif(r ->> 'number', '')::int, coalesce((r ->> 'federated')::boolean, false), now());
    end if;
  end loop;
end $$;

-- Avisos a personas reales, solo si quien envía tiene relación con el club o el deportista.
create function public.send_notifs(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb; cl uuid; pl uuid; roles text[]; msg text; ref text; mine accounts; ok boolean;
begin
  select * into mine from accounts where user_id = auth.uid();
  if not found then raise exception 'Debes iniciar sesión.'; end if;
  if jsonb_array_length(coalesce(p, '[]')) > 30 then raise exception 'Demasiados avisos a la vez.'; end if;
  for r in select * from jsonb_array_elements(coalesce(p, '[]')) loop
    cl := public._uuid_or_null(r ->> 'clubId'); pl := public._uuid_or_null(r ->> 'playerId');
    msg := left(r ->> 'text', 400); ref := left(coalesce(r ->> 'href', '/inicio'), 80);
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
        select p2.account_id as a from memberships m join players p2 on p2.id = m.player_id where m.club_id = cl and m.status in ('habil', 'suspendido') and p2.account_id is not null and 'jugador' = any (roles)
        union select p2.guardian_id from memberships m join players p2 on p2.id = m.player_id where m.club_id = cl and m.status in ('habil', 'suspendido') and p2.guardian_id is not null and 'apoderado' = any (roles)
        union select g.guardian_id from memberships m join guardian_links g on g.player_id = m.player_id where m.club_id = cl and m.status in ('habil', 'suspendido') and g.status = 'aceptada' and 'apoderado' = any (roles)
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
-- Categorías (equipos) y matrícula
-- ---------------------------------------------------------------------------
create function public._charge_matricula(t teams, pl uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare y text := to_char(public._today(), 'YYYY'); cid text := 'mat_' || t.id || '_' || pl || '_' || y; cnc text;
begin
  if t.matricula <= 0 then return; end if;
  cnc := 'Matrícula ' || y || ' · ' || t.name;
  if exists (select 1 from records where kind = 'charges' and id = cid) then return; end if;
  insert into records (kind, id, club_ids, player_id, data) values ('charges', cid, array[t.club_id], pl, jsonb_build_object(
    'id', cid, 'playerId', pl, 'clubId', t.club_id, 'teamId', t.id, 'concept', cnc, 'kind', 'matricula', 'amount', t.matricula,
    'due', public._today() + 10, 'status', 'pendiente', 'paidAt', null));
end $$;

create function public.update_team(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t teams; tid uuid := public._uuid_or_null(p ->> 'id'); monto bigint := nullif(p ->> 'matricula', '')::bigint;
begin
  select * into t from teams where id = tid for update;
  if not found or not public.is_club_owner(t.club_id) then raise exception 'Solo el club puede hacer esto.'; end if;
  if public._txt(p, 'name') is null then raise exception 'Escribe un nombre.'; end if;
  if monto is not null and monto < 0 then raise exception 'El monto no es válido.'; end if;
  update teams set name = public._txt(p, 'name'), category = coalesce(public._txt(p, 'category'), category), sex = coalesce(public._txt(p, 'sex'), sex),
         coach = coalesce(public._txt(p, 'coach'), coach), matricula = coalesce(monto, matricula) where id = tid returning * into t;
  if monto is not null then
    -- Los cobros pendientes toman el monto nuevo. Los pagados no se tocan.
    update records set data = data || jsonb_build_object('amount', monto), updated_at = now()
     where kind = 'charges' and data ->> 'teamId' = tid::text and data ->> 'kind' = 'matricula' and data ->> 'status' = 'pendiente';
    perform public._charge_matricula(t, m.player_id) from memberships m where m.team_id = tid and m.status in ('habil', 'suspendido');
  end if;
end $$;

-- Una categoría con deportistas activos no se elimina: primero hay que moverlos.
create function public.delete_team(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t teams;
begin
  select * into t from teams where id = p_id for update;
  if not found or not public.is_club_owner(t.club_id) then raise exception 'Solo el club puede hacer esto.'; end if;
  if exists (select 1 from memberships where team_id = p_id and status in ('pendiente', 'habil', 'suspendido')) then
    raise exception 'Esta categoría tiene deportistas. Muévelos a otra antes de eliminarla.';
  end if;
  delete from teams where id = p_id;
end $$;

-- La matrícula del deporte se aplica a todas sus categorías y a sus deportistas.
create function public.set_sport_matricula(p_sport text, p_amount bigint) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; t teams;
begin
  select * into c from clubs where owner_id = auth.uid();
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'El monto no es válido.'; end if;
  for t in select * from teams where club_id = c.id and sport = p_sport loop
    perform public.update_team(jsonb_build_object('id', t.id, 'name', t.name, 'matricula', p_amount));
  end loop;
end $$;

-- Al aceptar a un deportista se le carga la matrícula de su categoría.
create or replace function public.resolve_join(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m memberships; c clubs; pl players; t teams;
begin
  select * into m from memberships where id = p_id for update;
  if not found or not public.is_club_owner(m.club_id) then raise exception 'Solo el club puede resolver esta solicitud.'; end if;
  if m.status <> 'pendiente' then raise exception 'Esta solicitud ya fue resuelta.'; end if;
  update memberships set status = case when p_ok then 'habil' else 'rechazada' end, resolved_at = now() where id = p_id;
  select * into c from clubs where id = m.club_id;
  select * into pl from players where id = m.player_id;
  if p_ok and m.team_id is not null then
    select * into t from teams where id = m.team_id;
    perform public._charge_matricula(t, m.player_id);
  end if;
  perform public._notify(coalesce(pl.account_id, pl.guardian_id), m.club_id,
    c.short || case when p_ok then ' aceptó la incorporación de ' else ' rechazó la incorporación de ' end || pl.name || ' (' || m.sport || ').', '/inicio');
  perform public._notify(g.guardian_id, m.club_id, c.short || case when p_ok then ' aceptó la incorporación de ' else ' rechazó la incorporación de ' end || pl.name || ' (' || m.sport || ').', '/a/pupilos')
    from guardian_links g where g.player_id = pl.id and g.status = 'aceptada';
  perform public._audit('membership.resolve', p_id);
end $$;

-- ---------------------------------------------------------------------------
-- Pagos: lo que sigue a un pago confirmado ocurre en el servidor
-- ---------------------------------------------------------------------------
create function public.apply_payment(p_ids text[], p_method text, p_ref text) returns text
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
        'category', case d ->> 'kind' when 'matricula' then 'Matrículas' when 'mensual' then 'Cuotas mensuales' else 'Inscripciones' end, 'concept', d ->> 'concept', 'amount', (d ->> 'amount')::bigint, 'date', hoy)
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

-- El club registra un pago recibido fuera de la app, como efectivo o transferencia.
create function public.record_manual_payment(p_ids text[], p_method text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from records where kind = 'charges' and id = any (p_ids) and not public._owns_any(club_ids)) or not exists (select 1 from records where kind = 'charges' and id = any (p_ids)) then
    raise exception 'Solo el club puede registrar este pago.';
  end if;
  return public.apply_payment(p_ids, coalesce(nullif(btrim(p_method), ''), 'Pago manual'), 'manual');
end $$;

-- Prepara un cobro en línea. Lo llama la función de Mercado Pago con la sesión del usuario.
create function public.start_payment(p_ids text[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; total bigint; n int; titulo text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  select coalesce(sum((data ->> 'amount')::bigint), 0), count(*), min(data ->> 'concept') into total, n, titulo
    from records where kind = 'charges' and id = any (p_ids) and data ->> 'status' = 'pendiente' and player_id is not null and public.is_my_player(player_id);
  if n = 0 or n <> cardinality(p_ids) or total <= 0 then raise exception 'Estos cobros no están disponibles para pago.'; end if;
  insert into payments (user_id, charge_ids, amount) values (auth.uid(), p_ids, total) returning id into pid;
  return jsonb_build_object('id', pid, 'amount', total, 'title', case when n = 1 then titulo else n || ' cobros de My Club' end);
end $$;

-- Lo llama solo el webhook con la clave de servicio, tras confirmar el pago con Mercado Pago.
create function public.confirm_payment(p_id uuid, p_amount bigint, p_ref text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare pay payments; rid text;
begin
  select * into pay from payments where id = p_id for update;
  if not found or pay.status <> 'pendiente' then return null; end if;
  if pay.amount <> p_amount then raise exception 'El monto confirmado no coincide.'; end if;
  rid := public.apply_payment(pay.charge_ids, 'Mercado Pago', p_ref);
  update payments set status = 'aprobado', provider_ref = p_ref, resolved_at = now() where id = p_id;
  return rid;
end $$;

-- ---------------------------------------------------------------------------
-- Directorio público y estado de la sesión
-- ---------------------------------------------------------------------------
create function public.directory() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'clubs', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name, 'short', short, 'sports', to_jsonb(sports), 'city', city, 'region', region, 'color', color)) from clubs where owner_id is not null), '[]'),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'club_id', club_id, 'sport', sport, 'name', name, 'category', category, 'sex', sex, 'coach', coach)) from teams), '[]')
  )
$$;

-- Verificar un documento exige conocer su código: no se pueden listar los documentos de otros.
create function public.verify_doc(p_code text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select data from records where kind = 'docs' and id = upper(btrim(p_code))
$$;

create function public.my_records() returns jsonb
language sql stable security invoker set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'id', id, 'data', data)), '[]') from records
$$;

create function public.my_directory_players() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name)), '[]') from players p
  where exists (select 1 from records r where r.player_id = p.id and public.can_read_record(r.kind, r.club_ids, r.player_id, r.owner_id, r.data))
    and not public.is_my_player(p.id) and not public.club_sees_player(p.id)
$$;

create or replace function public.my_state() returns jsonb
language sql stable security invoker set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'account', (select to_jsonb(a) from accounts a where a.user_id = auth.uid()),
    'accounts', coalesce((select jsonb_agg(to_jsonb(a) - 'rut_clean') from accounts a), '[]'),
    'clubs', coalesce((select jsonb_agg(to_jsonb(c) - 'rut_clean') from clubs c), '[]'),
    'teams', coalesce((select jsonb_agg(to_jsonb(t)) from teams t), '[]'),
    'players', coalesce((select jsonb_agg(to_jsonb(p) - 'rut_clean') from players p), '[]'),
    'memberships', coalesce((select jsonb_agg(to_jsonb(m)) from memberships m), '[]'),
    'links', coalesce((select jsonb_agg(to_jsonb(l)) from links l), '[]'),
    'guardian_links', public.my_guardian_links(),
    'notifications', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (select * from notifications order by created_at desc limit 100) n), '[]'),
    'records', public.my_records(),
    'directory', public.directory(),
    'names', public.my_directory_players()
  )
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke all on public.records, public.payments from public, anon, authenticated;
revoke all on sequence public.receipt_number from public, anon, authenticated;
grant select on public.records to authenticated;

revoke execute on function
  public._today(), public._my_ids(), public._owns_any(uuid[]), public._staff_any(uuid[]), public._related_any(uuid[]),
  public.can_read_record(text, uuid[], uuid, uuid, jsonb), public._same_except(jsonb, jsonb, text[]),
  public._can_write(text, text, boolean, uuid[], uuid, uuid, jsonb, jsonb), public._kind_ok(text), public._uuid_or_null(text), public._clubs_of(jsonb),
  public.save_records(jsonb), public.save_memberships(jsonb), public.send_notifs(jsonb), public._charge_matricula(public.teams, uuid),
  public.update_team(jsonb), public.delete_team(uuid), public.set_sport_matricula(text, bigint),
  public.apply_payment(text[], text, text), public.record_manual_payment(text[], text), public.start_payment(text[]), public.confirm_payment(uuid, bigint, text),
  public.directory(), public.my_records(), public.my_directory_players()
from public, anon, authenticated;

grant execute on function
  public.can_read_record(text, uuid[], uuid, uuid, jsonb), public.save_records(jsonb), public.save_memberships(jsonb), public.send_notifs(jsonb),
  public.update_team(jsonb), public.delete_team(uuid), public.set_sport_matricula(text, bigint),
  public.record_manual_payment(text[], text), public.start_payment(text[]),
  public.directory(), public.my_records(), public.my_directory_players()
to authenticated;

grant execute on function public.confirm_payment(uuid, bigint, text) to service_role;
revoke execute on function public.verify_doc(text) from public, anon, authenticated;
grant execute on function public.verify_doc(text) to anon, authenticated;

commit;
