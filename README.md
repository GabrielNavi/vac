# vx-dga-l-vac — Vitalinux Autoregistration Client

Paquete Debian para Vitalinux que instala el cliente de autoregistro de red (VAC).

## Descripción

VAC registra el equipo en VAS usando un UUID persistente como identidad estable y mantiene una copia local del inventario de red en `/var/lib/vac/clients.json`. Funciona como servicio systemd en bucle continuo. Incluye `vac-register`, un script de registro puntual para uso desde systemd timers, scripts de administración o procesos productores de datos extra.

No tiene dependencia de Veyon. Si el equipo tiene Veyon instalado, la sincronización de networkobjects se gestiona mediante el paquete opcional `vx-dga-l-veyon-sync`.

## Ecosistema

```
vx-dga-l-vas          → registro canónico (servidor)
vx-dga-l-vac          → cliente de autoregistro (este paquete)
vx-dga-l-vcd          → consumidor genérico de inventario (hooks)
vx-dga-l-vaf          → federación de servidores VAS en jerarquía
vx-dga-l-veyon-sync   → integración Veyon opcional
```

## Requisitos

- `bash`, `curl`, `jq`, `uuid-runtime`, `iproute2`
- Conectividad de red con el servidor VAS
- `vx-dga-l-vas >= 0.9-1` (para `POST /heartbeat`)

## Información del paquete

- Nombre: `vx-dga-l-vac`
- Versión: 1.0-2~rc
- Arquitectura: all
- Mantenedor: Gabriel Navia \<correos@gabrielnav.es\>
- Licencia: Apache 2.0

## Archivos instalados

| Ruta | Descripción |
|---|---|
| `usr/bin/vac` | Script Bash del servicio en bucle |
| `usr/bin/vac-register` | Script de registro puntual |
| `usr/bin/vac-sub` | Bucle VAC completo para sub-instancias de paralelización |
| `usr/bin/vac-sub-manager` | Supervisor de sub-instancias (lanza y monitoriza `vac-sub`) |
| `usr/bin/vac-sub-instance` | Gestión del ciclo de vida de sub-instancias (crear/eliminar/listar) |
| `usr/lib/vac/vac-common.sh` | Librería compartida: log, registro, red, identidad, extras |
| `etc/vac/vac.conf` | Configuración editable |
| `lib/systemd/system/vac.service` | Unidad systemd del servicio principal |
| `lib/systemd/system/vac-sub.service` | Unidad systemd del supervisor independiente de sub-instancias |
| `usr/share/vac/vac.conf.defaults` | Referencia de valores por defecto (solo lectura) |

## Estado local

| Ruta | Descripción |
|---|---|
| `/etc/vac/vac-id` | UUID persistente del equipo (600, generado una sola vez) |
| `/etc/vac/vac.sub/<name>/` | Configuración de sub-instancia de paralelización |
| `/var/lib/vac/version` | Última versión del registro recibida de VAS |
| `/var/lib/vac/identity.json` | Datos propios tal como fueron enviados a VAS por última vez |
| `/var/lib/vac/clients.json` | Copia local del inventario completo (`SYNC_CLIENTS=true`) |
| `/var/lib/vac/extras_imperative.json` | Estado interno de extras imperativos por clave |
| `/var/lib/vac/extras_informative.json` | Estado interno de extras informativos por clave |
| `/var/lib/vac/sub/<name>/` | Estado de cada sub-instancia (UUID, versión, identity, clients) |

## Flujo de operación

### Arranque (bloqueante)

```
Esperar VAS_HOST definido
→ Ejecutar hooks de extras (si EXTRAS_ENABLED=true)
→ Expirar claves TTL vencidas
→ POST /register  (datos completos + merge de extras)
→ Guardar identity.json (datos locales enviados)
→ Inicializar VERSION_FILE con versión remota
→ Si SYNC_CLIENTS=true: GET /clients → clients.json
→ GET /clients/{UUID} → refrescar identity.json con valores confirmados por VAS
→ Entrar en el bucle principal
```

