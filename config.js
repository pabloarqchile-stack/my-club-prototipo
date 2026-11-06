// Conexión con Supabase. Con los dos valores vacíos, la app funciona solo en modo demo.
// Ambos son públicos por diseño: los datos los protege la seguridad por filas de la base.
// Nunca pongas aquí la clave secreta (service_role o sb_secret_...).
window.MYCLUB_CONFIG = {
  url: '',  // Project URL, por ejemplo https://abcdefgh.supabase.co
  key: ''   // Publishable key (sb_publishable_...) o anon key
};
