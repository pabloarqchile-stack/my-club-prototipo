-- My Club · Nivel Master (administración de la plataforma)
-- Solo existe en modo real. Se entra con el email y la clave de Supabase Auth de una persona que figure en
-- platform_admins. El dueño (owner) tiene todos los accesos y no se puede quitar ni desactivar desde la app;
-- se agrega a mano en SQL Editor (ver supabase/CONFIGURAR_MASTER.md), nunca en este archivo.
-- Modelo de cobro: cada club paga al mes por deportista hábil (Chile en pesos, resto del mundo en dólares),
-- con promociones generales y descuentos por club. Ingresos y egresos de My Club se registran a mano.
-- Estado de cada club según sus mensualidades a My Club (un club inactivo solo ve y paga), formas de pago y pagos informados.
-- Las tablas no tienen acceso directo: todo pasa por master_me, master_data, master_save, master_delete, club_billing y club_report_payment.
begin;

alter table public.clubs add column country text not null default 'CL' check (country ~ '^[A-Z]{2}$');

create table public.platform_admins (
  email text primary key check (email = lower(email) and email ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'),
  name text not null default '' check (length(name) <= 160),
  owner boolean not null default false,
  perms text[] not null default '{}',
  active boolean not null default true,
  created_by text,
  created_at timestamptz not null default now()
);

create table public.platform_settings (
  id int primary key default 1 check (id = 1),
  price_clp int not null default 1000 check (price_clp between 0 and 10000000),
  price_usd numeric(10, 2) not null default 1 check (price_usd between 0 and 100000),
  updated_at timestamptz not null default now()
);
insert into public.platform_settings default values;

create table public.platform_discounts (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs (id) on delete cascade,
  kind text not null check (kind in ('pct', 'monto')),
  value numeric(12, 2) not null check (value > 0),
  starts date not null,
  ends date,
  note text check (length(note) <= 300),
  active boolean not null default true,
  created_by text,
  created_at timestamptz not null default now(),
  check (kind <> 'pct' or value <= 100),
  check (ends is null or ends >= starts)
);

create table public.platform_promos (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 2 and 120),
  kind text not null check (kind in ('pct', 'meses')),
  value numeric(6, 2) not null check (value > 0),
  scope text not null default 'todos' check (scope in ('todos', 'CL', 'intl')),
  starts date not null,
  ends date,
  active boolean not null default true,
  created_by text,
  created_at timestamptz not null default now(),
  check (kind <> 'pct' or value <= 100),
  check (kind <> 'meses' or (value <= 24 and value = round(value))),
  check (ends is null or ends >= starts)
);

create table public.platform_moves (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('ingreso', 'egreso')),
  date date not null,
  amount numeric(14, 2) not null check (amount > 0),
  currency text not null default 'CLP' check (currency in ('CLP', 'USD')),
  category text not null check (length(category) between 2 and 60),
  club_id uuid references public.clubs (id) on delete set null,
  period text check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  description text check (length(description) <= 300),
  created_by text,
  created_at timestamptz not null default now()
);

-- Estado del club ante My Club: 'auto' sigue los meses impagos (igual que un deportista: 0 a 2 activo,
-- 3 a 4 en revisión, 5 o más inactivo); 'activo' e 'inactivo' los fija a mano el dueño de My Club.
alter table public.clubs add column platform_status text not null default 'auto' check (platform_status in ('auto', 'activo', 'inactivo'));
-- Desde qué mes se cobra: no se cobran meses anteriores a la puesta en marcha del modelo.
alter table public.platform_settings add column billing_start date not null default date_trunc('month', now())::date;

-- Cobro mensual de My Club a cada club. El del mes en curso se recalcula mientras no tenga pagos.
create table public.platform_charges (
  club_id uuid not null references public.clubs (id) on delete cascade,
  period date not null check (extract(day from period) = 1),
  amount numeric(14, 2) not null check (amount >= 0),
  currency text not null check (currency in ('CLP', 'USD')),
  active_players int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (club_id, period)
);

-- Formas de pago con que los clubes pagan a My Club. Se van agregando desde el panel Master.
create table public.platform_pay_methods (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('transferencia', 'link', 'otro')),
  name text not null check (length(name) between 2 and 80),
  data jsonb not null default '{}' check (pg_column_size(data) < 4000),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Pago que el club informa (transferencia, link de pago, etc.). My Club lo confirma o lo rechaza.
