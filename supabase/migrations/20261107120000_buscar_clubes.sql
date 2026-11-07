-- Busca clubes por nombre o ID para vincularse. Se usa también antes de iniciar
-- sesión, durante el registro, por eso entrega solo datos públicos del club.

begin;

create function public._norm(t text) returns text
language sql immutable as $$
  select lower(translate(coalesce(t, ''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun'))
$$;

create function public.search_clubs(p_q text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with q as (select public._norm(left(btrim(coalesce(p_q, '')), 80)) as v)
  select coalesce(jsonb_agg(r.x), '[]') from (
    select jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name, 'short', c.short,
                              'sports', to_jsonb(c.sports), 'logo', c.logo, 'city', c.city) as x
    from clubs c, q
    where c.owner_id is not null and length(q.v) >= 2
      and (position(q.v in public._norm(c.name)) > 0 or position(q.v in public._norm(c.short)) > 0 or lower(c.code) = q.v)
    order by position(q.v in public._norm(c.name)), c.name
    limit 8
  ) r
$$;

revoke execute on function public._norm(text), public.search_clubs(text) from public, anon, authenticated;
grant execute on function public.search_clubs(text) to anon, authenticated;

commit;
