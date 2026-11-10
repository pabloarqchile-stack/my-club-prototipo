-- Cada mensualidad vence el último día de su mes. El estado del deportista depende solo de cuántos meses
-- de mensualidad tiene vencidos en ese club y deporte: 0 a 2 hábil, 3 o 4 en revisión, 5 o más suspendido.
-- La matrícula y los demás cobros no influyen. El estado se calcula: pagar lo cambia sin ningún otro paso.

update public.records set
  data = data || jsonb_build_object('due', (date_trunc('month', (case
    when id ~ '_[0-9]{4}-[0-9]{2}$' then (right(id, 7) || '-01')::date
    else (created_at at time zone 'America/Santiago')::date end)::timestamp) + interval '1 month' - interval '1 day')::date),
  updated_at = now()
 where kind = 'charges' and data ->> 'kind' = 'mensual';

create or replace function public._gen_monthly(c uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  m record; hoy date := public._today(); per text := to_char(hoy, 'YYYY-MM'); rid text; amt bigint;
  fin_mes date := (date_trunc('month', public._today()::timestamp) + interval '1 month' - interval '1 day')::date;
  mes text := (array['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'])[extract(month from hoy)::int];
begin
  for m in select ms.player_id, t as tm from memberships ms join teams t on t.id = ms.team_id where ms.club_id = c and ms.status in ('habil', 'suspendido') and (t.mensualidad > 0 or exists (select 1 from records r where r.kind = 'feeRules' and r.id = 'fee_' || c || '_' || ms.player_id)) loop
    rid := 'men_' || (m.tm).id || '_' || m.player_id || '_' || per;
    amt := public._month_fee(m.tm, m.player_id);
    if amt > 0 then
      insert into records (kind, id, club_ids, player_id, data) values ('charges', rid, array[c], m.player_id, jsonb_build_object(
        'id', rid, 'playerId', m.player_id, 'clubId', c, 'teamId', (m.tm).id, 'concept', 'Mensualidad ' || mes || ' ' || left(per, 4) || ' · ' || (m.tm).name, 'kind', 'mensual', 'cat', 'Mensualidad', 'amount', amt, 'due', fin_mes, 'status', 'pendiente', 'paidAt', null, 'period', per))
      on conflict (kind, id) do update set data = records.data || jsonb_build_object('amount', amt), updated_at = now() where records.data ->> 'status' = 'pendiente';
    else
      delete from records where kind = 'charges' and id = rid and data ->> 'status' = 'pendiente';
    end if;
  end loop;
end $$;

-- Meses de mensualidad vencidos por inscripción. Solo los ve el propio deportista, su apoderado y el club.
-- Compara las fechas como texto ISO: un cobro con fecha mal escrita no debe romper el estado de todo el club.
create function public.my_fee_months() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_object_agg(x.id, x.n), '{}') from (
    select m.id, count(distinct left(r.data ->> 'due', 7)) as n
      from memberships m
      join records r on r.kind = 'charges' and r.player_id = m.player_id and m.club_id = any (r.club_ids)
      left join teams t on t.id::text = r.data ->> 'teamId'
     where m.status in ('habil', 'suspendido')
       and r.data ->> 'kind' = 'mensual' and r.data ->> 'status' = 'pendiente'
       and r.data ->> 'due' < to_char(public._today(), 'YYYY-MM-DD')
       and (t.id is null or t.sport = m.sport)
       and (public.is_my_player(m.player_id) or public.is_club_staff(m.club_id))
     group by m.id
  ) x
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
    'fee_months', public.my_fee_months()
  )
$$;

revoke execute on function public.my_fee_months() from public, anon, authenticated;
grant execute on function public.my_fee_months() to authenticated;