create table public.platform_reports (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs (id) on delete cascade,
  periods date[] not null check (cardinality(periods) between 1 and 36),
  amount numeric(14, 2) not null check (amount > 0),
  currency text not null check (currency in ('CLP', 'USD')),
  method text check (length(method) <= 80),
  reference text check (length(reference) <= 120),
  status text not null default 'pendiente' check (status in ('pendiente', 'confirmado', 'rechazado')),
  note text check (length(note) <= 300),
  created_by uuid,
  created_at timestamptz not null default now(),
  resolved_by text,
  resolved_at timestamptz
);

alter table public.platform_admins enable row level security;
alter table public.platform_settings enable row level security;
alter table public.platform_discounts enable row level security;
alter table public.platform_promos enable row level security;
alter table public.platform_moves enable row level security;
alter table public.platform_charges enable row level security;
alter table public.platform_pay_methods enable row level security;
alter table public.platform_reports enable row level security;
revoke all on public.platform_admins, public.platform_settings, public.platform_discounts, public.platform_promos, public.platform_moves,
  public.platform_charges, public.platform_pay_methods, public.platform_reports from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Cobro mensual y estado de cada club
-- ---------------------------------------------------------------------------
create function public._platform_paid(c uuid, per date, cur text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(amount), 0) from platform_moves
  where kind = 'ingreso' and club_id = c and period = to_char(per, 'YYYY-MM') and currency = cur
$$;

-- Deportistas hábiles × tarifa, menos la mejor promoción vigente y después los descuentos del club (en orden de creación).
create function public._platform_amount(c public.clubs, per date) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  st platform_settings; act int; pct numeric; tot numeric; d platform_discounts;
  fin date := (per + interval '1 month - 1 day')::date; cur text := case when c.country = 'CL' then 'CLP' else 'USD' end;
  meses int := (extract(year from per)::int - extract(year from c.created_at)::int) * 12 + extract(month from per)::int - extract(month from c.created_at)::int;
begin
  select * into st from platform_settings where id = 1;
  select count(distinct player_id) into act from memberships where club_id = c.id and status = 'habil';
  select coalesce(max(case
      when p.kind = 'pct' and p.starts <= fin and (p.ends is null or p.ends >= per) then p.value
      when p.kind = 'meses' and c.created_at::date >= p.starts and (p.ends is null or c.created_at::date <= p.ends) and meses between 0 and p.value - 1 then 100
      else 0 end), 0) into pct
    from platform_promos p
    where p.active and (p.scope = 'todos' or (p.scope = 'CL' and c.country = 'CL') or (p.scope = 'intl' and c.country <> 'CL'));
  tot := act * (case when cur = 'CLP' then st.price_clp else st.price_usd end) * (1 - pct / 100);
  for d in select * from platform_discounts x where x.club_id = c.id and x.active and x.starts <= fin and (x.ends is null or x.ends >= per) order by x.created_at loop
    tot := case when d.kind = 'pct' then tot * (1 - d.value / 100) else tot - d.value end;
  end loop;
  return greatest(0, case when cur = 'CLP' then round(tot) else round(tot, 2) end);
end $$;

