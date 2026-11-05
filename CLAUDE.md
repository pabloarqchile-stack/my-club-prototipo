# My Club – Prototipo MVP (contexto para Claude Code)

## Objetivo
Prototipo navegable e interactivo de **My Club**, app para administrar clubes deportivos, asociaciones y
federaciones de Chile (todos los deportes). Sirve para visualizar y validar el producto. **Sin backend**:
datos de ejemplo y persistencia en `localStorage` (clave `myclub-demo-v1`).

## Formato (obligatorio)
- PWA instalable en iPhone, sin frameworks, sin CDN ni recursos externos, sin paso de compilación.
- Archivos: `index.html` (HTML + CSS + JS juntos), `manifest.webmanifest`, `sw.js` (caché offline), `icons/` (180, 192, 512 px).
- Mobile-first 390 × 844, zonas seguras `env(safe-area-inset-*)`, metas Apple, a pantalla completa desde la pantalla de inicio.
- Navegación por hash (`#/ruta`). En escritorio se ve centrado como un teléfono.
- Todo en español de Chile; montos `$25.000`.

## Diseño
- Principal `#1F4E79`, acento `#1BAF7A`, fondos claros, modo oscuro automático (`prefers-color-scheme`).
- Tipografía del sistema (-apple-system / SF Pro). Esquinas 12–16 px, tarjetas, íconos SVG en línea.
- Barra de pestañas inferior estilo iOS (máx. 5, cambia por rol), campana de notificaciones con contador.
- Botones ≥ 44 px, transiciones suaves, estados vacíos, toasts de confirmación.

## Estructura de `index.html` (secciones comentadas)
1. UTILIDADES (formato CLP, fechas, RUT, días hábiles y feriados de Chile)
2. DATOS DE EJEMPLO (`seed()` genera todo relativo a la fecha del primer uso)
3. ESTADO (`S`, `save()`, `load()`, `commit()`), identidad por rol (`me()`)
4. LÓGICA DE NEGOCIO (pagos, transferencias, renuncias/bajas, plazos, aprobaciones)
5. COMPONENTES (íconos, tarjetas, listas, hojas inferiores, toasts, gráficos SVG, QR SVG)
6. PANTALLAS (compartidas y por rol)
7. RUTAS y arranque

Las acciones de la UI viven en el objeto global `A` (`onclick="A.algo('id')"`).

## Roles y usuarios demo
| Rol | Usuario demo | Pestañas |
|---|---|---|
| Jugador | Matías Rojas Fuentes – Los Halcones, Fútbol Adulto | Inicio, Calendario, Muro, Mensajes, Perfil |
| Apoderado | Carolina Muñoz Pérez – Tomás (Fútbol Sub-15, Los Halcones) y Sofía (Natación, Náutico Valparaíso) | Inicio, Pupilos, Pagos, Mensajes, Perfil |
| Entrenador | Rodrigo Saavedra – Head coach Fútbol, Los Halcones | Inicio, Partidos, Torneos, Mensajes, Perfil |
| Directivo | Patricia Lagos – Presidenta Club Deportivo Los Halcones | Inicio, Finanzas, Aprobaciones, Mensajes, Perfil |
| Federación | Jorge Contreras – Federación de Fútbol (selector: nacional / asociaciones regionales) | Inicio, Dashboard, Comunicados, Estadísticas, Perfil |
| Proveedor | Deportes Andes SpA (selector de empresa demo) | Inicio, Catálogo, Cotizaciones, Torneos, Perfil |

Se cambia de rol desde **Perfil → Cambiar de rol** sin cerrar sesión.

## Rutas
- Compartidas: `#/login`, `#/registro`, `#/inicio`, `#/perfil`, `#/notificaciones`, `#/mensajes`, `#/chat/:id`,
  `#/pagar/:ids`, `#/comprobante/:id`, `#/verificar/:code`, `#/torneo/:id`, `#/encuestas`, `#/encuesta/:id`,
  `#/marketplace`, `#/proveedor/:id`, `#/escanear`, `#/asamblea/:id`, `#/plazo/:id`, `#/calendario`, `#/muro`, `#/rutinas`.
