-- My Club · Etapa 1: núcleo operativo
-- Cuentas, clubes, equipos, deportistas, vínculos, incorporaciones y avisos.
--
-- Regla de seguridad: el navegador solo puede LEER lo que RLS le permite.
-- Toda escritura pasa por funciones de este archivo, que validan las reglas
-- de negocio. Nadie tiene INSERT, UPDATE ni DELETE directo sobre las tablas.

begin;

-- ---------------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------------
create function public.clean_rut(r text) returns text
language sql immutable as $$ select upper(regexp_replace(coalesce(r, ''), '[^0-9kK]', '', 'g')) $$;

create function public.rut_valido(r text) returns boolean
language plpgsql immutable as $$
declare
  c text := public.clean_rut(r);
  suma int := 0; factor int := 2; i int; resto int; dv text;
begin
  if c !~ '^[0-9]{7,8}[0-9K]$' then return false; end if;
  for i in reverse length(c) - 1 .. 1 loop
    suma := suma + substr(c, i, 1)::int * factor;
    factor := case when factor = 7 then 2 else factor + 1 end;
  end loop;
  resto := 11 - (suma % 11);
  dv := case resto when 11 then '0' when 10 then 'K' else resto::text end;
  return dv = right(c, 1);
end $$;

create function public._txt(p jsonb, k text) returns text
language sql immutable as $$ select nullif(btrim(p ->> k), '') $$;

-- ---------------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------------
create table public.id_counters (
  letter char(1) primary key,
  value bigint not null default 0
);
insert into public.id_counters (letter) values ('C'), ('D'), ('A'), ('E'), ('F'), ('P');

create table public.accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  public_id text not null unique,
  type text not null check (type in ('club', 'jugador', 'apoderado', 'entrenador', 'federacion', 'proveedor')),
  name text not null check (length(name) between 2 and 160),
  rut text not null,
  rut_clean text generated always as (public.clean_rut(rut)) stored,
  email text not null,
  phone text not null,
  photo text check (photo is null or length(photo) < 500000),
  city text, region text, specialty text, web text, ig text, descr text,
  sport text,
  category text,
  consent_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (type, rut_clean)
);

create table public.clubs (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  owner_id uuid references public.accounts (user_id) on delete set null,
  name text not null check (length(name) between 2 and 160),
  short text not null,
  rut text not null,
  rut_clean text generated always as (public.clean_rut(rut)) stored unique,
  constituted date not null,
  reg_number text not null,
  email text, phone text, address text, city text, region text, web text, ig text, descr text,
  color text not null default '#1F4E79',
  logo text check (logo is null or length(logo) < 500000),
  sports text[] not null default '{}',
  board jsonb not null default '[]',
  created_at timestamptz not null default now()
);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs (id) on delete cascade,
  sport text not null,
  name text not null check (length(name) between 1 and 120),
  category text not null,
  sex text not null,
  coach text not null default 'Por asignar',
  created_at timestamptz not null default now()
);
create index on public.teams (club_id);

-- Un deportista adulto tiene cuenta propia. Un menor no: lo administra su apoderado.
create table public.players (
  id uuid primary key default gen_random_uuid(),
  account_id uuid unique references public.accounts (user_id) on delete cascade,
  guardian_id uuid references public.accounts (user_id) on delete cascade,
  name text not null check (length(name) between 2 and 160),
  rut text not null,
  rut_clean text generated always as (public.clean_rut(rut)) stored unique,
  birth date not null,
  sex text,
  rel text,
  email text, phone text, position text, city text,
  height int check (height is null or height between 50 and 250),
  size text,
  photo text check (photo is null or length(photo) < 500000),
  created_at timestamptz not null default now(),
  check (account_id is not null or guardian_id is not null)
);
create index on public.players (guardian_id);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players (id) on delete cascade,
  club_id uuid not null references public.clubs (id) on delete cascade,
  team_id uuid references public.teams (id) on delete set null,
  sport text not null,
  status text not null default 'pendiente' check (status in ('pendiente', 'habil', 'suspendido', 'rechazada', 'desvinculado')),
  note text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
-- Regla de negocio: un deportista pertenece a un solo club por deporte.
create unique index one_club_per_sport on public.memberships (player_id, sport)
  where status in ('pendiente', 'habil', 'suspendido');
create index on public.memberships (club_id);