-- Crea los cobros que faltan desde el inicio del cobro (o el alta del club) hasta este mes.
create function public._platform_bill(p_club uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; st platform_settings; per date; mes date := date_trunc('month', current_date)::date; act int; cur text;
begin
  select * into st from platform_settings where id = 1;
  for c in select * from clubs where p_club is null or id = p_club loop
    per := greatest(st.billing_start, date_trunc('month', c.created_at)::date);
    cur := case when c.country = 'CL' then 'CLP' else 'USD' end;
    select count(distinct player_id) into act from memberships where club_id = c.id and status = 'habil';
    while per <= mes loop
      insert into platform_charges (club_id, period, amount, currency, active_players)
      values (c.id, per, public._platform_amount(c, per), cur, act)
      on conflict (club_id, period) do update set amount = excluded.amount, currency = excluded.currency, active_players = excluded.active_players, updated_at = now()
        where platform_charges.period = mes and public._platform_paid(platform_charges.club_id, platform_charges.period, platform_charges.currency) = 0;
      per := (per + interval '1 month')::date;
    end loop;
  end loop;
end $$;

-- Meses vencidos sin pagar completos (cada cobro vence el último día de su mes).
create function public._club_owed(c uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int from platform_charges ch
  where ch.club_id = c and ch.amount > 0 and (ch.period + interval '1 month')::date <= current_date
    and public._platform_paid(ch.club_id, ch.period, ch.currency) < ch.amount
$$;

create function public._club_state(c uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case cl.platform_status when 'activo' then 'activo' when 'inactivo' then 'inactivo'
    else (select case when n >= 5 then 'inactivo' when n >= 3 then 'revision' else 'activo' end from (select public._club_owed(c) n) x) end
  from clubs cl where cl.id = c
$$;

-- Un club inactivo solo ve y paga su mensualidad: se rechaza cualquier cambio que hagan su cuenta, sus directivos o sus
-- entrenadores en datos de ese club. Deportistas, apoderados, el panel Master y los procesos del servidor no se bloquean.
create function public._club_inactive_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  j jsonb := case when tg_op = 'DELETE' then '{}'::jsonb else to_jsonb(new) end;
  o jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  cs uuid[];
begin
  if auth.uid() is null or (tg_table_name = 'clubs' and tg_op = 'DELETE') then return coalesce(new, old); end if;
  if tg_table_name = 'records' then
    select coalesce(array_agg(distinct x::uuid), '{}') into cs from jsonb_array_elements_text(coalesce(j -> 'club_ids', '[]') || coalesce(o -> 'club_ids', '[]')) x;
  elsif tg_table_name = 'clubs' then
    cs := array[coalesce(j ->> 'id', o ->> 'id')::uuid];
  else
    cs := array_remove(array[(j ->> 'club_id')::uuid, (o ->> 'club_id')::uuid], null);
  end if;
  if exists (select 1 from unnest(cs) x where public._club_state(x) = 'inactivo'
             and (public._club_can(x, null) or public._club_coach(x, auth.uid()) is not null)) then
    raise exception 'Tu club está inactivo: solo puedes ver y pagar la mensualidad de My Club.';
  end if;
  return coalesce(new, old);
end $$;
create trigger club_inactive_guard before insert or update or delete on public.records for each row execute function public._club_inactive_guard();
create trigger club_inactive_guard before insert or update or delete on public.memberships for each row execute function public._club_inactive_guard();
create trigger club_inactive_guard before insert or update or delete on public.teams for each row execute function public._club_inactive_guard();
create trigger club_inactive_guard before update or delete on public.clubs for each row execute function public._club_inactive_guard();
create trigger club_inactive_guard before insert or update or delete on public.club_directors for each row execute function public._club_inactive_guard();
create trigger club_inactive_guard before insert or update or delete on public.club_invites for each row execute function public._club_inactive_guard();
create trigger club_inactive_guard before insert or update or delete on public.links for each row execute function public._club_inactive_guard();
create trigger club_inactive_guard before insert or update or delete on public.surveys for each row execute function public._club_inactive_guard();
create trigger club_inactive_guard before insert or update or delete on public.staff_docs for each row execute function public._club_inactive_guard();
create trigger club_inactive_guard before insert or update or delete on public.club_pay_keys for each row execute function public._club_inactive_guard();

-- Lo que ve la cuenta del club (o un directivo): su estado, sus cobros, las formas de pago y sus pagos informados.
create function public.club_billing() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid := public._my_club(); cl clubs;
begin
  if c is null then return null; end if;
  perform public._platform_bill(c);
  select * into cl from clubs where id = c;
  return jsonb_build_object('club', c, 'state', public._club_state(c), 'manual', cl.platform_status, 'owed', public._club_owed(c),
    'canPay', public._club_can(c, 'finanzas'),
    'charges', (select coalesce(jsonb_agg(jsonb_build_object('period', to_char(ch.period, 'YYYY-MM'), 'amount', ch.amount, 'currency', ch.currency,
        'players', ch.active_players, 'paid', public._platform_paid(ch.club_id, ch.period, ch.currency)) order by ch.period desc), '[]')
      from platform_charges ch where ch.club_id = c),
    'methods', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'name', m.name, 'data', m.data) order by m.created_at), '[]')
      from platform_pay_methods m where m.active),
    'reports', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'periods', r.periods, 'amount', r.amount, 'currency', r.currency, 'method', r.method,
        'reference', r.reference, 'status', r.status, 'note', r.note, 'date', r.created_at::date) order by r.created_at desc), '[]')
      from (select * from platform_reports where club_id = c order by created_at desc limit 24) r));
end $$;

