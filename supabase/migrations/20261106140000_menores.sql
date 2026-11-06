-- Menores de edad: pueden crear su cuenta y su apoderado se vincula con el ID.
-- El apoderado sigue pudiendo registrar a un menor sin cuenta (register_kid).
--
-- Los ID son correlativos y fáciles de adivinar, por eso el vínculo nunca es
-- automático: el deportista debe aceptarlo desde su cuenta. Antes de eso, quien
-- pide el vínculo no ve ningún dato del menor.

begin;

create table public.guardian_links (
  id uuid primary key default gen_random_uuid(),
  guardian_id uuid not null references public.accounts (user_id) on delete cascade,
  player_id uuid not null references public.players (id) on delete cascade,
  rel text not null default 'Apoderado',
  status text not null default 'pendiente' check (status in ('pendiente', 'aceptada', 'rechazada')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create unique index one_guardian_link on public.guardian_links (guardian_id, player_id);
create index on public.guardian_links (player_id);
alter table public.guardian_links enable row level security;

-- Un pupilo vinculado cuenta igual que uno registrado por el apoderado.
create or replace function public.is_my_player(p uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from players where id = p and (account_id = auth.uid() or guardian_id = auth.uid()))
      or exists (select 1 from guardian_links where player_id = p and guardian_id = auth.uid() and status = 'aceptada')
$$;

create or replace function public.is_club_related(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_club_owner(c)
    or exists (select 1 from links where club_id = c and account_id = auth.uid() and status in ('pendiente', 'aceptada'))
    or exists (
      select 1 from memberships m
      where m.club_id = c and m.status in ('pendiente', 'habil', 'suspendido') and public.is_my_player(m.player_id)
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
begin
  if uid is null then raise exception 'Debes iniciar sesión.'; end if;
  if exists (select 1 from accounts where user_id = uid) then raise exception 'Esta cuenta ya está registrada.'; end if;
  select email into mail from auth.users where id = uid;
  letter := case t when 'club' then 'C' when 'jugador' then 'D' when 'apoderado' then 'A' when 'entrenador' then 'E' when 'federacion' then 'F' when 'proveedor' then 'P' end;
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
    if exists (select 1 from players where rut_clean = public.clean_rut(v_rut)) then raise exception 'Ya existe un deportista con ese RUT.'; end if;
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
    insert into players (account_id, name, rut, birth, email, phone, height, size)
    values (uid, nm, v_rut, (p ->> 'birth')::date, mail, ph, nullif(p ->> 'height', '')::int, public._txt(p, 'size')) returning id into pl;
    if lk_club is not null then perform public._join(pl, lk_club, lk_sport, ''); end if;
  elsif t in ('apoderado', 'entrenador') and lk_club is not null then
    perform public._link(uid, lk_club);
  end if;

  perform public._audit('account.register', uid);
  return jsonb_build_object('publicId', pid);
end $$;

create or replace function public.resolve_join(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m memberships; c clubs; pl players;
begin
  select * into m from memberships where id = p_id for update;
  if not found or not public.is_club_owner(m.club_id) then raise exception 'Solo el club puede resolver esta solicitud.'; end if;
  if m.status <> 'pendiente' then raise exception 'Esta solicitud ya fue resuelta.'; end if;
  update memberships set status = case when p_ok then 'habil' else 'rechazada' end, resolved_at = now() where id = p_id;
  select * into c from clubs where id = m.club_id;
  select * into pl from players where id = m.player_id;
  perform public._notify(coalesce(pl.account_id, pl.guardian_id), m.club_id,
    c.short || case when p_ok then ' aceptó la incorporación de ' else ' rechazó la incorporación de ' end || pl.name || ' (' || m.sport || ').', '/inicio');
  perform public._notify(g.guardian_id, m.club_id, c.short || case when p_ok then ' aceptó la incorporación de ' else ' rechazó la incorporación de ' end || pl.name || ' (' || m.sport || ').', '/a/pupilos')
    from guardian_links g where g.player_id = pl.id and g.status = 'aceptada';
  perform public._audit('membership.resolve', p_id);
end $$;

-- Lo que cada parte puede ver del vínculo. Sin aceptar, el apoderado no recibe el nombre del menor.
create function public.my_guardian_links() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', g.id, 'status', g.status, 'rel', g.rel, 'date', g.created_at, 'code', a.public_id,
    'guardianCode', ga.public_id,
    'guardianName', case when p.account_id = auth.uid() then ga.name end,
    'playerId', case when g.status = 'aceptada' or p.account_id = auth.uid() then g.player_id end,
    'playerName', case when g.status = 'aceptada' or p.account_id = auth.uid() then p.name end
  ) order by g.created_at desc), '[]')
  from guardian_links g
  join players p on p.id = g.player_id
  join accounts a on a.user_id = p.account_id
  join accounts ga on ga.user_id = g.guardian_id
  where g.status in ('pendiente', 'aceptada') and (g.guardian_id = auth.uid() or p.account_id = auth.uid())
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
    'notifications', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (select * from notifications order by created_at desc limit 100) n), '[]')
  )