- Jugador / Apoderado (sujeto = el jugador o el pupilo elegido): `#/asistencia`, `#/pagos`, `#/unirme`, `#/cambio-club`,
  `#/renuncia`, `#/tramites`.
- Jugador: `#/j/cv`, `#/j/cv-imprimir`, `#/j/certificado`, `#/j/credencial`.
- Apoderado: `#/a/pupilos`, `#/a/registrar-hijo`, `#/a/reportes`.
- Entrenador: `#/e/eventos`, `#/e/evento/:id`, `#/e/nuevo-evento`, `#/torneos`, `#/e/proponer`, `#/e/encuesta-nueva`,
  `#/e/masivo`, `#/e/rutinas`, `#/e/staff`, `#/e/carga`, `#/e/plantel`.
- Directivo: `#/d/deportes`, `#/d/finanzas`, `#/d/aprobaciones`, `#/d/asambleas`, `#/d/solicitudes`, `#/d/bajas`,
  `#/d/reclamos`, `#/d/prestamos`, `#/d/prestamo/:id`, `#/d/jugadores`, `#/d/masivo`.
- Federación: `#/f/dashboard`, `#/f/comunicados`, `#/f/valores`, `#/f/ficha`, `#/f/estadisticas`, `#/f/clubes`.
- Proveedor: `#/p/perfil`, `#/p/catalogo`, `#/p/categorias`, `#/p/recintos`, `#/p/cotizaciones`, `#/p/cotizacion/:id`, `#/p/torneos`.

## Principios
- **Inicio personalizable** por rol: reordenar, fijar u ocultar accesos (modo "Editar inicio"), guardado en localStorage.
- **Varios deportes por club**; un jugador pertenece a **un solo club por deporte**.
- **Pagos simulados** (Webpay / Mercado Pago de ejemplo, sin datos de tarjeta) que terminan en comprobante.
- **Documentos verificables** con QR dibujado en SVG y código `MC-XXXX-XXXX` verificable en `#/verificar/:code`.

## Reglas de negocio
1. Incorporación: mensaje exacto "El club ha recibido su solicitud de incorporación. Cuando el club la acepte, aparecerá como jugador hábil." Estado "Pendiente" hasta que el directorio acepte.
2. Jugador adulto se registra con RUT del club + deporte. Menor solo lo registra su apoderado.
3. Transferencia: sin deuda → automática tras pagar el pase. Con deuda → requiere autorización del club de origen.
4. Renuncia / baja: la parte afectada recibe los motivos; plazo de **10 días hábiles** (lun–vie, sin feriados de Chile) para reclamar o subsanar, con cuenta regresiva y fecha límite.
5. Durante el plazo: jugador "Suspendido" en ese deporte (insignia roja), no convocable.
6. Baja por no pago + paga la deuda dentro del plazo → baja anulada automáticamente, vuelve a "Hábil".
7. Plazo vencido o reclamo rechazado → desvinculación firme + comprobante. El currículum nunca se borra.
8. Desvinculado con deuda puede pedir incorporación a otro club; ese club decide (ve aviso con el monto).
9. Botón "Simular paso del tiempo" (Perfil y pantallas de plazos) para adelantar días.

## Datos de ejemplo
3 clubes principales (Los Halcones: fútbol, básquetbol, vóleibol · Atlético Biobío: atletismo, rugby · Náutico Valparaíso:
remo, natación) + 4 "otros clubes de la red" usados como destino de transferencias y en estadísticas federadas.
Una federación por deporte, 2 asociaciones regionales (Biobío, Valparaíso), ~32 jugadores, apoderados con parentesco,
15 torneos, 6 meses de movimientos financieros, 10 proveedores.

## Criterios de aceptación
- Todas las pantallas existen y son alcanzables; nada roto; lo simulado lo avisa.
- Funciona en Safari iPhone, 375–430 px; cambios persisten; "Restablecer demo" en Perfil.
- Offline tras la primera carga. Recorrido de cada rol con Playwright (390×844 @3x), sin errores de consola; capturas en `/screenshots`.

## Verificación
Script Playwright en `tools/recorrido.py` (requiere `pip install playwright`). Servir con `python3 -m http.server 8080`.
