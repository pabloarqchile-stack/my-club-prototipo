"""Prueba el nivel Master (migración 20261128120000_master.sql) en un Postgres local.

Usa el mismo arnés que probar_base.py. El dueño se agrega con SQL, como se hace en el proyecto real.

Uso:  pip install pgserver psycopg2-binary  &&  python tools/probar_master.py
"""
import shutil
import sys
import tempfile

import pgserver
import psycopg2

from probar_base import J, Prueba, preparar, rut
from probar_invitaciones import BASE, BOARD, auth_admin


def correr(t):
    dueno, sub, sub2, club, club2, dep, nadie = [t.usuario(f'{n}@prueba.cl') for n in ('dueno', 'sub', 'sub2', 'club', 'club2', 'dep', 'nadie')]
    t.rpc(club, 'register_account', J({**BASE, 'type': 'club', 'name': 'Club Prueba', 'rut': rut(76086428), 'constituted': '2001-02-03', 'regNumber': '77', 'board': BOARD}))
    t.rpc(club2, 'register_account', J({**BASE, 'type': 'club', 'name': 'Club Extranjero', 'rut': rut(65000001), 'constituted': '2001-02-03', 'regNumber': '78', 'board': BOARD}))
    t.rpc(dep, 'register_account', J({**BASE, 'type': 'jugador', 'name': 'Dep Uno', 'rut': rut(13131313), 'birth': '1990-01-01'}))
    t.rpc(dueno, 'register_account', J({**BASE, 'type': 'jugador', 'name': 'Dueño Dep', 'rut': rut(12345678), 'birth': '1980-01-01'}))
    cid = t.rpc(club, 'my_state')['clubs'][0]['id']
    cid2 = [c for c in t.rpc(club2, 'my_state')['clubs'] if c['name'] == 'Club Extranjero'][0]['id']
    t.rpc(club, 'add_sport', 'Fútbol')
    t.rpc(club, 'club_add_members', cid, 'jugador', 'Fútbol', None, J([
        {'name': 'Ana Uno', 'rut': rut(24555666), 'birth': '2012-05-10', 'email': '', 'phone': ''},
        {'name': 'Beto Dos', 'rut': rut(21555777), 'birth': '2010-03-01', 'email': '', 'phone': ''}]))

    # --- Nadie es Master hasta que el dueño se agrega en la base ---
    for n, u in (('anónimo', None), ('club', club), ('deportista', dep), ('dueño sin fila', dueno)):
        t.check(f'{n}: master_me es null', t.rpc(u, 'master_me') is None if u else True)
    t.rechaza_rpc('anónimo no llama master_me', None, 'master_me', (), 'permission denied')
    t.rechaza_rpc('club no ve master_data', club, 'master_data', (), 'No tienes acceso')
    t.rechaza_rpc('club no guarda tarifas', club, 'master_save', ('tarifas', J({'price_clp': 0, 'price_usd': 0})), 'No tienes acceso')
    t.rechaza('club no lee platform_admins', club, 'select * from public.platform_admins', texto='permission denied')
    t.rechaza('club no se agrega como Master', club, "insert into public.platform_admins (email) values ('club@prueba.cl')", texto='permission denied')
    t.rechaza('club no cambia tarifas directo', club, 'update public.platform_settings set price_clp = 0', texto='permission denied')
    t.rechaza('club no llama _master_need', club, "select public._master_need('cuentas')", texto='permission denied')

    auth_admin(t, "insert into public.platform_admins (email, name, owner) values ('dueno@prueba.cl', 'Dueño', true)")
    me = t.rpc(dueno, 'master_me')
    t.check('dueño entra como Master', me and me['owner'] and set(me['perms']) == {'cuentas', 'finanzas', 'tarifas', 'descuentos', 'promociones', 'usuarios'})
    t.check('master_me indica que también tiene cuenta', me['account'] is True)
    d = t.rpc(dueno, 'master_data')
    t.check('cuenta cuentas por tipo', d['counts']['types']['club']['total'] == 2 and d['counts']['types']['jugador']['total'] == 2)
    t.check('cuenta deportistas y hábiles', d['counts']['players'] >= 4 and d['counts']['active'] == 2)
    t.check('lista clubes con deportistas hábiles', next(c for c in d['clubs'] if c['id'] == cid)['active'] == 2)
    t.check('tarifas por defecto: $1.000 en Chile', d['settings']['price_clp'] == 1000)
    t.check('clubes parten en Chile', all(c['country'] == 'CL' for c in d['clubs']))

    # --- Tarifas y país ---
    t.rpc(dueno, 'master_save', 'tarifas', J({'price_clp': 1200, 'price_usd': 1.5}))
    t.check('guarda tarifas', t.rpc(dueno, 'master_data')['settings']['price_clp'] == 1200)
    t.rechaza_rpc('tarifa negativa', dueno, 'master_save', ('tarifas', J({'price_clp': -1, 'price_usd': 1})))
    t.rpc(dueno, 'master_save', 'pais', J({'id': cid2, 'country': 'ar'}))
    t.check('cambia país del club', next(c for c in t.rpc(dueno, 'master_data')['clubs'] if c['id'] == cid2)['country'] == 'AR')
    t.rechaza_rpc('país inválido', dueno, 'master_save', ('pais', J({'id': cid2, 'country': 'Chile'})), 'país')

    # --- Descuentos, promociones y movimientos ---
    did = t.rpc(dueno, 'master_save', 'descuento', J({'club_id': cid, 'kind': 'pct', 'value': 20, 'starts': '2026-11-01', 'note': 'Club piloto'}))
    t.rechaza_rpc('descuento sobre 100%', dueno, 'master_save', ('descuento', J({'club_id': cid, 'kind': 'pct', 'value': 120, 'starts': '2026-11-01'})))
    t.rechaza_rpc('descuento con término antes del inicio', dueno, 'master_save', ('descuento', J({'club_id': cid, 'kind': 'monto', 'value': 100, 'starts': '2026-11-01', 'ends': '2026-10-01'})))
    t.rechaza_rpc('descuento a club inexistente', dueno, 'master_save', ('descuento', J({'club_id': '00000000-0000-0000-0000-000000000000', 'kind': 'pct', 'value': 5})), 'club')
    t.rpc(dueno, 'master_save', 'descuento', J({'id': did, 'club_id': cid, 'kind': 'pct', 'value': 25, 'starts': '2026-11-01', 'active': False}))
    dd = [x for x in t.rpc(dueno, 'master_data')['discounts'] if x['id'] == did][0]
    t.check('edita descuento', float(dd['value']) == 25 and dd['active'] is False)
    pid = t.rpc(dueno, 'master_save', 'promocion', J({'name': 'Lanzamiento', 'kind': 'meses', 'value': 2, 'scope': 'CL', 'starts': '2026-11-01'}))
    t.rechaza_rpc('promoción con meses fraccionados', dueno, 'master_save', ('promocion', J({'name': 'X', 'kind': 'meses', 'value': 1.5, 'starts': '2026-11-01'})))
    t.rechaza_rpc('promoción sin nombre', dueno, 'master_save', ('promocion', J({'name': '', 'kind': 'pct', 'value': 10})))
    t.rpc(dueno, 'master_save', 'movimiento', J({'kind': 'ingreso', 'date': '2026-11-20', 'amount': 2400, 'currency': 'CLP', 'category': 'Pago de club', 'club_id': cid, 'period': '2026-11'}))
    mid = t.rpc(dueno, 'master_save', 'movimiento', J({'kind': 'egreso', 'date': '2026-11-21', 'amount': 25, 'currency': 'USD', 'category': 'Servidores'}))
    t.rechaza_rpc('monto cero', dueno, 'master_save', ('movimiento', J({'kind': 'egreso', 'amount': 0, 'category': 'Otro'})))
    t.rechaza_rpc('moneda inventada', dueno, 'master_save', ('movimiento', J({'kind': 'egreso', 'amount': 5, 'currency': 'EUR', 'category': 'Otro'})))
    t.rechaza_rpc('periodo inválido', dueno, 'master_save', ('movimiento', J({'kind': 'ingreso', 'amount': 5, 'category': 'Otro', 'period': '2026-13'})))
    d = t.rpc(dueno, 'master_data')
    t.check('lista movimientos', len(d['moves']) == 2 and len(d['promos']) == 1)
    t.rpc(dueno, 'master_delete', 'movimiento', mid)
    t.check('borra movimiento', len(t.rpc(dueno, 'master_data')['moves']) == 1)
    t.rechaza_rpc('borrar algo que no existe', dueno, 'master_delete', ('promocion', '00000000-0000-0000-0000-000000000000'), 'No encontramos')

    # --- Usuarios Master con accesos ---
    t.rpc(dueno, 'master_save', 'usuario', J({'email': 'Sub@Prueba.cl', 'name': 'Contadora', 'perms': ['finanzas', 'usuarios']}))
    t.rechaza_rpc('email repetido', dueno, 'master_save', ('usuario', J({'email': 'sub@prueba.cl', 'name': 'Otra', 'perms': []})), 'ya es usuario')
    t.rechaza_rpc('acceso inventado', dueno, 'master_save', ('usuario', J({'email': 'x@prueba.cl', 'name': 'Equis', 'perms': ['todo']})), 'Acceso')
    ms = t.rpc(sub, 'master_me')
    t.check('sub entra con sus accesos', ms and not ms['owner'] and set(ms['perms']) == {'finanzas', 'usuarios'} and ms['account'] is False)
    ds = t.rpc(sub, 'master_data')
    t.check('sub con finanzas ve movimientos y no cuentas', 'moves' in ds and 'counts' not in ds)
    t.check('sub con usuarios ve usuarios', any(a['email'] == 'sub@prueba.cl' for a in ds['admins']))
    t.rechaza_rpc('sub sin tarifas no cambia tarifas', sub, 'master_save', ('tarifas', J({'price_clp': 1, 'price_usd': 1})), 'No tienes acceso')
    t.rechaza_rpc('sub sin descuentos no descuenta', sub, 'master_save', ('descuento', J({'club_id': cid, 'kind': 'pct', 'value': 5})), 'No tienes acceso')
    t.rechaza_rpc('sub no entrega accesos que no tiene', sub, 'master_save', ('usuario', J({'email': 'sub2@prueba.cl', 'name': 'Dos', 'perms': ['tarifas']})), 'tú tienes')
    t.rechaza_rpc('sub no se modifica a sí mismo', sub, 'master_save', ('usuario', J({'email': 'sub@prueba.cl', 'name': 'Yo', 'perms': ['finanzas'], 'edit': True})), 'propio')
    t.rechaza_rpc('sub no modifica al dueño', sub, 'master_save', ('usuario', J({'email': 'dueno@prueba.cl', 'name': 'Equis', 'perms': [], 'edit': True})), 'dueño')
    t.rechaza_rpc('sub no quita al dueño', sub, 'master_delete', ('usuario', 'dueno@prueba.cl'), 'dueño')
    t.rechaza_rpc('dueño no se quita a sí mismo', dueno, 'master_delete', ('usuario', 'dueno@prueba.cl'), 'dueño')
    t.rpc(sub, 'master_save', 'usuario', J({'email': 'sub2@prueba.cl', 'name': 'Dos', 'perms': ['finanzas']}))
    t.check('sub crea otro usuario con sus accesos', t.rpc(sub2, 'master_me')['perms'] == ['finanzas'])
    t.rpc(dueno, 'master_save', 'usuario', J({'email': 'sub2@prueba.cl', 'name': 'Dos', 'perms': ['finanzas'], 'active': False, 'edit': True}))
    t.check('usuario desactivado ya no entra', t.rpc(sub2, 'master_me') is None)
    t.rechaza_rpc('usuario desactivado no ve datos', sub2, 'master_data', (), 'No tienes acceso')
    t.rpc(dueno, 'master_delete', 'usuario', 'sub2@prueba.cl')
    t.check('quita usuario', not any(a['email'] == 'sub2@prueba.cl' for a in t.rpc(dueno, 'master_data')['admins']))
    t.rpc(dueno, 'master_save', 'usuario', J({'email': 'sub@prueba.cl', 'name': 'Contadora', 'perms': ['cuentas'], 'edit': True}))
    ds = t.rpc(sub, 'master_data')
    t.check('cambiar accesos rige de inmediato', 'counts' in ds and 'moves' not in ds and 'admins' not in ds)
    t.check('nadie sin fila sigue sin acceso', t.rpc(nadie, 'master_me') is None)

    # --- Cobro mensual, estado del club y bloqueo del club inactivo ---
    auth_admin(t, "update public.platform_discounts set active = false")
    auth_admin(t, "update public.platform_promos set active = false")
    auth_admin(t, "update public.platform_settings set price_clp = 1000, billing_start = date_trunc('month', current_date - interval '7 months')::date")
    auth_admin(t, "update public.clubs set created_at = now() - interval '8 months' where id = %s", (cid,))
    b = t.rpc(club, 'club_billing')
    t.check('el club ve sus cobros desde el inicio del cobro', len(b['charges']) == 8 and all(c['currency'] == 'CLP' for c in b['charges']))
    t.check('cobro de un mes = hábiles × tarifa', float(b['charges'][1]['amount']) == 2000 and b['charges'][1]['players'] == 2)
    t.check('el mes en curso con pagos no se recalcula', float(b['charges'][0]['paid']) == 2400)
    t.check('7 meses impagos: club inactivo', b['owed'] == 7 and b['state'] == 'inactivo' and b['canPay'] is True)
    t.check('master ve el estado del club', next(c for c in t.rpc(dueno, 'master_data')['clubs'] if c['id'] == cid)['state'] == 'inactivo')
    t.rechaza_rpc('club inactivo no crea categorías', club, 'add_team', (J({'sport': 'Fútbol', 'name': 'Sub-10', 'category': 'Sub-10', 'sex': 'Mixto'}),), 'inactivo')
    t.rechaza_rpc('club inactivo no inscribe socios', club, 'club_add_members', (cid, 'apoderado', None, None, J([{'name': 'Apo Nuevo', 'email': 'apo9@prueba.cl', 'phone': '+56911112222'}])), 'inactivo')
    t.rechaza_rpc('club inactivo no guarda registros', club, 'save_records', (J({'up': [{'kind': 'movements', 'id': 'mv_x', 'data': {'id': 'mv_x', 'clubId': cid, 'type': 'egreso', 'amount': 5}}], 'del': []}),), 'inactivo')
    t.check('club inactivo sigue viendo sus datos', t.rpc(club, 'my_state')['clubs'][0]['id'] == cid)
    t.rechaza_rpc('no se informan meses sin saldo', club, 'club_report_payment', (J({'periods': ['2001-01']}),), 'saldo')
    per = sorted(c['period'] for c in b['charges'])
    rid = t.rpc(club, 'club_report_payment', J({'periods': per[:3], 'method': 'Transferencia', 'reference': 'OP-123'}))
    t.rechaza_rpc('no se informa dos veces el mismo mes', club, 'club_report_payment', (J({'periods': per[:1]}),), 'Ya informaste')
    t.rechaza_rpc('deportista no informa pagos del club', dep, 'club_report_payment', (J({'periods': per[:1]}),), 'Solo la cuenta')
    rep = next(r for r in t.rpc(dueno, 'master_data')['reports'] if r['id'] == rid)
    t.check('master ve el pago informado', rep['status'] == 'pendiente' and float(rep['amount']) == 6000)
    t.rechaza_rpc('rechazo sin motivo', dueno, 'master_save', ('reporte', J({'id': rid, 'ok': False})), 'motivo')
    t.rechaza_rpc('sub sin finanzas no confirma pagos', sub, 'master_save', ('reporte', J({'id': rid, 'ok': True})), 'No tienes acceso')
    t.rpc(dueno, 'master_save', 'reporte', J({'id': rid, 'ok': True}))
    b = t.rpc(club, 'club_billing')
    t.check('confirmar paga los 3 meses más antiguos', b['owed'] == 4 and b['state'] == 'revision')
    t.check('el club ve su pago confirmado', b['reports'][0]['status'] == 'confirmado')
    t.check('club en revisión vuelve a poder actuar', t.rpc(club, 'add_team', J({'sport': 'Fútbol', 'name': 'Sub-10', 'category': 'Sub-10', 'sex': 'Mixto'})) is not None)
    t.rechaza_rpc('pago ya revisado', dueno, 'master_save', ('reporte', J({'id': rid, 'ok': True})), 'ya fue revisado')

    # --- Estado manual: solo el dueño ---
    auth_admin(t, "update public.platform_admins set perms = array['cuentas', 'usuarios'] where email = 'sub@prueba.cl'")
    t.rechaza_rpc('sub con cuentas no cambia el estado', sub, 'master_save', ('estado', J({'id': cid, 'status': 'activo'})), 'dueño')
    t.rpc(dueno, 'master_save', 'estado', J({'id': cid, 'status': 'inactivo'}))
    t.check('dueño inactiva un club al día', t.rpc(club, 'club_billing')['state'] == 'inactivo')
    t.check('el club recibe el aviso', any('inactivo' in n['text'] for n in t.rpc(club, 'my_state')['notifications']))
    t.rpc(dueno, 'master_save', 'estado', J({'id': cid, 'status': 'activo'}))
    t.check('dueño activa un club con deuda', t.rpc(club, 'club_billing')['state'] == 'activo')
    t.rpc(dueno, 'master_save', 'estado', J({'id': cid, 'status': 'auto'}))
    t.check('según pagos vuelve al estado por deuda', t.rpc(club, 'club_billing')['state'] == 'revision')
    t.rechaza_rpc('estado inventado', dueno, 'master_save', ('estado', J({'id': cid, 'status': 'feliz'})), 'Estado')
    t.rechaza('club no cambia su propio estado', club, "update public.clubs set platform_status = 'activo'", texto='permission denied')

    # --- Formas de pago de My Club ---
    t.rechaza_rpc('link sin https', dueno, 'master_save', ('metodo', J({'kind': 'link', 'name': 'Mercado Pago', 'url': 'http://x.cl'})), 'https')
    t.rechaza_rpc('transferencia sin número', dueno, 'master_save', ('metodo', J({'kind': 'transferencia', 'name': 'Banco', 'holder': 'My Club SpA'})), 'número')
    mid1 = t.rpc(dueno, 'master_save', 'metodo', J({'kind': 'transferencia', 'name': 'Transferencia', 'bank': 'BancoEstado', 'number': '123456', 'holder': 'My Club SpA', 'script': 'x'}))
    t.rpc(dueno, 'master_save', 'metodo', J({'kind': 'link', 'name': 'Mercado Pago', 'url': 'https://mpago.la/abc', 'active': False}))
    ms = t.rpc(club, 'club_billing')['methods']
    t.check('el club ve solo las formas de pago activas', [m['name'] for m in ms] == ['Transferencia'] and 'script' not in ms[0]['data'])
    t.rpc(dueno, 'master_delete', 'metodo', mid1)
    t.check('borra forma de pago', t.rpc(club, 'club_billing')['methods'] == [])
    t.rechaza('club no lee platform_charges', club, 'select * from public.platform_charges', texto='permission denied')
    t.rechaza('club no informa pagos directo', club, 'insert into public.platform_reports (club_id, periods, amount, currency) values (%s, array[current_date], 1, \'CLP\')', (cid,), 'permission denied')

    # --- El panel Master no cambia lo que ven las cuentas normales ---
    t.check('my_state del dueño sigue siendo su cuenta', t.rpc(dueno, 'my_state')['account']['type'] == 'jugador')
    t.rpc(dueno, 'master_save', 'estado', J({'id': cid2, 'status': 'inactivo'}))
    t.rpc(club2, 'delete_my_account')
    t.check('un club inactivo puede eliminar su cuenta (exigencia de tiendas)', not any(c['id'] == cid2 for c in t.rpc(dueno, 'master_data')['clubs']))


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