$$;

create function public.request_guardian(p_code text, p_rel text default 'Apoderado') returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); me_ accounts; pl players; prev guardian_links; r uuid;
begin
  select * into me_ from accounts where user_id = uid;
  if not found or me_.type <> 'apoderado' then raise exception 'Solo un apoderado puede vincular a un menor de edad.'; end if;
  select p.* into pl from players p join accounts a on a.user_id = p.account_id
   where a.public_id = upper(btrim(p_code)) and a.type = 'jugador' and age(p.birth) < interval '18 years';
  if not found then raise exception 'No encontramos a un deportista menor de edad con ese ID.'; end if;
  select * into prev from guardian_links where guardian_id = uid and player_id = pl.id;
  if found then
    if prev.status = 'aceptada' then raise exception 'Este deportista ya es tu pupilo.'; end if;
    if prev.status = 'pendiente' then raise exception 'Ya enviaste una solicitud a este deportista.'; end if;
    raise exception 'Este deportista ya rechazó tu solicitud.';
  end if;
  -- Evita que una cuenta envíe solicitudes masivas a menores.
  if (select count(*) from guardian_links where guardian_id = uid and status = 'pendiente') >= 5 then
    raise exception 'Tienes demasiadas solicitudes pendientes.';
  end if;
  insert into guardian_links (guardian_id, player_id, rel) values (uid, pl.id, coalesce(nullif(btrim(p_rel), ''), 'Apoderado')) returning id into r;
  perform public._notify(pl.account_id, null, me_.name || ' pide vincularse como tu apoderado. Acepta solo si lo conoces.', '/apoderados');
  perform public._audit('guardian.request', r);
  return r;
end $$;

create function public.resolve_guardian(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g guardian_links; pl players;
begin
  select * into g from guardian_links where id = p_id for update;
  if found then select * into pl from players where id = g.player_id; end if;
  if not found or pl.account_id is distinct from auth.uid() then raise exception 'Solo el deportista puede responder esta solicitud.'; end if;
  if g.status <> 'pendiente' then raise exception 'Esta solicitud ya fue resuelta.'; end if;
  update guardian_links set status = case when p_ok then 'aceptada' else 'rechazada' end, resolved_at = now() where id = p_id;
  perform public._notify(g.guardian_id, null,
    case when p_ok then pl.name || ' aceptó tu vínculo como apoderado.' else 'Rechazaron tu solicitud de vínculo.' end,
    case when p_ok then '/a/pupilos' else '/inicio' end);
  perform public._audit('guardian.resolve', p_id);
end $$;

-- Permite corregir un vínculo aceptado por error. Queda como rechazado para que no se pueda insistir.
create function public.remove_guardian(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g guardian_links; pl players;
begin
  select * into g from guardian_links where id = p_id for update;
  if found then select * into pl from players where id = g.player_id; end if;
  if not found or (g.guardian_id <> auth.uid() and pl.account_id is distinct from auth.uid()) then raise exception 'No puedes modificar este vínculo.'; end if;
  update guardian_links set status = 'rechazada', resolved_at = now() where id = p_id;
  perform public._notify(case when g.guardian_id = auth.uid() then pl.account_id else g.guardian_id end, null, 'Se eliminó un vínculo de apoderado.', '/inicio');
  perform public._audit('guardian.remove', p_id);
end $$;

-- Supabase da permisos por defecto a objetos nuevos: aquí se dejan solo los necesarios.
revoke all on public.guardian_links from public, anon, authenticated;
revoke execute on function public.my_guardian_links(), public.request_guardian(text, text), public.resolve_guardian(uuid, boolean), public.remove_guardian(uuid) from public, anon, authenticated;
grant execute on function public.my_guardian_links(), public.request_guardian(text, text), public.resolve_guardian(uuid, boolean), public.remove_guardian(uuid) to authenticated;

commit;
