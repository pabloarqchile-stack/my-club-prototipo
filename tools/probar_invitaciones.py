"""Prueba las invitaciones del club (migración 20261127120000_invitaciones.sql) en un Postgres local.

Usa el mismo arnés que probar_base.py. El envío del correo (función invitar-socios) se simula
llamando a invites_to_send e invite_sent como lo haría la función, con la clave de servicio.

Uso:  pip install pgserver psycopg2-binary  &&  python tools/probar_invitaciones.py
"""
import json
import shutil
import sys
import tempfile

import pgserver
import psycopg2

from probar_base import J, Prueba, preparar, rut

BASE = {'phone': '+56911111111', 'consent': True}
BOARD = [{'cargo': 'Presidente', 'name': 'Ana'}, {'cargo': 'Tesorero', 'name': 'Luis'}, {'cargo': 'Secretario', 'name': 'Rosa'}]


def servicio(t, sql, args=()):
    """Ejecuta como la función de borde (rol service_role, sin sesión de usuario)."""
    with t.c.cursor() as q:
        q.execute("select set_config('role', 'service_role', true)")
        q.execute(sql, args)
        filas = q.fetchall() if q.description else []
    t.c.commit()
    return filas


def auth_admin(t, sql, args=()):
    """Lo que hace la API de administración de Auth (crear o borrar usuarios)."""
    with t.c.cursor() as q:
        q.execute(sql, args)
        filas = q.fetchall() if q.description else []
    t.c.commit()
    return filas


def enviar(t, quien, ids):
    """Lo que hace invitar-socios: pide las invitaciones permitidas, crea el usuario de Auth y marca el envío."""
    filas = servicio(t, 'select public.invites_to_send(%s, %s::uuid[])', (str(quien), [str(i) for i in ids]))[0][0]
    users = {}
    for r in filas:
        if r['old_user']:
            auth_admin(t, 'delete from auth.users where id = %s', (r['old_user'],))
        u = auth_admin(t, 'insert into auth.users (email) values (%s) returning id', (r['email'],))[0][0]
        servicio(t, 'select public.invite_sent(%s, %s, null)', (r['id'], str(u)))
        users[r['email']] = u
    return users


