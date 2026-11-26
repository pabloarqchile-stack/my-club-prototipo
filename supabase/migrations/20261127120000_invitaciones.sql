-- My Club · Invitaciones del club por correo
-- El club (o un entrenador con vínculo aceptado) inscribe deportistas y apoderados, de a uno o con planilla.
-- Cada persona con email recibe una invitación de Supabase Auth (la envía la función invitar-socios):
-- al abrirla crea su clave, confirma su vinculación con el club y acepta términos (accept_invite),
-- o indica que no pertenece al club (reject_invite).
-- Un deportista inscrito por el club existe antes de tener cuenta: lo respalda players.invited_by.

begin;

alter table public.players add column invited_by uuid references public.clubs (id) on delete set null;
do $$
declare n text;
begin
  select conname into n from pg_constraint
   where conrelid = 'public.players'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%account_id IS NOT NULL%guardian_id IS NOT NULL%';
  if n is not null then execute format('alter table public.players drop constraint %I', n); end if;
end $$;
alter table public.players add constraint players_owner_check
  check (account_id is not null or guardian_id is not null or invited_by is not null);

create table public.club_invites (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs (id) on delete cascade,
  kind text not null check (kind in ('jugador', 'apoderado')),
  player_id uuid references public.players (id) on delete set null,
  name text not null check (length(name) between 2 and 160),
  email text not null check (email = lower(email)),
  phone text,
  sport text,
  user_id uuid references auth.users (id) on delete set null,
  status text not null default 'pendiente' check (status in ('pendiente', 'enviada', 'aceptada', 'rechazada', 'error')),
  error text,
  sent_count int not null default 0,
  sent_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
-- Un email solo puede tener una invitación abierta a la vez.
create unique index one_open_invite on public.club_invites (email) where status in ('pendiente', 'enviada', 'error');
create index on public.club_invites (club_id);
create index on public.club_invites (user_id);
alter table public.club_invites enable row level security;

-- Quién inscribe socios por el club: quien administra deportistas, o un entrenador con vínculo aceptado.
create function public._can_invite(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public._club_can(c, 'deportistas') or public._club_coach(c, auth.uid()) is not null
$$;

create policy invite_read on public.club_invites for select to authenticated
  using (public._can_invite(club_id) or user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Inscribir socios. p_rows: [{name, rut, birth, email, phone}] (apoderado: name, email, phone).
-- Devuelve las invitaciones creadas que hay que enviar.
-- ---------------------------------------------------------------------------
create function public.club_add_members(p_club uuid, p_kind text, p_sport text, p_team uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  c clubs; tm teams; r jsonb; i int := 0; nm text; v_rut text; bd date; mail text; ph text;
  pl uuid; inv uuid; ids uuid[] := '{}'; ruts text[] := '{}'; mails text[] := '{}'; added int := 0;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  select * into c from clubs where id = p_club;
  if not found or not public._can_invite(p_club) then raise exception 'No tienes permiso para inscribir socios en este club.'; end if;
  if p_kind not in ('jugador', 'apoderado') then raise exception 'Tipo de socio no válido.'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'No hay socios para agregar.'; end if;
  if jsonb_array_length(p_rows) > 1000 then raise exception 'Máximo 1.000 socios por planilla.'; end if;
  if p_kind = 'jugador' then
    if p_team is not null then
      select * into tm from teams where id = p_team and club_id = p_club;
      if not found then raise exception 'No encontramos esa categoría.'; end if;
      p_sport := tm.sport;
    end if;
    if p_sport is null or not p_sport = any (c.sports) then raise exception 'Elige un deporte del club.'; end if;
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    nm := public._txt(r, 'name'); v_rut := public._txt(r, 'rut'); mail := lower(coalesce(public._txt(r, 'email'), '')); ph := public._txt(r, 'phone');
    if nm is null or length(nm) not between 2 and 160 then raise exception 'Fila %: falta el nombre.', i; end if;
    if mail <> '' then
      if mail !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'Fila %: el email no es válido.', i; end if;
      if mail = any (mails) then raise exception 'Fila %: email repetido en la planilla.', i; end if;
      if exists (select 1 from auth.users u where lower(u.email) = mail) or exists (select 1 from club_invites x where x.email = mail and x.status in ('pendiente', 'enviada', 'error')) then
        raise exception 'Fila %: % ya tiene cuenta o invitación en My Club.', i, mail;
      end if;
      mails := mails || mail;
    end if;
    if ph is not null and regexp_replace(ph, '[[:space:]().-]', '', 'g') !~ '^[+]?[0-9]{8,12}$' then raise exception 'Fila %: el teléfono no es válido.', i; end if;
    if p_kind = 'apoderado' then
      if mail = '' then raise exception 'Fila %: falta el email.', i; end if;
      if ph is null then raise exception 'Fila %: falta el teléfono.', i; end if;
      insert into club_invites (club_id, kind, name, email, phone, created_by) values (p_club, 'apoderado', nm, mail, ph, auth.uid()) returning id into inv;
      ids := ids || inv;
    else
      if v_rut is null or not public.rut_valido(v_rut) then raise exception 'Fila %: el RUT no es válido.', i; end if;
      if public.clean_rut(v_rut) = any (ruts) then raise exception 'Fila %: RUT repetido en la planilla.', i; end if;
      if exists (select 1 from players where rut_clean = public.clean_rut(v_rut)) then raise exception 'Fila %: ese RUT ya está registrado en My Club.', i; end if;
      ruts := ruts || public.clean_rut(v_rut);
      begin bd := (r ->> 'birth')::date; exception when others then bd := null; end;
      if bd is null or bd > current_date or bd < date '1920-01-01' then raise exception 'Fila %: la fecha de nacimiento no es válida.', i; end if;
      insert into players (invited_by, name, rut, birth, email, phone) values (p_club, nm, v_rut, bd, nullif(mail, ''), ph) returning id into pl;
      insert into memberships (player_id, club_id, team_id, sport, status, note, resolved_at)
      values (pl, p_club, p_team, p_sport, 'habil', 'Inscrito por el club', now());
      if mail <> '' then
        insert into club_invites (club_id, kind, player_id, name, email, phone, sport, created_by) values (p_club, 'jugador', pl, nm, mail, ph, p_sport, auth.uid()) returning id into inv;
        ids := ids || inv;
      end if;
    end if;
    added := added + 1;
  end loop;
  perform public._audit('members.add', p_club);
  return jsonb_build_object('added', added, 'invites', to_jsonb(ids));
end $$;

-- ---------------------------------------------------------------------------
-- Envío: solo lo llama la función invitar-socios, con la clave de servicio.
-- p_uid es quien pidió el envío (verificado por la función con su sesión).
-- ---------------------------------------------------------------------------
create function public.invites_to_send(p_uid uuid, p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare res jsonb;
begin
  -- Los permisos se evalúan como quien pidió el envío.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid)::text, true);
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'email', x.email, 'name', x.name, 'club', c.name, 'kind', x.kind, 'sent_count', x.sent_count,
           -- Un reenvío borra el usuario de Auth anterior, solo si nunca creó su cuenta.
           'old_user', case when x.user_id is not null and not exists (select 1 from accounts a where a.user_id = x.user_id) then x.user_id end)), '[]')
    into res
    from club_invites x join clubs c on c.id = x.club_id
   where x.id = any (p_ids) and x.status in ('pendiente', 'enviada', 'error') and public._can_invite(x.club_id);
  perform set_config('request.jwt.claims', '', true);
  return res;
