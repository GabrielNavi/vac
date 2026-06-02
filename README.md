# versatile-autoreg-vac — Versatile Autoregistration Client

Cliente de autoregistro de red. Registra el equipo en VAS con un UUID persistente como identidad estable, mantiene heartbeats de liveness y una copia local del inventario. Soporta campos extra extensibles y registro simultáneo en múltiples servidores VAS mediante sub-instancias.

## Ecosistema

```
versatile-autoreg-vas          → servidor de inventario
versatile-autoreg-vac          → cliente de autoregistro (este paquete)
versatile-autoreg-val          → consumidor genérico con hooks
versatile-autoreg-veyon-sync   → integración Veyon opcional
```

## Requisitos

- `bash`, `curl`, `jq`, `uuid-runtime`, `iproute2`
- `versatile-autoreg-vas >= 0.9-1`

## Archivos instalados

| Ruta | Descripción |
|---|---|
| `/usr/bin/vac` | Servicio en bucle (dos temporizadores independientes: selfcheck + heartbeat) |
| `/usr/bin/vac-register` | Registro puntual e idempotente (timers, scripts externos) |
| `/usr/bin/vac-sub` | Bucle VAC completo para sub-instancias de paralelización |
| `/usr/bin/vac-sub-manager` | Supervisor de sub-instancias con fail counter |
| `/usr/bin/vac-sub-instance` | CLI para crear, listar y eliminar sub-instancias |
| `/usr/lib/vac/vac-common.sh` | Librería compartida: log, red, identidad, extras, registro |
| `/etc/vac/vac.conf` | Configuración principal |
| `/usr/share/vac/vac.conf.defaults` | Referencia exhaustiva de todas las variables (solo lectura) |
| `/usr/share/vac/instance-template/vac.conf` | Plantilla para nuevas sub-instancias |

## Estado local

| Ruta | Descripción |
|---|---|
| `/etc/vac/vac-id` | UUID persistente del equipo (generado una vez, modo 600) |
| `/etc/vac/vac.sub/<name>/.enabled` | Marca de activación de sub-instancia |
| `/var/lib/vac/version` | Última versión del registro conocida |
| `/var/lib/vac/identity.json` | Datos propios tal como los confirma VAS |
| `/var/lib/vac/clients.json` | Copia local del inventario (`SYNC_CLIENTS=true`) |
| `/var/lib/vac/extras_imperative.json` | Estado interno de extras imperativos (con timestamps TTL) |
| `/var/lib/vac/extras_informative.json` | Estado interno de extras informativos |

## Configuración

```ini
# /etc/vac/vac.conf  (referencia completa en vac.conf.defaults)
VAS_HOST=10.0.0.1        # IP/hostname; sin scheme, sin puerto si usa el 8000
# VAS_SCHEME=http        # http (defecto) | https
CHECK_SECONDS=300        # selfcheck + comparación de versión
# HEARTBEAT_SECONDS=60   # liveness independiente del selfcheck; vacío = igual a CHECK
SYNC_CLIENTS=false
EXTRAS_ENABLED=true
EXTRAS_TTL=86400
LOG_LEVEL=normal
PARALLEL_MODE=both
```

`VAS_HOST` acepta `10.0.0.1`, `10.0.0.1:9000` o `vas.ejemplo.org`. El scheme (`http://...`) se extrae automáticamente con `[WARN]`. Puerto `:8000` implícito si no se especifica.

## Bucle principal

```
Cada CHECK_SECONDS:
  collect_extras() → selfcheck vs identity.json
  Con cambios → POST /register; guarda identity.json
  GET /version → si nueva: GET /clients (SYNC_CLIENTS=true) + refrescar identity

Cada HEARTBEAT_SECONDS:
  POST /heartbeat → si 404 o error: POST /register (re-registro completo)
```

Un registro exitoso en cualquier bloque resetea el temporizador del otro, evitando señales redundantes en el mismo ciclo.

## Sistema de extras multi-fuente

Cada clave de `extra_imperative` / `extra_informative` se gestiona de forma independiente con timestamp interno. Los productores cíclicos y los puntuales coexisten sin pisarse.

```bash
# Hook cíclico: script ejecutable en extras_imperative.d/
# La clave es el basename sin extensión; timeout 10 s por hook
echo '{"server": "10.0.0.2"}'   # /etc/vac/extras_imperative.d/10-cups.sh

# Productor externo puntual (idempotente)
echo '{"server":"10.0.0.2"}' | vac-register --imperative --key cups -

# Eliminar una clave
vac-register --imperative --key cups -d
```

Con `EXTRAS_TTL=86400`, las claves sin actualizar en >24 h se eliminan automáticamente con `[WARN]` en log (detecta productores silenciados).

## Paralelización

Un equipo puede registrarse en múltiples VAS con UUIDs distintos y estado independiente por sub-instancia:

```bash
vac-sub-instance --create samba --vas 10.0.1.5
vac-sub-instance --list
# NOMBRE   VAS_HOST        ENABLED  ESTADO
# samba    10.0.1.5:8000   sí       activa
systemctl restart vac   # con PARALLEL_MODE=both
```

`PARALLEL_MODE`: `both` (main + instancias) · `only_parallel` (`exec vac-sub-manager`) · `only_main` (sin instancias). Las sub-instancias sin fichero `.enabled` se ignoran (retrocompatibilidad con upgrades sin ese fichero).

El supervisor distingue fallos duros (proceso muerto en <30 s, posible error de config) de fallos transitorios y deja de reiniciar una instancia tras 5 fallos duros consecutivos.

## Servicio

```bash
systemctl status vac
systemctl restart vac
journalctl -u vac -f
journalctl -u vac | grep '\[SELFCHECK\]'
journalctl -u vac | grep '\[PARALLEL\]'
```

## Wiki

[Instalación](../../wiki/Instalacion) · [Configuración](../../wiki/Configuracion) · [Flujo de operación](../../wiki/Flujo-de-operacion) · [Paralelización](../../wiki/Paralelizacion) · [vac-register](../../wiki/vac-register) · [Logging](../../wiki/Logging)
