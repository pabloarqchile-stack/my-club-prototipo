-- Entrenador a cargo de cada deporte y de cada categoría, elegido entre los entrenadores vinculados al club.
-- teams.coach sigue guardando el nombre que se muestra; teams.coach_id dice qué cuenta es.
-- clubs.sport_coaches guarda por deporte la cuenta y el nombre: {"Fútbol": {"id": "...", "name": "..."}}.
begin;

alter table public.teams add column coach_id uuid references public.accounts (user_id) on delete set null;
alter table public.clubs add column sport_coaches jsonb not null default '{}';

-- Nombre del entrenador si su vínculo con el club está aceptado. Si no, null.
create function public._club_coach(c uuid, u uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select a.name from links l join accounts a on a.user_id = l.account_id
   where l.club_id = c and l.account_id = u and l.status = 'aceptada' and a.type = 'entrenador'
   limit 1
$$;

-- Lee el entrenador pedido en p ->> 'coachId'. Vacío quiere decir "Por asignar".
create function public._pick_coach(c uuid, p jsonb, out cid uuid, out cname text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if coalesce(p ->> 'coachId', '') = '' then cid := null; cname := 'Por asignar'; return; end if;
  cid := public._uuid_or_null(p ->> 'coachId');
  cname := case when cid is null then null else public._club_coach(c, cid) end;
  if cname is null then raise exception 'Elige un entrenador vinculado al club.'; end if;
end $$;

create function public.set_sport_coach(p_sport text, p_coach uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; n text;
begin
  select * into c from clubs where id = public._my_club() and public._club_can(id, 'deportes') for update;
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
  if not coalesce(p_sport = any (c.sports), false) then raise exception 'Primero agrega ese deporte al club.'; end if;
  if p_coach is null then
    update clubs set sport_coaches = sport_coaches - p_sport where id = c.id;
  else
    n := public._club_coach(c.id, p_coach);
    if n is null then raise exception 'Elige un entrenador vinculado al club.'; end if;
    update clubs set sport_coaches = sport_coaches || jsonb_build_object(p_sport, jsonb_build_object('id', p_coach, 'name', n)) where id = c.id;
  end if;
  perform public._audit('sport.coach', c.id);
end $$;

create or replace function public.add_team(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; v_id uuid; sp text := public._txt(p, 'sport'); kid uuid; kname text;
begin
  select * into c from clubs where id = public._my_club() and public._club_can(id, 'deportes');
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
  if public._txt(p, 'name') is null then raise exception 'Escribe un nombre.'; end if;
  if not sp = any (c.sports) then raise exception 'Primero agrega ese deporte al club.'; end if;
  if p ? 'coachId' then
    select x.cid, x.cname into kid, kname from public._pick_coach(c.id, p) x;
  else
    kname := coalesce(public._txt(p, 'coach'), 'Por asignar');
  end if;
  insert into teams (club_id, sport, name, category, sex, coach, coach_id)
  values (c.id, sp, public._txt(p, 'name'), coalesce(public._txt(p, 'category'), 'Todo competidor'), coalesce(public._txt(p, 'sex'), 'Mixto'), kname, kid)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.update_team(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t teams; tid uuid := public._uuid_or_null(p ->> 'id'); monto bigint := nullif(p ->> 'matricula', '')::bigint; kid uuid; kname text;
begin
  select * into t from teams where id = tid for update;
  if not found or not public._club_can(t.club_id, 'deportes') then raise exception 'Solo el club puede hacer esto.'; end if;
  if public._txt(p, 'name') is null then raise exception 'Escribe un nombre.'; end if;
  if monto is not null and monto < 0 then raise exception 'El monto no es válido.'; end if;
  if p ? 'coachId' then
    select x.cid, x.cname into kid, kname from public._pick_coach(t.club_id, p) x;
  elsif public._txt(p, 'coach') is not null then
    kname := public._txt(p, 'coach');
  else
    kid := t.coach_id; kname := t.coach;
  end if;
  update teams set name = public._txt(p, 'name'), category = coalesce(public._txt(p, 'category'), category), sex = coalesce(public._txt(p, 'sex'), sex),
         coach = kname, coach_id = kid, matricula = coalesce(monto, matricula) where id = tid returning * into t;
  if monto is not null then
    -- Los cobros pendientes toman el monto nuevo. Los pagados no se tocan.
    update records set data = data || jsonb_build_object('amount', monto), updated_at = now()
     where kind = 'charges' and data ->> 'teamId' = tid::text and data ->> 'kind' = 'matricula' and data ->> 'status' = 'pendiente';
    perform public._charge_matricula(t, m.player_id) from memberships m where m.team_id = tid and m.status in ('habil', 'suspendido');
  end if;
end $$;

-- Escribir un nombre a mano deja la categoría sin cuenta de entrenador asociada.
create or replace function public.set_team_coach(p_team uuid, p_coach text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if coalesce(btrim(p_coach), '') = '' then raise exception 'Escribe un nombre.'; end if;
  update teams t set coach = btrim(p_coach), coach_id = null where t.id = p_team and public._club_can(t.club_id, 'deportes');
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
end $$;

revoke execute on function public._club_coach(uuid, uuid), public._pick_coach(uuid, jsonb), public.set_sport_coach(text, uuid) from public, anon, authenticated;
grant execute on function public.set_sport_coach(text, uuid) to authenticated;

commit;