-- El club informa que pagó uno o más meses. My Club lo confirma en el panel Master.
create function public.club_report_payment(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid := public._my_club(); per date[]; n int; tot numeric; curs text[]; v_id uuid;
begin
  if c is null or not public._club_can(c, 'finanzas') then raise exception 'Solo la cuenta del club o un directivo de finanzas puede informar pagos.'; end if;
  select coalesce(array_agg(distinct (x || '-01')::date), '{}') into per
    from jsonb_array_elements_text(coalesce(p -> 'periods', '[]')) x where x ~ '^[0-9]{4}-(0[1-9]|1[0-2])$';
  if cardinality(per) = 0 then raise exception 'Elige qué meses pagas.'; end if;
  select count(*), sum(ch.amount - public._platform_paid(ch.club_id, ch.period, ch.currency)), array_agg(distinct ch.currency)
    into n, tot, curs
    from platform_charges ch where ch.club_id = c and ch.period = any (per) and public._platform_paid(ch.club_id, ch.period, ch.currency) < ch.amount;
  if n <> cardinality(per) then raise exception 'Alguno de esos meses no tiene saldo por pagar.'; end if;
  if cardinality(curs) > 1 then raise exception 'Paga por separado los meses en pesos y en dólares.'; end if;
  if exists (select 1 from platform_reports r where r.club_id = c and r.status = 'pendiente' and r.periods && per) then
    raise exception 'Ya informaste el pago de alguno de esos meses: espera la confirmación de My Club.';
  end if;
  insert into platform_reports (club_id, periods, amount, currency, method, reference, created_by)
  values (c, per, tot, curs[1], left(public._m_txt(p, 'method'), 80), left(public._m_txt(p, 'reference'), 120), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- Accesos que se activan o desactivan a cada usuario Master.
create function public._master_perms() returns text[] language sql immutable as $$
  select array['cuentas', 'finanzas', 'tarifas', 'descuentos', 'promociones', 'usuarios']
$$;

-- La fila de quien llama, solo si está activa. El email sale de Supabase Auth, no de lo que envía la app.
create function public._master_row() returns public.platform_admins
language sql stable security definer set search_path = public, pg_temp as $$
  select a.* from platform_admins a
  where a.active and a.email = (select lower(u.email) from auth.users u where u.id = auth.uid())
$$;

create function public._master_can(p text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select r.owner or p = any (r.perms) from public._master_row() r where r.email is not null), false)
$$;

create function public._master_need(p text) returns public.platform_admins
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r platform_admins;
begin
  r := public._master_row();
  if r.email is null then raise exception 'No tienes acceso al panel Master.'; end if;
  if not (r.owner or p = any (r.perms)) then raise exception 'No tienes acceso a esta función del panel Master.'; end if;
  return r;
end $$;

create function public.master_me() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select case when r.email is null then null else jsonb_build_object(
    'email', r.email, 'name', r.name, 'owner', r.owner,
    'perms', case when r.owner then to_jsonb(public._master_perms()) else to_jsonb(r.perms) end,
    'account', exists (select 1 from accounts a where a.user_id = auth.uid())) end
  from public._master_row() r
$$;

-- Todo lo que el panel muestra, según los accesos de quien llama.
create function public.master_data() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r platform_admins; out jsonb; mes date := date_trunc('month', now())::date;
begin
  r := public._master_row();
  if r.email is null then raise exception 'No tienes acceso al panel Master.'; end if;
  perform public._platform_bill();
  out := jsonb_build_object('me', public.master_me(), 'settings', (select to_jsonb(s) from platform_settings s where id = 1));

  if public._master_can('cuentas') then
    out := out || jsonb_build_object('counts', jsonb_build_object(
      'types', coalesce((select jsonb_object_agg(t, jsonb_build_object('total', n, 'mes', m)) from (
        select type t, count(*) n, count(*) filter (where created_at >= mes) m from accounts group by type) x), '{}'),
      'players', (select count(*) from players),
      'players_mes', (select count(*) from players where created_at >= mes),
      'active', (select count(distinct player_id) from memberships where status = 'habil'),
      'pending_invites', (select count(*) from club_invites where status in ('pendiente', 'enviada', 'error'))));
  end if;

  if public._master_can('cuentas') or public._master_can('finanzas') or public._master_can('descuentos') or public._master_can('tarifas') then
    out := out || jsonb_build_object('clubs', coalesce((select jsonb_agg(jsonb_build_object(
      'id', c.id, 'code', c.code, 'name', c.name, 'short', c.short, 'country', c.country, 'region', c.region, 'city', c.city,
      'email', c.email, 'logo', c.logo, 'created', c.created_at::date, 'sports', c.sports,
      'active', (select count(distinct m.player_id) from memberships m where m.club_id = c.id and m.status = 'habil'),
      'players', (select count(distinct m.player_id) from memberships m where m.club_id = c.id and m.status in ('habil', 'suspendido')),
      'state', public._club_state(c.id), 'manual', c.platform_status, 'owed', public._club_owed(c.id)
    ) order by c.created_at) from clubs c), '[]'));
    out := out || jsonb_build_object('charges', coalesce((select jsonb_agg(jsonb_build_object('club_id', ch.club_id, 'period', to_char(ch.period, 'YYYY-MM'),
      'amount', ch.amount, 'currency', ch.currency, 'players', ch.active_players, 'paid', public._platform_paid(ch.club_id, ch.period, ch.currency)) order by ch.period desc)
      from platform_charges ch where ch.period >= (mes - interval '23 months')), '[]'));
  end if;

  if public._master_can('finanzas') then
    out := out || jsonb_build_object('reports', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'club_id', x.club_id, 'periods', x.periods,
      'amount', x.amount, 'currency', x.currency, 'method', x.method, 'reference', x.reference, 'status', x.status, 'note', x.note,
      'date', x.created_at::date, 'resolved_by', x.resolved_by) order by x.created_at desc)
      from (select * from platform_reports order by created_at desc limit 200) x), '[]'));
  end if;
  if public._master_can('tarifas') or public._master_can('finanzas') then
    out := out || jsonb_build_object('methods', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from platform_pay_methods m), '[]'));
  end if;

  if public._master_can('finanzas') or public._master_can('descuentos') or public._master_can('promociones') then
    out := out || jsonb_build_object(
      'discounts', coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at desc) from platform_discounts d), '[]'),
      'promos', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from platform_promos p), '[]'));
  end if;

  if public._master_can('finanzas') then
    out := out || jsonb_build_object('moves', coalesce((select jsonb_agg(to_jsonb(m) order by m.date desc, m.created_at desc)
      from platform_moves m where m.date >= (mes - interval '23 months')), '[]'));
  end if;

  if public._master_can('usuarios') then
    out := out || jsonb_build_object('admins', coalesce((select jsonb_agg(jsonb_build_object(
      'email', a.email, 'name', a.name, 'owner', a.owner, 'perms', a.perms, 'active', a.active, 'created', a.created_at::date,
      'hasUser', exists (select 1 from auth.users u where lower(u.email) = a.email)) order by a.owner desc, a.created_at) from platform_admins a), '[]'));
  end if;
  return out;