def correr(t):
    club, club2, ent, ajeno = [t.usuario(f'{n}@prueba.cl') for n in ('club', 'club2', 'ent', 'ajeno')]
    t.rpc(club, 'register_account', J({**BASE, 'type': 'club', 'name': 'Club Prueba', 'rut': rut(76086428), 'constituted': '2001-02-03', 'regNumber': '77', 'board': BOARD}))
    t.rpc(club2, 'register_account', J({**BASE, 'type': 'club', 'name': 'Club Dos', 'rut': rut(65000001), 'constituted': '2001-02-03', 'regNumber': '78', 'board': BOARD}))
    t.rpc(ent, 'register_account', J({**BASE, 'type': 'entrenador', 'name': 'Ent Uno', 'rut': rut(22222223)}))
    t.rpc(ajeno, 'register_account', J({**BASE, 'type': 'jugador', 'name': 'Ajeno', 'rut': rut(13131313), 'birth': '1985-01-01'}))
    cid = t.rpc(club, 'my_state')['clubs'][0]['id']
    cid2 = [c for c in t.rpc(club2, 'my_state')['clubs'] if c['name'] == 'Club Dos'][0]['id']
    t.rpc(club, 'add_sport', 'Fútbol')
    team = t.rpc(club, 'add_team', J({'sport': 'Fútbol', 'name': 'Sub-12', 'category': 'Sub-12', 'sex': 'Mixto'}))

    nino = {'name': 'Martina Lagos', 'rut': rut(24555666), 'birth': '2015-05-10', 'email': 'Martina@Prueba.cl', 'phone': '+56912345678'}
    joven = {'name': 'Tomás Vera', 'rut': rut(21555777), 'birth': '2010-03-01', 'email': 'tomas@prueba.cl', 'phone': ''}
    sin_mail = {'name': 'Pedro Sin Mail', 'rut': rut(25111222), 'birth': '2017-01-01', 'email': '', 'phone': ''}
    add = lambda quien, kind, sport, tm, rows: t.rpc(quien, 'club_add_members', cid, kind, sport, tm, J(rows))

    # --- Permisos para inscribir ---
    t.rechaza_rpc('anónimo no inscribe', None, 'club_add_members', (cid, 'jugador', 'Fútbol', None, J([nino])))
    t.rechaza_rpc('otro club no inscribe', club2, 'club_add_members', (cid, 'jugador', 'Fútbol', None, J([nino])), 'permiso')
    t.rechaza_rpc('deportista no inscribe', ajeno, 'club_add_members', (cid, 'jugador', 'Fútbol', None, J([nino])), 'permiso')
    t.rechaza_rpc('entrenador sin vínculo no inscribe', ent, 'club_add_members', (cid, 'jugador', 'Fútbol', None, J([nino])), 'permiso')
    t.rechaza_rpc('deporte que el club no tiene', club, 'club_add_members', (cid, 'jugador', 'Remo', None, J([nino])), 'deporte')
    t.rechaza_rpc('tipo inventado', club, 'club_add_members', (cid, 'socio', 'Fútbol', None, J([nino])), 'Tipo')
    t.rechaza_rpc('RUT inválido', club, 'club_add_members', (cid, 'jugador', 'Fútbol', None, J([{**nino, 'rut': '12.345.678-0'}])), 'RUT')
    t.rechaza_rpc('fecha futura', club, 'club_add_members', (cid, 'jugador', 'Fútbol', None, J([{**nino, 'birth': '2099-01-01'}])), 'nacimiento')
    t.rechaza_rpc('email de una cuenta existente', club, 'club_add_members', (cid, 'jugador', 'Fútbol', None, J([{**nino, 'email': 'ajeno@prueba.cl'}])), 'ya tiene cuenta')
    t.rechaza_rpc('RUT repetido en la planilla', club, 'club_add_members', (cid, 'jugador', 'Fútbol', None, J([nino, {**nino, 'email': ''}])), 'repetido')
    t.rechaza_rpc('apoderado sin teléfono', club, 'club_add_members', (cid, 'apoderado', None, None, J([{'name': 'Apo', 'email': 'x@prueba.cl'}])), 'teléfono')
    t.rechaza_rpc('una fila mala no deja nada a medias', club, 'club_add_members', (cid, 'jugador', 'Fútbol', None, J([joven, {**nino, 'rut': 'malo'}])), 'Fila 2')
    t.check('nada quedó a medias', not any(p['name'] == 'Tomás Vera' for p in t.rpc(club, 'my_state')['players']))

    # --- El club inscribe deportistas y apoderados ---
    r = add(club, 'jugador', 'Fútbol', None, [nino, sin_mail])
    t.check('agrega dos deportistas', r['added'] == 2)
    t.check('una invitación (el otro no tiene email)', len(r['invites']) == 1)
    st = t.rpc(club, 'my_state')
    t.check('el club ve a sus inscritos', {'Martina Lagos', 'Pedro Sin Mail'} <= {p['name'] for p in st['players']})
    t.check('quedan hábiles en el club', sum(1 for m in st['memberships'] if m['club_id'] == cid and m['status'] == 'habil') == 2)
    t.check('el club ve la invitación', [i['status'] for i in st['invites']] == ['pendiente'])
    t.check('email guardado en minúsculas', st['invites'][0]['email'] == 'martina@prueba.cl')
    t.check('otro club no ve la invitación', t.rpc(club2, 'my_state')['invites'] == [])
    t.rechaza_rpc('email con invitación abierta', club, 'club_add_members', (cid, 'apoderado', None, None, J([{'name': 'Otra', 'email': 'martina@prueba.cl', 'phone': '+56911112222'}])), 'invitación')
    ra = add(club, 'apoderado', None, None, [{'name': 'Paula Vera', 'email': 'paula@prueba.cl', 'phone': '9 8765 4321'}])
    t.check('apoderado inscrito', ra['added'] == 1 and len(ra['invites']) == 1)

    # --- Entrenador con vínculo aceptado ---
    lid = t.rpc(ent, 'request_link', cid)
    t.rpc(club, 'resolve_link', lid, True)
    re_ = add(ent, 'jugador', None, team, [joven])
    t.check('entrenador inscribe en una categoría', re_['added'] == 1)
    t.check('queda en la categoría', any(m['team_id'] == team for m in t.rpc(club, 'my_state')['memberships']))

    # --- Envío: solo lo hace la función con la clave de servicio, y solo lo que quien pide puede administrar ---
    t.rechaza('el navegador no lista invitaciones para enviar', club, 'select public.invites_to_send(%s, %s::uuid[])', (str(club), r['invites']), 'permission denied')
    t.rechaza('el navegador no marca envíos', club, "select public.invite_sent(%s, null, null)", (r['invites'][0],), 'permission denied')
    t.check('otro club no puede pedir el envío', servicio(t, 'select public.invites_to_send(%s, %s::uuid[])', (str(club2), r['invites']))[0][0] == [])
    users = enviar(t, club, r['invites'] + ra['invites'] + re_['invites'])
    t.check('tres correos enviados', len(users) == 3)
    t.check('invitación marcada enviada', t.rpc(club, 'my_state')['invites'][0]['status'] == 'enviada')
    m_uid = users['martina@prueba.cl']
    old = m_uid
    users = enviar(t, club, r['invites'])  # reenvío
    m_uid = users['martina@prueba.cl']
    t.check('reenvío reemplaza el usuario de Auth', m_uid != old)
    t.check('cuenta los envíos', [i for i in t.rpc(club, 'my_state')['invites'] if i['email'] == 'martina@prueba.cl'][0]['sent_count'] == 2)

    # --- La invitada abre el enlace ---
    info = t.rpc(m_uid, 'invite_info')
    t.check('ve su invitación', info and info['club']['name'] == 'Club Prueba' and info['kind'] == 'jugador' and info['sport'] == 'Fútbol')
    t.check('otro usuario no ve invitaciones ajenas', t.rpc(ajeno, 'invite_info') is None)
    t.rechaza_rpc('sin confirmar vínculo', m_uid, 'accept_invite', (J({'consent': True}),), 'Confirma')
    t.rechaza_rpc('sin aceptar términos', m_uid, 'accept_invite', (J({'confirm': True}),), 'Términos')
    t.check('ID de deportista', t.rpc(m_uid, 'accept_invite', J({'confirm': True, 'consent': True}))['publicId'].startswith('D'))
    st = t.rpc(m_uid, 'my_state')
    t.check('ya tiene cuenta de deportista', st['account']['type'] == 'jugador' and st['account']['name'] == 'Martina Lagos')
    t.check('su perfil es el que creó el club', any(p['account_id'] == str(m_uid) and p['rut'] == nino['rut'] for p in st['players']))
    t.check('sigue en el club', any(m['club_id'] == cid and m['status'] == 'habil' for m in st['memberships']))
    t.check('el club ve la cuenta activa', [i for i in t.rpc(club, 'my_state')['invites'] if i['email'] == 'martina@prueba.cl'][0]['status'] == 'aceptada')
    t.check('el club recibe aviso', any('activó su cuenta' in n['text'] for n in t.rpc(club, 'my_state')['notifications']))
    t.rechaza_rpc('no acepta dos veces', m_uid, 'accept_invite', (J({'confirm': True, 'consent': True}),), 'ya no está')

    # --- Apoderado: completa su RUT al activar y queda vinculado al club ---
    p_uid = users.get('paula@prueba.cl') or [u for e, u in enviar(t, club, ra['invites']).items()][0]
    t.check('apoderado ve su invitación', t.rpc(p_uid, 'invite_info')['kind'] == 'apoderado')
    t.rechaza_rpc('apoderado sin RUT', p_uid, 'accept_invite', (J({'confirm': True, 'consent': True}),), 'RUT')
    t.check('ID de apoderado', t.rpc(p_uid, 'accept_invite', J({'confirm': True, 'consent': True, 'rut': rut(11111112)}))['publicId'].startswith('A'))
    st = t.rpc(p_uid, 'my_state')
    t.check('apoderado vinculado al club', any(l['club_id'] == cid and l['status'] == 'aceptada' for l in st['links']))
    t.check('el club lista al apoderado', any(g['name'] == 'Paula Vera' for g in t.rpc(club, 'club_guardians')))

    # --- "No pertenezco a este club" ---
    t_uid = [u for e, u in enviar(t, ent, re_['invites']).items()][0]
    t.rpc(t_uid, 'reject_invite')
    st = t.rpc(club, 'my_state')
    t.check('se quita la inscripción', not any(p['name'] == 'Tomás Vera' for p in st['players']))
    t.check('invitación rechazada', [i for i in st['invites'] if i['email'] == 'tomas@prueba.cl'][0]['status'] == 'rechazada')
    t.check('el club recibe aviso del rechazo', any('no pertenece' in n['text'] for n in st['notifications']))
    with t.c.cursor() as q:
        q.execute('select count(*) from auth.users where id = %s', (t_uid,))
        t.check('se borra su usuario de Auth', q.fetchone()[0] == 0)
    t.c.commit()
    t.check('ese email se puede volver a invitar', add(club, 'apoderado', None, None, [{'name': 'Tomás Vera', 'email': 'tomas@prueba.cl', 'phone': '+56911113333'}])['added'] == 1)

    # --- Tablas cerradas ---
    t.rechaza('no se inserta en club_invites', club, 'insert into public.club_invites default values', texto='permission denied')
    t.rechaza('no se actualiza club_invites', club, "update public.club_invites set status = 'aceptada'", texto='permission denied')
    t.rechaza('anónimo no lee club_invites', None, 'select * from public.club_invites', texto='permission denied')
    t.check('un deportista no ve invitaciones del club', t.rpc(ajeno, 'my_state')['invites'] == [])

    # --- Borrar cuentas sigue funcionando ---
    t.rpc(m_uid, 'delete_my_account')
    t.check('deportista inscrito puede borrar su cuenta', not any(p['name'] == 'Martina Lagos' for p in t.rpc(club, 'my_state')['players']))
    t.rpc(club, 'delete_my_account')
    t.check('club con inscritos sin cuenta se borra sin errores', True)


def main():
    d = tempfile.mkdtemp(prefix='myclub-pg-')
    srv = pgserver.get_server(d)
    try:
        c = psycopg2.connect(srv.get_uri())
        preparar(c)
        c.commit()
        t = Prueba(c)
        correr(t)
        print(f'{t.ok} comprobaciones correctas, {len(t.fallos)} fallidas')
        return 1 if t.fallos else 0
    finally:
        srv.cleanup()
        shutil.rmtree(d, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
