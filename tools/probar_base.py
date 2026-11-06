"""Prueba las migraciones de supabase/ contra un Postgres real y local.

Crea una base temporal, simula lo mínimo de Supabase (esquema auth y roles) y
ejecuta cada caso con el rol y la identidad de un usuario, igual que la API.

Uso:  pip install pgserver psycopg2-binary  &&  python tools/probar_base.py
"""
import glob
import json
import os
import shutil
import sys
import tempfile
import uuid

import pgserver
import psycopg2

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUTH = """
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth; grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key default gen_random_uuid(), email text unique, encrypted_password text, raw_user_meta_data jsonb);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select current_setting('request.jwt.claims', true)::jsonb $$;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated;
"""


def preparar(c):
    with c.cursor() as q:
        q.execute(AUTH)
        for f in sorted(glob.glob(os.path.join(RAIZ, 'supabase/migrations/*.sql'))):
            q.execute(open(f, encoding='utf-8').read())


class Prueba:
    def __init__(self, c):
        self.c, self.ok, self.fallos = c, 0, []

    def como(self, uid, sql, args=()):
        """Ejecuta sql como el usuario uid (None = anónimo) y devuelve las filas."""
        with self.c.cursor() as q:
            try:
                q.execute("select set_config('request.jwt.claims', %s, true), set_config('role', %s, true)",
                          (json.dumps({'sub': str(uid) if uid else ''}), 'authenticated' if uid else 'anon'))
                q.execute(sql, args)
                filas = q.fetchall() if q.description else []
                self.c.commit()
                return filas
            except Exception:
                self.c.rollback()
                raise

    def rpc(self, uid, fn, *args):
        marcas = ','.join('%s' for _ in args)
        return self.como(uid, f'select public.{fn}({marcas})', args)[0][0]

    def check(self, nombre, cond):
        if cond:
            self.ok += 1
        else:
            self.fallos.append(nombre)
            print('  FALLA:', nombre)

    def rechaza(self, nombre, uid, sql, args=(), texto=None):
        try:
            self.como(uid, sql, args)
        except psycopg2.Error as e:
            msg = (e.diag.message_primary or str(e))
            self.check(f'{nombre} [{msg}]', texto is None or texto in msg)
            return
        self.check(nombre + ' (debió rechazarse)', False)

    def rechaza_rpc(self, nombre, uid, fn, args, texto=None):
        self.rechaza(nombre, uid, f"select public.{fn}({','.join('%s' for _ in args)})", args, texto)

    def usuario(self, email):
        with self.c.cursor() as q:
            q.execute('insert into auth.users (email) values (%s) returning id', (email,))
            u = q.fetchone()[0]
        self.c.commit()
        return u


J = lambda x: json.dumps(x)


def rut(n):
    """Devuelve un RUT con su dígito verificador correcto."""
    suma, factor = 0, 2
    for d in reversed(str(n)):
        suma += int(d) * factor
        factor = 2 if factor == 7 else factor + 1
    r = 11 - suma % 11
    return f"{n:,}".replace(',', '.') + '-' + {11: '0', 10: 'K'}.get(r, str(r))


RUTS = {k: rut(n) for k, n in dict(club=76086428, club2=65000001, dep=12345678, apo=11111112, ent=22222223,
                                   kid=23456789, otro=13131313, fed=14141414, prov=15151515).items()}
BOARD = [{'cargo': 'Presidente', 'name': 'Ana'}, {'cargo': 'Tesorero', 'name': 'Luis'}, {'cargo': 'Secretario', 'name': 'Rosa'}]