end $$;

create function public.invite_sent(p_id uuid, p_user uuid, p_error text) returns void
language sql security definer set search_path = public, pg_temp as $$
  update club_invites set
    status = case when p_error is null then 'enviada' else 'error' end,
    user_id = coalesce(p_user, case when p_error is null then user_id end),
    error = p_error,
    sent_count = sent_count + case when p_error is null then 1 else 0 end,
    sent_at = case when p_error is null then now() else sent_at end
  where id = p_id and status in ('pendiente', 'enviada', 'error')
$$;

-- ---------------------------------------------------------------------------
-- La persona invitada, con la sesión que trae el enlace del correo
-- ---------------------------------------------------------------------------
create function public.invite_info() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', x.id, 'kind', x.kind, 'name', x.name, 'email', x.email, 'sport', x.sport,
    'club', jsonb_build_object('id', c.id, 'name', c.name, 'short', c.short, 'logo', c.logo, 'color', c.color),
    'rut', p.rut, 'birth', p.birth)
  from club_invites x join clubs c on c.id = x.club_id left join players p on p.id = x.player_id
  where x.user_id = auth.uid() and x.status = 'enviada'
    and not exists (select 1 from accounts a where a.user_id = auth.uid())
  order by x.sent_at desc nulls last limit 1
$$;