### Bucle principal

```
1. Ejecutar hooks de extras → expirar TTL → construir merge
2. Selfcheck local: comparar merge plano con identity.json
   Sin cambios → POST /heartbeat ({id}, ~50 B; actualiza last_seen en VAS)
                  Si VAS devuelve 404 → re-registro automático
   Con cambios → POST /register; guardar identity.json
3. GET /version → comparar con versión local
   Sin cambios → sleep CHECK_SECONDS, siguiente ciclo
4. Nueva versión detectada:
   Si SYNC_CLIENTS=true → GET /clients → clients.json
   GET /clients/{UUID}  → identity.json (reflejo desde VAS)
   Actualizar VERSION_FILE
5. sleep CHECK_SECONDS
```

### Mecanismo TTL

El `POST /heartbeat` del paso 2 actualiza `last_seen` en VAS en cada ciclo aunque los datos no hayan cambiado, manteniendo al equipo activo frente al TTL de VAS. Relación de seguridad: `CHECK_SECONDS << TTL_INACTIVE_DAYS × 86400`.

## vac-register

Script de registro puntual. Idempotente: compara el merge actual con `identity.json` y omite el registro si no hay cambios.

```bash
# Registro sin tocar extras
vac-register

# Upsert de clave imperativa desde archivo
vac-register --imperative --key cups /tmp/cups.json

# Upsert de clave imperativa desde stdin
echo '{"server":"10.0.0.2"}' | vac-register --imperative --key cups -

# Eliminar una clave
vac-register --imperative --key cups -d

# Clave informativa
vac-register --informative --key hardware /tmp/hw.json
```

Tras un registro exitoso escribe `identity.json`, `VERSION_FILE` y `clients.json` (si `SYNC_CLIENTS=true`).

## Sistema de extras multi-fuente

Los campos `extra_imperative` y `extra_informative` se gestionan mediante un **estado interno por clave** en `STATE_DIR`. Cada productor gestiona su propia clave de forma independiente.

### Estado interno

```json
{
  "cups": {
    "timestamp": "20260525103000",
    "data": { "server": "10.0.0.2" }
  },
  "hardware": {
    "timestamp": "20260525103200",
    "data": { "ram": "8GB", "cpu": "Intel i5-8250U" }
  }
}
```

### Merge enviado a VAS

Solo el campo `.data` de cada clave; los timestamps no trascienden el estado local:

```json
{
  "cups":     { "server": "10.0.0.2" },
  "hardware": { "ram": "8GB", "cpu": "Intel i5-8250U" }
}
```

### Fuentes de datos

| Fuente | Mecanismo | Clave asignada |
|---|---|---|
| Hook cíclico | Script ejecutable en `extras_imperative.d/` | Basename sin extensión |
| Productor externo | `vac-register --imperative --key KEY` | Valor de `--key` |

Ambas fuentes coexisten en el mismo fichero de estado y se mezclan en cada merge.

### TTL de claves

Con `EXTRAS_TTL=86400`, una clave sin actualizar durante más de 24 horas se elimina del estado antes del siguiente merge, con aviso `[WARN]` en log. Útil para detectar productores silenciados sin borrar manualmente.

### Semántica de envío a VAS

| Situación | Valor enviado | Efecto en BD |
|---|---|---|
| Merge con claves vigentes | `{"k": {...}}` | Sobreescribe el campo |
| Fichero de estado no existe | `null` | COALESCE: conserva valor existente |
| Fichero de estado vacío (0 claves) | `{}` | Borra el campo (NULL en BD) |
| `EXTRAS_ENABLED=false` | `{}` | Borra el campo (NULL en BD) |

## Configuración

Fichero principal: `/etc/vac/vac.conf`  
Overlays (orden lexical): `/etc/vac/vac.conf.d/*.conf`

El parser no ejecuta código del fichero de configuración.

