-- Directivos del club: el club crea su ficha y autoriza su email. La persona se registra con ese email y su RUT,
-- y queda vinculada al club. El club activa o desactiva cada función, y la base lo hace cumplir.
-- Lo propio de la cuenta del club (perfil, cuenta y pagos en línea, directivos) nunca se delega.

begin;

alter table public.accounts drop constraint accounts_type_check;
alter table public.accounts add constraint accounts_type_check
  check (type in ('club', 'jugador', 'apoderado', 'entrenador', 'federacion', 'proveedor', 'dirigente'));
insert into public.id_counters (letter) values ('M');

create function public._dir_perms() returns text[]
language sql immutable as $$
  select array['deportes', 'deportistas', 'solicitudes', 'bajas', 'finanzas', 'aprobaciones', 'asambleas', 'masivo', 'marketplace', 'cuerpo', 'infra']
$$;

create table public.club_directors (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs (id) on delete cascade,
  account_id uuid unique references public.accounts (user_id) on delete set null,
  name text not null check (length(name) between 2 and 160),
  rut text not null,
  rut_clean text generated always as (public.clean_rut(rut)) stored,
  cargo text not null check (length(cargo) between 2 and 60),
  email text not null check (email = lower(email) and email ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'),
  perms text[] not null default '{}' check (perms <@ public._dir_perms()),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (club_id, rut_clean)
);
create index on public.club_directors (club_id);
create unique index one_pending_director on public.club_directors (email) where account_id is null;
alter table public.club_directors enable row level security;
revoke all on public.club_directors from public, anon, authenticated;
grant select on public.club_directors to authenticated;
create policy director_read on public.club_directors for select to authenticated
  using (public.is_club_owner(club_id) or account_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Quién actúa por el club
-- ---------------------------------------------------------------------------
-- Sin función indicada basta ser directivo activo. La función 'club' no se puede asignar: es solo de la cuenta del club.
create function public._club_can(c uuid, perm text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_club_owner(c) or exists (
    select 1 from club_directors d
    where d.club_id = c and d.account_id = auth.uid() and d.active and (perm is null or perm = any (d.perms))
  )
$$;

create function public._can_any(c uuid[], perm text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from unnest(c) x where public._club_can(x, perm))
$$;

create function public._kind_perm(k text) returns text
language sql immutable as $$
  select case
    when k in ('movements', 'discounts', 'settings', 'expenseCats', 'incomeItems', 'incomeCats', 'charges', 'receipts', 'feeRules') then 'finanzas'
    when k = 'clubPay' then 'club'
    when k = 'quotes' then 'marketplace'
    when k in ('separations', 'claims', 'loans', 'reports') then 'bajas'
    when k = 'credentials' then 'deportistas'
    when k = 'transfers' then 'solicitudes'
    when k = 'proposals' then 'aprobaciones'
    when k = 'assemblies' then 'asambleas'
    when k = 'broadcasts' then 'masivo'
    when k in ('techStaff', 'staffPays') then 'cuerpo'
    when k in ('facilities', 'bookings') then 'infra'
  end
$$;

create function public._admin_any(c uuid[], k text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public._can_any(c, public._kind_perm(k))
$$;

create function public._club_can_members(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public._club_can(c, 'deportistas') or public._club_can(c, 'bajas') or public._club_can(c, 'solicitudes')
$$;

create function public._coach_any(c uuid[]) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from links l join accounts a on a.user_id = l.account_id
    where l.club_id = any (c) and l.account_id = auth.uid() and l.status = 'aceptada' and a.type = 'entrenador'
  )
$$;

create function public._my_club() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from (
    select id, 0 as o from clubs where owner_id = auth.uid()
    union all select club_id, 1 from club_directors where account_id = auth.uid() and active
  ) t order by o limit 1
$$;

create or replace function public.is_club_staff(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public._club_can(c, null) or exists (
    select 1 from links l join accounts a on a.user_id = l.account_id
    where l.club_id = c and l.account_id = auth.uid() and l.status = 'aceptada' and a.type = 'entrenador'
  )
$$;

create or replace function public.is_club_related(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public._club_can(c, null)
    or exists (select 1 from links where club_id = c and account_id = auth.uid() and status in ('pendiente', 'aceptada'))
    or exists (
      select 1 from memberships m
      where m.club_id = c and m.status in ('pendiente', 'habil', 'suspendido') and public.is_my_player(m.player_id)
    )
$$;

create or replace function public.club_sees_account(a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from links l
    where l.account_id = a and l.status in ('pendiente', 'aceptada') and public._club_can(l.club_id, null)
  )
$$;

drop policy link_read on public.links;
create policy link_read on public.links for select to authenticated
  using (account_id = auth.uid() or public._club_can(club_id, null));

-- ---------------------------------------------------------------------------
-- Reglas de cada tipo de dato y operaciones del club
-- ---------------------------------------------------------------------------
create or replace function public.can_read_record(k text, c uuid[], p uuid, o uuid, d jsonb) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when k in ('tournaments', 'communiques', 'fedCharges', 'providers', 'fedConfig', 'fichaFields') then true
    when k = 'docs' then o = auth.uid()
    when k = 'chats' then exists (select 1 from jsonb_array_elements_text(coalesce(d -> 'members', '[]')) m where m = any (public._my_ids()))
    when k in ('movements', 'discounts', 'settings', 'expenseCats') then public._admin_any(c, k)
    when k = 'incomeItems' then public._staff_any(c)
    when k in ('staff', 'reports', 'proposals', 'clubUploads') then public._staff_any(c)
    when k = 'quotes' then public._admin_any(c, k) or d ->> 'providerId' = any (public._my_ids())
    when k in ('charges', 'receipts', 'credentials', 'separations', 'claims', 'transfers', 'loans') then
      public._admin_any(c, k) or (p is not null and public.is_my_player(p))
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
    return (isnew and t in ('club', 'dirigente', 'entrenador', 'federacion')) or o = auth.uid()
      or (not isnew and public._same_except(oldd, d, array['teams']) and t in ('club', 'dirigente', 'entrenador'));
  end if;
  if k = 'quotes' then
    return public._admin_any(c, k)
      or (not isnew and d ->> 'providerId' = 'pv_' || pub and oldd ->> 'providerId' = 'pv_' || pub);
  end if;
  if k = 'chats' then
    -- Quien no participa de un chat no puede sobrescribirlo, aunque se agregue en los datos nuevos.
    return exists (select 1 from jsonb_array_elements_text(coalesce(case when isnew then d else oldd end -> 'members', '[]')) m where m = any (public._my_ids()));
  end if;

  -- Un club solo cobra a deportistas que son o fueron parte de él.
  if k = 'charges' and isnew and p is not null and not mine
     and not exists (select 1 from memberships m where m.player_id = p and m.club_id = any (c)) then return false; end if;

  -- El club puede registrar todo lo suyo. Un directivo, solo lo de las funciones que tiene activas.
  if public._admin_any(c, k) then return true; end if;

  case k
    when 'events', 'polls', 'broadcasts', 'routines', 'staff', 'proposals', 'clubUploads' then
      if public._coach_any(c) then return true; end if;
      if k = 'events' then return not isnew and public._related_any(c) and public._same_except(oldd, d, array['present', 'attendance']); end if;
      if k = 'polls' then return not isnew and public._related_any(c) and public._same_except(oldd, d, array['votes']); end if;
      return false;
    when 'posts' then
      if isnew then return public._related_any(c); end if;
      return o = auth.uid() or public._staff_any(c) or (public._related_any(c) and public._same_except(oldd, d, array['likes', 'comments']));
    when 'assemblies' then return not isnew and public._related_any(c) and public._same_except(oldd, d, array['attendees', 'motions']);
    when 'reports' then return isnew and public._related_any(c);
    when 'incomeItems', 'incomeCats' then return public._coach_any(c) and (isnew or o = auth.uid());
    when 'charges' then
      if isnew and mine and d ->> 'kind' in ('pase', 'federacion') and d ->> 'status' = 'pendiente' then return true; end if;
      -- El entrenador cobra a deportistas activos de su club. Marcar un cobro pagado sigue siendo solo de apply_payment.
      return isnew and cardinality(c) = 1 and public._coach_any(c) and p is not null
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

create or replace function public.save_records(p jsonb) returns void
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
      if not (c <@ prev.club_ids and prev.club_ids <@ c) and not public._admin_any(prev.club_ids, k) then raise exception 'No tienes permiso para guardar este dato.'; end if;
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
      if not public._kind_ok(prev.kind) then raise exception 'No tienes permiso para eliminar este dato.'; end if;
      if not (public._admin_any(prev.club_ids, prev.kind) or prev.owner_id = auth.uid()) or prev.kind in ('charges', 'receipts', 'movements') and not public._admin_any(prev.club_ids, prev.kind) then
        raise exception 'No tienes permiso para eliminar este dato.';
      end if;
      delete from records where kind = prev.kind and id = prev.id;
    end if;
  end loop;
end $$;

create or replace function public.save_memberships(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb; m memberships; st text; mid uuid; pl uuid; cl uuid;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  for r in select * from jsonb_array_elements(coalesce(p, '[]')) loop
    mid := public._uuid_or_null(r ->> 'id'); st := r ->> 'status';
    if st not in ('pendiente', 'habil', 'suspendido', 'rechazada', 'desvinculado') then raise exception 'Estado no válido.'; end if;
    select * into m from memberships where id = mid for update;
    if found then
      if not (public._club_can_members(m.club_id) or (public.is_my_player(m.player_id) and m.status = 'habil' and st = 'suspendido')) then
        raise exception 'No tienes permiso para cambiar este estado.';
      end if;
      update memberships set status = st, team_id = public._uuid_or_null(r ->> 'teamId'), number = nullif(r ->> 'number', '')::int,
             federated = coalesce((r ->> 'federated')::boolean, false), until = nullif(r ->> 'until', '')::date, resolved_at = now()
       where id = mid;
    else
      pl := public._uuid_or_null(r ->> 'playerId'); cl := public._uuid_or_null(r ->> 'clubId');
      if not public._club_can_members(cl) and not (public.is_my_player(pl) and exists (
        select 1 from records t where t.kind = 'transfers' and t.player_id = pl and t.data ->> 'toClub' = cl::text and t.data ->> 'status' <> 'rechazada')) then
        raise exception 'No tienes permiso para cambiar este estado.';
      end if;
      insert into memberships (id, player_id, club_id, team_id, sport, status, number, federated, resolved_at)
      values (coalesce(mid, gen_random_uuid()), pl, cl, public._uuid_or_null(r ->> 'teamId'), r ->> 'sport', st, nullif(r ->> 'number', '')::int, coalesce((r ->> 'federated')::boolean, false), now());
    end if;
  end loop;
end $$;

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
      select t.a, cl, msg, ref from (
        select owner_id as a from clubs where id = cl and owner_id is not null
        union select account_id from club_directors where club_id = cl and active and account_id is not null
      ) t where t.a <> auth.uid();
    end if;
    if r ->> 'providerId' is not null and 'proveedor' = any (roles) and public._can_any(array[cl], 'marketplace') then
      insert into notifications (account_id, club_id, text, href)
      select user_id, cl, msg, ref from accounts where 'pv_' || public_id = r ->> 'providerId';
    end if;
  end loop;
end $$;

create or replace function public.add_sport(p_sport text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text := regexp_replace(btrim(coalesce(p_sport, '')), '\s+', ' ', 'g');
begin
  if v !~ '^[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ ().-]{2,40}$' then
    raise exception 'El nombre del deporte debe tener entre 2 y 40 caracteres: solo letras, números, espacios y . ( ) -';
  end if;
  update clubs set sports = case when exists (select 1 from unnest(sports) s where lower(s) = lower(v)) then sports else sports || v end
   where id = public._my_club() and public._club_can(id, 'deportes');
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
end $$;

create or replace function public.add_team(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; v_id uuid; sp text := public._txt(p, 'sport');
begin
  select * into c from clubs where id = public._my_club() and public._club_can(id, 'deportes');
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
  if public._txt(p, 'name') is null then raise exception 'Escribe un nombre.'; end if;
  if not sp = any (c.sports) then raise exception 'Primero agrega ese deporte al club.'; end if;
  insert into teams (club_id, sport, name, category, sex, coach)
  values (c.id, sp, public._txt(p, 'name'), coalesce(public._txt(p, 'category'), 'Todo competidor'), coalesce(public._txt(p, 'sex'), 'Mixto'), coalesce(public._txt(p, 'coach'), 'Por asignar'))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.set_team_coach(p_team uuid, p_coach text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if coalesce(btrim(p_coach), '') = '' then raise exception 'Escribe un nombre.'; end if;
  update teams t set coach = btrim(p_coach) where t.id = p_team and public._club_can(t.club_id, 'deportes');
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
end $$;

create or replace function public.resolve_link(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l links; c clubs;
begin
  select * into l from links where id = p_id for update;
  if not found or not public._club_can(l.club_id, 'solicitudes') then raise exception 'Solo el club puede resolver esta solicitud.'; end if;
  if l.status <> 'pendiente' then raise exception 'Esta solicitud ya fue resuelta.'; end if;
  update links set status = case when p_ok then 'aceptada' else 'rechazada' end, resolved_at = now() where id = p_id;
  select * into c from clubs where id = l.club_id;
  perform public._notify(l.account_id, l.club_id, c.short || case when p_ok then ' aceptó' else ' rechazó' end || ' tu vinculación.', '/inicio');
  perform public._audit('link.resolve', p_id);
end $$;

create or replace function public.resolve_join(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m memberships; c clubs; pl players; t teams;
begin
  select * into m from memberships where id = p_id for update;
  if not found or not public._club_can(m.club_id, 'solicitudes') then raise exception 'Solo el club puede resolver esta solicitud.'; end if;
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

create or replace function public.update_team(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t teams; tid uuid := public._uuid_or_null(p ->> 'id'); monto bigint := nullif(p ->> 'matricula', '')::bigint;
begin
  select * into t from teams where id = tid for update;
  if not found or not public._club_can(t.club_id, 'deportes') then raise exception 'Solo el club puede hacer esto.'; end if;
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

create or replace function public.delete_team(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t teams;
begin
  select * into t from teams where id = p_id for update;
  if not found or not public._club_can(t.club_id, 'deportes') then raise exception 'Solo el club puede hacer esto.'; end if;
  if exists (select 1 from memberships where team_id = p_id and status in ('pendiente', 'habil', 'suspendido')) then
    raise exception 'Esta categoría tiene deportistas. Muévelos a otra antes de eliminarla.';
  end if;
  delete from teams where id = p_id;
end $$;

create or replace function public.set_sport_matricula(p_sport text, p_amount bigint) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; t teams;
begin
  select * into c from clubs where id = public._my_club() and public._club_can(id, 'deportes');
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'El monto no es válido.'; end if;
  for t in select * from teams where club_id = c.id and sport = p_sport loop
    perform public.update_team(jsonb_build_object('id', t.id, 'name', t.name, 'matricula', p_amount));
  end loop;
end $$;

create or replace function public.record_manual_payment(p_ids text[], p_method text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from records where kind = 'charges' and id = any (p_ids) and not public._can_any(club_ids, 'finanzas')) or not exists (select 1 from records where kind = 'charges' and id = any (p_ids)) then
    raise exception 'Solo el club puede registrar este pago.';
  end if;
  return public.apply_payment(p_ids, coalesce(nullif(btrim(p_method), ''), 'Pago manual'), 'manual');
end $$;

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
    'directors', coalesce((select jsonb_agg(to_jsonb(d) - 'rut_clean') from club_directors d), '[]'),
    'notifications', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (select * from notifications order by created_at desc limit 100) n), '[]'),
    'records', public.my_records(),
    'directory', public.directory(),
    'names', public.my_directory_players()
  )
$$;

create or replace function public.register_account(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  t text := public._txt(p, 'type');
  nm text := public._txt(p, 'name');
  v_rut text := public._txt(p, 'rut');
  ph text := public._txt(p, 'phone');
  mail text;
  letter char(1);
  pid text;
  brd jsonb;
  cl uuid;
  pl uuid;
  lk_club uuid := nullif(p #>> '{link,clubId}', '')::uuid;
  lk_sport text := nullif(p #>> '{link,sport}', '');
  ex players;
  dir club_directors;
begin
  if uid is null then raise exception 'Debes iniciar sesión.'; end if;
  if exists (select 1 from accounts where user_id = uid) then raise exception 'Esta cuenta ya está registrada.'; end if;
  select email into mail from auth.users where id = uid;
  letter := case t when 'club' then 'C' when 'jugador' then 'D' when 'apoderado' then 'A' when 'entrenador' then 'E' when 'federacion' then 'F' when 'proveedor' then 'P' when 'dirigente' then 'M' end;
  if letter is null then raise exception 'Tipo de usuario no válido.'; end if;
  if nm is null or v_rut is null or ph is null then raise exception 'Completa nombre, RUT, email y teléfono.'; end if;
  if not public.rut_valido(v_rut) then raise exception 'El RUT no es válido.'; end if;
  if coalesce((p ->> 'consent')::boolean, false) is not true then raise exception 'Debes aceptar los Términos de uso y la Política de privacidad.'; end if;
  if exists (select 1 from accounts where type = t and rut_clean = public.clean_rut(v_rut)) then raise exception 'Ya existe una cuenta de este tipo con ese RUT.'; end if;

  if t = 'club' then
    select coalesce(jsonb_agg(jsonb_build_object('cargo', btrim(x ->> 'cargo'), 'name', btrim(x ->> 'name'))), '[]') into brd
      from jsonb_array_elements(coalesce(p -> 'board', '[]')) x
     where coalesce(btrim(x ->> 'cargo'), '') <> '' and coalesce(btrim(x ->> 'name'), '') <> '';
    if public._txt(p, 'constituted') is null or public._txt(p, 'regNumber') is null then raise exception 'Indica la fecha de constitución y el registro deportivo.'; end if;
    if jsonb_array_length(brd) < 3 then raise exception 'El directorio requiere mínimo 3 cargos con nombre.'; end if;
    if exists (select 1 from clubs where rut_clean = public.clean_rut(v_rut)) then raise exception 'Ya existe un club con ese RUT.'; end if;
  end if;
  if t = 'jugador' then
    if public._txt(p, 'birth') is null then raise exception 'Indica tu fecha de nacimiento.'; end if;
    -- Si su apoderado lo registró y le dio acceso con este email, la cuenta nueva toma ese perfil.
    select * into ex from players where rut_clean = public.clean_rut(v_rut);
    if found and not (ex.account_id is null and ex.access_email is not null and ex.access_email = lower(mail)) then
      raise exception 'Ya existe un deportista con ese RUT. Si tu apoderado te registró, pídele que te dé acceso desde Mis pupilos con este email.';
    end if;
  end if;
  -- Un directivo solo existe si su club lo creó antes, con este email y este RUT.
  if t = 'dirigente' then
    select * into dir from club_directors where email = lower(mail) and rut_clean = public.clean_rut(v_rut) and account_id is null and active for update;
    if not found then raise exception 'Tu club debe crearte primero en Directivos, con este email y este RUT.'; end if;
  end if;
  if t = 'federacion' and public._txt(p, 'sport') is null then raise exception 'Indica el deporte de la federación.'; end if;
  if t = 'proveedor' and public._txt(p, 'cat') is null then raise exception 'Indica la categoría.'; end if;

  pid := public._next_public_id(letter);
  insert into accounts (user_id, public_id, type, name, rut, email, phone, sport, category, consent_at)
  values (uid, pid, t, nm, v_rut, mail, ph, public._txt(p, 'sport'), public._txt(p, 'cat'), now());

  if t = 'club' then
    insert into clubs (code, owner_id, name, short, rut, constituted, reg_number, email, phone, board)
    values (pid, uid, nm, nm, v_rut, (p ->> 'constituted')::date, public._txt(p, 'regNumber'), mail, ph, brd) returning id into cl;
  elsif t = 'jugador' then
    if ex.id is not null then
      update players set account_id = uid, email = mail, phone = ph, access_email = null where id = ex.id returning id into pl;
      perform public._notify(ex.guardian_id, null, ex.name || ' ya entra con su propia cuenta.', '/a/pupilos');
    else
      insert into players (account_id, name, rut, birth, email, phone, height, size)
      values (uid, nm, v_rut, (p ->> 'birth')::date, mail, ph, nullif(p ->> 'height', '')::int, public._txt(p, 'size')) returning id into pl;
    end if;
    if lk_club is not null then perform public._join(pl, lk_club, lk_sport, ''); end if;
  elsif t = 'dirigente' then
    update club_directors set account_id = uid where id = dir.id;
    perform public._notify(c2.owner_id, dir.club_id, nm || ' activó su cuenta de directivo.', '/d/directivos') from clubs c2 where c2.id = dir.club_id;
  elsif t in ('apoderado', 'entrenador') and lk_club is not null then
    perform public._link(uid, lk_club);
  end if;

  perform public._audit('account.register', uid);
  return jsonb_build_object('publicId', pid);
end $$;

-- ---------------------------------------------------------------------------
-- Administración de directivos: solo la cuenta del club
-- ---------------------------------------------------------------------------
create function public.save_director(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  c uuid; did uuid := public._uuid_or_null(p ->> 'id'); d club_directors; acc accounts; per text[]; r uuid;
  nm text := public._txt(p, 'name'); v_rut text := public._txt(p, 'rut'); car text := public._txt(p, 'cargo');
  mail text := lower(coalesce(public._txt(p, 'email'), '')); act boolean := coalesce((p ->> 'active')::boolean, true);
begin
  select id into c from clubs where owner_id = auth.uid() order by created_at limit 1;
  if c is null then raise exception 'Solo la cuenta del club puede administrar directivos.'; end if;
  select coalesce(array_agg(distinct x), '{}') into per from jsonb_array_elements_text(coalesce(p -> 'perms', '[]')) x;
  if not per <@ public._dir_perms() then raise exception 'Función no válida.'; end if;
  if car is null or length(car) not between 2 and 60 then raise exception 'Indica el cargo.'; end if;

  if did is not null then
    select * into d from club_directors where id = did and club_id = c for update;
    if not found then raise exception 'No encontramos a ese directivo.'; end if;
  end if;
  -- Con la cuenta ya activada, el nombre, el RUT y el email son los de esa cuenta.
  if did is null or d.account_id is null then
    if nm is null or length(nm) not between 2 and 160 then raise exception 'Escribe el nombre.'; end if;
    if v_rut is null or not public.rut_valido(v_rut) then raise exception 'El RUT no es válido.'; end if;
    if mail !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'El email no es válido.'; end if;
    if exists (select 1 from club_directors x where x.club_id = c and x.rut_clean = public.clean_rut(v_rut) and x.id is distinct from did) then raise exception 'Ese RUT ya está en tu directiva.'; end if;
    if exists (select 1 from club_directors x where x.email = mail and x.account_id is null and x.id is distinct from did) then raise exception 'Ese email ya está autorizado como directivo.'; end if;
    select * into acc from accounts where lower(email) = mail;
    -- Una cuenta de directivo que quedó sin club puede volver a vincularse. Otra cuenta necesita un email distinto.
    if found and (acc.type <> 'dirigente' or acc.rut_clean <> public.clean_rut(v_rut) or exists (select 1 from club_directors x where x.account_id = acc.user_id)) then
      raise exception 'Ese email ya tiene una cuenta en My Club. Usa otro.';
    end if;
  end if;

  if did is null then
    insert into club_directors (club_id, account_id, name, rut, cargo, email, perms, active)
    values (c, acc.user_id, nm, v_rut, car, mail, per, act) returning id into r;
    perform public._audit('director.create', r);
    if acc.user_id is not null then perform public._notify(acc.user_id, c, 'Tu club te vinculó como directivo.', '/inicio'); end if;
    return r;
  end if;
  if d.account_id is null then
    update club_directors set name = nm, rut = v_rut, email = mail, account_id = acc.user_id where id = did;
  end if;
  update club_directors set cargo = car, perms = per, active = act where id = did;
  if d.account_id is not null and (d.perms is distinct from per or d.active is distinct from act) then
    perform public._notify(d.account_id, c, case when act then 'El club actualizó tus funciones de directivo.' else 'El club desactivó tu acceso de directivo.' end, '/inicio');
  end if;
  perform public._audit('director.update', did);
  return did;
end $$;

create function public.remove_director(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d club_directors;
begin
  select * into d from club_directors where id = p_id and public.is_club_owner(club_id) for update;
  if not found then raise exception 'Solo la cuenta del club puede quitar directivos.'; end if;
  delete from club_directors where id = p_id;
  perform public._notify(d.account_id, d.club_id, 'El club te quitó de su directiva.', '/inicio');
  perform public._audit('director.remove', p_id);
end $$;

-- Apoderados de los deportistas activos del club y apoderados vinculados directamente.
create function public.club_guardians() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c uuid := public._my_club(); res jsonb;
begin
  if c is null or not public._club_can(c, 'deportistas') then raise exception 'No tienes permiso para ver esto.'; end if;
  with g as (
    select p.guardian_id as uid, p.id as pid, p.name as pname from memberships m join players p on p.id = m.player_id
     where m.club_id = c and m.status in ('habil', 'suspendido') and p.guardian_id is not null
    union select gl.guardian_id, p.id, p.name from memberships m join players p on p.id = m.player_id
      join guardian_links gl on gl.player_id = p.id and gl.status = 'aceptada'
     where m.club_id = c and m.status in ('habil', 'suspendido')
    union select l.account_id, null, null from links l join accounts a on a.user_id = l.account_id
     where l.club_id = c and l.status = 'aceptada' and a.type = 'apoderado'
  )
  select coalesce(jsonb_agg(f order by f ->> 'name'), '[]') into res from (
    select jsonb_build_object('id', a.public_id, 'name', a.name, 'email', a.email, 'phone', a.phone,
      'kids', coalesce(jsonb_agg(g.pname order by g.pname) filter (where g.pid is not null), '[]')) as f
    from g join accounts a on a.user_id = g.uid group by a.user_id
  ) t;
  return res;
end $$;

revoke execute on function public._dir_perms(), public._can_any(uuid[], text), public._kind_perm(text), public._admin_any(uuid[], text),
  public._club_can_members(uuid), public._coach_any(uuid[]), public._my_club(),
  public.save_director(jsonb), public.remove_director(uuid), public.club_guardians() from public, anon, authenticated;
revoke execute on function public._club_can(uuid, text) from public, anon;
-- La política de vínculos la evalúa con el rol del usuario.
grant execute on function public._club_can(uuid, text) to authenticated;
grant execute on function public.save_director(jsonb), public.remove_director(uuid), public.club_guardians() to authenticated;

commit;