create function public.accept_invite(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); x club_invites; pl players; c clubs; pid text; mail text; v_rut text := public._txt(p, 'rut');
begin
  if uid is null then raise exception 'Debes iniciar sesión.'; end if;
  select * into x from club_invites where user_id = uid and status = 'enviada' order by sent_at desc nulls last limit 1 for update;
  if not found then raise exception 'Esta invitación ya no está disponible.'; end if;
  if exists (select 1 from accounts where user_id = uid) then raise exception 'Esta cuenta ya está registrada.'; end if;
  if coalesce((p ->> 'confirm')::boolean, false) is not true then raise exception 'Confirma tu vinculación con el club.'; end if;
  if coalesce((p ->> 'consent')::boolean, false) is not true then raise exception 'Debes aceptar los Términos de uso y la Política de privacidad.'; end if;
  select * into c from clubs where id = x.club_id;
  select lower(email) into mail from auth.users where id = uid;
  if x.kind = 'jugador' then
    select * into pl from players where id = x.player_id for update;
    if not found then raise exception 'El club ya no tiene esta inscripción.'; end if;
    if exists (select 1 from accounts where type = 'jugador' and rut_clean = pl.rut_clean) then raise exception 'Ya existe una cuenta de deportista con ese RUT.'; end if;
    pid := public._next_public_id('D');
    insert into accounts (user_id, public_id, type, name, rut, email, phone, consent_at)
    values (uid, pid, 'jugador', pl.name, pl.rut, mail, coalesce(pl.phone, ''), now());
    update players set account_id = uid, email = mail where id = pl.id;
  else
    if v_rut is null or not public.rut_valido(v_rut) then raise exception 'El RUT no es válido.'; end if;
    if exists (select 1 from accounts where type = 'apoderado' and rut_clean = public.clean_rut(v_rut)) then raise exception 'Ya existe una cuenta de apoderado con ese RUT.'; end if;
    pid := public._next_public_id('A');
    insert into accounts (user_id, public_id, type, name, rut, email, phone, consent_at)
    values (uid, pid, 'apoderado', x.name, v_rut, mail, coalesce(x.phone, ''), now());
    insert into links (account_id, club_id, status, resolved_at) values (uid, x.club_id, 'aceptada', now());
  end if;
  update club_invites set status = 'aceptada', resolved_at = now() where id = x.id;
  perform public._notify(c.owner_id, c.id, x.name || ' activó su cuenta y confirmó su vinculación como ' || case x.kind when 'jugador' then 'deportista' else 'apoderado' end || '.',
    case x.kind when 'jugador' then '/d/jugadores' else '/d/apoderados' end);
  perform public._audit('invite.accept', x.id);
  return jsonb_build_object('publicId', pid);
end $$;

-- "No pertenezco a este club": quita la inscripción, avisa al club y borra el usuario de Auth sin cuenta.
create function public.reject_invite() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); x club_invites; c clubs;
begin
  select * into x from club_invites where user_id = uid and status = 'enviada' order by sent_at desc nulls last limit 1 for update;
  if not found or exists (select 1 from accounts where user_id = uid) then raise exception 'Esta invitación ya no está disponible.'; end if;
  update club_invites set status = 'rechazada', resolved_at = now(), user_id = null where id = x.id;
  if x.kind = 'jugador' then
    delete from memberships where player_id = x.player_id and club_id = x.club_id;
    delete from players p where p.id = x.player_id and p.account_id is null and p.guardian_id is null
      and not exists (select 1 from memberships m where m.player_id = p.id)
      and not exists (select 1 from guardian_links g where g.player_id = p.id);
  end if;
  select * into c from clubs where id = x.club_id;
  perform public._notify(c.owner_id, c.id, x.name || ' indicó que no pertenece al club. Se quitó su inscripción.',
    case x.kind when 'jugador' then '/d/jugadores' else '/d/apoderados' end);
  perform public._audit('invite.reject', x.id);
  delete from auth.users where id = uid;
end $$;

-- ---------------------------------------------------------------------------
-- Estado: agrega las invitaciones que la sesión puede ver (RLS)
-- ---------------------------------------------------------------------------
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
    'names', public.my_directory_players(),
    'fee_months', public.my_fee_months(),
    'surveys', public.my_surveys(),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'club_id', i.club_id, 'kind', i.kind, 'player_id', i.player_id, 'name', i.name,
      'email', i.email, 'phone', i.phone, 'sport', i.sport, 'status', i.status, 'error', i.error, 'sent_count', i.sent_count,
      'sent_at', i.sent_at, 'created_at', i.created_at, 'resolved_at', i.resolved_at) order by i.created_at desc)
      from club_invites i), '[]')
  )
$$;

revoke all on public.club_invites from public, anon, authenticated;
grant select on public.club_invites to authenticated;
revoke execute on function public._can_invite(uuid), public.club_add_members(uuid, text, text, uuid, jsonb), public.invites_to_send(uuid, uuid[]),
  public.invite_sent(uuid, uuid, text), public.invite_info(), public.accept_invite(jsonb), public.reject_invite() from public, anon, authenticated;
grant execute on function public._can_invite(uuid) to authenticated;
grant execute on function public.club_add_members(uuid, text, text, uuid, jsonb), public.invite_info(), public.accept_invite(jsonb), public.reject_invite() to authenticated;
grant execute on function public.invites_to_send(uuid, uuid[]), public.invite_sent(uuid, uuid, text) to service_role;

commit;
