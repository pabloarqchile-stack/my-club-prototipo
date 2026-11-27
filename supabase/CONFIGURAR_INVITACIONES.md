# Activar las invitaciones por correo (cuentas reales)

Todo se hace en el panel de Supabase del proyecto `plehacherjnbhnodykmy` y, para el correo, en Resend y Hetzner.
Ninguna clave se pega en la app ni en el chat: solo en los paneles indicados.

## 1. Base de datos
SQL Editor → New query → pega todo `supabase/migrations/20261127120000_invitaciones.sql` → Run.
Debe terminar sin errores (crea `club_invites` y las funciones `club_add_members`, `invite_info`, `accept_invite`, `reject_invite`).

## 2. Función que envía los correos
Edge Functions → Deploy a new function → Via Editor.
- Nombre: `invitar-socios`
- Código: pega `supabase/functions/invitar-socios/index.ts`
- Despliega. Luego, en la pestaña Settings de la función, **apaga "Verify JWT with legacy secret"** y guarda:
  el proyecto firma las sesiones con la clave nueva (ECC), que ese control rechaza. La función verifica la sesión
  por su cuenta (`/auth/v1/user`) y usa la clave service_role antigua: no desactives las "legacy API keys".

## 3. Direcciones permitidas
Authentication → URL Configuration:
- Site URL: `https://demo.app-myclub.cl`
- Redirect URLs: agrega `https://demo.app-myclub.cl/**`

## 4. Servicio de correo (Resend)
El correo de Supabase solo envía unos pocos mensajes por hora y solo a miembros del equipo del proyecto: no sirve para socios.
1. Crea una cuenta en https://resend.com (plan gratis: 3.000 correos al mes, máximo 100 por día; Pro: US$ 20 al mes por 50.000).
2. Domains → Add domain → `app-myclub.cl`. Resend muestra unos registros DNS (TXT y MX): agrégalos en la zona `app-myclub.cl` de Hetzner DNS y espera que Resend lo marque como verificado.
3. API Keys → Create API key (permiso "Sending access"). Cópiala solo para el paso siguiente.
4. En Supabase: Authentication → Emails → SMTP Settings → Enable custom SMTP:
   - Sender email: `no-responder@app-myclub.cl` · Sender name: `My Club`
   - Host: `smtp.resend.com` · Port: `465` · Username: `resend` · Password: la API key de Resend
5. Authentication → Rate Limits → sube "Rate limit for sending emails" (por ejemplo a 100 por hora, el máximo diario del plan gratis).

## 5. Plantilla del correo en español
Authentication → Emails → Templates → Invite user:
- Subject: `{{ .Data.club }} te inscribió en My Club`
- Body: pega `supabase/plantillas/invitacion.html`

## 6. Probar
Ingresa con una cuenta de club real → Apoderados → AGREGAR, con un email tuyo que no tenga cuenta en My Club.
Debe llegar el correo; su botón abre la app en "Activar mi cuenta".