end $$;

create function public._m_txt(p jsonb, k text) returns text language sql immutable as $$
  select nullif(btrim(p ->> k), '')
$$;
create function public._m_date(p jsonb, k text) returns date language plpgsql immutable as $$
begin
  if public._m_txt(p, k) is null then return null; end if;
  return (p ->> k)::date;
exception when others then raise exception 'La fecha no es válida.';
end $$;
create function public._m_num(p jsonb, k text) returns numeric language plpgsql immutable as $$
begin
  return (p ->> k)::numeric;
exception when others then raise exception 'El monto no es válido.';
end $$;

-- p_kind: tarifas, pais, descuento, promocion, movimiento, usuario. Devuelve el id guardado.
create function public.master_save(p_kind text, p jsonb) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r platform_admins; v_id uuid := case when public._m_txt(p, 'id') ~ '^[0-9a-f-]{36}$' then (p ->> 'id')::uuid end;
  v_num numeric; v_txt text; v_per text[]; v_old platform_admins; v_mail text;
  v_rep platform_reports; v_ch record; v_left numeric; v_pay numeric; v_owner uuid; v_data jsonb; v_last date;
begin
  if p_kind = 'tarifas' then
    r := public._master_need('tarifas');
    if public._m_num(p, 'price_clp') is null or public._m_num(p, 'price_usd') is null then raise exception 'Indica ambas tarifas.'; end if;
    update platform_settings set price_clp = round(public._m_num(p, 'price_clp')), price_usd = round(public._m_num(p, 'price_usd'), 2), updated_at = now() where id = 1;
    return '1';

  elsif p_kind = 'pais' then
    r := public._master_need('tarifas');
    v_txt := upper(coalesce(public._m_txt(p, 'country'), ''));
    if v_txt !~ '^[A-Z]{2}$' then raise exception 'Elige un país.'; end if;
    update clubs set country = v_txt where id = v_id;
    if not found then raise exception 'No encontramos ese club.'; end if;
    return v_id::text;

  elsif p_kind = 'descuento' then
    r := public._master_need('descuentos');
    if not exists (select 1 from clubs where id = public._m_txt(p, 'club_id')::uuid) then raise exception 'Elige un club.'; end if;
    if v_id is null then
      insert into platform_discounts (club_id, kind, value, starts, ends, note, active, created_by)
      values ((p ->> 'club_id')::uuid, p ->> 'kind', public._m_num(p, 'value'), coalesce(public._m_date(p, 'starts'), current_date),
              public._m_date(p, 'ends'), public._m_txt(p, 'note'), coalesce((p ->> 'active')::boolean, true), r.email) returning id into v_id;
    else
      update platform_discounts set kind = p ->> 'kind', value = public._m_num(p, 'value'), starts = coalesce(public._m_date(p, 'starts'), starts),
        ends = public._m_date(p, 'ends'), note = public._m_txt(p, 'note'), active = coalesce((p ->> 'active')::boolean, active) where id = v_id;
      if not found then raise exception 'No encontramos ese descuento.'; end if;
    end if;
    return v_id::text;

  elsif p_kind = 'promocion' then
    r := public._master_need('promociones');
    if v_id is null then
      insert into platform_promos (name, kind, value, scope, starts, ends, active, created_by)
      values (public._m_txt(p, 'name'), p ->> 'kind', public._m_num(p, 'value'), coalesce(p ->> 'scope', 'todos'),
              coalesce(public._m_date(p, 'starts'), current_date), public._m_date(p, 'ends'), coalesce((p ->> 'active')::boolean, true), r.email) returning id into v_id;
    else
      update platform_promos set name = public._m_txt(p, 'name'), kind = p ->> 'kind', value = public._m_num(p, 'value'), scope = coalesce(p ->> 'scope', scope),
        starts = coalesce(public._m_date(p, 'starts'), starts), ends = public._m_date(p, 'ends'), active = coalesce((p ->> 'active')::boolean, active) where id = v_id;
      if not found then raise exception 'No encontramos esa promoción.'; end if;
    end if;
    return v_id::text;

  elsif p_kind = 'movimiento' then
    r := public._master_need('finanzas');
    if public._m_txt(p, 'club_id') is not null and not exists (select 1 from clubs where id = (p ->> 'club_id')::uuid) then raise exception 'Ese club no existe.'; end if;
    if v_id is null then
      insert into platform_moves (kind, date, amount, currency, category, club_id, period, description, created_by)
      values (p ->> 'kind', coalesce(public._m_date(p, 'date'), current_date), public._m_num(p, 'amount'), coalesce(p ->> 'currency', 'CLP'),
              coalesce(public._m_txt(p, 'category'), 'Otro'), public._m_txt(p, 'club_id')::uuid, public._m_txt(p, 'period'), public._m_txt(p, 'description'), r.email)
      returning id into v_id;
    else
      update platform_moves set kind = p ->> 'kind', date = coalesce(public._m_date(p, 'date'), date), amount = public._m_num(p, 'amount'),
        currency = coalesce(p ->> 'currency', currency), category = coalesce(public._m_txt(p, 'category'), category), club_id = public._m_txt(p, 'club_id')::uuid,
        period = public._m_txt(p, 'period'), description = public._m_txt(p, 'description') where id = v_id;
      if not found then raise exception 'No encontramos ese movimiento.'; end if;
    end if;
    return v_id::text;

  elsif p_kind = 'estado' then
    -- Solo el dueño de My Club activa o inactiva clubes.
    r := public._master_need('cuentas');
    if not r.owner then raise exception 'Solo el dueño de My Club puede cambiar el estado de un club.'; end if;
    v_txt := coalesce(public._m_txt(p, 'status'), '');
    if v_txt not in ('auto', 'activo', 'inactivo') then raise exception 'Estado no válido.'; end if;
    update clubs set platform_status = v_txt where id = v_id returning owner_id into v_owner;
    if not found then raise exception 'No encontramos ese club.'; end if;
    perform public._notify(v_owner, v_id, case public._club_state(v_id)
      when 'activo' then 'My Club activó tu club. Ya puedes usar todas las funciones.'
      when 'revision' then 'Tu club está en revisión por mensualidades de My Club impagas.'
      else 'Tu club quedó inactivo: solo puedes ver y pagar la mensualidad de My Club.' end, '/d/myclub');
    return v_id::text;

  elsif p_kind = 'metodo' then
    r := public._master_need('tarifas');
    v_txt := coalesce(p ->> 'kind', '');
    if v_txt not in ('transferencia', 'link', 'otro') then raise exception 'Tipo de forma de pago no válido.'; end if;
    v_data := jsonb_strip_nulls(jsonb_build_object(
      'bank', left(public._m_txt(p, 'bank'), 60), 'accType', left(public._m_txt(p, 'accType'), 40), 'number', left(public._m_txt(p, 'number'), 30),
      'holder', left(public._m_txt(p, 'holder'), 120), 'rut', left(public._m_txt(p, 'rut'), 20), 'email', left(public._m_txt(p, 'email'), 120),
      'url', left(public._m_txt(p, 'url'), 500), 'info', left(public._m_txt(p, 'info'), 500)));
    if v_txt = 'transferencia' and (v_data ->> 'number' is null or v_data ->> 'holder' is null) then raise exception 'Indica número de cuenta y titular.'; end if;
    if v_txt = 'link' and coalesce(v_data ->> 'url', '') !~ '^https://[^[:space:]]+$' then raise exception 'El link debe empezar con https://'; end if;
    if v_txt = 'otro' and v_data ->> 'info' is null then raise exception 'Escribe las instrucciones de pago.'; end if;
    if v_id is null then
      insert into platform_pay_methods (kind, name, data, active) values (v_txt, public._m_txt(p, 'name'), v_data, coalesce((p ->> 'active')::boolean, true)) returning id into v_id;
    else
      update platform_pay_methods set kind = v_txt, name = public._m_txt(p, 'name'), data = v_data, active = coalesce((p ->> 'active')::boolean, active) where id = v_id;
      if not found then raise exception 'No encontramos esa forma de pago.'; end if;
    end if;
    return v_id::text;

  elsif p_kind = 'reporte' then
    -- Confirmar un pago informado lo reparte entre sus meses (del más antiguo al más nuevo) como ingresos de My Club.
    r := public._master_need('finanzas');
    select * into v_rep from platform_reports where id = v_id for update;
    if not found then raise exception 'No encontramos ese pago informado.'; end if;
    if v_rep.status <> 'pendiente' then raise exception 'Ese pago ya fue revisado.'; end if;
    select owner_id into v_owner from clubs where id = v_rep.club_id;
    if coalesce((p ->> 'ok')::boolean, false) then
      v_left := coalesce(public._m_num(p, 'amount'), v_rep.amount);
      if v_left <= 0 then raise exception 'El monto no es válido.'; end if;
      for v_ch in select ch.*, ch.amount - public._platform_paid(ch.club_id, ch.period, ch.currency) as saldo
                  from platform_charges ch where ch.club_id = v_rep.club_id and ch.period = any (v_rep.periods) order by ch.period loop
        v_last := v_ch.period;
        v_pay := least(v_left, greatest(v_ch.saldo, 0));
        if v_pay > 0 then
          insert into platform_moves (kind, date, amount, currency, category, club_id, period, description, created_by)
          values ('ingreso', current_date, v_pay, v_rep.currency, 'Pago de club', v_rep.club_id, to_char(v_ch.period, 'YYYY-MM'),
                  left(concat_ws(' · ', 'Pago informado', v_rep.method, v_rep.reference), 300), r.email);
          v_left := v_left - v_pay;
        end if;
      end loop;
      if v_left > 0 then
        insert into platform_moves (kind, date, amount, currency, category, club_id, period, description, created_by)
        values ('ingreso', current_date, v_left, v_rep.currency, 'Pago de club', v_rep.club_id, to_char(coalesce(v_last, v_rep.periods[1]), 'YYYY-MM'),
                left(concat_ws(' · ', 'Pago informado (saldo a favor)', v_rep.method, v_rep.reference), 300), r.email);
      end if;
      update platform_reports set status = 'confirmado', resolved_by = r.email, resolved_at = now(), note = public._m_txt(p, 'note') where id = v_id;
      perform public._notify(v_owner, v_rep.club_id, 'My Club confirmó el pago de tu mensualidad. ¡Gracias!', '/d/myclub');
    else
      if public._m_txt(p, 'note') is null then raise exception 'Escribe el motivo del rechazo.'; end if;
      update platform_reports set status = 'rechazado', resolved_by = r.email, resolved_at = now(), note = public._m_txt(p, 'note') where id = v_id;
      perform public._notify(v_owner, v_rep.club_id, 'My Club no pudo confirmar el pago informado: ' || left(public._m_txt(p, 'note'), 200), '/d/myclub');
    end if;
    return v_id::text;

  elsif p_kind = 'usuario' then
    r := public._master_need('usuarios');
    v_mail := lower(coalesce(public._m_txt(p, 'email'), ''));
    if v_mail !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'El email no es válido.'; end if;
    if coalesce(length(public._m_txt(p, 'name')), 0) not between 2 and 160 then raise exception 'Escribe el nombre.'; end if;
    select coalesce(array_agg(distinct x), '{}') into v_per from jsonb_array_elements_text(coalesce(p -> 'perms', '[]')) x;
    if not v_per <@ public._master_perms() then raise exception 'Acceso no válido.'; end if;
    -- Nadie entrega accesos que no tiene, ni se modifica a sí mismo; al dueño solo se le cambia desde la base.
    if not r.owner and not v_per <@ r.perms then raise exception 'Solo puedes entregar accesos que tú tienes.'; end if;
    if v_mail = r.email then raise exception 'No puedes modificar tu propio usuario.'; end if;
    select * into v_old from platform_admins where email = v_mail;
    if found and v_old.owner then raise exception 'El usuario dueño no se puede modificar.'; end if;
    if not found and coalesce((p ->> 'edit')::boolean, false) then raise exception 'No encontramos ese usuario.'; end if;
    if found and not coalesce((p ->> 'edit')::boolean, false) then raise exception 'Ese email ya es usuario Master.'; end if;
    insert into platform_admins (email, name, perms, active, created_by)
    values (v_mail, public._m_txt(p, 'name'), v_per, coalesce((p ->> 'active')::boolean, true), r.email)
    on conflict (email) do update set name = excluded.name, perms = excluded.perms, active = excluded.active;
    return v_mail;
  end if;
  raise exception 'Operación no válida.';