def correr(t):
    # --- Registro ---
    club, dep, apo, ent, ajeno, club2 = [t.usuario(f'{n}@prueba.cl') for n in ('club', 'dep', 'apo', 'ent', 'ajeno', 'club2')]
    t.check('rut válido', t.rpc(club, 'clean_rut', '12.345.678-k') == '12345678K')
    base = {'name': 'Club Prueba', 'rut': RUTS['club'], 'phone': '+56911111111', 'consent': True}
    bad = lambda **k: J({**base, 'type': 'club', 'constituted': '2001-02-03', 'regNumber': '77', 'board': BOARD, **k})
    t.rechaza_rpc('anónimo no registra', None, 'register_account', (bad(),))
    t.rechaza_rpc('RUT inválido', club, 'register_account', (bad(rut='12.345.678-9' if RUTS['dep'][-1] != '9' else '12.345.678-1'),), 'RUT no es válido')
    t.rechaza_rpc('sin consentimiento', club, 'register_account', (bad(consent=False),), 'aceptar')
    t.rechaza_rpc('directorio con 2', club, 'register_account', (bad(board=BOARD[:2]),), 'mínimo 3')
    t.rechaza_rpc('tipo inventado', club, 'register_account', (bad(type='admin'),), 'Tipo')
    r = t.rpc(club, 'register_account', bad())
    t.check('ID de club correlativo', r['publicId'] == 'C00000001')
    t.rechaza_rpc('no registra dos veces', club, 'register_account', (bad(),), 'ya está registrada')
    t.rechaza_rpc('RUT de club repetido', club2, 'register_account', (bad(),), 'este tipo con ese RUT')
    r = t.rpc(club2, 'register_account', bad(name='Club Dos', rut=RUTS['club2']))
    t.check('segundo club C00000002', r['publicId'] == 'C00000002')
    r = t.rpc(dep, 'register_account', J({**base, 'type': 'jugador', 'rut': RUTS['dep'], 'name': 'Deportista Uno', 'birth': '1990-05-05', 'height': 180, 'size': 'M'}))
    t.check('ID de deportista', r['publicId'] == 'D00000001')
    t.check('ID de apoderado', t.rpc(apo, 'register_account', J({**base, 'type': 'apoderado', 'rut': RUTS['apo'], 'name': 'Apo Uno'}))['publicId'] == 'A00000001')
    t.check('ID de entrenador', t.rpc(ent, 'register_account', J({**base, 'type': 'entrenador', 'rut': RUTS['ent'], 'name': 'Ent Uno'}))['publicId'] == 'E00000001')
    t.check('ID de otro deportista', t.rpc(ajeno, 'register_account', J({**base, 'type': 'jugador', 'rut': RUTS['otro'], 'name': 'Ajeno', 'birth': '1985-01-01'}))['publicId'] == 'D00000002')
    t.check('email viene de Auth', t.rpc(dep, 'my_state')['account']['email'] == 'dep@prueba.cl')

    # --- Sin acceso directo a las tablas ---
    for tabla in ('accounts', 'clubs', 'teams', 'players', 'memberships', 'links', 'notifications'):
        t.rechaza(f'anónimo no lee {tabla}', None, f'select * from public.{tabla}', texto='permission denied')
        t.rechaza(f'no se inserta en {tabla}', dep, f'insert into public.{tabla} default values', texto='permission denied')
        t.rechaza(f'no se actualiza {tabla}', club, f"update public.{tabla} set created_at = now()", texto='permission denied')
        t.rechaza(f'no se borra {tabla}', club, f'delete from public.{tabla}', texto='permission denied')
    t.rechaza('audit_log cerrado', club, 'select * from public.audit_log', texto='permission denied')
    t.rechaza('contadores cerrados', club, 'select * from public.id_counters', texto='permission denied')
    t.rechaza('función interna cerrada', club, "select public._next_public_id('C')", texto='permission denied')
    t.rechaza('_notify cerrada', dep, "select public._notify(%s, null, 'x', null)", (str(club),))

    # --- Búsqueda por ID ---
    h = t.rpc(None, 'find_club', 'c00000001 ')
    cid = h['id']
    t.check('busca por ID sin sesión', h['name'] == 'Club Prueba')
    t.check('búsqueda no entrega datos sensibles', set(h) == {'id', 'code', 'name', 'short', 'sports'})
    t.check('no ve club ajeno sin vínculo', len(t.rpc(dep, 'my_state')['clubs']) == 0)

    # --- Club: deportes, equipos, datos bloqueados ---
    cid2 = t.rpc(None, 'find_club', 'C00000002')['id']
    t.rechaza_rpc('deportista no agrega deportes', dep, 'add_sport', ('Fútbol',), 'Solo el club')
    t.rpc(club, 'add_sport', 'Fútbol')
    for malo in ("<img src=x>", "D'Artagnan", "');alert(1)//", 'x', 'a' * 41, '   '):
        t.rechaza_rpc('nombre de deporte peligroso: ' + malo, club, 'add_sport', (malo,), 'nombre del deporte')
    t.rpc(club, 'add_sport', '  Pádel   2 (Ñuble) ')
    t.rpc(club, 'add_sport', 'pádel 2 (ñuble)')
    t.check('deporte libre se normaliza y no se duplica', t.rpc(club, 'my_state')['clubs'][0]['sports'] == ['Fútbol', 'Pádel 2 (Ñuble)'])
    t.rechaza_rpc('equipo de deporte no habilitado', club, 'add_team', (J({'sport': 'Remo', 'name': 'X'}),), 'agrega ese deporte')
    team = t.rpc(club, 'add_team', J({'sport': 'Fútbol', 'name': 'Adulto', 'category': 'Adulto', 'sex': 'Mixto'}))
    t.rechaza_rpc('otro club no toca el equipo', club2, 'set_team_coach', (team, 'Yo'), 'Solo el club')
    t.rpc(club, 'set_team_coach', team, 'Rodrigo')
    t.rechaza_rpc('update_profile exige directorio', club, 'update_profile', (J({'email': 'a@b.cl', 'phone': '1', 'board': BOARD[:1]}),), 'mínimo 3')
    t.rpc(club, 'update_profile', J({'email': 'nuevo@club.cl', 'phone': '999', 'board': BOARD, 'city': 'Talca', 'name': 'HACKEADO', 'rut': '1-9', 'constituted': '1900-01-01'}))
    c = t.rpc(club, 'my_state')['clubs'][0]
    t.check('club edita datos editables', c['city'] == 'Talca' and c['email'] == 'nuevo@club.cl')
    t.check('nombre, RUT y fecha no cambian por update_profile', c['name'] == 'Club Prueba' and c['rut'] == RUTS['club'] and c['constituted'] == '2001-02-03')
    t.rpc(dep, 'update_profile', J({'email': 'dep@prueba.cl', 'phone': '123', 'height': 181, 'birth': '2000-01-01', 'name': 'Otro'}))
    p = t.rpc(dep, 'my_state')['players'][0]
    t.check('deportista edita estatura pero no fecha ni nombre', p['height'] == 181 and p['birth'] == '1990-05-05' and p['name'] == 'Deportista Uno')
    with t.c.cursor() as q:
        for sql in ("update public.clubs set name = 'X'", "update public.players set birth = '2000-01-01'", "update public.accounts set rut = '1-9'"):
            try:
                q.execute(sql)
                t.check('trigger bloquea: ' + sql, False)
            except psycopg2.Error:
                t.check('trigger bloquea: ' + sql, True)
            t.c.rollback()

    # --- Imágenes ---
    png = 'data:image/png;base64,iVBORw0KGgo='
    t.rechaza_rpc('rechaza SVG', club, 'set_photo', ('data:image/svg+xml;base64,PHN2Zz4=',), 'Formato')
    t.rechaza_rpc('rechaza imagen enorme', club, 'set_photo', ('data:image/png;base64,' + 'A' * 500000,), 'grande')
    t.rpc(club, 'set_photo', png)
    t.rpc(dep, 'set_photo', png)

    # --- Incorporación ---
    pid = t.rpc(dep, 'my_state')['players'][0]['id']
    otro_pid = t.rpc(ajeno, 'my_state')['players'][0]['id']
    t.rechaza_rpc('no pide por otro', dep, 'request_join', (otro_pid, cid, 'Fútbol', ''), 'tuya o de tus pupilos')
    t.rechaza_rpc('deporte no habilitado', dep, 'request_join', (pid, cid, 'Remo', ''), 'no tiene habilitado')
    mid = t.rpc(dep, 'request_join', pid, cid, 'Fútbol', 'Hola')
    t.check('deportista ve el club al solicitar', len(t.rpc(dep, 'my_state')['clubs']) == 1)
    t.check('logo del club llega al deportista', t.rpc(dep, 'my_state')['clubs'][0]['logo'] == png)
    t.check('equipo asignado solo', t.rpc(dep, 'my_state')['memberships'][0]['team_id'] == team)
    t.rechaza_rpc('un club por deporte', dep, 'request_join', (pid, cid, 'Fútbol', ''), 'un club por deporte')
    t.check('club recibe aviso', any('incorporación' in n['text'] for n in t.rpc(club, 'my_state')['notifications']))
    t.check('club ve al solicitante', any(x['id'] == pid for x in t.rpc(club, 'my_state')['players']))
    t.check('otro club no lo ve', not t.rpc(club2, 'my_state')['players'])
    t.rechaza_rpc('otro club no acepta', club2, 'resolve_join', (mid, True), 'Solo el club')
    t.rechaza_rpc('el deportista no se acepta solo', dep, 'resolve_join', (mid, True), 'Solo el club')
    t.rpc(club, 'resolve_join', mid, True)
    t.check('queda hábil', t.rpc(dep, 'my_state')['memberships'][0]['status'] == 'habil')
    t.check('deportista recibe aviso', any('aceptó' in n['text'] for n in t.rpc(dep, 'my_state')['notifications']))
    t.rechaza_rpc('no se resuelve dos veces', club, 'resolve_join', (mid, False), 'ya fue resuelta')
    t.check('no ve avisos ajenos', all(n['account_id'] == str(dep) for n in t.rpc(dep, 'my_state')['notifications']))

    # --- Vínculos ---
    t.rechaza_rpc('deportista no usa vínculo', dep, 'request_link', (cid,), 'no se vincula')
    lid = t.rpc(ent, 'request_link', cid)
    t.rechaza_rpc('vínculo duplicado', ent, 'request_link', (cid,), 'Ya enviaste')
    t.check('entrenador pendiente no ve plantel', not t.rpc(ent, 'my_state')['players'])
    t.check('club ve al solicitante del vínculo', any(a['public_id'] == 'E00000001' for a in t.rpc(club, 'my_state')['accounts']))
    t.rechaza_rpc('entrenador no se aprueba', ent, 'resolve_link', (lid, True), 'Solo el club')
    t.rpc(club, 'resolve_link', lid, True)
    t.check('entrenador aceptado ve plantel', len(t.rpc(ent, 'my_state')['players']) == 1)
    t.rechaza_rpc('ya vinculado', ent, 'request_link', (cid,), 'Ya estás vinculado')

    # --- Menores ---
    kid = {'name': 'Niña Prueba', 'rut': RUTS['kid'], 'birth': '2013-03-03', 'sex': 'F', 'rel': 'Madre', 'clubId': cid, 'sport': 'Fútbol'}
    t.rechaza_rpc('solo apoderado registra menores', dep, 'register_kid', (J(kid),), 'Solo el apoderado')
    t.rechaza_rpc('adulto no es pupilo', apo, 'register_kid', (J({**kid, 'birth': '1990-01-01'}),), 'menores de 18')
    k = t.rpc(apo, 'register_kid', J(kid))
    t.rechaza_rpc('RUT de menor repetido', apo, 'register_kid', (J(kid),), 'Ya existe')
    t.check('apoderado ve a su pupilo', any(x['id'] == k for x in t.rpc(apo, 'my_state')['players']))
    t.check('otro no ve al menor', not any(x['id'] == k for x in t.rpc(ajeno, 'my_state')['players']))
    t.check('otro club no ve al menor', not any(x['id'] == k for x in t.rpc(club2, 'my_state')['players']))
    t.check('otro deportista del club no ve al menor', not any(x['id'] == k for x in t.rpc(dep, 'my_state')['players']))
    t.rechaza_rpc('otro no postula al menor', dep, 'request_join', (k, cid2, 'Fútbol', ''), 'tuya o de tus pupilos')

    # --- Menores con cuenta propia y apoderados por ID ---
    menor, papa, mama, extrano = [t.usuario(f'{n}@prueba.cl') for n in ('menor', 'papa', 'mama', 'extrano')]
    r = t.rpc(menor, 'register_account', J({**base, 'type': 'jugador', 'rut': rut(21000001), 'name': 'Menor Solo', 'birth': '2014-02-02'}))
    code = r['publicId']
    t.check('menor crea su cuenta', code.startswith('D'))
    for u, n, x in ((papa, 'Papá Uno', 21000002), (mama, 'Mamá Uno', 21000003), (extrano, 'Extraño', 21000004)):
        t.rpc(u, 'register_account', J({**base, 'type': 'apoderado', 'rut': rut(x), 'name': n}))
    t.rechaza_rpc('solo apoderado pide vínculo', dep, 'request_guardian', (code, 'Padre'), 'Solo un apoderado')
    t.rechaza_rpc('no vincula a un adulto', papa, 'request_guardian', ('D00000001', 'Padre'), 'menor de edad')
    t.rechaza_rpc('ID inexistente', papa, 'request_guardian', ('D99999999', 'Padre'), 'menor de edad')
    t.rechaza_rpc('anónimo no pide vínculo', None, 'request_guardian', (code, 'Padre'))
    g = t.rpc(papa, 'request_guardian', code, 'Padre')
    s = t.rpc(papa, 'my_state')
    t.check('sin aceptar no ve al menor', not s['players'] and s['guardian_links'][0]['playerName'] is None and s['guardian_links'][0]['playerId'] is None)
    t.rechaza_rpc('sin aceptar no puede inscribirlo', papa, 'request_join', (t.rpc(menor, 'my_state')['players'][0]['id'], cid, 'Fútbol', ''), 'tuya o de tus pupilos')
    t.rechaza_rpc('solicitud repetida', papa, 'request_guardian', (code, 'Padre'), 'Ya enviaste')
    s = t.rpc(menor, 'my_state')
    pm = s['players'][0]['id']
    t.check('menor ve quién pide el vínculo', s['guardian_links'][0]['guardianName'] == 'Papá Uno')
    t.check('menor recibe aviso', any('apoderado' in n['text'] for n in s['notifications']))
    t.check('menor no ve datos privados del apoderado', len(s['accounts']) == 1)
    t.rechaza_rpc('apoderado no se acepta solo', papa, 'resolve_guardian', (g, True), 'Solo el deportista')
    t.rechaza_rpc('un tercero no acepta', extrano, 'resolve_guardian', (g, True), 'Solo el deportista')
    t.rechaza_rpc('otro deportista no acepta', dep, 'resolve_guardian', (g, True), 'Solo el deportista')
    t.rpc(menor, 'resolve_guardian', g, True)
    s = t.rpc(papa, 'my_state')
    t.check('aceptado ve a su pupilo', s['players'][0]['id'] == pm and s['guardian_links'][0]['playerName'] == 'Menor Solo')
    t.rechaza_rpc('no se resuelve dos veces', menor, 'resolve_guardian', (g, False), 'ya fue resuelta')
    t.rechaza_rpc('ya es pupilo', papa, 'request_guardian', (code, 'Padre'), 'ya es tu pupilo')
    m2 = t.rpc(papa, 'request_join', pm, cid, 'Fútbol', '')
    g2 = t.rpc(mama, 'request_guardian', code, 'Madre')
    t.rpc(menor, 'resolve_guardian', g2, True)
    t.check('dos apoderados a la vez', t.rpc(mama, 'my_state')['players'][0]['id'] == pm)
    t.rpc(club, 'resolve_join', m2, True)
    t.check('ambos apoderados reciben el aviso del club', all(any('aceptó la incorporación' in n['text'] for n in t.rpc(u, 'my_state')['notifications']) for u in (papa, mama)))
    t.check('apoderado vinculado ve el club', len(t.rpc(papa, 'my_state')['clubs']) == 1)
    t.rpc(menor, 'remove_guardian', g2)
    t.check('quitado deja de ver al menor', not t.rpc(mama, 'my_state')['players'])
    t.rechaza_rpc('quitado no puede insistir', mama, 'request_guardian', (code, 'Madre'), 'ya rechazó')
    g3 = t.rpc(extrano, 'request_guardian', code, 'Padre')
    t.rpc(menor, 'resolve_guardian', g3, False)
    t.check('rechazado no ve al menor', not t.rpc(extrano, 'my_state')['players'])
    t.rechaza_rpc('rechazado no puede insistir', extrano, 'request_guardian', (code, 'Padre'), 'ya rechazó')
    t.rechaza_rpc('un tercero no quita vínculos', extrano, 'remove_guardian', (g,), 'No puedes modificar')
    for i in range(6):
        u = t.usuario(f'hijo{i}@prueba.cl')
        c = t.rpc(u, 'register_account', J({**base, 'type': 'jugador', 'rut': rut(21000100 + i), 'name': 'Hijo Masivo', 'birth': '2012-01-01'}))['publicId']
        if i < 5:
            t.rpc(extrano, 'request_guardian', c, 'Padre')
        else:
            t.rechaza_rpc('límite de solicitudes masivas', extrano, 'request_guardian', (c, 'Padre'), 'demasiadas')
    t.rechaza('vínculos cerrados por API', menor, 'select * from public.guardian_links', texto='permission denied')
    t.rechaza('función interna de vínculos', None, 'select public.my_guardian_links()', texto='permission denied')
    t.rpc(papa, 'delete_my_account')
    t.check('borrar apoderado no borra al menor con cuenta', len(t.rpc(menor, 'my_state')['players']) == 1)

    n = t.rpc(dep, 'my_state')['notifications'][0]['id']
    t.rpc(ajeno, 'mark_notifs_read', n)
    t.check('no marca avisos ajenos', not t.rpc(dep, 'my_state')['notifications'][0]['read'])
    t.rpc(dep, 'mark_notifs_read', n)
    t.check('marca avisos propios', t.rpc(dep, 'my_state')['notifications'][0]['read'])

    # --- Registro con vínculo incluido ---
    nuevo = t.usuario('nuevo@prueba.cl')
    t.rpc(nuevo, 'register_account', J({**base, 'type': 'jugador', 'rut': RUTS['fed'], 'name': 'Nuevo', 'birth': '1980-01-01', 'link': {'clubId': cid, 'sport': 'Fútbol'}}))
    t.check('registro deja solicitud pendiente', t.rpc(nuevo, 'my_state')['memberships'][0]['status'] == 'pendiente')
    fallido = t.usuario('fallido@prueba.cl')
    t.rechaza_rpc('registro falla entero si el vínculo falla', fallido, 'register_account',
                  (J({**base, 'type': 'jugador', 'rut': RUTS['prov'], 'name': 'Fallido', 'birth': '1980-01-01', 'link': {'clubId': cid, 'sport': 'Remo'}}),))
    t.check('sin cuenta a medias', t.rpc(fallido, 'my_state')['account'] is None)

    # --- Eliminar cuenta ---
    t.rpc(apo, 'delete_my_account')
    with t.c.cursor() as q:
        q.execute('select count(*) from public.players where id = %s', (k,))
        t.check('al borrar apoderado se borra su pupilo', q.fetchone()[0] == 0)
        q.execute('select count(*) from auth.users where id = %s', (apo,))
        t.check('usuario de Auth eliminado', q.fetchone()[0] == 0)
    t.c.commit()
    t.rpc(club, 'delete_my_account')
    t.check('club con deportistas sobrevive', t.rpc(dep, 'my_state')['clubs'][0]['name'] == 'Club Prueba')
    t.rpc(club2, 'delete_my_account')
    t.check('club sin deportistas se borra', t.rpc(None, 'find_club', 'C00000002') is None)


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
