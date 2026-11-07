"""Prueba la app en modo real: navegador -> API -> Postgres con las migraciones.

Las funciones SQL y la seguridad son las reales. La API de Supabase se emula aquí
(Auth y /rest/v1/rpc), así que esta prueba NO reemplaza probar contra el proyecto.
Cada usuario usa un contexto de navegador separado, como un teléfono distinto.

Uso, desde la raíz:  pip install pgserver psycopg2-binary playwright  &&  python tools/flujos_real.py
"""
import functools
import hashlib
import http.server
import json
import os
import shutil
import sys
import tempfile
import threading
from urllib.parse import parse_qs, urlparse

import pgserver
import psycopg2
from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probar_base import RAIZ, preparar, rut

WEB, API = 8125, 8126
PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP8z8DAwMDAxAABDAwMAAAVAQMBqWWoZAAAAABJRU5ErkJggg=='
TOKENS, LOCK = {}, threading.Lock()


def clave(p):
    return hashlib.sha256(p.encode()).hexdigest()


class Api(http.server.BaseHTTPRequestHandler):
    db = None

    def log_message(self, *a):
        pass

    def responder(self, code, body=None):
        d = b'' if body is None else json.dumps(body, default=str).encode()
        self.send_response(code)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.send_header('Access-Control-Allow-Methods', '*')
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(d)))
        self.end_headers()
        self.wfile.write(d)

    def do_OPTIONS(self):
        self.responder(204)

    def uid(self):
        return TOKENS.get(self.headers.get('Authorization', '').replace('Bearer ', ''))

    def usuario(self, u):
        with self.db.cursor() as q:
            q.execute('select id, email, raw_user_meta_data from auth.users where id = %s', (u,))
            f = q.fetchone()
        self.db.commit()
        return {'id': str(f[0]), 'email': f[1], 'user_metadata': f[2] or {}}

    def sesion(self, u):
        t = os.urandom(12).hex()
        TOKENS[t] = str(u)
        return {'access_token': t, 'refresh_token': 'r' + t, 'expires_in': 3600, 'user': self.usuario(u)}

    def handle_any(self, metodo):
        if not self.headers.get('apikey'):
            return self.responder(401, {'message': 'Falta apikey'})
        n = int(self.headers.get('Content-Length') or 0)
        cuerpo = json.loads(self.rfile.read(n) or '{}')
        url = urlparse(self.path)
        with LOCK:
            if url.path.startswith('/rest/v1/rpc/'):
                return self.rpc(url.path.rsplit('/', 1)[1], cuerpo)
            return self.auth(metodo, url, cuerpo)

    def do_POST(self):
        self.handle_any('POST')

    def do_PUT(self):
        self.handle_any('PUT')

    def do_GET(self):
        self.handle_any('GET')

    def auth(self, metodo, url, b):
        ruta = url.path.replace('/auth/v1/', '')
        if ruta == 'signup':
            if len(b['password']) < 6:
                return self.responder(422, {'error_code': 'weak_password', 'msg': 'débil'})
            try:
                with self.db.cursor() as q:
                    q.execute('insert into auth.users (email, encrypted_password, raw_user_meta_data) values (%s, %s, %s) returning id',
                              (b['email'], clave(b['password']), json.dumps(b.get('data') or {})))
                    u = q.fetchone()[0]
                self.db.commit()
            except psycopg2.Error:
                self.db.rollback()
                return self.responder(422, {'error_code': 'user_already_exists', 'msg': 'existe'})
            return self.responder(200, self.usuario(u))  # Igual que Supabase con confirmación de email: sin sesión.
        if ruta == 'token':
            with self.db.cursor() as q:
                q.execute('select id from auth.users where email = %s and encrypted_password = %s', (b.get('email'), clave(b.get('password') or '')))
                f = q.fetchone()
            self.db.commit()
            if not f:
                return self.responder(400, {'error_code': 'invalid_credentials', 'msg': 'mal'})
            return self.responder(200, self.sesion(f[0]))
        u = self.uid()
        if ruta == 'user' and metodo == 'GET':
            return self.responder(200, self.usuario(u))
        if ruta == 'user' and metodo == 'PUT':
            with self.db.cursor() as q:
                if b.get('password'):
                    q.execute('update auth.users set encrypted_password = %s where id = %s', (clave(b['password']), u))
            self.db.commit()
            return self.responder(200, self.usuario(u))
        return self.responder(200, {})

    def rpc(self, fn, args):
        u = self.uid()
        nombres = ', '.join(f'{k} => %s' for k in args)
        vals = [json.dumps(v) if isinstance(v, (dict, list)) else v for v in args.values()]
        try:
            with self.db.cursor() as q:
                q.execute("select set_config('request.jwt.claims', %s, true), set_config('role', %s, true)",
                          (json.dumps({'sub': u or ''}), 'authenticated' if u else 'anon'))
                q.execute(f'select public.{fn}({nombres})', vals)
                r = q.fetchone()[0]
            self.db.commit()
            return self.responder(200, r)
        except psycopg2.Error as e:
            self.db.rollback()
            return self.responder(400, {'message': e.diag.message_primary, 'code': e.pgcode})


