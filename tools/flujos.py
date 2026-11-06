import servidor_demo
servidor_demo.servir()
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
    g.get_by_role('button',name='INGRESAR').click(); g.wait_for_selector('.grid')
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
    # Ingreso: solo email, clave y dos botones
    ev("A.logout()"); g.wait_for_timeout(300)
    ok(g.locator('.login input').count()==2 and g.locator('.login button').count()==2,'ingreso solo con email, clave y 2 botones'); ok('INGRESAR' in g.inner_text('.login') and 'REGISTRARSE' in g.inner_text('.login'),'botones INGRESAR y REGISTRARSE')
    g.fill('#lg-pw','mala'); g.get_by_role('button',name='INGRESAR').click(); g.wait_for_timeout(100); ok('incorrectos' in g.inner_text('#lg-err'),'clave incorrecta rechazada')
    def rut(n): return ev(f"fmtRut({n})")
    def abrir(tipo):
        ev("A.logout()"); g.wait_for_timeout(200); nav('/registro'); g.wait_for_timeout(120)
        if ev("S.ui.regType")!=None: ev("S.ui.regType=null;rerender()")
        g.locator(f'#rg-{tipo} button.li').click(); g.wait_for_timeout(200)
    def base(nombre,r,email,clave='prueba123'):
        g.fill('#rg-name',nombre); g.fill('#rg-rut',r); g.fill('#rg-email',email); g.fill('#rg-phone','+56 9 1111 2222'); g.fill('#rg-pass',clave); g.check('#rg-legal')
    def completar(): g.get_by_role('button',name='Completar Registro').click(); g.wait_for_timeout(120)
    def nuevoid():
        g.wait_for_selector('#new-id',timeout=3000); v=g.inner_text('#new-id'); g.wait_for_timeout(350); return v
    nav('/registro'); g.wait_for_timeout(150); ok(g.locator('#view .list').count()==6 and 'Directivo' not in g.inner_text('#view'),'registro muestra 6 tipos, sin Directivo'); ok('Deportista' in g.inner_text('#view') and 'Jugador' not in g.inner_text('#view'),'Jugador renombrado a Deportista')
    # Club: mínimo 3 cargos
    abrir('club'); base('Club Deportivo Prueba',rut(66111222),'club@prueba.cl'); g.fill('#rg-date','2010-03-15'); g.fill('#rg-num','RD-4471')
    n=g.locator('.dir-n'); n.nth(0).fill('Ana Presidenta'); n.nth(1).fill('Beto Vice'); completar(); ok('mínimo 3 cargos' in g.inner_text('#rg-err'),'club exige mínimo 3 cargos')
    g.get_by_role('button',name='Agregar cargo').click(); ok(g.locator('.dir-row').count()==6,'botón agregar cargo'); g.locator('.dir-c').nth(5).fill('Delegado'); g.locator('.dir-n').nth(5).fill('Carla Delegada'); completar()
    cid_new=nuevoid(); ok(cid_new=='C00000008','club recibe C00000008 correlativo: '+cid_new)
    nav('/club/'+ev("S.clubs.at(-1).id")); g.wait_for_timeout(150); t=g.inner_text('#view'); ok(cid_new in t and 'Carla Delegada' in t and 'RD-4471' in t,'ficha del club muestra ID y directorio')
    # Deportista: menor, ID erróneo, vinculación y mensaje exacto
    abrir('jugador'); base('Paula Atleta',rut(19888777),'paula@prueba.cl')
    g.fill('#rg-birth','1995-01-01'); g.fill('#rg-height','172'); g.fill('#lk-id','C99999999'); g.get_by_role('button',name='VINCULAR AL CLUB').click(); g.wait_for_timeout(100); ok('No encontramos' in g.inner_text('#lk-res'),'ID de club inexistente')
    completar(); ok('VINCULAR AL CLUB' in g.inner_text('#rg-err'),'exige confirmar el ID')
    g.fill('#lk-id','c00000001'); g.get_by_role('button',name='VINCULAR AL CLUB').click(); g.wait_for_timeout(100); ok('Los Halcones' in g.inner_text('#lk-res'),'VINCULAR encuentra el club'); g.select_option('#lk-sport','Vóleibol'); completar()
    v=nuevoid(); ok(v=='D00000002','deportista correlativo: '+v); ok('El club ha recibido su solicitud de incorporación. Cuando el club la acepte, aparecerá como jugador hábil.' in g.inner_text('.sheet'),'mensaje exacto de incorporación')
    ok(ev("S.players.at(-1).height")==172,'estatura guardada'); ok(ev("S.memberships.at(-1).status")=='pendiente' and ev("S.memberships.at(-1).sport")=='Vóleibol','membresía pendiente con deporte elegido')
    # Sin vincular: entrenador, directivo, apoderado, federación, proveedor
    abrir('entrenador'); base('Eva Coach',rut(16222333),'eva@prueba.cl'); g.fill('#lk-id',cid_new); g.get_by_role('button',name='VINCULAR AL CLUB').click(); g.wait_for_timeout(100); completar(); v=nuevoid(); ok(v=='E00000002','entrenador correlativo: '+v); ok('Vincúlate' in g.inner_text('#view') or 'pendiente' in g.inner_text('#view').lower(),'entrenador sin aprobar ve pantalla de vinculación')
    abrir('apoderado'); base('Ale Apoderada',rut(14666777),'ale@prueba.cl'); completar(); v=nuevoid(); ok(v=='A00000002','apoderado correlativo: '+v)
    ok('pupilos' in g.inner_text('#view').lower(),'apoderado sin pupilos ve aviso'); nav('/a/registrar-hijo'); g.wait_for_timeout(120); g.fill('#rh-name','Lola Hija'); g.fill('#rh-rut',rut(24555666)); g.fill('#rh-birth','2014-06-06'); tap('Registrar y solicitar'); g.wait_for_timeout(800); ok(ev("myKids().length")==1,'apoderado registra hijo'); ev("closeSheet()"); g.wait_for_timeout(350)
    abrir('federacion'); base('Fede Remo',rut(13888999),'fede@prueba.cl'); g.select_option('#rg-sport','Remo'); completar(); v=nuevoid(); ok(v=='F00000002','federación correlativo: '+v); ok(ev("S.ui.fedSport")=='Remo','federación usa su deporte')
    abrir('proveedor'); base('Tienda Prueba',rut(77222333),'tienda@prueba.cl'); completar(); v=nuevoid(); ok(v=='P00000002','proveedor correlativo: '+v)
    # Email repetido y reingreso con cuenta creada
    abrir('entrenador'); base('Otro',rut(12333444),'eva@prueba.cl'); completar(); ok('ya está registrado' in g.inner_text('#rg-err'),'email duplicado rechazado')
    def login(e,c):
        ev("A.logout()"); g.wait_for_timeout(250); g.fill('#lg-em',e); g.fill('#lg-pw',c); g.get_by_role('button',name='INGRESAR').click(); g.wait_for_timeout(250)
    # Club aprueba la vinculación del entrenador y este queda con acceso cuando hay equipo
    login('club@prueba.cl','prueba123'); nav('/d/solicitudes'); g.wait_for_timeout(120); ok('Eva Coach' in g.inner_text('#view'),'club ve la vinculación pendiente'); g.locator('button:has-text("Aceptar")').first.click(); g.wait_for_timeout(150)
    ev("S.clubs.at(-1).sports.push('Fútbol');S.teams.push({id:'t_new',clubId:S.clubs.at(-1).id,sport:'Fútbol',name:'Fútbol Prueba',category:'Adulto',sex:'Mixto',coach:'Eva'});save()")
    login('eva@prueba.cl','prueba123'); ok(ev("!needsClub()"),'entrenador vinculado entra a su club'); ok(ev("coach().clubId")==ev("S.clubs.at(-1).id"),'entrenador en club nuevo')
    # Cuentas nuevas recorren sus pantallas sin errores ni datos del demo
    rutas={'club@prueba.cl':'/inicio /d/finanzas /d/deportes /d/aprobaciones /d/asambleas /d/solicitudes /d/bajas /d/reclamos /d/prestamos /d/jugadores /d/masivo /marketplace /mensajes /perfil /notificaciones','eva@prueba.cl':'/inicio /e/eventos /e/nuevo-evento /e/plantel /torneos /e/proponer /encuestas /e/encuesta-nueva /e/masivo /rutinas /e/staff /e/carga /marketplace /mensajes /perfil','paula@prueba.cl':'/inicio /calendario /asistencia /pagos /muro /mensajes /encuestas /j/cv /j/cv-imprimir /j/certificado /j/credencial /unirme /cambio-club /renuncia /rutinas /tramites /perfil','ale@prueba.cl':'/inicio /a/pupilos /pagos /asistencia /calendario /mensajes /a/reportes /cambio-club /renuncia /tramites /perfil /vincular','fede@prueba.cl':'/inicio /f/dashboard /f/clubes /f/comunicados /f/valores /f/ficha /f/estadisticas /perfil','tienda@prueba.cl':'/inicio /p/perfil /p/catalogo /p/categorias /p/recintos /p/cotizaciones /p/torneos /p/pagos /perfil'}
    malas=[]
    for mail,rs in rutas.items():
        login(mail,'prueba123')
        for r in rs.split():
            nav(r); g.wait_for_timeout(90)
            t=g.inner_text('#view')
            if 'No pudimos' in t or 'undefined' in t or 'NaN' in t: malas.append(mail+' '+r)
    ok(not malas,'cuentas nuevas sin pantallas rotas: '+str(malas))
    login('club@prueba.cl','prueba123'); nav('/d/aprobaciones'); g.wait_for_timeout(120); ok('Copa Primavera' not in g.inner_text('#view'),'club nuevo no ve propuestas de otro club'); ok(ev("unread()")<=2,'club nuevo sin notificaciones del demo')
    # Logo del club: se actualiza en todas las cuentas vinculadas
    login('club@myclub.cl','demo'); ok(ev("acct().id")=='C00000001' and ev("role()")=='directivo','Directivo reemplazado por Club con ID C'); nav('/perfil'); g.wait_for_timeout(120); ok('Directivo' not in g.inner_text('#view') and 'ID C00000001' in g.inner_text('#view'),'perfil dice Club, no Directivo')
    nav('/perfil/editar'); g.wait_for_timeout(150); ok(g.locator('#view .lockf').count()==3 and g.locator('#ed-name').count()==0,'nombre, RUT y constitución bloqueados en club')
    g.set_input_files('input[type=file]','tools/logo-original.png'); g.wait_for_function("!!club('halcones').logo",timeout=5000); g.wait_for_timeout(150); ok(ev("club('halcones').logo.length")<400000,'logo reducido antes de guardar'); ok(g.locator('#ph-prev img.clog').count()==1,'vista previa del logo')
    g.fill('#ed-desc','Descripción actualizada del club'); g.fill('#ed-city','Ñuñoa'); g.get_by_role('button',name='Guardar cambios').click(); g.wait_for_timeout(250)
    login('entrenador@myclub.cl','demo'); nav('/inicio'); g.wait_for_timeout(150); ok(g.locator('#view img.clog').count()>=1,'entrenador vinculado ve el logo'); g.locator('#view button.hero').click(); g.wait_for_timeout(200); ok('Descripción actualizada del club' in g.inner_text('#view') and 'Presidenta' in g.inner_text('#view'),'entrenador ve la ficha actualizada')
    login('apoderado@myclub.cl','demo'); nav('/a/pupilos'); ev("A.ui('kid','p_tomas')"); g.wait_for_timeout(150); ok(g.locator('#view img.clog').count()>=1,'apoderado ve el logo')
    login('paula@prueba.cl','prueba123'); ev("A.simJoin()"); nav('/inicio'); g.wait_for_timeout(150); ok(g.locator('#view img.clog').count()>=1,'deportista vinculado ve el logo'); g.reload(); g.wait_for_timeout(300); ok(g.locator('#view img.clog').count()>=1,'logo persiste al recargar')
    # Foto y datos editables; lo bloqueado no cambia
    nav('/perfil/editar'); g.wait_for_timeout(150); ok(g.locator('#view .lockf').count()==3,'deportista: nombre, RUT y nacimiento bloqueados'); g.set_input_files('input[type=file]','tools/logo-original.png'); g.wait_for_function("!!player(S.users.jugador).photo",timeout=5000); g.fill('#ed-height','181'); g.fill('#ed-email','paula2@prueba.cl'); g.get_by_role('button',name='Guardar cambios').click(); g.wait_for_timeout(250)
    ok(ev("player(S.users.jugador).height")==181 and ev("acct().name")=='Paula Atleta','editar guarda opcionales y no toca el nombre'); nav('/perfil'); g.wait_for_timeout(150); ok(g.locator('#view img.av').count()==1,'foto visible en perfil'); login('paula2@prueba.cl','prueba123'); ok(ev("acct().email")=='paula2@prueba.cl','ingreso con email editado')
    for mail in ['eva@prueba.cl','ale@prueba.cl','fede@prueba.cl','tienda@prueba.cl']:
        login(mail,'prueba123'); nav('/perfil/editar'); g.wait_for_timeout(120); g.set_input_files('input[type=file]','tools/logo-original.png'); g.wait_for_timeout(500); ok(ev("!!myPhoto()"),'foto en '+mail)
    # Directorio editable, mínimo 3
    login('club@prueba.cl','prueba123'); nav('/perfil/editar'); g.wait_for_timeout(150); g.locator('.dir-n').nth(0).fill(''); g.locator('.dir-n').nth(1).fill(''); g.get_by_role('button',name='Guardar cambios').click(); g.wait_for_timeout(150); ok('mínimo 3 cargos' in g.inner_text('#ed-err'),'editar directorio mantiene mínimo de 3 cargos')
    # Moderación: filtro, reportar, bloquear y bandeja del club
    login('demo@myclub.cl','demo'); ev("S.ui.wall='todos';save()"); nav('/muro'); g.wait_for_timeout(150); ev("A.newPost()"); g.wait_for_timeout(400); g.fill('#np-t','eres un weón'); g.get_by_role('button',name='Publicar').click(); g.wait_for_timeout(150); ok(ev("S.posts[0].text")!='eres un weón','filtro bloquea lenguaje ofensivo'); ev("closeSheet()"); g.wait_for_timeout(350)
    g.locator('button[aria-label="Reportar o bloquear"]').first.click(); g.wait_for_timeout(400); g.get_by_role('button',name='Enviar reporte').click(); g.wait_for_timeout(300); ok(ev("S.reports.length")==1,'reporte creado')
    g.locator('button[aria-label="Reportar o bloquear"]').nth(0).click(); g.wait_for_timeout(400); g.locator('.sheet button:has-text("Bloquear a")').click(); g.wait_for_timeout(300); ok(ev("myBlocks().length")==1,'usuario bloqueado')
    nav('/chat/ch2'); g.wait_for_timeout(150); g.locator('button[aria-label="Reportar o bloquear"]').click(); g.wait_for_timeout(400); g.locator('.sheet button:has-text("Bloquear a")').click(); g.wait_for_timeout(350); ok(ev("myChats().every(c=>c.id!=='ch2')"),'chat bloqueado desaparece')
    login('club@myclub.cl','demo'); nav('/d/reclamos'); g.wait_for_timeout(150); ok('Contenido reportado' in g.inner_text('#view').title() or 'CONTENIDO REPORTADO' in g.inner_text('#view').upper(),'club ve contenido reportado'); g.locator('button:has-text("Ocultar")').first.click(); g.wait_for_timeout(150); ok(ev("S.posts.some(p=>p.hidden)"),'club oculta contenido')
    # Eliminar cuenta y páginas legales
    login('tienda@prueba.cl','prueba123'); ev("A.deleteAsk()"); g.wait_for_timeout(400); g.fill('#del-pw','mala'); g.get_by_role('button',name='Eliminar definitivamente').click(); g.wait_for_timeout(120); ok('no es correcta' in g.inner_text('#del-err'),'eliminar exige clave'); g.fill('#del-pw','prueba123'); g.get_by_role('button',name='Eliminar definitivamente').click(); g.wait_for_timeout(500); ok(g.locator('.login').count()==1 and ev("S.accounts.filter(a=>a.email==='tienda@prueba.cl').length")==0,'eliminar borra la cuenta')
    login('demo@myclub.cl','demo'); ev("A.deleteAsk()"); g.wait_for_timeout(150); ok(ev("!!acct()"),'cuenta demo no se elimina'); ev("A.logout()"); g.wait_for_timeout(200); nav('/legal/privacidad'); g.wait_for_timeout(150); ok('Menores de edad' in g.inner_text('#view'),'privacidad visible sin sesión')
    nav('/login'); g.wait_for_timeout(200); bg=ev("[getComputedStyle([...document.querySelectorAll('.login .btn')][0]).backgroundColor,getComputedStyle([...document.querySelectorAll('.login .btn')][1]).backgroundColor]"); ok(bg==['rgb(244, 122, 31)','rgb(28, 209, 191)'],'INGRESAR naranjo y REGISTRARSE calipso '+str(bg))
    nav('/legal/eliminar-cuenta'); g.wait_for_timeout(150); ok('Sin la app instalada' in g.inner_text('#view'),'página web de eliminación de cuenta')
    # Menor con cuenta propia y apoderado que se vincula con el ID
    abrir('jugador'); base('Mina Menor',rut(22333444),'mina@prueba.cl'); g.fill('#rg-birth','2014-01-01'); completar(); mid=nuevoid(); ok(mid.startswith('D'),'menor crea su cuenta: '+mid)
    nav('/apoderados'); g.wait_for_timeout(150); ok(mid in g.inner_text('#view'),'menor ve su ID para compartirlo')
    abrir('apoderado'); base('Andrea Madre',rut(16555444),'andrea@prueba.cl'); completar(); nuevoid()
    nav('/a/vincular-pupilo'); g.wait_for_timeout(150); g.fill('#gl-id','D99999999'); g.get_by_role('button',name='Enviar solicitud').click(); g.wait_for_timeout(120); ok('No encontramos' in g.inner_text('#gl-err'),'ID inexistente rechazado')
    g.fill('#gl-id',mid.lower()); g.get_by_role('button',name='Enviar solicitud').click(); g.wait_for_timeout(150); ok('Simular aceptación' in g.inner_text('#view'),'solicitud queda pendiente')
    ok(ev("myKids().length")==0,'sin aceptar no queda como pupilo'); tap('Simular aceptación'); g.wait_for_timeout(150); ok(ev("myKids().length")==1,'aceptado queda como pupilo')
    nav('/a/pupilos'); g.wait_for_timeout(150); ok('Mina Menor' in g.inner_text('#view'),'pupilo con cuenta aparece')
    # Restablecer demo
    ev("A.doReset()"); g.wait_for_timeout(300); ok(ev("S.session.loggedIn")==False and g.locator('.login').count()==1,'restablecer demo')
    # Offline con SW
    c2=b.new_context(viewport={'width':390,'height':844}); h=c2.new_page(); h.goto(URL); h.wait_for_function("navigator.serviceWorker.ready.then(()=>true)"); h.wait_for_timeout(600); h.reload(); h.wait_for_timeout(300); c2.set_offline(True); h.reload(); h.wait_for_selector('.login',timeout=4000); ok(True,'funciona sin conexión'); 
    b.close()
print('\n'.join(l for l in log if l.startswith('FALLA')) or 'TODOS OK'); print(len(log),'comprobaciones'); print('CONSOLA:',errs[:8])
