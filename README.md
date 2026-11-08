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

**Modo demo:** usuario `demo`, clave `demo`. Permite elegir cualquier perfil y consultar todas las funciones con datos inventados. Para ingresar datos hay que crear una cuenta.

**Importante:** las cuentas creadas guardan todos los módulos en la base de datos. Faltan por activar los pagos en línea, las notificaciones al teléfono y el QR escaneable. Aún no está lista para enviarse a las tiendas.

## Conectar la base de datos

1. En Supabase, crea un proyecto en la región **South America (São Paulo)**. Guarda la contraseña de la base en un gestor de contraseñas.
2. En **SQL Editor**, pega y ejecuta `supabase/migrations/20261106120000_nucleo.sql`.
3. En **Authentication → URL Configuration**, usa como Site URL y Redirect URL la dirección pública de la app.
4. En **Authentication → Providers → Email**, deja activa la confirmación de email y pide una clave de 8 caracteres como mínimo.
5. Copia la Project URL y la Publishable key en `config.js`, y sube `CACHE` en `sw.js`. **Nunca** pongas ahí la clave secreta.
6. Antes de abrir el registro al público, configura un correo propio en **Authentication → SMTP**. El correo incluido en Supabase solo llega a miembros del proyecto, con un máximo de 2 mensajes por hora.

La app ya está conectada a su proyecto de Supabase. Las pruebas del demo usan una copia sin conexión y no tocan la base real.

## Activar Mercado Pago

El dinero llega directo a la cuenta de Mercado Pago de cada club.

1. Despliega `supabase/functions/mp-crear-pago` y `supabase/functions/mp-webhook`. La segunda debe ir sin verificación de JWT, porque la llama Mercado Pago. No necesitan secretos propios: usan la clave de servicio que Supabase entrega a las funciones.
2. Cada club crea su aplicación en Mercado Pago Developers, copia su Access Token y lo pega en la app: Perfil → Cuenta y pagos en línea. Usa primero las credenciales de prueba (TEST-).
3. Haz un pago de prueba y revisa que el cobro quede pagado y se emita el comprobante.

En la misma pantalla el club registra su cuenta para transferencias, que ven apoderados y deportistas al pagar.

Pruebas: `python tools/probar_base.py` (permisos en Postgres local) y `python tools/flujos_real.py` (navegador con API emulada).

## Cómo está organizada

- `index.html`: HTML, CSS y JavaScript juntos, en secciones comentadas.
- `manifest.webmanifest`, `sw.js`, `icons/`: instalación y modo sin conexión.
- `CLAUDE.md`: contexto del proyecto (roles, rutas y reglas).
- `tools/`: scripts opcionales (recorrido con Playwright, generación de íconos).
- `screenshots/`: capturas finales.

Si cambias archivos, sube `CACHE` en `sw.js` para que los teléfonos reciban la actualización.
En el Perfil está **Restablecer demo** y **Simular paso del tiempo**.