| Variable | Defecto | Descripción |
|---|---|---|
| `VAS_HOST` | — | URL base del servidor VAS (sin barra final). **Obligatorio.** |
| `RETRY_SECONDS` | `60` | Espera entre reintentos ante fallo de red |
| `CHECK_SECONDS` | `300` | Intervalo de comprobación de versión |
| `SYNC_CLIENTS` | `true` | Descargar y mantener `clients.json` local |
| `EXTRAS_ENABLED` | `false` | Habilitar campos extra en el registro |
| `EXTRAS_TTL` | `86400` | TTL de claves extras en segundos (0 = sin expiración) |
| `EXTRAS_IMPERATIVE_HOOKS_DIR` | `/etc/vac/extras_imperative.d` | Directorio de hooks cíclicos imperativos |
| `EXTRAS_INFORMATIVE_HOOKS_DIR` | `/etc/vac/extras_informative.d` | Directorio de hooks cíclicos informativos |
| `LOG_LEVEL` | `normal` | Nivel de log: `no` · `normal` · `debug` |
| `LOG_FILE` | — | Fichero de log adicional con timestamp ISO-8601 UTC (vacío = solo journald) |
| `PARALLELIZATION` | `false` | Si `true`, `vac` lanza `vac-sub-manager` al arrancar para gestionar sub-instancias |

## Paralelización

Un mismo equipo puede registrarse en múltiples VAS simultáneamente mediante sub-instancias independientes. Cada una tiene su propio UUID derivado (v5, determinista), su propio estado y su propia configuración.

```
/etc/vac/vac.sub/
└── samba/
    ├── vac.conf           # Solo VAS_HOST; hereda /etc/vac/vac.conf
    └── vac.conf.d/

/var/lib/vac/sub/
└── samba/
    ├── vac-id             # UUID v5 (sha1 del UUID base + "samba")
    ├── version
    ├── identity.json
    └── clients.json
```

### Gestión de sub-instancias

```bash
# Crear sub-instancia
vac-sub-instance --create samba --vas "http://10.0.1.5:8000"

# Listar todas
vac-sub-instance --list

# Eliminar (aborta si el proceso está activo)
vac-sub-instance --delete samba
```

### Modos de activación

**Integrado en `vac.service`** (modo recomendado):
```ini
# /etc/vac/vac.conf
PARALLELIZATION=true
```
```bash
systemctl restart vac
journalctl -u vac | grep '\[PARALLEL\]'
```

**Supervisor independiente** (sin instancia principal):
```bash
systemctl enable --now vac-sub.service
journalctl -u vac-sub | grep '\[PARALLEL\]'
```

### Registro puntual en sub-instancia

```bash
echo '{"server":"10.0.0.2"}' | vac-register --name samba --imperative --key cups -
```

### Logging

| Proceso | Journal | Filtro |
|---|---|---|
| `vac` (principal) | `vac.service` | `[VAC]` |
| `vac-sub-manager` | `vac.service` o `vac-sub.service` | `[PARALLEL]` |
| `vac-sub samba` | mismo que su padre | `[SAMBA-VAC]` |

```bash
journalctl -u vac | grep '\[PARALLEL\]'   # lifecycle
journalctl -u vac | grep '\[SAMBA-VAC\]'  # sub-instancia samba
```

## Integración con Veyon

VAC no interactúa con Veyon directamente. Si el equipo tiene Veyon instalado, instalar `vx-dga-l-veyon-sync` con `SOURCE=vac`. Este leerá `/var/lib/vac/clients.json` y `/var/lib/vac/version` para detectar cambios y aplicarlos a Veyon sin añadir carga extra a la red.

## Servicio systemd

```bash
# Instancia principal
systemctl status vac
systemctl restart vac
journalctl -u vac -f

# Supervisor independiente de sub-instancias
systemctl status vac-sub
systemctl restart vac-sub
journalctl -u vac-sub -f
```

## Construcción del paquete

```bash
dpkg-buildpackage -us -uc -b
```
