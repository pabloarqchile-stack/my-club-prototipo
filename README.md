# My Club – prototipo MVP

Prototipo navegable para administrar clubes deportivos, asociaciones y federaciones de Chile.
**Versión publicada:** https://pabloarqchile-stack.github.io/my-club-prototipo/

No tiene servidor: los datos son de ejemplo y los cambios se guardan en el navegador (localStorage).
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

**Importante:** esta app aún no tiene servidor. Los datos viven en cada dispositivo, así que no está lista para operar con clubes reales ni para enviarse a las tiendas.

## Cómo está organizada

- `index.html`: HTML, CSS y JavaScript juntos, en secciones comentadas.
- `manifest.webmanifest`, `sw.js`, `icons/`: instalación y modo sin conexión.
- `CLAUDE.md`: contexto del proyecto (roles, rutas y reglas).
- `tools/`: scripts opcionales (recorrido con Playwright, generación de íconos).
- `screenshots/`: capturas finales.

Si cambias archivos, sube `CACHE` en `sw.js` para que los teléfonos reciban la actualización.
En el Perfil está **Restablecer demo** y **Simular paso del tiempo**.
