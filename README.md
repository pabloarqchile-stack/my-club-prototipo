# My Club – prototipo MVP

Prototipo navegable para administrar clubes deportivos, asociaciones y federaciones de Chile.
**Versión publicada:** https://pabloarqchile-stack.github.io/my-club-prototipo/

No tiene servidor: los datos son de ejemplo y los cambios se guardan en el navegador (localStorage).
Pagos, QR, chats, carga de archivos y escaneo son simulados.

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

## Cómo está organizada

- `index.html`: HTML, CSS y JavaScript juntos, en secciones comentadas.
- `manifest.webmanifest`, `sw.js`, `icons/`: instalación y modo sin conexión.
- `CLAUDE.md`: contexto del proyecto (roles, rutas y reglas).
- `tools/`: scripts opcionales (recorrido con Playwright, generación de íconos).
- `screenshots/`: capturas finales.

Si cambias archivos, sube `CACHE` en `sw.js` para que los teléfonos reciban la actualización.
En el Perfil está **Restablecer demo** y **Simular paso del tiempo**.
