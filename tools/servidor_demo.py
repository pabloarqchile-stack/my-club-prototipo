"""Sirve una copia de la app con config.js vacío en el puerto 8123.

Las pruebas del demo registran usuarios: con la configuración real terminarían
en la base de producción. Esta copia garantiza que nunca salgan del computador.
"""
import atexit
import functools
import http.server
import os
import shutil
import tempfile
import threading

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARCHIVOS = ['index.html', 'sw.js', 'manifest.webmanifest']


class Silencioso(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


def servir(puerto=8123):
    d = tempfile.mkdtemp(prefix='myclub-demo-')
    atexit.register(shutil.rmtree, d, ignore_errors=True)
    for f in ARCHIVOS:
        shutil.copy(os.path.join(RAIZ, f), d)
    shutil.copytree(os.path.join(RAIZ, 'icons'), os.path.join(d, 'icons'))
    with open(os.path.join(d, 'config.js'), 'w', encoding='utf-8') as f:
        f.write("window.MYCLUB_CONFIG = { url: '', key: '' };\n")
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', puerto), functools.partial(Silencioso, directory=d))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
