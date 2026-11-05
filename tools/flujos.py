from playwright.sync_api import sync_playwright
URL='http://localhost:8123/'
errs=[]; log=[]
def ok(c,m): log.append(('OK ' if c else 'FALLA ')+m)
with sync_playwright() as p:
    b=p.chromium.launch()
    c=b.new_context(viewport={'width':390,'height':844},device_scale_factor=2,is_mobile=True,has_touch=True,service_workers='block')
    g=c.new_page()
    g.on('console',lambda m:errs.append(m.text) if m.type=='error' else None); g.on('pageerror',lambda e:errs.append(str(e)))
    g.goto(URL); g.wait_for_selector('.login')
    def tap(t): g.get_by_text(t,exact=False).first.click(timeout=4000); g.wait_for_timeout(120)
    def ev(j): return g.evaluate(j)
    def nav(r): g.evaluate("h=>{location.hash='#'+h}",r); g.wait_for_timeout(120)
    def setrole(r): g.evaluate("r=>{A.setRole(r)}",r); g.wait_for_timeout(420)
    # Login con clic real
    g.click('button.role:has-text("Jugador")'); g.get_by_role('button',name='Entrar').click(); g.wait_for_selector('.grid')
    ok(g.inner_text('.ttl')=='Hola, Matías','login jugador')
    # Editar inicio persiste tras recarga
    tap('Editar inicio'); g.wait_for_selector('.edrow'); g.click('.edrow:nth-child(3) button[aria-label^="Fijar"]'); g.click('.edrow:nth-child(2) button[aria-label^="Ocultar"]'); tap('Listo')
    g.reload(); g.wait_for_selector('.grid')
    ok('Fijados' in g.inner_text('#view') or 'FIJADOS' in g.inner_text('#view').upper(),'inicio persiste fijado tras recargar')
    ok(ev("homeLayout('jugador')[1].hidden")==True,'inicio persiste oculto')
    # Pago de cuota -> comprobante
    nav('/pagos'); g.click('input[name=chg]'); g.wait_for_timeout(50); g.click('#pay-btn'); g.wait_for_selector('text=Medio de pago'); g.get_by_role('button',name='Pagar $').click(); g.wait_for_function("location.hash.includes('comprobante')",timeout=4000)
    ok('COMPROBANTE N' in g.inner_text('#view').upper(),'pago termina en comprobante')
    # QR verificable
    g.click('.ver button'); g.wait_for_timeout(200); ok('Documento válido' in g.inner_text('#view'),'QR verifica comprobante')
    # Credencial al pagar federación
    nav('/j/credencial'); tap('Pagar cuota'); g.wait_for_selector('text=Medio de pago'); g.get_by_role('button',name='Pagar $').click(); g.wait_for_function("location.hash.includes('comprobante')",timeout=4000)
    nav('/j/credencial'); ok('Credencial federada' in g.inner_text('#view') and 'Temporada' in g.inner_text('#view'),'credencial generada tras pago')
    # Certificado: solo un campo editable
    nav('/j/certificado'); g.fill('#ce-to','Universidad de Concepción'); ok('Universidad de Concepción' in g.inner_text('.docp'),'certificado refleja Para presentar en'); ok(g.locator('.card input:not([type=hidden])').count()==1,'certificado solo 1 campo editable')
    # Escanear QR y votar
    nav('/escanear'); g.wait_for_timeout(2300);  ok('Asistencia registrada' in g.inner_text('#view'),'escaneo registra asistencia'); g.locator('button:has-text("A favor")').first.click(); g.wait_for_timeout(150); ok(ev("assemblyOf('as1').motions[0].votes.p_matias")=='si','voto registrado')
    # Transferencia sin deuda: automática
    nav('/cambio-club'); g.wait_for_timeout(120); ok('automática' in g.inner_text('#view'),'sin deuda: aviso automática'); tap('Continuar'); g.wait_for_selector('text=Medio de pago'); g.get_by_role('button',name='Pagar $').click(); g.wait_for_function("location.hash.includes('comprobante')",timeout=4000)
    ok(ev("activeInSport('p_matias','Fútbol').clubId")!='halcones','transferencia completada tras pago'); ok(ev("S.memberships.find(m=>m.id==='m_p_matias').status")=='desvinculado','historial conservado')
    nav('/j/cv'); ok('Los Halcones' in g.inner_text('#view'),'CV conserva club anterior')
    # Regla un club por deporte
    ev("(()=>{window._r=requestJoin('p_matias','halcones','Fútbol','hal-fut-adu','')})()"); ok('error' in ev("_r"),'un club por deporte')
    # Apoderado: transferencia con deuda requiere autorización
    setrole('apoderado'); ev("S.ui.kid='p_tomas'"); nav('/cambio-club'); g.wait_for_timeout(120); ok('autorización' in g.inner_text('#view'),'con deuda: requiere autorización'); tap('Continuar'); g.wait_for_timeout(200)
    ok(ev("S.transfers.at(-1).status")=='pendiente_autorizacion','transferencia queda pendiente')
    setrole('directivo'); nav('/d/solicitudes'); g.wait_for_timeout(100); ok('Deuda con tu club' in g.inner_text('#view'),'directivo ve transferencia'); ok('$45.000' in g.inner_text('#view'),'aviso deuda otro club $45.000'); 
    g.locator('button:has-text("Autorizar")').first.click(); g.wait_for_timeout(120); ok(ev("S.transfers.at(-1).status")=='pendiente_pago','autorizada queda por pagar')
    g.locator('button:has-text("Aceptar")').first.click(); g.wait_for_timeout(120); ok(ev("S.requests[0].status")=='aceptada' and ev("S.memberships.find(m=>m.id==='m_renato_req').status")=='habil','solicitud aceptada queda hábil')
    # Baja por no pago, suspendido, pago anula
    ev("S.memberships.find(m=>m.id==='m_p_ignacio')&&0"); nav('/d/bajas'); ev("A.ui('bjTab','nueva')"); g.wait_for_timeout(120); g.select_option('#bj-m','m_p_ignacio'); g.fill('#bj-d','Dos meses impagos'); g.fill('#bj-a','Art. 12 b)'); tap('Adjuntar antecedente'); g.get_by_role('button',name='Iniciar baja').click(); g.wait_for_timeout(450); g.locator('.sheet button:has-text("Iniciar baja")').click(); g.wait_for_timeout(450)
    ok(ev("S.memberships.find(m=>m.id==='m_p_ignacio').status")=='suspendido','baja deja suspendido'); t=g.inner_text('#view'); ok('Días hábiles restantes' in t or 'DÍAS HÁBILES' in t.upper(),'cuenta regresiva visible'); ok('10' in g.inner_text('.countdown'),'10 días hábiles')
    sid=ev("S.separations.at(-1).id")
    ev("(()=>{window._s=S.separations.at(-1);window._ids=debtCharges('p_ignacio','halcones').map(c=>c.id);payCharges(_ids,'x')})()"); ok(ev("S.separations.at(-1).status")=='anulada' and ev("S.memberships.find(m=>m.id==='m_p_ignacio').status")=='habil','pago dentro del plazo anula baja')
    # Coach: suspendido no convocable
    setrole('entrenador'); ev("S.ui.coachTeam='hal-fut-adu'"); eid=ev("nextEvent('hal-fut-adu').id"); nav('/e/evento/'+eid); g.wait_for_timeout(120); ok('Suspendido' in g.inner_text('#view'),'suspendido visible al citar'); ok('p_diego' not in ev(f"(A.citeAll('{eid}'),S.events.find(e=>e.id==='{eid}').cited)"),'suspendido no se cita')
    # Propuesta, aprobación manual y automática
    n=ev("S.charges.length"); nav('/e/proponer'); g.wait_for_timeout(100); g.fill('#ep-t','Viaje a Rancagua'); g.fill('#ep-a','12000'); tap('Enviar a VB'); ok('Pendiente de VB' in g.inner_text('#view'),'propuesta pendiente de VB')
    setrole('directivo'); nav('/d/aprobaciones'); g.wait_for_timeout(120); g.locator('button:has-text("Aprobar")').first.click(); g.wait_for_timeout(120); ok(ev("S.proposals[0].status")=='aprobada' and ev("S.charges.length")>n,'aprobar genera cobros')
    # CSV
    setrole('entrenador'); nav('/e/carga'); tap('Usar archivo de ejemplo'); t=g.inner_text('#view'); ok('RUT inválido' in t and 'RUT duplicado' in t and 'Falta el nombre' in t,'CSV valida rut, duplicado, obligatorio'); 
    with g.expect_download() as d: tap('Descargar plantilla')
    ok(d.value.suggested_filename.endswith('.csv'),'plantilla CSV se descarga')
    # Plazo vence: desvinculación firme
    setrole('directivo'); nav('/plazo/sp2'); g.wait_for_timeout(120); ok(ev("S.separations.find(x=>x.id==='sp2').status")=='en_plazo','renuncia en plazo'); ev("(A.time(15))"); g.wait_for_timeout(200); ok(ev("S.separations.find(x=>x.id==='sp2').status")=='firme' and 'COMPROBANTE' in g.inner_text('#view').upper(),'plazo vencido deja firme y comprobante')
    ok(ev("S.memberships.find(m=>m.id==='m_p_fernanda').status")=='desvinculado','membresía conservada como desvinculada')
    # Reclamo rechazado -> firme
    nav('/d/reclamos'); g.wait_for_timeout(120); tap('Reclamo por baja'); g.wait_for_timeout(420); g.locator('.sheet button:has-text("Rechazar")').click(); g.wait_for_timeout(400); ok(ev("S.separations.find(x=>x.id==='sp1').status")=='firme','reclamo rechazado deja firme')
    # Cotización: proveedor responde, club paga, comisión
    setrole('proveedor'); nav('/p/cotizacion/q1'); g.wait_for_timeout(120); g.fill('.ql-q','30'); tap('Enviar cotización'); ok(ev("S.quotes.find(q=>q.id==='q1').status")=='enviada','proveedor envía cotización')
    setrole('directivo'); nav('/cotizacion/q1'); g.wait_for_timeout(120); tap('Aceptar y pagar'); g.wait_for_selector('text=Medio de pago'); g.get_by_role('button',name='Pagar $').click(); g.wait_for_function("location.hash.includes('comprobante')",timeout=4000); ok(ev("S.quotes.find(q=>q.id==='q1').status")=='pagada','club paga cotización')
    setrole('proveedor'); nav('/p/cotizacion/q1'); g.wait_for_timeout(120); ok('Comisión My Club' in g.inner_text('#view'),'proveedor ve neto con comisión')
    # Federación ámbito y comunicado
    setrole('federacion'); ev("A.ui('fedScope','as-bio')"); nav('/f/dashboard'); g.wait_for_timeout(120); ok('Biobío' in g.inner_text('#view'),'vista asociación limitada'); nav('/f/comunicados'); g.wait_for_timeout(100); tap('Nuevo comunicado'); g.wait_for_timeout(420); g.fill('#co-t','Aviso'); g.fill('#co-b','Texto'); tap('Enviar a todos los clubes'); g.wait_for_timeout(420); ok(ev("S.notifs.filter(n=>n.text.includes('Aviso')).length")==4,'comunicado llega a todos los roles')
    # Registro: menor bloqueado, adulto mensaje exacto
    ev("A.logout()"); g.wait_for_timeout(200); nav('/registro'); g.wait_for_timeout(100); g.fill('#rg-name','Test Menor'); g.fill('#rg-rut','11.111.111-1'); g.fill('#rg-birth','2015-01-01'); tap('65.123.456'); tap('Enviar solicitud'); ok('menores de edad' in g.inner_text('#rg-err'),'menor bloqueado en registro')
    g.fill('#rg-birth','1995-01-01'); tap('Enviar solicitud'); g.wait_for_timeout(900); ok('El club ha recibido su solicitud de incorporación. Cuando el club la acepte, aparecerá como jugador hábil.' in g.inner_text('.sheet'),'mensaje exacto incorporación'); g.screenshot(path='/tmp/myclub-registro.png')
    # Restablecer demo
    ev("A.doReset()"); g.wait_for_timeout(300); ok(ev("S.session.loggedIn")==False and g.locator('.login').count()==1,'restablecer demo')
    # Offline con SW
    c2=b.new_context(viewport={'width':390,'height':844}); h=c2.new_page(); h.goto(URL); h.wait_for_function("navigator.serviceWorker.ready.then(()=>true)"); h.wait_for_timeout(600); h.reload(); h.wait_for_timeout(300); c2.set_offline(True); h.reload(); h.wait_for_selector('.login',timeout=4000); ok(True,'funciona sin conexión'); 
    b.close()
print('\n'.join(l for l in log if l.startswith('FALLA')) or 'TODOS OK'); print(len(log),'comprobaciones'); print('CONSOLA:',errs[:8])
