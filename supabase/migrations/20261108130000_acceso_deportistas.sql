-- Un deportista registrado por su apoderado no tiene clave propia. El apoderado le da acceso indicando su email;
-- el deportista se registra con ese email y su RUT, y su cuenta toma el perfil existente.
-- Que confirme el email prueba que es la persona que el apoderado autorizó.

alter table public.players add column access_email text
  check (access_email is null or (access_email = lower(access_email) and access_email ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'));

create function public.grant_player_access(p_player uuid, p_email text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare pl players; e text := lower(btrim(coalesce(p_email, '')));
begin
  select * into pl from players where id = p_player for update;
  if not found or not (pl.guardian_id = auth.uid()
    or exists (select 1 from guardian_links g where g.player_id = pl.id and g.guardian_id = auth.uid() and g.status = 'aceptada')) then
    raise exception 'Solo su apoderado puede darle acceso.';
  end if;
  if pl.account_id is not null then raise exception 'Ya tiene su propia cuenta.'; end if;
  if e !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'El email no es válido.'; end if;
  if exists (select 1 from accounts where lower(email) = e) then raise exception 'Ese email ya tiene una cuenta en My Club. Usa otro.'; end if;
  update players set access_email = e where id = pl.id;
  perform public._audit('player.grant_access', pl.id);
end $$;

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
  ex players;
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
    -- Si su apoderado lo registró y le dio acceso con este email, la cuenta nueva toma ese perfil.
    select * into ex from players where rut_clean = public.clean_rut(v_rut);
    if found and not (ex.account_id is null and ex.access_email is not null and ex.access_email = lower(mail)) then
      raise exception 'Ya existe un deportista con ese RUT. Si tu apoderado te registró, pídele que te dé acceso desde Mis pupilos con este email.';
    end if;
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
    if ex.id is not null then
      update players set account_id = uid, email = mail, phone = ph, access_email = null where id = ex.id returning id into pl;
      perform public._notify(ex.guardian_id, null, ex.name || ' ya entra con su propia cuenta.', '/a/pupilos');
    else
      insert into players (account_id, name, rut, birth, email, phone, height, size)
      values (uid, nm, v_rut, (p ->> 'birth')::date, mail, ph, nullif(p ->> 'height', '')::int, public._txt(p, 'size')) returning id into pl;
    end if;
    if lk_club is not null then perform public._join(pl, lk_club, lk_sport, ''); end if;
  elsif t in ('apoderado', 'entrenador') and lk_club is not null then
    perform public._link(uid, lk_club);
  end if;

  perform public._audit('account.register', uid);
  return jsonb_build_object('publicId', pid);
end $$;

revoke execute on function public.grant_player_access(uuid, text) from public, anon, authenticated;
grant execute on function public.grant_player_access(uuid, text) to authenticated;
