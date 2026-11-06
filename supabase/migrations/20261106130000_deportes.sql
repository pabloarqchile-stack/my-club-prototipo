-- Deportes del club: lista olímpica más nombre libre (botón OTRO).
-- El nombre libre se muestra en muchas pantallas: solo se aceptan letras,
-- números, espacios y . ( ) -, sin comillas ni signos de HTML.

begin;

create or replace function public.add_sport(p_sport text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text := regexp_replace(btrim(coalesce(p_sport, '')), '\s+', ' ', 'g');
begin
  if v !~ '^[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ ().-]{2,40}$' then
    raise exception 'El nombre del deporte debe tener entre 2 y 40 caracteres: solo letras, números, espacios y . ( ) -';
  end if;
  update clubs set sports = case when exists (select 1 from unnest(sports) s where lower(s) = lower(v)) then sports else sports || v end
   where owner_id = auth.uid();
  if not found then raise exception 'Solo el club puede hacer esto.'; end if;
end $$;

commit;
