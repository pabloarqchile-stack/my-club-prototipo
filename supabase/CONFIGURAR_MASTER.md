# Activar el panel Master (administración de My Club)

El panel Master solo existe con la base de datos conectada: no aparece en el demo ni en el registro.
Se entra por el ingreso normal con el email y la clave de Supabase Auth de una persona que esté en `platform_admins`.

## 1. Base de datos
SQL Editor → New query → pega todo `supabase/migrations/20261128120000_master.sql` → Run.
Supabase advierte de una operación destructiva: es por la línea `revoke`, que solo quita permisos.

## 2. Usuario dueño
El dueño tiene todos los accesos y no se puede quitar ni desactivar desde la app. Se agrega solo aquí, nunca en el repositorio:

```sql
insert into public.platform_admins (email, name, owner) values ('email-del-dueño', 'Nombre', true);
```

El email debe escribirse en minúsculas. Si ya tiene cuenta de My Club, entra con esa misma clave y desde el panel puede ir a su cuenta.
Para cambiar la clave: en el ingreso, RECUPERAR MI CLAVE. Nunca guardes una clave en `config.js` ni en el código.

## 3. Otros usuarios Master
Desde el panel: Más → Usuarios Master → Agregar usuario, con sus accesos. Si la persona no tiene cuenta en My Club,
crea su clave en `https://demo.app-myclub.cl/#/master-clave` con ese mismo email.

## Modelo de cobro
- Chile: `price_clp` pesos por deportista hábil al mes (parte en $1.000). Resto del mundo: `price_usd` dólares (parte en US$ 1, se cambia en Tarifas).
- El país de cada club (`clubs.country`, parte en CL) define la moneda.
- A cada club se le aplica la mejor promoción vigente y después sus descuentos.
- Cada mes se guarda la mensualidad de cada club desde el mes en que se aplica la migración (`billing_start`); no se cobran meses anteriores.
- Estado del club: 0 a 2 meses impagos Activo, 3 a 4 En revisión, 5 o más Inactivo. Solo el dueño puede fijarlo a mano (Clubes → club → Cambiar estado).
- Un club inactivo solo puede ver y pagar su mensualidad. Paga en Mensualidad My Club con las formas de pago que agregues en Más → Formas de pago, y avisa que pagó.
- Confirmas el pago en Ingresos y egresos → Pagos informados por confirmar. Los gastos de My Club y otros pagos se registran a mano ahí mismo.

## 4. Formas de pago de My Club
Antes de que los clubes paguen, agrega al menos una en Más → Formas de pago (cuenta para transferencias, link de pago u otras instrucciones).
