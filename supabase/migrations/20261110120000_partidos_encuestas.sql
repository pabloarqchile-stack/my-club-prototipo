-- Partidos y torneos con mínimo de confirmados, y encuestas con formato de formulario.
-- Una convocatoria entra al calendario y genera sus cobros solo cuando se alcanza el mínimo.
-- Las respuestas de las encuestas viven en una tabla sin acceso directo: solo pasan por estas funciones.

create or replace function public._dir_perms() returns text[]
language sql immutable as $$
  select array['deportes', 'deportistas', 'solicitudes', 'bajas', 'finanzas', 'aprobaciones', 'asambleas', 'masivo', 'marketplace', 'cuerpo', 'infra', 'partidos', 'encuestas']
$$;

-- ---------------------------------------------------------------------------
-- Partidos y torneos
-- ---------------------------------------------------------------------------
create function public._fee_overdue(p_player uuid, p_club uuid, p_sport text) returns bigint
language sql stable security definer set search_path = public, pg_temp as $$
  select count(distinct left(r.data ->> 'due', 7))
    from records r left join teams t on t.id::text = r.data ->> 'teamId'
   where r.kind = 'charges' and r.player_id = p_player and p_club = any (r.club_ids)
     and r.data ->> 'kind' = 'mensual' and r.data ->> 'status' = 'pendiente'
     and r.data ->> 'due' < to_char(public._today(), 'YYYY-MM-DD')
     and (t.id is null or t.sport = p_sport)
$$;

create function public.create_match(p jsonb) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  k text := p ->> 'kind'; nm text := btrim(coalesce(p ->> 'name', '')); f text := coalesce(p ->> 'date', '');
  hora text := coalesce(nullif(p ->> 'time', ''), '10:00'); lugar text := left(btrim(coalesce(p ->> 'place', '')), 120);
  rid text := 'cv_' || replace(gen_random_uuid()::text, '-', '');
  amt bigint; mn int; cl uuid; tms uuid[]; nc int; pids jsonb; n int; quien text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  if k is null or k not in ('Partido', 'Torneo') then raise exception 'Elige partido o torneo.'; end if;
  if length(nm) not between 2 and 120 then raise exception 'Escribe el nombre.'; end if;
  if f !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Indica la fecha.'; end if;
  if f::date < public._today() then raise exception 'La fecha no puede ser anterior a hoy.'; end if;
  if hora !~ '^[0-9]{2}:[0-9]{2}$' then raise exception 'La hora no es válida.'; end if;
  if coalesce(p ->> 'amount', '') !~ '^[0-9]{1,9}$' or (p ->> 'amount')::bigint <= 0 then raise exception 'Indica un monto mayor que cero.'; end if;
  if coalesce(p ->> 'min', '') !~ '^[0-9]{1,4}$' or (p ->> 'min')::int < 1 then raise exception 'Indica la cantidad mínima de deportistas.'; end if;
  amt := (p ->> 'amount')::bigint; mn := (p ->> 'min')::int;
  select array_agg(t.id), count(distinct t.club_id), min(t.club_id::text)::uuid into tms, nc, cl
    from teams t where t.id::text in (select jsonb_array_elements_text(coalesce(p -> 'teams', '[]')));
  if tms is null or nc <> 1 then raise exception 'Elige a quién convocar.'; end if;
  if not (public._club_can(cl, 'partidos') or public._coach_any(array[cl])) then raise exception 'No tienes permiso para crear partidos o torneos.'; end if;
  select coalesce(jsonb_agg(x.player_id), '[]'), count(*) into pids, n
    from (select distinct player_id from memberships where team_id = any (tms) and status in ('habil', 'suspendido')) x;
  if n = 0 then raise exception 'No hay deportistas activos en esa selección.'; end if;
  if mn > n then raise exception 'El mínimo no puede superar a los % deportistas convocados.', n; end if;
  select case when public._coach_any(array[cl]) then a.name else 'Directorio' end into quien from accounts a where a.user_id = auth.uid();
  insert into records (kind, id, club_ids, owner_id, data) values ('incomeItems', rid, array[cl], auth.uid(), jsonb_build_object(
    'id', rid, 'clubId', cl, 'kind', k, 'name', nm, 'amount', amt, 'target', left(coalesce(p ->> 'target', ''), 120), 'scope', 'match', 'due', f, 'by', quien,
    'date', public._today(), 'confirm', true, 'playerIds', pids, 'answers', '{}'::jsonb,
    'minPlayers', mn, 'matchDate', f, 'time', hora, 'place', lugar, 'teamIds', to_jsonb(tms), 'active', false));
  perform public._notify(x.a, cl, 'Confirma tu participación: ' || nm, '/calendario') from (
    select p2.account_id as a from memberships m join players p2 on p2.id = m.player_id where m.team_id = any (tms) and m.status in ('habil', 'suspendido')
    union select p2.guardian_id from memberships m join players p2 on p2.id = m.player_id where m.team_id = any (tms) and m.status in ('habil', 'suspendido')
    union select g.guardian_id from memberships m join guardian_links g on g.player_id = m.player_id and g.status = 'aceptada' where m.team_id = any (tms) and m.status in ('habil', 'suspendido')
  ) x;
  perform public._audit('match.create', null);
  return rid;