class Web(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


class Telefono:
    """Un dispositivo: contexto de navegador propio, sin nada compartido."""

    def __init__(self, br, errores):
        self.ctx = br.new_context(viewport={'width': 390, 'height': 844}, service_workers='block')
        self.ctx.route('**/config.js', lambda r: r.fulfill(
            content_type='text/javascript', body=f"window.MYCLUB_CONFIG = {{ url: 'http://127.0.0.1:{API}', key: 'clave-publica' }};"))
        self.p = self.ctx.new_page()
        self.p.on('pageerror', lambda e: errores.append(str(e)))
        self.p.on('console', lambda m: errores.append(m.text) if m.type == 'error' and 'status of 4' not in m.text else None)
        self.ir('/login')

    def ir(self, ruta):
        self.p.goto(f'http://127.0.0.1:{WEB}/index.html#{ruta}')
        self.p.wait_for_timeout(350)

    def f(self, sel, v):
        self.p.fill(sel, v)

    def tap(self, texto):
        self.p.locator('button', has_text=texto).first.click()
        self.p.wait_for_timeout(350)

    def texto(self):
        return self.p.inner_text('#phone')

    def registrar(self, tipo, nombre, r, email, clave_='ClaveSegura1', extra=None):
        self.ir('/registro')
        self.p.locator(f'#rg-{tipo} button.li').first.click()
        self.p.wait_for_timeout(150)
        self.f('#rg-name', nombre)
        self.f('#rg-rut', r)
        self.f('#rg-email', email)
        self.f('#rg-phone', '+56912345678')
        self.f('#rg-pass', clave_)
        if extra:
            extra(self)
        self.p.check('#rg-legal')
        self.tap('Completar Registro')

    def entrar(self, email, clave_='ClaveSegura1'):
        self.ir('/login')
        self.f('#lg-em', email)
        self.f('#lg-pw', clave_)
        self.tap('INGRESAR')
        self.p.wait_for_timeout(700)

    def cerrar_hoja(self):
        if self.p.locator('button', has_text='Entendido').count():
            self.tap('Entendido')
            self.p.wait_for_timeout(250)


def correr(br, check, errores):
    club = Telefono(br, errores)

    # --- Pantalla de ingreso con base conectada ---
    t = club.texto()
    check('ingreso muestra enlace de clave', 'Olvidé mi clave' in t)
    check('ingreso sin datos precargados', club.p.input_value('#lg-em') == '' and club.p.input_value('#lg-pw') == '')

    # --- El demo sigue funcionando junto a la base ---
    club.entrar('demo', 'demo')
    check('ingreso demo único pide elegir perfil', 'Modo demo' in club.texto() and club.p.locator('.sheet .li').count() == 6)
    club.p.locator('.sheet button.li', has_text='Club').first.click()
    club.p.wait_for_timeout(400)
    check('demo entra al perfil elegido con datos inventados', club.p.evaluate('role()') == 'directivo' and 'Halcones' in club.texto())
    antes = club.p.evaluate('S.movements.length')
    club.p.evaluate("A.addExpense()")
    club.p.wait_for_timeout(200)
    check('demo no permite ingresar datos', club.p.evaluate('S.movements.length') == antes and 'crea una cuenta' in club.p.inner_text('#toasts'))
    club.p.evaluate("A.doAddSport()")
    club.p.wait_for_timeout(200)
    check('demo tampoco usa la base', club.p.evaluate('!!S.session.real') is False and 'crea una cuenta' in club.p.inner_text('#toasts'))
    club.ir('/d/finanzas')
    check('demo muestra la función con sus datos', 'No pudimos abrir' not in club.texto() and 'todavía no guarda' not in club.texto())
    club.p.evaluate('A.logout()')
    club.p.wait_for_timeout(300)
    club.entrar('demo@myclub.cl', 'demo')
    check('cuenta demo entra con datos de ejemplo', 'Matías' in club.texto())
    club.ir('/perfil')
    check('demo conserva cambiar de rol', 'Cambiar de rol' in club.texto())
    club.p.evaluate('A.logout()')
    club.p.wait_for_timeout(300)

    # --- Registro de club ---
    def datos_club(tel):
        tel.f('#rg-date', '1995-03-20')
        tel.f('#rg-num', '12345')
        for i, n in enumerate(['Ana Pérez', 'Luis Soto', 'Rosa Díaz']):
            tel.p.locator('.dir-n').nth(i).fill(n)

    club.registrar('club', 'Club Real', rut(76086428), 'CLUB@real.cl', 'corta', datos_club)
    check('exige clave de 8 caracteres', '8 caracteres' in club.p.inner_text('#rg-err'))
    club.f('#rg-pass', 'ClaveSegura1')
    club.tap('Completar Registro')
    club.p.wait_for_timeout(600)
    check('pide confirmar email', 'Confirma tu email' in club.texto())
    club.cerrar_hoja()
    club.entrar('club@real.cl', 'incorrecta')
    check('clave incorrecta', 'incorrectos' in club.p.inner_text('#lg-err'))
    club.entrar('club@real.cl')
    check('ID de club correlativo', 'C00000001' in club.texto())
    club.cerrar_hoja()
    t = club.texto()
    check('no aparece ningún dato inventado', not any(x in t for x in ('Halcones', 'Matías', 'Patricia', 'Ingresos del mes')))
    pestanas = club.p.inner_text('#tabbar')
    check('club tiene los mismos menús que el demo', all(x in pestanas for x in ('Inicio', 'Finanzas', 'Aprobaciones', 'Mensajes', 'Perfil')))
    club.ir('/d/finanzas')
    t = club.texto()
    check('pantalla sin base avisa y queda vacía', 'todavía no guarda' in t and '$0' in t and 'Honorarios' not in t)
    antes = club.p.evaluate('S.movements.length')
    club.p.evaluate("A.addExpense()")
    club.p.wait_for_timeout(200)
    check('acción sin base no finge guardar', club.p.evaluate('S.movements.length') == antes and 'todavía no guarda' in club.p.inner_text('#toasts'))

    # --- Logo, deportes y equipos ---
    club.ir('/perfil/editar')
    t = club.texto()
    check('nombre, RUT y fecha bloqueados', 'datos que no se pueden cambiar' in t.lower() and club.p.locator('#ed-name').count() == 0)
    club.p.set_input_files('input[type=file]', files=[{'name': 'logo.png', 'mimeType': 'image/png', 'buffer': __import__('base64').b64decode(PNG)}])
    club.p.wait_for_timeout(900)
    club.ir('/d/deportes')
    club.tap('Agregar deporte')
    club.p.select_option('#ds-s', 'Fútbol')
    club.p.locator('.sheet button', has_text='Agregar').first.click()
    club.p.wait_for_timeout(500)
    club.p.locator('text=Agregar equipo').first.click()
    club.p.wait_for_timeout(250)
    club.f('#dt-n', 'Fútbol Adulto')
    club.p.locator('.sheet button', has_text='Crear equipo').click()
    club.p.wait_for_timeout(500)
    check('equipo creado', 'Fútbol Adulto' in club.texto())
    club.tap('Agregar deporte')
    opciones = club.p.locator('#ds-s option').all_inner_texts()
    check('lista con deportes olímpicos', len(opciones) == 58 and 'Esgrima' in opciones and 'Fútbol' not in opciones)
    club.p.select_option('#ds-s', 'Esgrima')
    club.p.locator('.sheet button', has_text='Agregar').last.click()
    club.p.wait_for_timeout(500)
    check('deporte olímpico agregado', 'Esgrima' in club.texto())
    club.tap('Agregar deporte')
    club.tap('OTRO')
    club.f('#ds-n', "<b>D'Art</b>")
    club.p.locator('.sheet button', has_text='Agregar').last.click()
    club.p.wait_for_timeout(200)
    check('OTRO rechaza caracteres peligrosos', 'solo letras' in club.p.inner_text('#ds-err'))
    club.f('#ds-n', 'esgrima')
    club.p.locator('.sheet button', has_text='Agregar').last.click()
    club.p.wait_for_timeout(200)
    check('OTRO no duplica', 'ya está' in club.p.inner_text('#ds-err'))
    club.f('#ds-n', 'Pádel')
    club.p.locator('.sheet button', has_text='Agregar').last.click()
    club.p.wait_for_timeout(500)
    check('OTRO agrega el nombre escrito', 'Pádel' in club.texto() and 'undefined' not in club.texto())

    # --- Persistencia: recarga y sesión ---
    club.ir('/d/deportes')
    club.p.reload()
    club.p.wait_for_timeout(700)
    check('datos siguen tras recargar', 'Fútbol Adulto' in club.texto())

    # --- Deportista en otro dispositivo, con vínculo desde el registro ---
    dep = Telefono(br, errores)

    def datos_dep(tel):
        tel.f('#rg-birth', '1990-05-05')
        tel.f('#rg-height', '180')
        tel.f('#lk-id', 'c00000001')
        tel.tap('VINCULAR AL CLUB')
        tel.p.wait_for_timeout(400)

    dep.registrar('jugador', 'Pedro Real', rut(12345678), 'pedro@real.cl', extra=datos_dep)
    dep.p.wait_for_timeout(600)
    dep.cerrar_hoja()
    dep.entrar('pedro@real.cl')
    check('ID de deportista', 'D00000001' in dep.texto())
    dep.cerrar_hoja()
    check('solicitud pendiente', 'Pendiente' in dep.texto())
    # El logo cargado en el otro dispositivo llega a esta cuenta.
    src = dep.p.evaluate("S.clubs[0].logo || ''")
    check('logo del club llega a otro dispositivo', src.startswith('data:image/png'))

    club.ir('/d/solicitudes')
    club.p.reload()
    club.p.wait_for_timeout(700)
    check('club ve la solicitud del otro dispositivo', 'Pedro Real' in club.texto())
    club.tap('Aceptar')
    club.p.wait_for_timeout(500)
    dep.p.reload()
    dep.p.wait_for_timeout(700)
    check('deportista queda Hábil en su dispositivo', 'Hábil' in dep.texto())
    dep.ir('/notificaciones')
    check('deportista recibe aviso real', 'aceptó la incorporación' in dep.texto())
    dep.tap('Marcar todas como leídas')
    dep.p.reload()
    dep.p.wait_for_timeout(700)
    check('aviso leído persiste', 'Marcar todas' not in dep.texto())

    # --- Edición de perfil ---
    dep.ir('/perfil/editar')
    dep.f('#ed-height', '182')
    dep.tap('Guardar cambios')
    dep.p.wait_for_timeout(600)
    dep.p.reload()
    dep.p.wait_for_timeout(700)
    check('perfil editado persiste', '182 cm' in dep.texto())
    check('perfil real sin controles de demo', not any(x in dep.texto() for x in ('Cambiar de rol', 'Modo demo', 'Restablecer demo', 'datos ficticios')))

    # --- Apoderado y pupilo ---
    apo = Telefono(br, errores)
    apo.registrar('apoderado', 'Carla Real', rut(11111112), 'carla@real.cl')
    apo.p.wait_for_timeout(500)
    apo.cerrar_hoja()
    apo.entrar('carla@real.cl')
    apo.cerrar_hoja()
    check('apoderado sin pupilos ve cómo seguir', 'Aún no tienes pupilos' in apo.texto())
    apo.ir('/a/registrar-hijo')
    apo.f('#rh-name', 'Sofía Real')
    apo.f('#rh-rut', rut(23456789))
    apo.f('#rh-birth', '2013-04-04')
    apo.f('#rh-id', 'C00000001')
    apo.tap('VINCULAR AL CLUB')
    apo.p.wait_for_timeout(400)
    apo.tap('Registrar y solicitar incorporación')
    apo.p.wait_for_timeout(800)
    apo.cerrar_hoja()
    check('pupilo registrado', 'Sofía Real' in apo.texto())
    club.ir('/d/solicitudes')
    club.p.reload()
    club.p.wait_for_timeout(700)
    club.tap('Aceptar')
    club.p.wait_for_timeout(500)
    apo.p.reload()
    apo.p.wait_for_timeout(700)
    check('pupilo aceptado por el club', 'Hábil' in apo.texto())

    # --- Menor con cuenta propia y apoderado por ID ---
    menor = Telefono(br, errores)
    menor.registrar('jugador', 'Lucas Menor', rut(21000001), 'lucas@real.cl', extra=lambda tel: tel.f('#rg-birth', '2014-02-02'))
    menor.p.wait_for_timeout(500)
    menor.cerrar_hoja()
    menor.entrar('lucas@real.cl')
    menor.cerrar_hoja()
    code = menor.p.evaluate('acct().id')
    check('menor crea su propia cuenta', code.startswith('D') and 'dale tu ID' in menor.texto())
    check('menor de 14 sin apoderado no ve unirse a un club', 'Unirme a un club' not in menor.texto())
    menor.ir('/unirme')
    check('unirse explica que falta el apoderado', 'menores de 14' in menor.texto() and menor.p.locator('#jn-id').count() == 0)
    otro14 = Telefono(br, errores)

    def datos_14(tel):
        tel.f('#rg-birth', '2015-03-03')
        tel.f('#lk-id', 'C00000001')
        tel.tap('VINCULAR AL CLUB')
        tel.p.wait_for_timeout(400)

    otro14.registrar('jugador', 'Niño Con Club', rut(21000002), 'nino@real.cl', extra=datos_14)
    check('registro de menor de 14 no acepta club', 'sin ID de club' in otro14.p.inner_text('#rg-err'))
    apo.ir('/a/vincular-pupilo')
    apo.f('#gl-id', 'D99999999')
    apo.tap('Enviar solicitud')
    apo.p.wait_for_timeout(300)
    check('ID inexistente', 'No encontramos' in apo.p.inner_text('#gl-err'))
    apo.f('#gl-id', code.lower())
    apo.tap('Enviar solicitud')
    apo.p.wait_for_timeout(500)
    t = apo.texto()
    check('solicitud pendiente sin mostrar al menor', code in t and 'Lucas' not in t and 'Simular' not in t)
    menor.ir('/inicio')
    menor.p.reload()
    menor.p.wait_for_timeout(700)
    menor.tap('Revisar solicitud de apoderado')
    check('menor ve quién lo pide', 'Carla Real' in menor.texto())
    menor.tap('Aceptar')
    menor.p.wait_for_timeout(500)
    apo.p.reload()
    apo.p.wait_for_timeout(700)
    apo.ir('/a/pupilos')
    check('apoderado ve al pupilo aceptado', 'Lucas' in apo.texto() and 'Sofía' in apo.texto())
    apo.p.evaluate("S.ui.kid = S.players.find(p => p.name === 'Lucas Menor').id; rerender()")
    apo.p.wait_for_timeout(300)
    check('pantalla del pupilo con cuenta abre', 'No pudimos abrir' not in apo.texto() and 'Lucas Menor' in apo.texto())
    menor.ir('/unirme')
    check('con apoderado aceptado ya puede unirse', menor.p.locator('#jn-id').count() == 1)
    menor.ir('/apoderados')
    menor.tap('Quitar')
    menor.p.wait_for_timeout(500)
    apo.p.reload()
    apo.p.wait_for_timeout(700)
    apo.ir('/a/pupilos')
    check('vínculo quitado', 'Lucas' not in apo.texto() and 'Sofía' in apo.texto())

    # --- Entrenador ---
    ent = Telefono(br, errores)

    def datos_ent(tel):
        tel.p.locator('#lk-id').press_sequentially('CLUB re', delay=30)
        tel.p.wait_for_timeout(700)
        check('escribir el nombre muestra el club con su logo', tel.p.locator('#lk-list .li img.clog').count() == 1 and 'Club Real' in tel.p.inner_text('#lk-list'))
        tel.p.locator('#lk-list button.li').first.click()
        tel.p.wait_for_timeout(200)
        check('tocar el club lo selecciona', 'Club encontrado' in tel.p.inner_text('#lk-res') and tel.p.input_value('#lk-id') == 'Club Real')

    ent.registrar('entrenador', 'Tomás Real', rut(22222223), 'tomas@real.cl', extra=datos_ent)
    ent.p.wait_for_timeout(500)
    ent.cerrar_hoja()
    ent.entrar('tomas@real.cl')
    ent.cerrar_hoja()
    check('entrenador espera aprobación', 'El club debe aprobar' in ent.texto() or 'Vincúlate' in ent.texto())
    check('sin botón de simulación', 'Simular aprobación' not in ent.texto())
    club.ir('/d/solicitudes')
    club.p.reload()
    club.p.wait_for_timeout(700)
    club.tap('Aceptar')
    club.p.wait_for_timeout(500)
    ent.p.reload()
    ent.p.wait_for_timeout(700)
    ent.ir('/e/plantel')
    check('entrenador aceptado ve el plantel real', 'Pedro Real' in ent.texto() and 'Sofía Real' in ent.texto())

    # --- Federación y proveedor: cuenta real, sin estadísticas inventadas ---
    fed = Telefono(br, errores)
    fed.registrar('federacion', 'Federación Real', rut(14141414), 'fed@real.cl')
    fed.p.wait_for_timeout(500)
    fed.cerrar_hoja()
    fed.entrar('fed@real.cl')
    fed.cerrar_hoja()
    check('federación sin datos inventados', 'F00000001' in fed.texto() and 'Dashboard' in fed.p.inner_text('#tabbar'))
    pro = Telefono(br, errores)
    pro.registrar('proveedor', 'Proveedor Real', rut(15151515), 'prov@real.cl')
    pro.p.wait_for_timeout(500)
    pro.cerrar_hoja()
    pro.entrar('prov@real.cl')
    pro.cerrar_hoja()
    check('proveedor con su propia cuenta', 'P00000001' in pro.texto() and 'Deportes Andes' not in pro.texto())
    pro.ir('/perfil')
    check('perfil de proveedor abre', 'Proveedor Real' in pro.texto() and 'No pudimos abrir' not in pro.texto())

    # --- Todos los perfiles: mismos menús e íconos, pantallas vacías y sin datos inventados ---
    inventado = ('Halcones', 'Matías', 'Carolina', 'Patricia', 'Rodrigo Saavedra', 'Deportes Andes', 'Atlético Biobío', 'Náutico', 'Contreras', 'Simular', 'simulad', 'de ejemplo', ' demo', 'Demo')
    for nombre, tel in (('club', club), ('deportista', dep), ('apoderado', apo), ('entrenador', ent), ('federación', fed), ('proveedor', pro)):
        info = tel.p.evaluate('''() => { const r = role(); return { tabs: TABS[r].length, tabsVistas: document.querySelectorAll('#tabbar .tab').length, home: HOME[r].length, rutas: ROUTES.filter(x => !x.public && !x.path.includes(':') && (!x.roles || x.roles.includes(r)) && x.path !== '/nueva-clave').map(x => x.path) }; }''')
        check(f'{nombre}: todas las pestañas', info['tabs'] == info['tabsVistas'] == 5)
        tel.ir('/inicio')
        check(f'{nombre}: todos los accesos del inicio', tel.p.locator('#view .tile').count() == info['home'])
        malas, datos = [], []
        for ruta in info['rutas']:
            tel.p.evaluate("r => { location.hash = '#' + r }", ruta)
            tel.p.wait_for_timeout(90)
            if tel.p.evaluate('location.hash') != '#' + ruta:
                malas.append(ruta + ' (redirige)')
            t = tel.p.inner_text('#view')
            if 'No pudimos abrir' in t:
                malas.append(ruta)
            if any(x in t for x in inventado):
                datos.append(ruta)
        check(f'{nombre}: {len(info["rutas"])} pantallas abren: {malas[:6]}', not malas)
        check(f'{nombre}: sin datos inventados: {datos[:6]}', not datos)

    # --- RUT repetido: el email queda libre para reintentar ---
    otro = Telefono(br, errores)
    otro.registrar('jugador', 'Copia', rut(12345678), 'copia@real.cl', extra=lambda tel: tel.f('#rg-birth', '1980-01-01'))
    otro.p.wait_for_timeout(500)
    otro.cerrar_hoja()
    otro.entrar('copia@real.cl')
    check('RUT repetido se informa', 'Ya existe' in otro.p.inner_text('#lg-err'))

    # --- Cerrar sesión y eliminar cuenta ---
    dep.ir('/perfil')
    dep.p.evaluate('A.deleteAsk()')
    dep.p.wait_for_timeout(250)
    dep.f('#del-pw', 'equivocada')
    dep.tap('Eliminar definitivamente')
    dep.p.wait_for_timeout(500)
    check('eliminar exige la clave', 'no es correcta' in dep.p.inner_text('#del-err'))
    dep.f('#del-pw', 'ClaveSegura1')
    dep.tap('Eliminar definitivamente')
    dep.p.wait_for_timeout(800)
    dep.entrar('pedro@real.cl')
    check('cuenta eliminada ya no entra', 'incorrectos' in dep.p.inner_text('#lg-err'))
    check('sesión real no deja datos en el demo local', 'pedro@real.cl' not in (dep.p.evaluate("localStorage.getItem('myclub-demo-v1')") or ''))

    club.p.evaluate('A.logout()')
    club.p.wait_for_timeout(400)
    club.p.reload()
    club.p.wait_for_timeout(400)
    check('cerrar sesión funciona', club.p.evaluate('location.hash') == '#/login')


def main():
    d = tempfile.mkdtemp(prefix='myclub-e2e-')
    srv = pgserver.get_server(d)
    ok, fallos, errores = [], [], []

    def check(n, c):
        (ok if c else fallos).append(n)
        if not c:
            print('  FALLA:', n)

    try:
        db = psycopg2.connect(srv.get_uri())
        preparar(db)
        db.commit()
        Api.db = db
        http.server.ThreadingHTTPServer.allow_reuse_address = True
        for puerto, h in ((API, Api), (WEB, functools.partial(Web, directory=RAIZ))):
            threading.Thread(target=http.server.ThreadingHTTPServer(('127.0.0.1', puerto), h).serve_forever, daemon=True).start()
        with sync_playwright() as pw:
            br = pw.chromium.launch()
            correr(br, check, errores)
            br.close()
        check('sin errores de consola', not errores)
        for e in errores[:8]:
            print('  consola:', e[:200])
        print(f'{len(ok)} comprobaciones correctas, {len(fallos)} fallidas')
        return 1 if fallos else 0
    finally:
        srv.cleanup()
        shutil.rmtree(d, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
