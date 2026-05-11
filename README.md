# vx-dga-l-vac — Vitalinux Autoregistration Client

Paquete Debian para Vitalinux que instala el cliente de autoregistro de red (VAC).

## Descripción

VAC registra el equipo en VAS usando un UUID persistente como identidad estable, y mantiene una copia local del inventario de red en `/var/lib/vac/clients.json`. Funciona como servicio systemd en bucle continuo.

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

## Información del paquete

- Nombre: `vx-dga-l-vac`
- Versión: 0.4-2
- Arquitectura: all
- Mantenedor: Gabriel Navia \<correos@gabrielnav.es\>
- Licencia: GPL-3.0+

## Archivos instalados

| Ruta | Descripción |
|---|---|
| `usr/bin/vac` | Script Bash principal del cliente |
| `etc/vac/vac.conf` | Configuración editable |
| `lib/systemd/system/vac.service` | Unidad systemd |

## Estado local

| Ruta | Descripción |
|---|---|
| `/etc/vac/vac-id` | UUID persistente del equipo (600, generado una sola vez) |
| `/var/lib/vac/version` | Última versión del registro recibida de VAS |
| `/var/lib/vac/clients.json` | Copia local del inventario completo |

## Flujo de operación

Cada ciclo del bucle principal:

```
1. POST /register  (heartbeat + datos actuales)
      VAS actualiza last_seen siempre.
      VAS sube versión solo si hostname/IP/MAC han cambiado.
      → fallo: sleep RETRY_SECONDS, reintentar

2. GET /version
      → igual que versión local: sleep CHECK_SECONDS, siguiente ciclo
      → diferente: continuar

3. GET /clients  → guardar en /var/lib/vac/clients.json

4. Comprobar si los propios datos están en el registro y son correctos
      → coinciden:     actualizar /var/lib/vac/version
      → no coinciden:  POST /register de nuevo, actualizar versión
                        (ocurre si otro proceso limpió el registro)

5. sleep CHECK_SECONDS
```

### Mecanismo TTL

El `POST /register` del paso 1 actualiza `last_seen` en VAS en cada ciclo, aunque los datos no hayan cambiado. Esto mantiene al equipo activo frente a la limpieza automática por TTL de VAS. La relación de seguridad es `CHECK_SECONDS << CLIENT_TTL_DAYS × 86400`.

## Configuración

Fichero principal: `/etc/vac/vac.conf`  
Overlays (orden lexical): `/etc/vac/vac.conf.d/*.conf`

El parser no ejecuta código del fichero de configuración.

| Variable | Defecto | Descripción |
|---|---|---|
| `VAS_HOST` | — | URL base del servidor VAS (sin barra final). **Obligatorio.** |
| `RETRY_SECONDS` | `60` | Espera entre reintentos ante fallo de red |
| `CHECK_SECONDS` | `300` | Intervalo de comprobación de versión |

Ejemplo:

```bash
VAS_HOST="http://10.0.0.1:8000"
RETRY_SECONDS=60
CHECK_SECONDS=300
```

## Integración con Veyon

VAC no interactúa con Veyon directamente. Si el equipo tiene Veyon instalado y se quiere sincronizar los networkobjects localmente, instalar `vx-dga-l-veyon-sync` con `SOURCE=vac`. Este leerá `/var/lib/vac/clients.json` y `/var/lib/vac/version` para detectar cambios y aplicarlos a Veyon sin añadir carga extra a la red.

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
