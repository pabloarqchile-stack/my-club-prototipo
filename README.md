# My Club – prototipo MVP

Prototipo navegable para administrar clubes deportivos, asociaciones y federaciones de Chile.
**Versión publicada:** https://pabloarqchile-stack.github.io/my-club-prototipo/

Tiene dos modos: **demo**, con datos de ejemplo guardados en el navegador, y **real**, con base de datos en Supabase. El modo real se activa al completar `config.js`.
Pagos, QR, chats, carga de archivos y escaneo son simulados.

## Cuentas de demostración

Clave `demo` para todas. La pantalla de ingreso ya trae la primera.

| Rol | Email |
|---|---|
| Deportista | `demo@myclub.cl` |
| Apoderado | `apoderado@myclub.cl` |
| Entrenador | `entrenador@myclub.cl` |
| Club | `club@myclub.cl` |
| Federación | `federacion@myclub.cl` |
| Proveedor | `proveedor@myclub.cl` |

Dentro de la app, **Perfil → Cambiar de rol** cambia entre estas cuentas. Para probar una vinculación, Club Deportivo Los Halcones tiene el ID `C00000001`.

## Probarla en el computador

Desde esta carpeta, con cualquiera de estos comandos:

```bash
python3 -m http.server 8080
```

```bash
npx serve .
```

Abre `http://localhost:8080` (con `npx serve` usa la dirección que muestre la terminal).

## Verla en el iPhone desde la misma red wifi

1. Deja el servidor corriendo en el computador.
2. Busca la IP del computador; en Mac: `ipconfig getifaddr en0`.
3. En Safari del iPhone abre `http://TU-IP:8080`.

Por `http` se navega, pero el modo sin conexión requiere `https`. Para instalarla bien usa GitHub Pages.

## Publicarla gratis en GitHub Pages

Con la CLI `gh` autenticada, desde esta carpeta:

```bash
gh repo create my-club-prototipo --public --source=. --push
```

```bash
gh api repos/{owner}/{repo}/pages -X POST -f "source[branch]=main" -f "source[path]=/"
```

También se puede hacer desde la web: crea el repositorio, sube los archivos y entra a
**Settings → Pages → Deploy from a branch → main / (root)**.
La URL queda como `https://TU-USUARIO.github.io/my-club-prototipo/`.

## Agregarla a la pantalla de inicio

1. Abre la URL `https` en **Safari** del iPhone.
2. Toca **Compartir** y luego **Agregar a pantalla de inicio**.
3. Confirma con **Agregar**. Se abrirá a pantalla completa, como una app.
4. Ábrela una vez con internet: después funciona sin conexión.

## Compilar para iOS y Android

`capacitor.config.json` y `package.json` dejan listo Capacitor 8, pero todavía no se ha compilado. Requiere Node 22+, Xcode 26+ y Android Studio 2025.2.1+:

```bash
npm install
```

```bash
npx cap add ios
```

```bash
npx cap add android
```

Luego `npm run ios` o `npm run android` abre el proyecto nativo.

**Importante:** el modo real cubre por ahora cuentas, clubes, vínculos, plantel y avisos. Calendario, pagos, mensajes y los demás módulos siguen solo en el demo, y en modo real no se muestran. Aún no está lista para enviarse a las tiendas.

## Conectar la base de datos

1. En Supabase, crea un proyecto en la región **South America (São Paulo)**. Guarda la contraseña de la base en un gestor de contraseñas.
2. En **SQL Editor**, pega y ejecuta `supabase/migrations/20261106120000_nucleo.sql`.
3. En **Authentication → URL Configuration**, usa como Site URL y Redirect URL la dirección pública de la app.
4. En **Authentication → Providers → Email**, deja activa la confirmación de email y pide una clave de 8 caracteres como mínimo.
5. Copia la Project URL y la Publishable key en `config.js`, y sube `CACHE` en `sw.js`. **Nunca** pongas ahí la clave secreta.
6. Antes de abrir el registro al público, configura un correo propio en **Authentication → SMTP**. El correo incluido en Supabase solo llega a miembros del proyecto, con un máximo de 2 mensajes por hora.

Pruebas: `python tools/probar_base.py` (permisos en Postgres local) y `python tools/flujos_real.py` (navegador con API emulada).

## Cómo está organizada

- `index.html`: HTML, CSS y JavaScript juntos, en secciones comentadas.
- `manifest.webmanifest`, `sw.js`, `icons/`: instalación y modo sin conexión.
- `CLAUDE.md`: contexto del proyecto (roles, rutas y reglas).
- `tools/`: scripts opcionales (recorrido con Playwright, generación de íconos).
- `screenshots/`: capturas finales.

Si cambias archivos, sube `CACHE` en `sw.js` para que los teléfonos reciban la actualización.
En el Perfil está **Restablecer demo** y **Simular paso del tiempo**.