end $$;

create function public.master_delete(p_kind text, p_id text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r platform_admins; v_old platform_admins;
begin
  if p_kind = 'descuento' then
    r := public._master_need('descuentos'); delete from platform_discounts where id = p_id::uuid;
  elsif p_kind = 'promocion' then
    r := public._master_need('promociones'); delete from platform_promos where id = p_id::uuid;
  elsif p_kind = 'movimiento' then
    r := public._master_need('finanzas'); delete from platform_moves where id = p_id::uuid;
  elsif p_kind = 'metodo' then
    r := public._master_need('tarifas'); delete from platform_pay_methods where id = p_id::uuid;
  elsif p_kind = 'usuario' then
    r := public._master_need('usuarios');
    select * into v_old from platform_admins where email = lower(p_id);
    if not found then raise exception 'No encontramos ese usuario.'; end if;
    if v_old.owner then raise exception 'El usuario dueño no se puede quitar.'; end if;
    if v_old.email = r.email then raise exception 'No puedes quitarte a ti mismo.'; end if;
    delete from platform_admins where email = v_old.email;
  else
    raise exception 'Operación no válida.';
  end if;
  if not found then raise exception 'No encontramos ese registro.'; end if;
end $$;

-- Una persona invitada como usuario Master que aún no tiene clave se registra con su email (sin tipo de cuenta).
-- Al ingresar sin cuenta y sin ser Master, la app borra ese usuario de Auth con delete_my_account.

revoke execute on function public._master_perms(), public._master_row(), public._master_can(text), public._master_need(text),
  public.master_me(), public.master_data(), public.master_save(text, jsonb), public.master_delete(text, text),
  public._m_txt(jsonb, text), public._m_date(jsonb, text), public._m_num(jsonb, text),
  public._platform_paid(uuid, date, text), public._platform_amount(public.clubs, date), public._platform_bill(uuid), public._club_owed(uuid),
  public._club_state(uuid), public._club_inactive_guard(), public.club_billing(), public.club_report_payment(jsonb) from public, anon, authenticated;
grant execute on function public.master_me(), public.master_data(), public.master_save(text, jsonb), public.master_delete(text, text),
  public.club_billing(), public.club_report_payment(jsonb) to authenticated;

commit;