end $$;

-- Carga el cobro con la fecha del partido y agrega al deportista al evento de su categoría.
create function public._match_apply(p_item text, d jsonb, cl uuid, p_player uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare tid uuid; sp text; eid text; rid text := 'part_' || p_item || '_' || p_player;
begin
  select m.team_id, m.sport into tid, sp from memberships m
   where m.player_id = p_player and m.club_id = cl and m.status in ('habil', 'suspendido') and d -> 'teamIds' ? m.team_id::text
   order by m.created_at limit 1;
  if not found then return; end if;
  insert into records (kind, id, club_ids, player_id, data) values ('charges', rid, array[cl], p_player, jsonb_build_object(
    'id', rid, 'playerId', p_player, 'clubId', cl, 'teamId', tid, 'concept', d ->> 'name', 'kind', 'extraordinaria', 'cat', d ->> 'kind', 'amount', (d ->> 'amount')::bigint,
    'due', d ->> 'matchDate', 'status', 'pendiente', 'paidAt', null, 'by', d ->> 'by', 'partial', true, 'meta', jsonb_build_object('itemId', p_item)))
  on conflict (kind, id) do nothing;
  eid := 'cv_' || p_item || '_' || tid;
  insert into records (kind, id, club_ids, data) values ('events', eid, array[cl], jsonb_build_object(
    'id', eid, 'type', case when d ->> 'kind' = 'Torneo' then 'torneo' else 'partido' end, 'clubId', cl, 'sport', sp, 'teamId', tid,
    'date', d ->> 'matchDate', 'time', d ->> 'time', 'place', d ->> 'place', 'title', d ->> 'name', 'itemId', p_item,
    'cited', jsonb_build_array(p_player), 'present', '[]'::jsonb, 'result', null, 'stats', '{}'::jsonb))
  on conflict (kind, id) do update set data = jsonb_set(records.data, '{cited}', (records.data -> 'cited') || to_jsonb(p_player::text)), updated_at = now()
    where not records.data -> 'cited' ? p_player::text;
end $$;

-- El bloqueo del registro hace que dos confirmaciones simultáneas no se salten el mínimo.
create or replace function public.confirm_participation(p_item text, p_player uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare it records; d jsonb; ch records; rid text := 'part_' || p_item || '_' || p_player; cl uuid; tid uuid; msp text; mst text; vmin int := 0; si int; x record;
begin
  select * into it from records where kind = 'incomeItems' and id = p_item for update;
  if not found or it.data ->> 'confirm' is distinct from 'true' or it.data ->> 'canceled' = 'true' then raise exception 'Esta convocatoria no existe.'; end if;
  d := it.data; cl := it.club_ids[1];
  if not public.is_my_player(p_player) or not coalesce(d -> 'playerIds', '[]') ? p_player::text then raise exception 'No tienes permiso para responder esta convocatoria.'; end if;
  if coalesce(d ->> 'minPlayers', '') ~ '^[0-9]{1,4}$' then vmin := (d ->> 'minPlayers')::int; end if;
  select * into ch from records where kind = 'charges' and id = rid for update;
  if p_ok then
    if nullif(d ->> 'due', '') is not null and (d ->> 'due')::date < public._today() then raise exception 'El plazo de esta convocatoria ya terminó.'; end if;
    select team_id, sport, status into tid, msp, mst from memberships
     where player_id = p_player and club_id = cl and status in ('habil', 'suspendido') and (vmin = 0 or d -> 'teamIds' ? team_id::text) order by created_at limit 1;
    if not found then raise exception 'El deportista no está activo en este club.'; end if;
    if vmin > 0 and (mst = 'suspendido' or public._fee_overdue(p_player, cl, msp) >= 5) then raise exception 'Un deportista suspendido no puede confirmar su participación.'; end if;
    if vmin = 0 and ch.id is null then
      insert into records (kind, id, club_ids, player_id, data) values ('charges', rid, array[cl], p_player, jsonb_build_object(
        'id', rid, 'playerId', p_player, 'clubId', cl, 'teamId', tid, 'concept', d ->> 'name', 'kind', 'extraordinaria', 'cat', d ->> 'kind', 'amount', (d ->> 'amount')::bigint,
        'due', nullif(d ->> 'due', ''), 'status', 'pendiente', 'paidAt', null, 'by', d ->> 'by', 'partial', true, 'meta', jsonb_build_object('itemId', p_item)));
    end if;
  else
    if ch.id is not null and (ch.data ->> 'status' <> 'pendiente' or ch.data ->> 'original' is not null) then raise exception 'Ya registra pagos: habla con el club para cancelar.'; end if;
    delete from records where kind = 'charges' and id = rid;
  end if;
  update records set data = jsonb_set(data, '{answers}', coalesce(data -> 'answers', '{}') || jsonb_build_object(p_player::text, case when p_ok then 'si' else 'no' end)), updated_at = now()
   where kind = 'incomeItems' and id = p_item returning data into d;
  if vmin = 0 then return; end if;
  if not p_ok then
    update records set data = jsonb_set(data, '{cited}', (data -> 'cited') - p_player::text), updated_at = now()
     where kind = 'events' and data ->> 'itemId' = p_item;
    return;
  end if;
  if d ->> 'active' = 'true' then perform public._match_apply(p_item, d, cl, p_player); return; end if;
  select count(*) into si from jsonb_each_text(d -> 'answers') where value = 'si';
  if si < vmin then return; end if;
  update records set data = data || '{"active": true}'::jsonb, updated_at = now() where kind = 'incomeItems' and id = p_item;
  for x in select key::uuid as pl from jsonb_each_text(d -> 'answers') where value = 'si' loop
    perform public._match_apply(p_item, d, cl, x.pl);
    perform public._notify(p2.account_id, cl, (d ->> 'name') || ' ya está confirmado: quedó en el calendario y se cargó su cobro.', '/calendario') from players p2 where p2.id = x.pl;
    perform public._notify(p2.guardian_id, cl, (d ->> 'name') || ' ya está confirmado: quedó en el calendario y se cargó su cobro.', '/calendario') from players p2 where p2.id = x.pl;
  end loop;
  perform public._notify(it.owner_id, cl, (d ->> 'name') || ' alcanzó el mínimo de confirmados.', '/convocatorias/' || p_item);
end $$;

create function public.cancel_match(p_item text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare it records; cl uuid; x record;
begin
  select * into it from records where kind = 'incomeItems' and id = p_item and data ? 'minPlayers' for update;
  if not found then raise exception 'Esta convocatoria no existe.'; end if;
  cl := it.club_ids[1];
  if not (it.owner_id = auth.uid() or public._club_can(cl, 'partidos')) then raise exception 'No tienes permiso para cancelar esta convocatoria.'; end if;
  if it.data ->> 'active' = 'true' then raise exception 'Ya está en el calendario y con cobros cargados: no se puede cancelar.'; end if;
  update records set data = data || '{"canceled": true}'::jsonb, updated_at = now() where kind = 'incomeItems' and id = p_item;
  for x in select key::uuid as pl from jsonb_each_text(coalesce(it.data -> 'answers', '{}')) where value = 'si' loop
    perform public._notify(p2.account_id, cl, (it.data ->> 'name') || ' fue cancelado.', '/calendario') from players p2 where p2.id = x.pl;
    perform public._notify(p2.guardian_id, cl, (it.data ->> 'name') || ' fue cancelado.', '/calendario') from players p2 where p2.id = x.pl;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Encuestas
-- ---------------------------------------------------------------------------
create table public.surveys (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs (id) on delete cascade,
  created_by uuid references public.accounts (user_id) on delete set null,
  by_name text not null,
  title text not null check (length(title) between 1 and 150),
  message text not null default '' check (length(message) <= 2000),
  questions jsonb not null,
  audience text[] not null check (cardinality(audience) > 0 and audience <@ array['jugadores', 'apoderados']),
  team_ids uuid[] not null check (cardinality(team_ids) > 0),
  scope_label text not null default '',
  status text not null default 'abierta' check (status in ('abierta', 'cerrada')),
  created_at timestamptz not null default now()
);
create index on public.surveys (club_id);

create table public.survey_responses (
  survey_id uuid not null references public.surveys (id) on delete cascade,
  account_id uuid not null references public.accounts (user_id) on delete cascade,
  who text not null check (who in ('jugadores', 'apoderados')),
  answers jsonb not null,
  created_at timestamptz not null default now(),
  primary key (survey_id, account_id)
);

alter table public.surveys enable row level security;
alter table public.survey_responses enable row level security;
revoke all on public.surveys, public.survey_responses from public, anon, authenticated;

create function public._survey_targets(a text[], t uuid[]) returns table (account_id uuid, who text)
language sql stable security definer set search_path = public, pg_temp as $$
  with activos as (select distinct m.player_id from memberships m where m.team_id = any (t) and m.status in ('habil', 'suspendido'))
  select p.account_id, 'jugadores' from activos x join players p on p.id = x.player_id where p.account_id is not null and 'jugadores' = any (a)
  union
  select g.id, 'apoderados' from (
    select p.guardian_id as id from activos x join players p on p.id = x.player_id where p.guardian_id is not null
    union select l.guardian_id from activos x join guardian_links l on l.player_id = x.player_id and l.status = 'aceptada'
  ) g where 'apoderados' = any (a)
$$;

create function public._survey_questions(q jsonb) returns jsonb
language plpgsql immutable set search_path = public, pg_temp as $$
declare r jsonb; res jsonb := '[]'; i int := 0; t text; tx text; it jsonb; ops jsonb; n int; nd int; lmin int; lmax int; mn int; mx int;
begin
  if jsonb_typeof(q) is distinct from 'array' or jsonb_array_length(q) not between 1 and 50 then raise exception 'Agrega entre 1 y 50 preguntas.'; end if;
  for r in select * from jsonb_array_elements(q) loop
    i := i + 1; t := r ->> 'type'; tx := btrim(coalesce(r ->> 'text', ''));
    if t is null or t not in ('unica', 'multiple', 'lista', 'corta', 'parrafo', 'escala', 'fecha') then raise exception 'Tipo de pregunta no válido.'; end if;
    if length(tx) not between 1 and 300 then raise exception 'Escribe la pregunta %.', i; end if;
    it := jsonb_build_object('id', 'q' || i, 'text', tx, 'type', t, 'required', r ->> 'required' = 'true');
    if t in ('unica', 'multiple', 'lista') then
      if jsonb_typeof(r -> 'options') is distinct from 'array' then raise exception 'La pregunta % necesita opciones.', i; end if;
      select jsonb_agg(y.b order by y.o), count(*), count(distinct y.b), min(length(y.b)), max(length(y.b)) into ops, n, nd, lmin, lmax
        from (select btrim(v) as b, o from jsonb_array_elements_text(r -> 'options') with ordinality z(v, o)) y;
      if n not between 2 and 30 or lmin < 1 or lmax > 200 then raise exception 'La pregunta % necesita entre 2 y 30 opciones.', i; end if;
      if n <> nd then raise exception 'La pregunta % tiene opciones repetidas.', i; end if;
      it := it || jsonb_build_object('options', ops);
    elsif t = 'escala' then
      if coalesce(r ->> 'min', '') !~ '^[01]$' or coalesce(r ->> 'max', '') !~ '^([2-9]|10)$' then raise exception 'La escala de la pregunta % no es válida.', i; end if;
      mn := (r ->> 'min')::int; mx := (r ->> 'max')::int;
      it := it || jsonb_build_object('min', mn, 'max', mx, 'minLabel', left(btrim(coalesce(r ->> 'minLabel', '')), 40), 'maxLabel', left(btrim(coalesce(r ->> 'maxLabel', '')), 40));
    end if;
    res := res || jsonb_build_array(it);
  end loop;
  return res;
end $$;

create function public.save_survey(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tit text := btrim(coalesce(p ->> 'title', '')); msg text := btrim(coalesce(p ->> 'message', ''));
  aud text[]; tms uuid[]; nc int; cl uuid; quien text; sid uuid; x record;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  if length(tit) not between 1 and 150 then raise exception 'Escribe el título.'; end if;
  if length(msg) > 2000 then raise exception 'El mensaje es demasiado largo.'; end if;
  select array_agg(distinct v) into aud from jsonb_array_elements_text(coalesce(p -> 'audience', '[]')) v;
  if aud is null or not aud <@ array['jugadores', 'apoderados'] then raise exception 'Elige deportistas, apoderados o ambos.'; end if;
  select array_agg(t.id), count(distinct t.club_id), min(t.club_id::text)::uuid into tms, nc, cl
    from teams t where t.id::text in (select jsonb_array_elements_text(coalesce(p -> 'teams', '[]')));
  if tms is null or nc <> 1 then raise exception 'Elige al menos una categoría.'; end if;
  if not (public._club_can(cl, 'encuestas') or public._coach_any(array[cl])) then raise exception 'No tienes permiso para crear encuestas.'; end if;
  select case when public._coach_any(array[cl]) then a.name else 'Directorio' end into quien from accounts a where a.user_id = auth.uid();
  insert into surveys (club_id, created_by, by_name, title, message, questions, audience, team_ids, scope_label)
  values (cl, auth.uid(), quien, tit, msg, public._survey_questions(p -> 'questions'), aud, tms, left(coalesce(p ->> 'scope', ''), 120)) returning id into sid;
  for x in select distinct account_id from public._survey_targets(aud, tms) loop
    perform public._notify(x.account_id, cl, 'Nueva encuesta: ' || tit, '/encuestas/' || sid);
  end loop;
  perform public._audit('survey.create', sid);
  return sid;
end $$;

create function public.answer_survey(p_id uuid, p_answers jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s surveys; w text; q jsonb; a jsonb; res jsonb := '{}'; t text; ok boolean;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  select * into s from surveys where id = p_id;
  if not found then raise exception 'Esta encuesta no existe.'; end if;
  if s.status <> 'abierta' then raise exception 'Esta encuesta está cerrada.'; end if;
  select x.who into w from public._survey_targets(s.audience, s.team_ids) x where x.account_id = auth.uid() limit 1;
  if not found then raise exception 'Esta encuesta no está dirigida a ti.'; end if;
  if jsonb_typeof(p_answers) is distinct from 'object' then raise exception 'Respuestas no válidas.'; end if;
  for q in select * from jsonb_array_elements(s.questions) loop
    a := p_answers -> (q ->> 'id'); t := q ->> 'type';
    if a is null or a in ('null'::jsonb, '""'::jsonb, '[]'::jsonb) then
      if q ->> 'required' = 'true' then raise exception 'Responde: %', q ->> 'text'; end if;
      continue;
    end if;
    ok := case
      when t in ('unica', 'lista') then jsonb_typeof(a) = 'string' and q -> 'options' ? (a #>> '{}')
      when t = 'multiple' then jsonb_typeof(a) = 'array' and not exists (select 1 from jsonb_array_elements(a) v where jsonb_typeof(v) <> 'string' or not q -> 'options' ? (v #>> '{}'))
        and (select count(*) = count(distinct v) from jsonb_array_elements(a) v)
      when t = 'escala' then jsonb_typeof(a) = 'number' and (a #>> '{}') ~ '^[0-9]{1,2}$' and (a #>> '{}')::int between (q ->> 'min')::int and (q ->> 'max')::int
      when t = 'corta' then jsonb_typeof(a) = 'string' and length(a #>> '{}') <= 300
      when t = 'parrafo' then jsonb_typeof(a) = 'string' and length(a #>> '{}') <= 3000
      when t = 'fecha' then jsonb_typeof(a) = 'string' and (a #>> '{}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      else false end;
    if not ok then raise exception 'Respuesta no válida en: %', q ->> 'text'; end if;
    res := res || jsonb_build_object(q ->> 'id', a);
  end loop;
  insert into survey_responses (survey_id, account_id, who, answers) values (p_id, auth.uid(), w, res) on conflict do nothing;
  if not found then raise exception 'Ya respondiste esta encuesta.'; end if;
end $$;

create function public.set_survey_status(p_id uuid, p_open boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s surveys;
begin
  select * into s from surveys where id = p_id;
  if not found or not (s.created_by = auth.uid() or public._club_can(s.club_id, 'encuestas')) then raise exception 'No tienes permiso para cambiar esta encuesta.'; end if;
  update surveys set status = case when p_open then 'abierta' else 'cerrada' end where id = p_id;
end $$;

-- Quien administra ve las respuestas sin saber quién las dio. Quien responde solo ve la encuesta.
create function public.my_surveys() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(y.j order by y.created_at desc), '[]') from (
    select s.created_at, to_jsonb(s) - 'created_by' || jsonb_build_object(
      'manage', z.mg,
      'answered', exists (select 1 from survey_responses r where r.survey_id = s.id and r.account_id = auth.uid()),
      'eligible', case when z.mg then (select count(distinct t.account_id) from public._survey_targets(s.audience, s.team_ids) t) else 0 end,
      'responses', case when z.mg then coalesce((select jsonb_agg(jsonb_build_object('who', r.who, 'answers', r.answers) order by r.created_at desc) from survey_responses r where r.survey_id = s.id), '[]') else '[]' end) as j
    from surveys s
    cross join lateral (select s.created_by = auth.uid() or public._club_can(s.club_id, 'encuestas') as mg) z
    where coalesce(z.mg, false) or exists (select 1 from public._survey_targets(s.audience, s.team_ids) t where t.account_id = auth.uid())
    order by s.created_at desc limit 100
  ) y
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
    'directors', coalesce((select jsonb_agg(to_jsonb(d) - 'rut_clean') from club_directors d), '[]'),
    'notifications', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (select * from notifications order by created_at desc limit 100) n), '[]'),
    'records', public.my_records(),
    'directory', public.directory(),
    'names', public.my_directory_players(),
    'fee_months', public.my_fee_months(),
    'surveys', public.my_surveys()
  )
$$;

revoke execute on function public._fee_overdue(uuid, uuid, text), public._match_apply(text, jsonb, uuid, uuid),
  public._survey_targets(text[], uuid[]), public._survey_questions(jsonb) from public, anon, authenticated;
revoke execute on function public.create_match(jsonb), public.cancel_match(text), public.save_survey(jsonb), public.answer_survey(uuid, jsonb),
  public.set_survey_status(uuid, boolean), public.my_surveys() from public, anon;
grant execute on function public.create_match(jsonb), public.cancel_match(text), public.save_survey(jsonb), public.answer_survey(uuid, jsonb),
  public.set_survey_status(uuid, boolean), public.my_surveys() to authenticated;
