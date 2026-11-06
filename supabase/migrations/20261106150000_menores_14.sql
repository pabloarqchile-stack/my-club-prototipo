-- Menores de 14 años: pueden crear su cuenta, pero solo se unen a un club
-- cuando un apoderado está vinculado y aceptado.

begin;

create or replace function public._join(p_player uuid, p_club uuid, p_sport text, p_note text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c clubs; dup record; t uuid; m uuid; pname text; pl players;
begin
  select * into c from clubs where id = p_club;
  if not found then raise exception 'No encontramos ese club.'; end if;
  if not p_sport = any (c.sports) then raise exception '% no tiene habilitado ese deporte.', c.short; end if;
  select * into pl from players where id = p_player;
  pname := pl.name;
  -- Ley 21.719, art. 16 quáter: bajo 14 años se requiere el consentimiento de padres o representantes.
  -- Sin apoderado, los datos del menor no llegan a ningún club.
  if age(pl.birth) < interval '14 years' and pl.guardian_id is null
     and not exists (select 1 from guardian_links g where g.player_id = p_player and g.status = 'aceptada') then
    raise exception 'Los menores de 14 años necesitan un apoderado vinculado antes de unirse a un club.';
  end if;
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

commit;
