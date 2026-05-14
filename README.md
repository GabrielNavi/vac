# vx-dga-l-vac — Vitalinux Autoregistration Client

Paquete Debian para Vitalinux que instala el cliente de autoregistro de red (VAC).

## Descripción

VAC registra el equipo en VAS usando un UUID persistente como identidad estable y mantiene una copia local del inventario de red en `/var/lib/vac/clients.json`. Funciona como servicio systemd en bucle continuo. Incluye `vac-register`, un script de registro puntual para uso desde systemd timers, scripts de administración o procesos productores de datos extra.

No tiene dependencia de Veyon. Si el equipo tiene Veyon instalado, la sincronización de networkobjects se gestiona mediante el paquete opcional `vx-dga-l-veyon-sync`.

## Ecosistema

```
vx-dga-l-vas          → registro canónico (servidor)
vx-dga-l-vac          → cliente de autoregistro (este paquete)
vx-dga-l-veyon-sync   → integración Veyon opcional
```

## Requisitos

- `bash`, `curl`, `jq`, `uuid-runtime`, `iproute2`
- Conectividad de red con el servidor VAS
- `vx-dga-l-vas >= 0.9-1` (para `POST /heartbeat`)

## Información del paquete

- Nombre: `vx-dga-l-vac`
- Versión: 0.9-1
- Arquitectura: all
- Mantenedor: Gabriel Navia \<correos@gabrielnav.es\>
- Licencia: GPL-3.0+

## Archivos instalados

| Ruta | Descripción |
|---|---|
| `usr/bin/vac` | Script Bash del servicio en bucle |
| `usr/bin/vac-register` | Script de registro puntual |
| `usr/lib/vac/vac-common.sh` | Librería compartida: log, log_debug, registro, red, identidad |
| `etc/vac/vac.conf` | Configuración editable |
| `lib/systemd/system/vac.service` | Unidad systemd |

## Estado local

| Ruta | Descripción |
|---|---|
| `/etc/vac/vac-id` | UUID persistente del equipo (600, generado una sola vez) |
| `/var/lib/vac/version` | Última versión del registro recibida de VAS |
| `/var/lib/vac/identity.json` | Datos propios tal como fueron enviados a VAS por última vez |
| `/var/lib/vac/clients.json` | Copia local del inventario completo (`SYNC_CLIENTS=true`) |

## Flujo de operación

### Arranque (bloqueante)

```
Esperar VAS_HOST definido
→ POST /register  (datos completos + extras según config)
→ Guardar identity.json (datos locales enviados)
→ Inicializar VERSION_FILE con versión remota
→ Si SYNC_CLIENTS=true: GET /clients → clients.json
→ GET /clients/{UUID} → refrescar identity.json con valores confirmados por VAS
  (necesario si VAS aplicó COALESCE sobre extras de un registro anterior)
→ Entrar en el bucle principal
```

### Bucle principal

```
1. Recopilar hostname/IP/MAC y extras (según EXTRAS_ENABLED y EXEC_*)

2. Selfcheck local: comparar con identity.json
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

Script de registro puntual. Idempotente: compara con `identity.json` y omite el registro si no hay cambios.

```bash
# Registro sin extras (null → COALESCE en VAS)
vac-register

# Extras desde archivo
vac-register --imperative /tmp/extra-imp.json

# Extras desde stdin
echo '{"cups_server":"10.0.0.2"}' | vac-register --informative -

# Ambos campos
vac-register --imperative /tmp/imp.json --informative /tmp/inf.json
```

Tras un registro exitoso escribe `identity.json`, `VERSION_FILE` y `clients.json` (si `SYNC_CLIENTS=true`).

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
| `EXEC_IMPERATIVE` | `cycle` | Dónde ejecutar el script imperativo: `cycle` o `delegate` |
| `EXEC_INFORMATIVE` | `cycle` | Dónde ejecutar el script informativo: `cycle` o `delegate` |
| `EXTRA_IMPERATIVE_SCRIPT` | — | Script que produce `extra_imperative` (JSON en stdout) |
| `EXTRA_INFORMATIVE_SCRIPT` | — | Script que produce `extra_informative` (JSON en stdout) |
| `LOG_LEVEL` | `normal` | Nivel de log: `no` (silencio), `normal` (eventos importantes), `debug` (detallado) |
| `LOG_FILE` | — | Fichero de log adicional con timestamp ISO-8601 UTC (vacío = solo journald) |

### Semántica de extras

| Situación | Valor enviado a VAS | Efecto en BD |
|---|---|---|
| Script produce JSON válido | `{"k":"v"}` | Sobreescribe el campo |
| Script falla / no configurado | `null` | COALESCE: conserva valor existente |
| `EXTRAS_ENABLED=false` | `{}` | Borra el campo (NULL en BD) |

### Modos EXEC_*

- `cycle`: VAC ejecuta el script en cada ciclo. Los cambios disparan heartbeat→register automáticamente via selfcheck.
- `delegate`: VAC envía `null` (COALESCE). Un proceso externo llama a `vac-register --imperative <json>` cuando cambian los datos.

## Integración con Veyon

VAC no interactúa con Veyon directamente. Si el equipo tiene Veyon instalado, instalar `vx-dga-l-veyon-sync` con `SOURCE=vac`. Este leerá `/var/lib/vac/clients.json` y `/var/lib/vac/version` para detectar cambios y aplicarlos a Veyon sin añadir carga extra a la red.

## Servicio systemd

```bash
systemctl status vac
systemctl restart vac
journalctl -u vac -f
```

## Construcción del paquete

```bash
dpkg-buildpackage -us -uc -b
```