create table public.links (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts (user_id) on delete cascade,
  club_id uuid not null references public.clubs (id) on delete cascade,
  status text not null default 'pendiente' check (status in ('pendiente', 'aceptada', 'rechazada')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create unique index one_open_link on public.links (account_id, club_id) where status in ('pendiente', 'aceptada');
create index on public.links (club_id);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts (user_id) on delete cascade,
  club_id uuid references public.clubs (id) on delete set null,
  text text not null,
  href text not null default '/inicio',
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index on public.notifications (account_id, created_at desc);

-- La bitácora conserva el identificador, no datos personales: sobrevive a la eliminación de cuentas.
create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null,
  target uuid,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Datos que nunca cambian: nombre, RUT y fecha de nacimiento o constitución
-- ---------------------------------------------------------------------------
create function public._lock_identity() returns trigger
language plpgsql as $$
begin
  if new.name is distinct from old.name or new.rut is distinct from old.rut then
    raise exception 'El nombre y el RUT no se pueden cambiar.';
  end if;
  if tg_table_name = 'players' then
    if new.birth is distinct from old.birth then raise exception 'La fecha de nacimiento no se puede cambiar.'; end if;
  elsif tg_table_name = 'clubs' then
    if new.constituted is distinct from old.constituted then raise exception 'La fecha de constitución no se puede cambiar.'; end if;
  end if;
  return new;
end $$;
create trigger lock_identity before update on public.accounts for each row execute function public._lock_identity();
create trigger lock_identity before update on public.clubs for each row execute function public._lock_identity();
create trigger lock_identity before update on public.players for each row execute function public._lock_identity();

-- ---------------------------------------------------------------------------
-- Consultas de pertenencia usadas por RLS
-- ---------------------------------------------------------------------------
create function public.is_club_owner(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from clubs where id = c and owner_id = auth.uid())
$$;

create function public.is_my_player(p uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from players where id = p and (account_id = auth.uid() or guardian_id = auth.uid()))
$$;

-- Directorio y entrenadores aceptados: ven a los deportistas del club.
create function public.is_club_staff(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_club_owner(c) or exists (
    select 1 from links l join accounts a on a.user_id = l.account_id
    where l.club_id = c and l.account_id = auth.uid() and l.status = 'aceptada' and a.type = 'entrenador'
  )
$$;

-- Cualquiera con un vínculo o solicitud con el club: ve su ficha y sus equipos.
create function public.is_club_related(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_club_owner(c)
    or exists (select 1 from links where club_id = c and account_id = auth.uid() and status in ('pendiente', 'aceptada'))
    or exists (
      select 1 from memberships m join players p on p.id = m.player_id
      where m.club_id = c and m.status in ('pendiente', 'habil', 'suspendido')
        and (p.account_id = auth.uid() or p.guardian_id = auth.uid())
    )
$$;

create function public.club_sees_account(a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from links l join clubs c on c.id = l.club_id
    where l.account_id = a and c.owner_id = auth.uid() and l.status in ('pendiente', 'aceptada')
  )
$$;

create function public.club_sees_player(p uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from memberships m
    where m.player_id = p and m.status in ('pendiente', 'habil', 'suspendido') and public.is_club_staff(m.club_id)
  )
$$;

-- ---------------------------------------------------------------------------
-- Seguridad por filas: solo lectura
-- ---------------------------------------------------------------------------
alter table public.id_counters enable row level security;
alter table public.accounts enable row level security;
alter table public.clubs enable row level security;
alter table public.teams enable row level security;
alter table public.players enable row level security;
alter table public.memberships enable row level security;
alter table public.links enable row level security;
alter table public.notifications enable row level security;
alter table public.audit_log enable row level security;

create policy account_read on public.accounts for select to authenticated
  using (user_id = auth.uid() or public.club_sees_account(user_id));
create policy club_read on public.clubs for select to authenticated
  using (public.is_club_related(id));
create policy team_read on public.teams for select to authenticated
  using (public.is_club_related(club_id));
create policy player_read on public.players for select to authenticated
  using (public.is_my_player(id) or public.club_sees_player(id));
create policy membership_read on public.memberships for select to authenticated
  using (public.is_my_player(player_id) or public.is_club_staff(club_id));
create policy link_read on public.links for select to authenticated
  using (account_id = auth.uid() or public.is_club_owner(club_id));
create policy notification_read on public.notifications for select to authenticated
  using (account_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Funciones internas (no accesibles desde la app)
-- ---------------------------------------------------------------------------
create function public._next_public_id(l char) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare n bigint;
begin
  update id_counters set value = value + 1 where letter = l returning value into n;
  return l || lpad(n::text, 8, '0');
end $$;

create function public._notify(to_account uuid, c uuid, msg text, ref text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into notifications (account_id, club_id, text, href)
  select to_account, c, msg, coalesce(ref, '/inicio') where to_account is not null
$$;

create function public._audit(what text, target uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into audit_log (actor_id, action, target) values (auth.uid(), what, target)
$$;

create function public._join(p_player uuid, p_club uuid, p_sport text, p_note text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; dup record; t uuid; m uuid; pname text;
begin
  select * into c from clubs where id = p_club;
  if not found then raise exception 'No encontramos ese club.'; end if;
  if not p_sport = any (c.sports) then raise exception '% no tiene habilitado ese deporte.', c.short; end if;
  select name into pname from players where id = p_player;
  select cl.short as club into dup from memberships x join clubs cl on cl.id = x.club_id
   where x.player_id = p_player and x.sport = p_sport and x.status in ('pendiente', 'habil', 'suspendido');
  if found then
    raise exception '% ya pertenece a % en %. Un deportista solo puede estar en un club por deporte.', split_part(pname, ' ', 1), dup.club, p_sport;
  end if;
  select id into t from teams where club_id = p_club and sport = p_sport order by created_at limit 1;
  insert into memberships (player_id, club_id, team_id, sport, note) values (p_player, p_club, t, p_sport, p_note) returning id into m;
  perform public._notify(c.owner_id, p_club, 'Nueva solicitud de incorporación: ' || pname || ' (' || p_sport || ').', '/d/solicitudes');
  perform public._audit('membership.request', m);
  return m;
end $$;

create function public._link(p_account uuid, p_club uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; a accounts; r uuid;
begin
  select * into a from accounts where user_id = p_account;
  if a.type not in ('apoderado', 'entrenador') then raise exception 'Este tipo de cuenta no se vincula a un club por esta vía.'; end if;
  select * into c from clubs where id = p_club;
  if not found then raise exception 'No encontramos ese club.'; end if;
  if exists (select 1 from links where account_id = p_account and club_id = p_club and status = 'aceptada') then raise exception 'Ya estás vinculado a este club.'; end if;
  if exists (select 1 from links where account_id = p_account and club_id = p_club and status = 'pendiente') then raise exception 'Ya enviaste una solicitud a este club.'; end if;
  insert into links (account_id, club_id) values (p_account, p_club) returning id into r;
  perform public._notify(c.owner_id, p_club, a.name || ' pide vincularse a ' || c.short || '.', '/d/solicitudes');
  perform public._audit('link.request', r);
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- Funciones públicas
-- ---------------------------------------------------------------------------

-- Búsqueda por ID: la única forma de ver un club sin estar vinculado. Entrega lo mínimo.
create function public.find_club(p_code text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', id, 'code', code, 'name', name, 'short', short, 'sports', to_jsonb(sports))
  from clubs where code = upper(btrim(p_code))
$$;

-- Todo lo que la sesión puede ver. Corre con los permisos del usuario: manda RLS.
create function public.my_state() returns jsonb
language sql stable security invoker set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'account', (select to_jsonb(a) from accounts a where a.user_id = auth.uid()),
    'accounts', coalesce((select jsonb_agg(to_jsonb(a) - 'rut_clean') from accounts a), '[]'),
    'clubs', coalesce((select jsonb_agg(to_jsonb(c) - 'rut_clean') from clubs c), '[]'),
    'teams', coalesce((select jsonb_agg(to_jsonb(t)) from teams t), '[]'),
    'players', coalesce((select jsonb_agg(to_jsonb(p) - 'rut_clean') from players p), '[]'),
    'memberships', coalesce((select jsonb_agg(to_jsonb(m)) from memberships m), '[]'),
    'links', coalesce((select jsonb_agg(to_jsonb(l)) from links l), '[]'),
    'notifications', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (select * from notifications order by created_at desc limit 100) n), '[]')
  )
$$;

-- Completa el registro tras crear el usuario en Auth. El email viene de Auth, no del cliente.
create function public.register_account(p jsonb) returns jsonb
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
    if age((p ->> 'birth')::date) < interval '18 years' then raise exception 'Los menores de edad solo pueden ser registrados por su apoderado.'; end if;
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

-- Solo toca datos editables. Nombre, RUT y fechas ni siquiera se leen del parámetro.
create function public.update_profile(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); a accounts; brd jsonb; mail text := public._txt(p, 'email'); ph text := public._txt(p, 'phone');
begin
  select * into a from accounts where user_id = uid;
  if not found then raise exception 'Debes iniciar sesión.'; end if;
  if mail is null or mail !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'El email no es válido.'; end if;
  if ph is null then raise exception 'Indica un teléfono.'; end if;
  update accounts set email = lower(mail), phone = ph, city = public._txt(p, 'city'), region = public._txt(p, 'region'),
         specialty = public._txt(p, 'specialty'), web = public._txt(p, 'web'), ig = public._txt(p, 'ig'), descr = public._txt(p, 'desc')
   where user_id = uid;
  if a.type = 'jugador' then
    update players set email = lower(mail), phone = ph, height = nullif(p ->> 'height', '')::int, size = public._txt(p, 'size'),
           position = public._txt(p, 'position'), city = public._txt(p, 'city')
     where account_id = uid;
  elsif a.type = 'club' then
    select coalesce(jsonb_agg(jsonb_build_object('cargo', btrim(x ->> 'cargo'), 'name', btrim(x ->> 'name'))), '[]') into brd
      from jsonb_array_elements(coalesce(p -> 'board', '[]')) x
     where coalesce(btrim(x ->> 'cargo'), '') <> '' and coalesce(btrim(x ->> 'name'), '') <> '';
    if jsonb_array_length(brd) < 3 then raise exception 'El directorio requiere mínimo 3 cargos con nombre.'; end if;
    update clubs set email = lower(mail), phone = ph, reg_number = coalesce(public._txt(p, 'regNumber'), reg_number),
           address = public._txt(p, 'address'), city = public._txt(p, 'city'), region = public._txt(p, 'region'),
           web = public._txt(p, 'web'), ig = public._txt(p, 'ig'), descr = public._txt(p, 'desc'), board = brd
     where owner_id = uid;
  end if;
  perform public._audit('account.update', uid);
end $$;

-- Foto de perfil o logo del club. Solo imágenes generadas por la app.
create function public.set_photo(p_data text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); t text;
begin
  select type into t from accounts where user_id = uid;
  if t is null then raise exception 'Debes iniciar sesión.'; end if;
  if p_data is not null and p_data !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$' then raise exception 'Formato de imagen no válido.'; end if;
  if length(p_data) >= 500000 then raise exception 'La imagen es demasiado grande.'; end if;
  if t = 'club' then update clubs set logo = p_data where owner_id = uid;
  elsif t = 'jugador' then update players set photo = p_data where account_id = uid;
  else update accounts set photo = p_data where user_id = uid;
  end if;
end $$;

create function public.add_sport(p_sport text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if coalesce(btrim(p_sport), '') = '' or length(p_sport) > 40 then raise exception 'Deporte no válido.'; end if;
  update clubs set sports = case when p_sport = any (sports) then sports else sports || p_sport end where owner_id = auth.uid();
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
end $$;

create function public.add_team(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; v_id uuid; sp text := public._txt(p, 'sport');
begin
  select * into c from clubs where owner_id = auth.uid();
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
  if public._txt(p, 'name') is null then raise exception 'Escribe un nombre.'; end if;
  if not sp = any (c.sports) then raise exception 'Primero agrega ese deporte al club.'; end if;
  insert into teams (club_id, sport, name, category, sex, coach)
  values (c.id, sp, public._txt(p, 'name'), coalesce(public._txt(p, 'category'), 'Todo competidor'), coalesce(public._txt(p, 'sex'), 'Mixto'), coalesce(public._txt(p, 'coach'), 'Por asignar'))
  returning id into v_id;
  return v_id;
end $$;

create function public.set_team_coach(p_team uuid, p_coach text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if coalesce(btrim(p_coach), '') = '' then raise exception 'Escribe un nombre.'; end if;
  update teams t set coach = btrim(p_coach) where t.id = p_team and public.is_club_owner(t.club_id);
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
end $$;

create function public.request_link(p_club uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  return public._link(auth.uid(), p_club);
end $$;

create function public.resolve_link(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l links; c clubs;
begin
  select * into l from links where id = p_id for update;
  if not found or not public.is_club_owner(l.club_id) then raise exception 'Solo el club puede resolver esta solicitud.'; end if;
  if l.status <> 'pendiente' then raise exception 'Esta solicitud ya fue resuelta.'; end if;
  update links set status = case when p_ok then 'aceptada' else 'rechazada' end, resolved_at = now() where id = p_id;
  select * into c from clubs where id = l.club_id;
  perform public._notify(l.account_id, l.club_id, c.short || case when p_ok then ' aceptó' else ' rechazó' end || ' tu vinculación.', '/inicio');
  perform public._audit('link.resolve', p_id);
end $$;

create function public.request_join(p_player uuid, p_club uuid, p_sport text, p_note text default '') returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_my_player(p_player) then raise exception 'Solo puedes solicitar la incorporación tuya o de tus pupilos.'; end if;
  return public._join(p_player, p_club, p_sport, p_note);
end $$;

create function public.resolve_join(p_id uuid, p_ok boolean) returns void
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
  perform public._audit('membership.resolve', p_id);
end $$;

-- Regla de negocio: un menor solo lo registra su apoderado.
create function public.register_kid(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); nm text := public._txt(p, 'name'); v_rut text := public._txt(p, 'rut'); pl uuid; cl uuid := nullif(p ->> 'clubId', '')::uuid;
begin
  if not exists (select 1 from accounts where user_id = uid and type = 'apoderado') then raise exception 'Solo el apoderado puede registrar a un menor de edad.'; end if;
  if nm is null or v_rut is null or public._txt(p, 'birth') is null then raise exception 'Completa nombre, RUT y fecha de nacimiento.'; end if;
  if not public.rut_valido(v_rut) then raise exception 'El RUT no es válido.'; end if;
  if exists (select 1 from players where rut_clean = public.clean_rut(v_rut)) then raise exception 'Ya existe un deportista con ese RUT.'; end if;
  if age((p ->> 'birth')::date) >= interval '18 years' then raise exception 'Solo los menores de 18 años se registran por apoderado. Un adulto se registra por sí mismo.'; end if;
  insert into players (guardian_id, name, rut, birth, sex, rel)
  values (uid, nm, v_rut, (p ->> 'birth')::date, public._txt(p, 'sex'), public._txt(p, 'rel')) returning id into pl;
  if cl is not null then perform public._join(pl, cl, public._txt(p, 'sport'), 'Registrado por su apoderado'); end if;
  perform public._audit('player.register', pl);
  return pl;
end $$;

create function public.mark_notifs_read(p_id uuid default null) returns void
language sql security definer set search_path = public, pg_temp as $$
  update notifications set read = true where account_id = auth.uid() and (p_id is null or id = p_id)
$$;

-- Exigido por App Store y Google Play. Un club con deportistas activos sigue existiendo
-- sin administrador, porque sus integrantes dependen de él; sin ellos, se borra.
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Debes iniciar sesión.'; end if;
  delete from clubs c where c.owner_id = uid and not exists (
    select 1 from memberships m where m.club_id = c.id and m.status in ('habil', 'suspendido')
  );
  perform public._audit('account.delete', uid);
  delete from auth.users where id = uid;
end $$;

-- ---------------------------------------------------------------------------
-- Permisos: se declaran explícitos, sin depender de los valores por defecto
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

grant usage on schema public to anon, authenticated;
grant select on public.accounts, public.clubs, public.teams, public.players, public.memberships, public.links, public.notifications to authenticated;

-- Las políticas de RLS las evalúan con el rol del usuario.
grant execute on function
  public.is_club_owner(uuid), public.is_my_player(uuid), public.is_club_staff(uuid), public.is_club_related(uuid),
  public.club_sees_account(uuid), public.club_sees_player(uuid), public.clean_rut(text)
to authenticated;

grant execute on function public.find_club(text) to anon, authenticated;
grant execute on function
  public.my_state(), public.register_account(jsonb), public.update_profile(jsonb), public.set_photo(text),
  public.add_sport(text), public.add_team(jsonb), public.set_team_coach(uuid, text),
  public.request_link(uuid), public.resolve_link(uuid, boolean),
  public.request_join(uuid, uuid, text, text), public.resolve_join(uuid, boolean),
  public.register_kid(jsonb), public.mark_notifs_read(uuid), public.delete_my_account()
to authenticated;

commit;
