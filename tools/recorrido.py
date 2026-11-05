#!/usr/bin/env python3
"""Recorre la app por rol con Playwright (390x844 @3x). Uso: python tools/recorrido.py [url] [roles,coma]"""
import sys, os
from playwright.sync_api import sync_playwright
URL = sys.argv[1] if len(sys.argv) > 1 else 'http://localhost:8123/'
ONLY = sys.argv[2].split(',') if len(sys.argv) > 2 else None
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'screenshots')
RUTAS = {
 'jugador': ['/inicio','/calendario','/asistencia','/pagos','/muro','/mensajes','/chat/ch2','/encuestas','/encuesta/po1','/j/cv','/j/cv-imprimir','/j/certificado','/j/credencial','/unirme','/cambio-club','/renuncia','/rutinas','/tramites','/escanear','/perfil','/notificaciones'],
 'apoderado': ['/inicio','/a/pupilos','/pagos','/asistencia','/calendario','/mensajes','/a/reportes','/a/registrar-hijo','/cambio-club','/renuncia','/encuestas','/tramites','/perfil'],
 'entrenador': ['/inicio','/e/eventos','/e/nuevo-evento','/e/plantel','/torneos','/torneo/t1','/e/proponer','/encuestas','/e/encuesta-nueva','/e/masivo','/rutinas','/e/staff','/e/carga','/marketplace','/mensajes','/perfil'],
 'directivo': ['/inicio','/d/finanzas','/d/deportes','/d/aprobaciones','/d/asambleas','/d/asamblea/as1','/d/solicitudes','/d/bajas','/d/reclamos','/d/prestamos','/d/prestamo/ln1','/d/jugadores','/d/masivo','/marketplace','/cotizacion/q2','/plazo/sp1','/mensajes','/perfil'],
 'federacion': ['/inicio','/f/dashboard','/f/clubes','/f/comunicados','/f/valores','/f/ficha','/f/estadisticas','/perfil'],
 'proveedor': ['/inicio','/p/perfil','/p/catalogo','/p/categorias','/p/recintos','/p/cotizaciones','/p/cotizacion/q1','/p/torneos','/p/pagos','/perfil'],
}
def slug(r): return r.strip('/').replace('/','-') or 'raiz'
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    c = b.new_context(viewport={'width':390,'height':844}, device_scale_factor=3, is_mobile=True, has_touch=True, service_workers='block')
    pg = c.new_page()
    pg.on('console', lambda m: errs.append((cur, m.text)) if m.type == 'error' else None)
    pg.on('pageerror', lambda e: errs.append((cur, str(e))))
    cur = 'login'
    pg.goto(URL); pg.wait_for_selector('.login'); pg.screenshot(path=f'{OUT}/00-login.png')
    for rol, rutas in RUTAS.items():
        if ONLY and rol not in ONLY: continue
        pg.evaluate("r=>{S.session.loggedIn=true;S.session.role=r;save()}", rol)
        for i, r in enumerate(rutas):
            cur = f'{rol} {r}'
            pg.evaluate("h=>{location.hash='#'+h}", r); pg.wait_for_timeout(120)
            t = pg.evaluate("""()=>({h:location.hash,bad:!!document.querySelector('#view .empty h3')&&document.querySelector('#view .empty h3').textContent.startsWith('No pudimos'),over:document.documentElement.scrollWidth>innerWidth||document.querySelector('#view').scrollWidth>document.querySelector('#view').clientWidth+1,undef:/undefined|NaN|\\[object/.test(document.querySelector('#view').innerText)})""")
            if not t['h'].endswith(r): errs.append((cur, 'redirigido a ' + t['h']))
            if t['bad']: errs.append((cur, 'pantalla con error: ' + pg.inner_text('#view .empty')))
            if t['over']: errs.append((cur, 'desborde horizontal'))
            if t['undef']: errs.append((cur, 'texto undefined/NaN'))
            pg.screenshot(path=f'{OUT}/{rol}-{i+1:02d}-{slug(r)}.png')
    b.close()
print('\n'.join(f'ERROR {a}: {m}' for a, m in errs) or 'SIN ERRORES')
