"""Prueba las migraciones de supabase/ contra un Postgres real y local.

Crea una base temporal, simula lo mínimo de Supabase (esquema auth y roles) y
ejecuta cada caso con el rol y la identidad de un usuario, igual que la API.

Uso:  pip install pgserver psycopg2-binary  &&  python tools/probar_base.py
"""
import datetime
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
create function auth.uid() returns uuid language sql stable as $$ select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid $$;
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
    r = t.rpc(None, 'search_clubs', 'club')
    t.check('busca por nombre sin sesión', {x['name'] for x in r} == {'Club Prueba', 'Club Dos'})
    t.check('búsqueda solo entrega datos públicos', all(set(x) == {'id', 'code', 'name', 'short', 'sports', 'logo', 'city'} for x in r))
    t.check('sin distinguir mayúsculas ni acentos', [x['name'] for x in t.rpc(None, 'search_clubs', 'PRÚEBA')] == ['Club Prueba'])
    t.check('busca por ID', [x['name'] for x in t.rpc(None, 'search_clubs', 'c00000002')] == ['Club Dos'])
    t.check('exige 2 caracteres', t.rpc(None, 'search_clubs', 'c') == [] and t.rpc(None, 'search_clubs', '  ') == [])
    t.check('comodines no listan todo', t.rpc(None, 'search_clubs', '%%') == [] and t.rpc(None, 'search_clubs', '__') == [])
    t.check('nombre inexistente', t.rpc(None, 'search_clubs', 'no existe') == [])
    t.rechaza('búsqueda interna cerrada', None, "select public._norm('x')", texto='permission denied')
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
    t.rechaza_rpc('menor de 14 sin apoderado no se une', menor, 'request_join', (t.rpc(menor, 'my_state')['players'][0]['id'], cid, 'Fútbol', ''), 'menores de 14')
    t.check('sus datos no llegan al club', not any(x['name'] == 'Menor Solo' for x in t.rpc(club, 'my_state')['players']))
    ado = t.usuario('ado@prueba.cl')
    t.rpc(ado, 'register_account', J({**base, 'type': 'jugador', 'rut': rut(21000005), 'name': 'Adolescente', 'birth': '2011-01-01'}))
    t.check('desde 14 años se une solo', bool(t.rpc(ado, 'request_join', t.rpc(ado, 'my_state')['players'][0]['id'], cid, 'Fútbol', '')))
    n14 = t.usuario('n14@prueba.cl')
    t.rechaza_rpc('menor de 14 no entra con vínculo en el registro', n14, 'register_account', (J({**base, 'type': 'jugador', 'rut': rut(21000006), 'name': 'Chico', 'birth': '2015-01-01', 'link': {'clubId': cid, 'sport': 'Fútbol'}}),), 'menores de 14')
    t.check('registro rechazado no deja cuenta', t.rpc(n14, 'my_state')['account'] is None)
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
    m3 = t.rpc(menor, 'my_state')['memberships'][0]['id']
    t.check('con apoderado aceptado sí se une', bool(m3))
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

    # --- Módulos: cada dato con sus reglas de lectura y escritura ---
    def guarda(u, kind, rid, data):
        return t.rpc(u, 'save_records', J({'up': [{'kind': kind, 'id': rid, 'data': data}]}))

    def niega(nombre, u, kind, rid, data):
        t.rechaza_rpc(nombre, u, 'save_records', (J({'up': [{'kind': kind, 'id': rid, 'data': data}]}),), 'permiso')

    def ve(u, kind, rid):
        return any(r['kind'] == kind and r['id'] == rid for r in t.rpc(u, 'my_state')['records'])

    def dato(u, kind, rid):
        return next(r['data'] for r in t.rpc(u, 'my_state')['records'] if r['kind'] == kind and r['id'] == rid)

    t.rechaza_rpc('tipo de dato inventado', club, 'save_records', (J({'up': [{'kind': 'hack', 'id': 'x', 'data': {}}]}),), 'no válido')
    t.rechaza_rpc('anónimo no guarda', None, 'save_records', (J({'up': []}),))
    ev = {'id': 'e1', 'clubId': cid, 'teamId': team, 'title': 'Partido', 'present': [], 'date': '2026-12-01'}
    niega('deportista no crea eventos', dep, 'events', 'e1', ev)
    niega('otro club no crea eventos ajenos', club2, 'events', 'e1', ev)
    guarda(ent, 'events', 'e1', ev)
    t.check('deportista del club ve el evento', ve(dep, 'events', 'e1'))
    t.check('ajeno no ve el evento', not ve(ajeno, 'events', 'e1'))
    guarda(dep, 'events', 'e1', {**ev, 'present': [str(pid)]})
    t.check('deportista marca asistencia', dato(club, 'events', 'e1')['present'] == [str(pid)])
    niega('deportista no cambia el evento', dep, 'events', 'e1', {**ev, 'title': 'Hackeado'})
    niega('ajeno no marca asistencia', ajeno, 'events', 'e1', {**ev, 'present': ['x']})
    guarda(club, 'movements', 'm1', {'id': 'm1', 'clubId': cid, 'type': 'egreso', 'amount': 1000})
    t.check('finanzas visibles para el club', ve(club, 'movements', 'm1'))
    t.check('finanzas ocultas al deportista', not ve(dep, 'movements', 'm1'))
    t.check('finanzas ocultas al entrenador', not ve(ent, 'movements', 'm1'))
    niega('entrenador no registra finanzas', ent, 'movements', 'm2', {'id': 'm2', 'clubId': cid, 'amount': 1})
    niega('finanzas en club ajeno', club2, 'movements', 'm3', {'id': 'm3', 'clubId': cid, 'amount': 1})
    ch = {'id': 'c1', 'playerId': str(pid), 'clubId': cid, 'concept': 'Cuota', 'kind': 'mensual', 'amount': 20000, 'status': 'pendiente'}
    niega('deportista no crea cuotas', dep, 'charges', 'c1', ch)
    guarda(club, 'charges', 'c1', ch)
    t.check('deportista ve su cobro', ve(dep, 'charges', 'c1'))
    t.check('ajeno no ve el cobro', not ve(ajeno, 'charges', 'c1'))
    niega('deportista no se marca pagado', dep, 'charges', 'c1', {**ch, 'status': 'pagado'})
    guarda(club, 'charges', 'c2', {**ch, 'id': 'c2', 'amount': 5000})
    t.rechaza_rpc('deportista no registra pago manual', dep, 'record_manual_payment', (['c1'], 'Efectivo'), 'Solo el club')
    t.rechaza_rpc('otro club no registra pago', club2, 'record_manual_payment', (['c1'], 'Efectivo'), 'Solo el club')
    rc = t.rpc(club, 'record_manual_payment', ['c1'], 'Efectivo')
    t.check('pago manual marca el cobro', dato(dep, 'charges', 'c1')['status'] == 'pagado')
    t.check('deportista ve su comprobante', dato(dep, 'receipts', rc)['amount'] == 20000)
    t.check('pago genera ingreso del club', any(r['kind'] == 'movements' and r['data'].get('category') == 'Cuotas mensuales' for r in t.rpc(club, 'my_state')['records']))
    t.check('pago no se aplica dos veces', t.rpc(club, 'record_manual_payment', ['c1'], 'Efectivo') is None)
    t.rechaza_rpc('ajeno no inicia pago', ajeno, 'start_payment', (['c2'],), 'no están disponibles')
    t.rechaza_rpc('no inicia pago de cobro pagado', dep, 'start_payment', (['c1'],), 'no están disponibles')
    t.rechaza_rpc('sin cuenta conectada no hay pago en línea', dep, 'start_payment', (['c2'],), 'aún no activa')
    tok = 'TEST-' + '1234567890' * 3
    t.rechaza_rpc('deportista no conecta pagos', dep, 'set_club_pay_key', ('mercadopago', tok), 'Solo la cuenta del club')
    t.rechaza_rpc('token inválido', club, 'set_club_pay_key', ('mercadopago', 'abc'), 'no es válido')
    t.rechaza_rpc('proveedor no disponible', club, 'set_club_pay_key', ('flow', tok), 'no está disponible')
    t.rpc(club, 'set_club_pay_key', 'mercadopago', tok)
    t.check('club queda con pago en línea', next(c for c in t.rpc(dep, 'my_state')['clubs'] if c['id'] == cid)['pay_provider'] == 'mercadopago')
    t.rechaza('nadie de la app lee el token', club, 'select secret from public.club_pay_keys', (), 'permission denied')
    t.check('el token no viaja en el estado', tok not in json.dumps(t.rpc(club, 'my_state')))
    pg = t.rpc(dep, 'start_payment', ['c2'])
    t.check('pago en línea toma el monto del servidor', pg['amount'] == 5000 and pg['club'] == cid)
    t.rechaza('deportista no confirma pagos', dep, 'select public.confirm_payment(%s, 5000, %s, %s)', (pg['id'], 'x', cid), 'permission denied')
    t.rechaza('anónimo no confirma pagos', None, 'select public.confirm_payment(%s, 5000, %s, %s)', (pg['id'], 'x', cid), 'permission denied')
    with t.c.cursor() as q:
        for nombre, args in (('rechaza monto distinto', (pg['id'], 1, 'x', cid)), ('rechaza pago de otro club', (pg['id'], 5000, 'x', cid2))):
            try:
                q.execute('select public.confirm_payment(%s, %s, %s, %s)', args)
                t.check(nombre, False)
            except psycopg2.Error:
                t.check(nombre, True)
            t.c.rollback()
        q.execute('select public.confirm_payment(%s, 5000, %s, %s)', (pg['id'], 'mp-1', cid))
        t.c.commit()
    t.check('confirmación marca el cobro', dato(dep, 'charges', 'c2')['status'] == 'pagado')
    pas = {'id': 'c3', 'playerId': str(pid), 'clubId': cid, 'kind': 'matricula', 'amount': 1, 'status': 'pendiente'}
    niega('deportista no crea matrículas', dep, 'charges', 'c3', pas)
    t.rpc(club, 'remove_club_pay_key')
    t.check('club desconecta el pago en línea', next(c for c in t.rpc(club, 'my_state')['clubs'] if c['id'] == cid)['pay_provider'] is None)

    # Ingresos: el club con su clubId, el entrenador a deportistas activos de su club
    guarda(club, 'incomeItems', 'ii1', {'id': 'ii1', 'clubId': cid, 'kind': 'Torneo', 'name': 'Torneo verano', 'amount': 8000})
    t.check('entrenador ve los conceptos de cobro', ve(ent, 'incomeItems', 'ii1'))
    t.check('deportista no ve los conceptos de cobro', not ve(dep, 'incomeItems', 'ii1'))
    niega('ingreso sin club se rechaza', club, 'incomeItems', 'ii0', {'id': 'ii0', 'kind': 'Torneo', 'name': 'x', 'amount': 1})
    guarda(ent, 'incomeItems', 'ii2', {'id': 'ii2', 'clubId': cid, 'kind': 'Viaje', 'name': 'Viaje', 'amount': 15000})
    guarda(ent, 'incomeCats', 'ic1', {'id': 'ic1', 'clubId': cid, 'name': 'Rifa'})
    t.check('cargo propio visible para el deportista', ve(dep, 'incomeCats', 'ic1'))
    niega('deportista no crea cargos', dep, 'incomeCats', 'ic2', {'id': 'ic2', 'clubId': cid, 'name': 'Hack'})
    chv = {'id': 'c4', 'playerId': str(pid), 'clubId': cid, 'teamId': team, 'concept': 'Viaje', 'kind': 'extraordinaria', 'cat': 'Viaje', 'amount': 15000, 'status': 'pendiente', 'paidAt': None}
    guarda(ent, 'charges', 'c4', chv)
    t.check('deportista recibe el cobro del entrenador', ve(dep, 'charges', 'c4'))
    t.check('entrenador ve el cobro que creó', ve(ent, 'charges', 'c4'))
    t.check('entrenador no ve otros cobros', not ve(ent, 'charges', 'c2'))
    niega('entrenador no marca pagado', ent, 'charges', 'c4', {**chv, 'status': 'pagado'})
    niega('entrenador no crea cobros pagados', ent, 'charges', 'c5', {**chv, 'id': 'c5', 'status': 'pagado'})
    niega('entrenador no cobra pases', ent, 'charges', 'c6', {**chv, 'id': 'c6', 'kind': 'pase'})
    niega('entrenador no cobra montos inválidos', ent, 'charges', 'c7', {**chv, 'id': 'c7', 'amount': -5})
    niega('entrenador no cobra a otro club', ent, 'charges', 'c8', {**chv, 'id': 'c8', 'clubId': cid2, 'teamId': None})
    niega('otro club no cobra a mi deportista', club2, 'charges', 'c9', {**chv, 'id': 'c9', 'clubId': cid2, 'teamId': None})
    t.rechaza_rpc('entrenador no borra cobros', ent, 'save_records', (J({'del': [{'kind': 'charges', 'id': 'c4'}]}),), 'permiso')
    t.rpc(club, 'record_manual_payment', ['c4'], 'Transferencia')
    t.check('el pago entra con la categoría del ingreso', any(r['kind'] == 'movements' and r['data'].get('category') == 'Viaje' for r in t.rpc(club, 'my_state')['records']))

    # Cuenta para transferencias: la ven los relacionados con el club, la escribe solo el club
    cb = {'id': cid, 'clubId': cid, 'bank': 'BancoEstado', 'accType': 'Cuenta corriente', 'number': '123', 'holder': 'Club', 'rut': '1-9'}
    niega('entrenador no cambia la cuenta del club', ent, 'clubPay', cid, cb)
    guarda(club, 'clubPay', cid, cb)
    t.check('deportista ve la cuenta del club', ve(dep, 'clubPay', cid))
    t.check('ajeno no ve la cuenta del club', not ve(ajeno, 'clubPay', cid))

    # Avisos segmentados por categoría y deporte
    def avisos(u):
        return [n['text'] for n in t.rpc(u, 'my_state')['notifications']]
    t.rpc(club, 'send_notifs', J([{'to': ['jugador'], 'text': 'Solo otra categoría', 'clubId': cid, 'teams': [str(uuid.uuid4())]}]))
    t.rpc(club, 'send_notifs', J([{'to': ['jugador'], 'text': 'Solo Remo', 'clubId': cid, 'sport': 'Remo'}]))
    t.rpc(club, 'send_notifs', J([{'to': ['jugador'], 'text': 'Mi categoría', 'clubId': cid, 'teams': [team], 'sport': 'Fútbol'}]))
    t.rpc(club, 'send_notifs', J([{'to': ['entrenador'], 'text': 'A entrenadores', 'clubId': cid}]))
    ta = avisos(dep)
    t.check('aviso llega solo a su categoría', 'Mi categoría' in ta and 'Solo otra categoría' not in ta and 'Solo Remo' not in ta)
    t.check('aviso a entrenadores', 'A entrenadores' in avisos(ent) and 'A entrenadores' not in ta)
    post = {'id': 'po1', 'clubId': cid, 'text': 'Hola', 'likes': [], 'comments': []}
    niega('ajeno no publica en el muro', ajeno, 'posts', 'po1', post)
    guarda(dep, 'posts', 'po1', post)
    t.check('entrenador ve la publicación', ve(ent, 'posts', 'po1'))
    guarda(ent, 'posts', 'po1', {**post, 'likes': ['e']})
    niega('otro no edita el texto ajeno', ajeno, 'posts', 'po1', {**post, 'text': 'x'})
    chat = {'id': 'ch1', 'type': 'directo', 'title': 'x', 'members': [str(pid), 'E00000001'], 'msgs': []}
    guarda(dep, 'chats', 'ch1', chat)
    t.check('participante ve el chat', ve(ent, 'chats', 'ch1'))
    t.check('ajeno no ve el chat', not ve(ajeno, 'chats', 'ch1'))
    niega('ajeno no sobrescribe un chat agregándose', ajeno, 'chats', 'ch1', {**chat, 'members': chat['members'] + [t.rpc(ajeno, 'my_state')['account']['public_id']]})

    # --- Acceso propio para un menor que registró su apoderado ---
    hija, intruso = t.usuario('hija@prueba.cl'), t.usuario('intruso@prueba.cl')
    kidreg = J({**base, 'type': 'jugador', 'rut': RUTS['kid'], 'name': 'Niña Prueba', 'birth': '2013-03-03'})
    t.rechaza_rpc('sin acceso del apoderado no toma el perfil', hija, 'register_account', (kidreg,), 'pídele que te dé acceso')
    t.rechaza_rpc('solo su apoderado da acceso', dep, 'grant_player_access', (k, 'hija@prueba.cl'), 'Solo su apoderado')
    t.rechaza_rpc('email inválido para el acceso', apo, 'grant_player_access', (k, 'hija'), 'no es válido')
    t.rechaza_rpc('email de otra cuenta', apo, 'grant_player_access', (k, 'dep@prueba.cl'), 'ya tiene una cuenta')
    t.rpc(apo, 'grant_player_access', k, ' Hija@Prueba.cl ')
    t.rechaza_rpc('otro email no toma el perfil', intruso, 'register_account', (kidreg,), 'pídele que te dé acceso')
    t.rpc(hija, 'register_account', kidreg)
    t.check('la hija entra con su mismo perfil', any(x['id'] == k and x['account_id'] == str(hija) for x in t.rpc(hija, 'my_state')['players']))
    t.check('no se duplica el deportista', sum(1 for x in t.rpc(apo, 'my_state')['players'] if x['rut'] == RUTS['kid']) == 1)
    t.check('el apoderado mantiene el acceso', any(x['id'] == k for x in t.rpc(apo, 'my_state')['players']))
    t.check('el apoderado recibe el aviso', any('propia cuenta' in n['text'] for n in t.rpc(apo, 'my_state')['notifications']))
    t.rechaza_rpc('no se da acceso dos veces', apo, 'grant_player_access', (k, 'otra@prueba.cl'), 'Ya tiene su propia cuenta')

    # --- Estados de deportistas ---
    mm = t.rpc(dep, 'my_state')['memberships'][0]['id']
    es = lambda st: J([{'id': mm, 'status': st, 'teamId': team}])
    t.rechaza_rpc('ajeno no cambia estados', ajeno, 'save_memberships', (es('suspendido'),), 'permiso')
    t.rpc(dep, 'save_memberships', es('suspendido'))
    t.rechaza_rpc('deportista no se reactiva solo', dep, 'save_memberships', (es('habil'),), 'permiso')
    t.rpc(club, 'save_memberships', es('habil'))
    t.check('club reactiva', t.rpc(dep, 'my_state')['memberships'][0]['status'] == 'habil')

    # --- Categorías y matrícula ---
    t.rechaza_rpc('otro club no edita categorías', club2, 'update_team', (J({'id': team, 'name': 'X'}),), 'Solo el club')
    t.rpc(club, 'update_team', J({'id': team, 'name': 'Adulto A', 'category': 'Adulto', 'sex': 'Mixto'}))
    t.check('categoría editada', t.rpc(dep, 'my_state')['teams'][0]['name'] == 'Adulto A')
    t.rechaza_rpc('categoría con deportistas no se elimina', club, 'delete_team', (team,), 'tiene deportistas')
    vacia = t.rpc(club, 'add_team', J({'sport': 'Fútbol', 'name': 'Sub-15', 'category': 'Sub-15', 'sex': 'Mixto'}))
    t.rechaza_rpc('otro club no elimina categorías', club2, 'delete_team', (vacia,), 'Solo el club')
    t.rpc(club, 'set_sport_matricula', 'Fútbol', 30000)
    equipos = t.rpc(club, 'my_state')['teams']
    t.check('matrícula en todas las categorías del deporte', all(x['matricula'] == 30000 for x in equipos if x['sport'] == 'Fútbol'))
    mats = [r for r in t.rpc(dep, 'my_state')['records'] if r['kind'] == 'charges' and r['data']['kind'] == 'matricula']
    t.check('matrícula se carga al deportista', len(mats) == 1 and mats[0]['data']['amount'] == 30000 and mats[0]['data']['status'] == 'pendiente')
    t.rpc(club, 'update_team', J({'id': team, 'name': 'Adulto A', 'matricula': 25000}))
    t.check('monto editable por categoría', dato(dep, 'charges', mats[0]['id'])['amount'] == 25000)
    t.check('otra categoría conserva su monto', next(x for x in t.rpc(club, 'my_state')['teams'] if x['id'] == vacia)['matricula'] == 30000)
    t.rpc(club, 'record_manual_payment', [mats[0]['id']], 'Efectivo')
    t.rpc(club, 'update_team', J({'id': team, 'name': 'Adulto A', 'matricula': 99000}))
    t.check('cobro pagado no cambia de monto', dato(dep, 'charges', mats[0]['id'])['amount'] == 25000)
    t.check('tampoco se cobra dos veces', len([r for r in t.rpc(dep, 'my_state')['records'] if r['kind'] == 'charges' and r['data']['kind'] == 'matricula']) == 1)
    t.rpc(club, 'delete_team', vacia)
    t.check('categoría vacía eliminada', not any(x['id'] == vacia for x in t.rpc(club, 'my_state')['teams']))
    t.rpc(club, 'set_sport_matricula', 'Fútbol', 40000)
    pend = [m for m in t.rpc(club, 'my_state')['memberships'] if m['status'] == 'pendiente' and m['team_id'] == team]
    t.rpc(club, 'resolve_join', pend[0]['id'], True)
    t.check('deportista aceptado después recibe su matrícula', any(r['kind'] == 'charges' and r['data']['kind'] == 'matricula' and r['data']['amount'] == 40000 and r['data']['playerId'] == pend[0]['player_id'] for r in t.rpc(club, 'my_state')['records']))
    guarda(dep, 'docs', 'MC-AAAA-BBBB', {'code': 'MC-AAAA-BBBB', 'type': 'Certificado', 'title': 'x', 'holder': 'Deportista Uno'})
    t.check('documento se verifica por código', t.rpc(None, 'verify_doc', 'mc-aaaa-bbbb')['holder'] == 'Deportista Uno')
    t.check('documentos ajenos no se listan', not ve(ajeno, 'docs', 'MC-AAAA-BBBB'))

    # --- Avisos, directorio y perfiles externos ---
    t.rpc(dep, 'send_notifs', J([{'to': ['directivo'], 'text': 'Aviso del deportista', 'clubId': cid}]))
    t.check('aviso llega al club', any(n['text'] == 'Aviso del deportista' for n in t.rpc(club, 'my_state')['notifications']))
    t.rpc(ajeno, 'send_notifs', J([{'to': ['directivo'], 'text': 'Spam', 'clubId': cid}]))
    t.check('ajeno no envía avisos al club', not any(n['text'] == 'Spam' for n in t.rpc(club, 'my_state')['notifications']))
    t.rpc(club, 'send_notifs', J([{'to': ['jugador'], 'text': 'Aviso a todos', 'clubId': cid}]))
    t.check('aviso a deportistas del club', any(n['text'] == 'Aviso a todos' for n in t.rpc(dep, 'my_state')['notifications']))
    t.check('directorio para buscar clubes', len(t.rpc(ajeno, 'my_state')['directory']['clubs']) >= 1)
    t.check('directorio sin datos sensibles', all('rut' not in c and 'phone' not in c for c in t.rpc(ajeno, 'my_state')['directory']['clubs']))
    t.rechaza('anónimo no ve directorio', None, 'select public.directory()', texto='permission denied')
    t.rechaza('anónimo no lee registros', None, 'select * from public.records', texto='permission denied')
    t.rechaza('nadie escribe registros directo', club, "insert into public.records (kind, id, data) values ('docs', 'x', '{}')", texto='permission denied')
    t.rechaza('pagos cerrados por API', club, 'select * from public.payments', texto='permission denied')
    fe, fe2, pv = t.usuario('fe@prueba.cl'), t.usuario('fe2@prueba.cl'), t.usuario('pv@prueba.cl')
    t.rpc(fe, 'register_account', J({**base, 'type': 'federacion', 'rut': rut(17000001), 'name': 'Fed Fútbol', 'sport': 'Fútbol'}))
    t.rpc(pv, 'register_account', J({**base, 'type': 'proveedor', 'rut': rut(17000002), 'name': 'Prov Uno', 'cat': 'Alimentación'}))
    cm = {'id': 'co1', 'sport': 'Fútbol', 'title': 'Comunicado'}
    niega('club no publica comunicados', club, 'communiques', 'co1', cm)
    niega('federación no publica en otro deporte', fe, 'communiques', 'co2', {**cm, 'id': 'co2', 'sport': 'Remo'})
    guarda(fe, 'communiques', 'co1', cm)
    t.check('todos leen comunicados', ve(ajeno, 'communiques', 'co1'))
    pid_ = 'pv_' + t.rpc(pv, 'my_state')['account']['public_id']
    guarda(pv, 'providers', pid_, {'id': pid_, 'name': 'Prov Uno', 'items': []})
    niega('nadie edita un proveedor ajeno', club, 'providers', pid_, {'id': pid_, 'name': 'Hack'})
    qt = {'id': 'q1', 'providerId': pid_, 'clubId': cid, 'status': 'solicitada'}
    niega('deportista no pide cotizaciones del club', dep, 'quotes', 'q1', qt)
    guarda(club, 'quotes', 'q1', qt)
    t.check('proveedor ve la cotización', ve(pv, 'quotes', 'q1'))
    t.check('otro no ve la cotización', not ve(ajeno, 'quotes', 'q1'))
    guarda(pv, 'quotes', 'q1', {**qt, 'status': 'enviada'})

    # --- Directivos: el club los crea y decide qué funciones usan ---
    dir1, dir2 = t.usuario('dir1@prueba.cl'), t.usuario('dir2@prueba.cl')
    rd = rut(18000001)
    ficha = {'name': 'Directiva Uno', 'rut': rd, 'cargo': 'Tesorera', 'email': 'dir1@prueba.cl', 'perms': ['finanzas']}
    reg_d = J({**base, 'type': 'dirigente', 'rut': rd, 'name': 'Directiva Uno'})
    t.rechaza_rpc('sin ficha del club no hay directivo', dir1, 'register_account', (reg_d,), 'crearte primero')
    t.rechaza_rpc('solo el club crea directivos', ent, 'save_director', (J(ficha),), 'cuenta del club')
    t.rechaza_rpc('función de la cuenta del club no se delega', club, 'save_director', (J({**ficha, 'perms': ['club']}),), 'no válida')
    t.rechaza_rpc('email con otra cuenta', club, 'save_director', (J({**ficha, 'email': 'dep@prueba.cl'}),), 'ya tiene una cuenta')
    t.rechaza_rpc('RUT inválido en la ficha', club, 'save_director', (J({**ficha, 'rut': '1-1'}),), 'RUT no es válido')
    did = t.rpc(club, 'save_director', J(ficha))
    t.rechaza_rpc('email ya autorizado', club, 'save_director', (J({**ficha, 'rut': rut(18000002)}),), 'ya está autorizado')
    t.rechaza_rpc('otro email no activa la ficha', dir2, 'register_account', (reg_d,), 'crearte primero')
    t.check('ID de directivo', t.rpc(dir1, 'register_account', reg_d)['publicId'] == 'M00000001')
    est = t.rpc(dir1, 'my_state')
    t.check('directivo vinculado a su club', est['directors'][0]['club_id'] == cid and est['directors'][0]['account_id'] == str(dir1))
    t.check('directivo ve el club y sus deportistas', any(c['id'] == cid for c in est['clubs']) and len(est['memberships']) > 0)
    t.check('club ve a su directivo', any(x['id'] == did for x in t.rpc(club, 'my_state')['directors']))
    t.check('otro no ve directivos', t.rpc(ajeno, 'my_state')['directors'] == [])
    t.check('aviso al club al activar', any('activó su cuenta' in n['text'] for n in t.rpc(club, 'my_state')['notifications']))
    t.rechaza('directivos cerrados a anónimos', None, 'select * from public.club_directors', texto='permission denied')
    t.rechaza('nadie escribe directivos directo', club, 'delete from public.club_directors', texto='permission denied')
    pd = next(m['player_id'] for m in est['memberships'] if m['club_id'] == cid and m['status'] == 'habil')
    cobro = {'id': 'chd1', 'playerId': pd, 'clubId': cid, 'kind': 'mensual', 'amount': 1000, 'status': 'pendiente', 'concept': 'Cuota', 'paidAt': None}
    guarda(club, 'movements', 'mvd1', {'id': 'mvd1', 'clubId': cid, 'type': 'ingreso', 'amount': 1})
    guarda(dir1, 'charges', 'chd1', cobro)
    t.check('con finanzas ve movimientos', ve(dir1, 'movements', 'mvd1'))
    t.check('con finanzas registra un pago', t.rpc(dir1, 'record_manual_payment', ['chd1'], 'Efectivo') is not None)
    niega('sin mensajes masivos no publica', dir1, 'broadcasts', 'bd1', {'id': 'bd1', 'clubId': cid})
    niega('sin asambleas no convoca', dir1, 'assemblies', 'as1', {'id': 'as1', 'clubId': cid})
    niega('cuenta bancaria es solo del club', dir1, 'clubPay', 'cpd', {'id': 'cpd', 'clubId': cid})
    t.rechaza_rpc('sin deportes no agrega deportes', dir1, 'add_sport', ('Remo',), 'Solo el club')
    t.rechaza_rpc('sin solicitudes no resuelve', dir1, 'resolve_join', (str(uuid.uuid4()), True), 'Solo el club')
    t.rechaza_rpc('directivo no crea directivos', dir1, 'save_director', (J({**ficha, 'email': 'x@prueba.cl', 'rut': rut(18000003)}),), 'cuenta del club')
    t.rechaza_rpc('directivo no conecta pagos', dir1, 'set_club_pay_key', ('mercadopago', 'TEST-' + '1234567890' * 3), 'cuenta del club')
    t.rechaza_rpc('sin deportistas no ve apoderados', dir1, 'club_guardians', (), 'permiso')
    t.rechaza_rpc('deportista no ve apoderados', dep, 'club_guardians', (), 'permiso')
    # El club cambia las funciones y rige de inmediato
    t.rpc(club, 'save_director', J({**ficha, 'id': did, 'perms': ['deportes', 'masivo', 'deportistas']}))
    t.check('aviso al cambiar funciones', any('actualizó tus funciones' in n['text'] for n in t.rpc(dir1, 'my_state')['notifications']))
    t.check('sin finanzas ya no ve movimientos', not ve(dir1, 'movements', 'mvd1'))
    niega('sin finanzas ya no cobra', dir1, 'charges', 'chd2', {**cobro, 'id': 'chd2'})
    guarda(dir1, 'broadcasts', 'bd1', {'id': 'bd1', 'clubId': cid})
    t.rpc(dir1, 'add_sport', 'Remo')
    t.check('agrega deporte a su club', 'Remo' in next(c['sports'] for c in t.rpc(club, 'my_state')['clubs'] if c['id'] == cid))
    nt = t.rpc(dir1, 'add_team', J({'sport': 'Remo', 'name': 'Remo Adulto'}))
    t.check('crea categoría en su club', any(x['id'] == nt and x['club_id'] == cid for x in t.rpc(club, 'my_state')['teams']))
    t.check('con deportistas ve apoderados', isinstance(t.rpc(dir1, 'club_guardians'), list))
    t.rpc(club2, 'add_sport', 'Remo')
    t2 = t.rpc(club2, 'add_team', J({'sport': 'Remo', 'name': 'Otro club'}))
    t.rechaza_rpc('no toca categorías de otro club', dir1, 'update_team', (J({'id': t2, 'name': 'Hack'}),), 'Solo el club')
    t.rpc(dir1, 'delete_team', nt)
    # Acceso desactivado y directivo quitado
    t.rpc(club, 'save_director', J({**ficha, 'id': did, 'perms': ['deportes', 'masivo', 'deportistas'], 'active': False}))
    t.rechaza_rpc('desactivado no opera', dir1, 'add_sport', ('Vela',), 'Solo el club')
    niega('desactivado no publica', dir1, 'broadcasts', 'bd2', {'id': 'bd2', 'clubId': cid})
    t.check('desactivado no ve el club', not any(c['id'] == cid for c in t.rpc(dir1, 'my_state')['clubs']))
    t.rechaza_rpc('otro club no quita directivos', club2, 'remove_director', (did,), 'cuenta del club')
    t.rpc(club, 'remove_director', did)
    t.check('directivo quitado queda sin club', t.rpc(dir1, 'my_state')['directors'] == [])
    t.rpc(club, 'save_director', J({**ficha, 'perms': ['finanzas']}))
    t.check('cuenta sin club se vuelve a vincular', t.rpc(dir1, 'my_state')['directors'][0]['account_id'] == str(dir1))

    # --- Cuerpo técnico: cada pago exige su respaldo ---
    ts = {'id': 'ts1', 'clubId': cid, 'name': 'Kine Uno', 'cargo': 'Kinesiólogo', 'contract': 'honorarios', 'rates': {'sesion': 20000}, 'active': True}
    niega('deportista no crea cuerpo técnico', dep, 'techStaff', 'ts1', ts)
    niega('directivo sin la función no crea cuerpo técnico', dir1, 'techStaff', 'ts1', ts)
    guarda(club, 'techStaff', 'ts1', ts)
    t.check('deportista no ve sueldos', not ve(dep, 'techStaff', 'ts1'))
    pago = {'staffId': 'ts1', 'form': 'sesion', 'qty': 2, 'amount': 40000, 'period': 'noviembre', 'docName': 'boleta.pdf', 'doc': 'data:application/pdf;base64,QUJDREVG'}
    t.rechaza_rpc('pago sin boleta se rechaza', club, 'pay_staff', (J({**pago, 'doc': None}),), 'boleta de honorarios')
    t.rechaza_rpc('archivo de otro tipo se rechaza', club, 'pay_staff', (J({**pago, 'doc': 'data:text/html;base64,QUJD'}),), 'boleta de honorarios')
    t.rechaza_rpc('forma de pago inventada', club, 'pay_staff', (J({**pago, 'form': 'x'}),), 'no válida')
    t.rechaza_rpc('directivo sin función no paga', dir1, 'pay_staff', (J(pago),), 'permiso')
    sp = t.rpc(club, 'pay_staff', J(pago))
    est = t.rpc(club, 'my_state')
    t.check('pago registrado con su respaldo', any(r['kind'] == 'staffPays' and r['id'] == sp and r['data']['docType'] == 'Boleta de honorarios' for r in est['records']))
    t.check('pago entra como egreso', any(r['kind'] == 'movements' and r['data'].get('category') == 'Cuerpo técnico' and r['data']['amount'] == 40000 for r in est['records']))
    t.check('el archivo no viaja en el estado', 'QUJDREVG' not in json.dumps(est))
    t.check('club abre el respaldo', t.rpc(club, 'staff_doc', sp)['data'].endswith('QUJDREVG'))
    t.rechaza_rpc('deportista no abre el respaldo', dep, 'staff_doc', (sp,), 'permiso')
    t.rechaza('respaldos cerrados por API', club, 'select * from public.staff_docs', texto='permission denied')
    t.rechaza_rpc('un pago no se fabrica a mano', club, 'save_records', (J({'up': [{'kind': 'staffPays', 'id': 'x', 'data': {'clubId': cid}}]}),), 'no válido')
    t.rechaza_rpc('un pago no se borra a mano', club, 'save_records', (J({'del': [{'kind': 'staffPays', 'id': sp}]}),), 'permiso')

    # --- Infraestructura ---
    fac = {'id': 'f1', 'clubId': cid, 'name': 'Cancha', 'type': 'Cancha'}
    niega('deportista no crea recintos', dep, 'facilities', 'f1', fac)
    niega('directivo sin función no crea recintos', dir1, 'facilities', 'f1', fac)
    guarda(club, 'facilities', 'f1', fac)
    guarda(club, 'bookings', 'b1', {'id': 'b1', 'clubId': cid, 'facilityId': 'f1', 'date': '2026-12-01', 'from': '18:00', 'to': '19:00', 'title': 'Entrenamiento'})
    t.check('agenda visible para el club', ve(dep, 'bookings', 'b1') and not ve(ajeno, 'bookings', 'b1'))

    # --- Reglas de cobro ---
    pd = next(p['id'] for p in t.rpc(dep, 'my_state')['players'] if p['account_id'] == str(dep))
    pm = next(m for m in t.rpc(club, 'my_state')['memberships'] if m['player_id'] == pd and m['status'] == 'habil')
    tm = pm['team_id']
    fee = lambda u, a: t.como(u, 'select public.set_team_fee(%s::uuid[], %s)', ([tm], a))
    cuotas = lambda: [r for r in t.rpc(club, 'my_state')['records'] if r['kind'] == 'charges' and r['id'].startswith(f'men_{tm}_{pd}_')]
    t.rechaza('deportista no fija mensualidades', dep, 'select public.set_team_fee(%s::uuid[], 1000)', ([tm],), 'permiso')
    fee(club, 30000)
    t.check('mensualidad vence el último día del mes', len(cuotas()) == 1 and cuotas()[0]['data']['amount'] == 30000 and (datetime.date.fromisoformat(cuotas()[0]['data']['due']) + datetime.timedelta(1)).day == 1 and cuotas()[0]['data']['kind'] == 'mensual')
    t.rpc(dep, 'run_monthly')
    t.check('mensualidad no se duplica', len(cuotas()) == 1)
    regla = lambda **k: {'id': f'fee_{cid}_{pd}', 'clubId': cid, 'playerId': pd, 'amount': None, 'benefit': '', 'mode': 'pct', 'value': 0, **k}
    niega('deportista no se pone becas', dep, 'feeRules', f'fee_{cid}_{pd}', regla(benefit='Beca', value=100))
    guarda(club, 'feeRules', f'fee_{cid}_{pd}', regla(benefit='Beca', value=50))
    t.rpc(club, 'run_monthly')
    t.check('beca en porcentaje', cuotas()[0]['data']['amount'] == 15000)
    guarda(club, 'feeRules', f'fee_{cid}_{pd}', regla(benefit='Convenio', mode='fijo', value=5000))
    t.rpc(club, 'run_monthly')
    t.check('convenio en monto fijo', cuotas()[0]['data']['amount'] == 25000)
    guarda(club, 'feeRules', f'fee_{cid}_{pd}', regla(amount=12000))
    t.rpc(club, 'run_monthly')
    t.check('monto propio del deportista', cuotas()[0]['data']['amount'] == 12000)
    guarda(club, 'feeRules', f'fee_{cid}_{pd}', regla(benefit='Beca', value=100))
    t.rpc(club, 'run_monthly')
    t.check('beca total no genera cuota', cuotas() == [])

    # --- Estado por mensualidades vencidas ---
    meses = lambda u: t.rpc(u, 'my_state')['fee_months'].get(pm['id'], 0)

    def cobro_mes(mes, due=None, kind='mensual', team=tm):
        rid = f'est_{kind}_{mes}'
        guarda(club, 'charges', rid, {'id': rid, 'playerId': pd, 'clubId': cid, 'teamId': team, 'kind': kind, 'amount': 1000, 'status': 'pendiente', 'concept': f'Cuota {mes}', 'paidAt': None, 'due': due or f'2020-{mes:02d}-28'})
        return rid
    t.check('sin mensualidades vencidas', meses(club) == 0)
    ids = [cobro_mes(m) for m in (1, 2)]
    t.check('dos meses vencidos cuentan dos', meses(dep) == 2)
    ids.append(cobro_mes(2, kind='mensual', due='2020-02-29'))
    t.check('el mismo mes cuenta una vez', meses(dep) == 2)
    otros = [cobro_mes(9, kind='matricula'), cobro_mes(10, kind='extraordinaria')]
    t.check('matrícula y otros cobros no cuentan', meses(dep) == 2)
    otros.append(cobro_mes(11, due='2099-01-31'))
    t.check('mensualidad por vencer no cuenta', meses(dep) == 2)
    ids += [cobro_mes(m) for m in (3, 4, 5)]
    t.check('cinco meses vencidos', meses(club) == 5 and meses(dep) == 5)
    t.check('el entrenador del club lo ve', meses(ent) == 5)
    t.check('otra cuenta no lo ve', meses(ajeno) == 0)
    t.rpc(club, 'record_manual_payment', ['est_mensual_1'], 'Efectivo')
    t.check('pagar un mes baja el conteo', meses(dep) == 4)
    t.rpc(club, 'record_manual_payment', [i for i in dict.fromkeys(ids) if i != 'est_mensual_1'] + otros, 'Efectivo')
    t.check('al pagar todo vuelve a cero', meses(dep) == 0)

    # --- Partidos y torneos con mínimo de confirmados ---
    with t.c.cursor() as q:
        q.execute("insert into public.memberships (player_id, club_id, team_id, sport, status) values (%s, %s, %s, 'Fútbol', 'habil') returning id", (otro_pid, cid, tm))
        mid_otro = q.fetchone()[0]
    t.c.commit()
    futura = (datetime.date.today() + datetime.timedelta(20)).isoformat()
    partido = lambda **k: J({'kind': 'Partido', 'name': 'Clásico', 'date': futura, 'time': '19:30', 'place': 'Estadio', 'amount': 7000, 'min': 2, 'teams': [tm], 'target': 'Equipo', **k})
    estado_ = lambda u=club: t.rpc(u, 'my_state')['records']
    eventos = lambda it: [r for r in estado_() if r['kind'] == 'events' and r['data'].get('itemId') == it]
    cobro_p = lambda it, p: next((r['data'] for r in estado_() if r['kind'] == 'charges' and r['id'] == f'part_{it}_{p}'), None)
    item_d = lambda it: next(r['data'] for r in estado_() if r['kind'] == 'incomeItems' and r['id'] == it)
    t.rechaza_rpc('deportista no crea partidos', dep, 'create_match', (partido(),), 'permiso')
    t.rechaza_rpc('otro club no crea partidos', club2, 'create_match', (partido(),), 'permiso')
    t.rechaza_rpc('fecha pasada', club, 'create_match', (partido(date='2020-01-01'),), 'anterior')
    t.rechaza_rpc('monto en cero', club, 'create_match', (partido(amount=0),), 'monto')
    t.rechaza_rpc('sin mínimo', club, 'create_match', (partido(min=0),), 'mínima')
    t.rechaza_rpc('mínimo mayor que el plantel', club, 'create_match', (partido(min=4000),), 'superar')
    it1 = t.rpc(club, 'create_match', partido())
    t.check('sin confirmados no está en el calendario', eventos(it1) == [] and cobro_p(it1, pd) is None)
    t.check('el deportista ve la convocatoria', any(r['id'] == it1 for r in estado_(dep)))
    t.rechaza_rpc('no confirma por otro', dep, 'confirm_participation', (it1, otro_pid, True), 'permiso')
    t.rpc(dep, 'confirm_participation', it1, pd, True)
    t.check('bajo el mínimo no cobra ni agenda', eventos(it1) == [] and cobro_p(it1, pd) is None and item_d(it1)['active'] is False)
    t.rpc(dep, 'confirm_participation', it1, pd, False)
    t.rpc(ajeno, 'confirm_participation', it1, otro_pid, True)
    t.check('cancelar descuenta confirmados', eventos(it1) == [])
    t.rpc(dep, 'confirm_participation', it1, pd, True)
    ev_ = eventos(it1)
    t.check('al llegar al mínimo entra al calendario', len(ev_) == 1 and ev_[0]['data']['date'] == futura and ev_[0]['data']['type'] == 'partido' and set(ev_[0]['data']['cited']) == {pd, str(otro_pid)})
    c1 = cobro_p(it1, pd)
    t.check('cobra monto y fecha a cada confirmado', c1 and c1['amount'] == 7000 and c1['due'] == futura and cobro_p(it1, otro_pid) is not None)
    t.check('el creador recibe el aviso', any('mínimo' in n['text'] for n in t.rpc(club, 'my_state')['notifications']))
    t.rechaza_rpc('con cobros no se cancela', club, 'cancel_match', (it1,), 'no se puede')
    t.rpc(dep, 'confirm_participation', it1, pd, False)
    t.check('quien se baja queda sin cobro y sin citación', cobro_p(it1, pd) is None and eventos(it1)[0]['data']['cited'] == [str(otro_pid)])
    t.rpc(dep, 'confirm_participation', it1, pd, True)
    t.check('tras el mínimo confirmar cobra de inmediato', cobro_p(it1, pd) is not None and len(eventos(it1)) == 1 and len(eventos(it1)[0]['data']['cited']) == 2)
    it2 = t.rpc(ent, 'create_match', partido(kind='Torneo', name='Copa'))
    t.rechaza_rpc('otro no cancela', dep, 'cancel_match', (it2,), 'permiso')
    ids_v = [cobro_mes(m) for m in (1, 2, 3, 4, 5)]
    t.rechaza_rpc('suspendido por mensualidades no confirma', dep, 'confirm_participation', (it2, pd, True), 'suspendido')
    t.rpc(club, 'record_manual_payment', ids_v[:1], 'Efectivo')
    t.rpc(dep, 'confirm_participation', it2, pd, True)
    t.check('al pagar lo necesario puede confirmar', item_d(it2)['answers'][pd] == 'si')
    t.rpc(club, 'record_manual_payment', ids_v[1:], 'Efectivo')
    t.rpc(ent, 'cancel_match', it2)
    t.rechaza_rpc('cancelada no se confirma', ajeno, 'confirm_participation', (it2, otro_pid, True), 'no existe')

    # --- Encuestas ---
    preg = [{'text': 'Horario', 'type': 'unica', 'required': True, 'options': ['AM', 'PM']}, {'text': 'Mejoras', 'type': 'multiple', 'required': False, 'options': ['Luz', 'Baños', 'Cancha']},
            {'text': 'Nota', 'type': 'escala', 'required': True, 'min': 1, 'max': 5}, {'text': 'Algo más', 'type': 'parrafo', 'required': False}]
    enc = lambda **k: J({'title': 'Temporada', 'message': 'Tu opinión', 'questions': preg, 'audience': ['jugadores'], 'teams': [tm], 'scope': 'Equipo', **k})
    sv = lambda u, i: next((x for x in t.rpc(u, 'my_state')['surveys'] if x['id'] == i), None)
    t.rechaza_rpc('deportista no crea encuestas', dep, 'save_survey', (enc(),), 'permiso')
    t.rechaza_rpc('otro club no crea encuestas', club2, 'save_survey', (enc(),), 'permiso')
    t.rechaza_rpc('opciones repetidas', club, 'save_survey', (enc(questions=[{'text': 'x', 'type': 'unica', 'options': ['A', 'A']}]),), 'repetidas')
    t.rechaza_rpc('una sola opción', club, 'save_survey', (enc(questions=[{'text': 'x', 'type': 'lista', 'options': ['A']}]),), 'opciones')
    t.rechaza_rpc('tipo desconocido', club, 'save_survey', (enc(questions=[{'text': 'x', 'type': 'otro'}]),), 'Tipo')
    t.rechaza_rpc('escala fuera de rango', club, 'save_survey', (enc(questions=[{'text': 'x', 'type': 'escala', 'min': 5, 'max': 99}]),), 'escala')
    t.rechaza_rpc('sin destinatarios', club, 'save_survey', (enc(audience=[]),), 'Elige')
    s1 = t.rpc(club, 'save_survey', enc())
    t.check('el destinatario la ve sin resultados', sv(dep, s1) is not None and sv(dep, s1)['responses'] == [] and sv(dep, s1)['manage'] is False)
    t.check('avisa al destinatario', any('Nueva encuesta' in n['text'] for n in t.rpc(dep, 'my_state')['notifications']))
    t.check('apoderado fuera del público no la ve', sv(club2, s1) is None)
    t.rechaza_rpc('falta obligatoria', dep, 'answer_survey', (s1, J({'q1': 'AM'})), 'Responde')
    t.rechaza_rpc('opción inexistente', dep, 'answer_survey', (s1, J({'q1': 'Noche', 'q3': 3})), 'no válida')
    t.rechaza_rpc('escala fuera de rango al responder', dep, 'answer_survey', (s1, J({'q1': 'AM', 'q3': 9})), 'no válida')
    t.rechaza_rpc('quien no es destinatario no responde', club2, 'answer_survey', (s1, J({'q1': 'AM', 'q3': 3})), 'dirigida')
    t.rpc(dep, 'answer_survey', s1, J({'q1': 'AM', 'q2': ['Luz', 'Baños'], 'q3': 4, 'q4': 'Bien', 'extra': 'no se guarda'}))
    t.rechaza_rpc('no responde dos veces', dep, 'answer_survey', (s1, J({'q1': 'PM', 'q3': 1})), 'Ya respondiste')
    t.rpc(ajeno, 'answer_survey', s1, J({'q1': 'PM', 'q3': 2}))
    r_ = sv(club, s1)
    t.check('el club ve resultados', r_['manage'] is True and len(r_['responses']) == 2 and r_['eligible'] >= 2)
    t.check('los resultados no identifican a nadie', all(set(x) == {'who', 'answers'} for x in r_['responses']) and 'created_by' not in r_)
    t.check('solo guarda respuestas conocidas', not any('extra' in x['answers'] for x in r_['responses']))
    t.check('el deportista no ve los resultados', sv(dep, s1)['responses'] == [] and sv(dep, s1)['answered'] is True)
    t.rechaza('tabla de respuestas cerrada', dep, 'select * from public.survey_responses', (), 'permission')
    t.rechaza('tabla de encuestas cerrada', dep, 'select * from public.surveys', (), 'permission')
    s2 = t.rpc(ent, 'save_survey', enc(audience=['apoderados', 'jugadores']))
    t.check('el entrenador ve la suya', sv(ent, s2)['manage'] is True and sv(ent, s1) is None)
    t.check('el club ve la del entrenador', sv(club, s2)['manage'] is True)
    t.rechaza_rpc('otro no la cierra', dep, 'set_survey_status', (s2, False), 'permiso')
    t.rpc(ent, 'set_survey_status', s2, False)
    t.rechaza_rpc('cerrada no se responde', dep, 'answer_survey', (s2, J({'q1': 'AM', 'q3': 1})), 'cerrada')
    with t.c.cursor() as q:
        q.execute("delete from public.records where id like 'part_cv_%%' or id like 'cv_%%'")
        q.execute('delete from public.surveys')
        q.execute('delete from public.memberships where id = %s', (mid_otro,))
    t.c.commit()
    t.check('matrículas pendientes sin vencimiento', all(r['data'].get('due') is None for r in t.rpc(club, 'my_state')['records'] if r['kind'] == 'charges' and r['data'].get('kind') == 'matricula' and r['data']['status'] == 'pendiente'))
    t.rpc(club, 'update_team', J({'id': tm, 'name': 'Equipo', 'matricula': 7000}))
    matri = lambda: [r for r in t.rpc(club, 'my_state')['records'] if r['kind'] == 'charges' and r['data'].get('kind') == 'matricula' and r['data'].get('playerId') == pd]
    n1 = len(matri())
    t.rpc(club, 'update_team', J({'id': tm, 'name': 'Equipo', 'matricula': 8000}))
    t.check('matrícula única por club', n1 >= 1 and len(matri()) == n1)

    item = {'id': 'ii1', 'clubId': cid, 'kind': 'Partido', 'name': 'Final', 'amount': 10000, 'due': None, 'confirm': True, 'playerIds': [pd], 'answers': {}, 'by': 'Directorio'}
    guarda(club, 'incomeItems', 'ii1', item)
    t.check('convocado ve la convocatoria', ve(dep, 'incomeItems', 'ii1') and not ve(ajeno, 'incomeItems', 'ii1'))
    rc = f'part_ii1_{pd}'
    t.check('sin confirmar no hay cobro', not ve(dep, 'charges', rc))
    t.rechaza_rpc('otro no responde por él', ajeno, 'confirm_participation', ('ii1', pd, True), 'permiso')
    t.rpc(dep, 'confirm_participation', 'ii1', pd, True)
    t.rpc(dep, 'confirm_participation', 'ii1', pd, True)
    t.check('al confirmar nace el cobro', dato(dep, 'charges', rc)['amount'] == 10000 and dato(dep, 'charges', rc)['partial'] is True)
    t.rpc(dep, 'confirm_participation', 'ii1', pd, False)
    t.check('cancelar quita el cobro', not ve(dep, 'charges', rc))
    t.rpc(dep, 'confirm_participation', 'ii1', pd, True)
    guarda(club, 'charges', 'chp', {'id': 'chp', 'playerId': pd, 'clubId': cid, 'kind': 'mensual', 'amount': 1000, 'status': 'pendiente', 'concept': 'Sin abono', 'paidAt': None})
    t.rechaza_rpc('otros cobros no admiten abono', club, 'record_manual_payment', (['chp'], 'Efectivo', 500), 'no admite')
    t.rechaza_rpc('solo el club registra abonos', dep, 'record_manual_payment', ([rc], 'Efectivo', 500), 'Solo el club')
    t.check('abono entrega comprobante', t.rpc(club, 'record_manual_payment', [rc], 'Efectivo', 4000) is not None)
    d_ = dato(dep, 'charges', rc)
    t.check('abono baja el saldo', d_['amount'] == 6000 and d_['original'] == 10000 and d_['status'] == 'pendiente')
    t.rechaza_rpc('con abono no se cancela', dep, 'confirm_participation', ('ii1', pd, False), 'Ya registra')
    t.rpc(club, 'set_club_pay_key', 'mercadopago', 'TEST-' + '1234567890' * 3)
    t.rechaza_rpc('abono no supera el saldo en línea', dep, 'start_payment', ([rc], 9000), 'no superar')
    pg2 = t.rpc(dep, 'start_payment', [rc], 2000)
    t.check('pago parcial en línea', pg2['amount'] == 2000 and pg2['title'].startswith('Abono'))
    with t.c.cursor() as q:
        q.execute('select public.confirm_payment(%s, %s, %s, %s)', (pg2['id'], 2000, 'mp-parcial', cid))
    t.c.commit()
    t.check('confirmación parcial baja el saldo', dato(dep, 'charges', rc)['amount'] == 4000)
    t.rpc(club, 'record_manual_payment', [rc], 'Efectivo', 4000)
    t.check('el último abono deja pagado', dato(dep, 'charges', rc)['status'] == 'pagado')
    guarda(club, 'incomeItems', 'ii2', {**item, 'id': 'ii2', 'due': '2020-01-01'})
    t.rechaza_rpc('plazo vencido no confirma', dep, 'confirm_participation', ('ii2', pd, True), 'plazo')

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
    t.check('club sin administrador no aparece en la búsqueda', t.rpc(None, 'search_clubs', 'club prueba') == [])


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
