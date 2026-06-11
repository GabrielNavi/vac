<div align="center">
  <img src="assets/logo.svg" alt="VAC logo" width="100"/>
  <h1>VAC — Versatile Autoregistration Client</h1>
</div>

[![en](https://img.shields.io/badge/lang-en-blue.svg)](README.md)
[![es](https://img.shields.io/badge/lang-es-green.svg)](README.es.md)

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Debian package](https://img.shields.io/badge/package-versatile--autoreg--vac-brightgreen)](https://github.com/GabrielNavi/vac/releases)
[![Bash](https://img.shields.io/badge/shell-bash-89e051.svg)](https://www.gnu.org/software/bash/)
[![Platform: Linux](https://img.shields.io/badge/platform-Linux-lightgrey.svg)]()

Cliente de autoregistro para redes Linux gestionadas centralmente. Registra el equipo en VAS con un UUID persistente, mantiene heartbeats de liveness y publica campos extra extensibles. Soporta registro simultáneo en múltiples servidores VAS mediante sub-instancias.

---

## Tabla de contenidos

- [Ecosistema](#ecosistema)
- [Instalación rápida](#instalación-rápida)
- [Archivos instalados](#archivos-instalados)
- [Configuración](#configuración)
- [Bucle principal](#bucle-principal)
- [Sistema de extras](#sistema-de-extras)
- [Paralelización](#paralelización)
- [Servicio](#servicio)
- [Wiki](#wiki)
- [Licencia](#licencia)

---

## Ecosistema

```
VAC  ──POST /register──►  VAS  ──bump──►  VAL
     ──POST /heartbeat──►
```

| Paquete | Repositorio | Descripción |
|---------|-------------|-------------|
| `versatile-autoreg-vas` | [vas](https://github.com/GabrielNavi/vas) | Servidor de inventario |
| `versatile-autoreg-vac` | [vac](https://github.com/GabrielNavi/vac) ← *este* | Cliente de autoregistro |
| `versatile-autoreg-val` | [val](https://github.com/GabrielNavi/val) | Consumidor genérico con hooks |
| `versatile-autoreg-vaf` | vaf | Federación de servidores (experimental) |

---

## Instalación rápida

```bash
# Instalar
sudo dpkg -i versatile-autoreg-vac_*.deb
sudo apt-get -f install

# Configurar — mínimo necesario
sudo nano /etc/vac/vac.conf
# VAS_HOST=10.0.0.1

# Arrancar
sudo systemctl enable --now vac

# Verificar
journalctl -u vac -f
```

> **Dependencias:** `bash`, `curl`, `jq`, `uuid-runtime`, `iproute2`  
> Ver [Instalación](https://github.com/GabrielNavi/vac/wiki/ES_Instalacion) en la wiki para instrucciones completas.

---

## Archivos instalados

| Ruta | Descripción |
|------|-------------|
| `/usr/bin/vac` | Servicio en bucle (dos temporizadores: selfcheck + heartbeat) |
| `/usr/bin/vac-register` | Registro puntual e idempotente |
| `/usr/bin/vac-sub` | Bucle VAC completo para sub-instancias |
| `/usr/bin/vac-sub-manager` | Supervisor de sub-instancias con fail counter |
| `/usr/bin/vac-sub-instance` | CLI para crear, listar y eliminar sub-instancias |
| `/usr/lib/vac/vac-common.sh` | Librería compartida: log, red, identidad, extras, registro |
| `/etc/vac/vac.conf` | Configuración principal |
| `/etc/vac/vac.conf.d/` | Overlays en orden lexical |
| `/etc/vac/extras_imperative.d/` | Scripts hook cíclicos para extras imperativos |
| `/etc/vac/extras_informative.d/` | Scripts hook cíclicos para extras informativos |
| `/usr/share/vac/vac.conf.defaults` | Referencia exhaustiva de variables (solo lectura) |
| `/lib/systemd/system/vac.service` | Unidad systemd |

**Estado en tiempo de ejecución:**

| Ruta | Descripción |
|------|-------------|
| `/etc/vac/vac-id` | UUID persistente del equipo (generado una vez, modo 600) |
| `/var/lib/vac/identity.json` | Datos propios tal como los confirma VAS |
| `/var/lib/vac/version` | Última versión del inventario conocida |
| `/var/lib/vac/clients.json` | Copia local del inventario (`SYNC_CLIENTS=true`) |

---

## Configuración

```ini
# /etc/vac/vac.conf  (referencia completa en /usr/share/vac/vac.conf.defaults)

VAS_HOST=10.0.0.1        # IP/hostname; sin scheme, puerto 8000 implícito
# VAS_SCHEME=http        # http (defecto) | https
CHECK_SECONDS=300        # intervalo de selfcheck + comparación de versión
# HEARTBEAT_SECONDS=60   # liveness independiente; vacío = igual a CHECK_SECONDS
SYNC_CLIENTS=false       # descargar copia local del inventario
# USE_VAT=false          # opcional: transformar clients.json con VAT
# VAT_PRESET=            # nombre del preset para transformación VAT (downstream)
EXTRAS_ENABLED=true
EXTRAS_TTL=86400         # expiración de claves en segundos (0 = sin límite)
LOG_LEVEL=normal         # no | normal | debug
PARALLEL_MODE=both       # both | only_parallel | only_main
```

`VAS_HOST` acepta `10.0.0.1`, `10.0.0.1:9000` o `vas.ejemplo.org`. El scheme se extrae automáticamente con `[WARN]`.

Cuando `USE_VAT=true`, VAC transforma el `clients.json` descargado usando un preset. Véase la [documentación VAT](https://github.com/GabrielNavi/vat) para la configuración.

Guía completa: [Configuración](https://github.com/GabrielNavi/vac/wiki/ES_Configuracion)

---

## Bucle principal

```
Cada CHECK_SECONDS:
  collect_extras() → selfcheck vs identity.json
  Con cambios → POST /register; guarda identity.json
  GET /version → si nueva: GET /clients (SYNC_CLIENTS) + refrescar identity

Cada HEARTBEAT_SECONDS:
  POST /heartbeat → si 404 o error: POST /register (re-registro completo)
```

Un registro exitoso en cualquier bloque resetea el temporizador del otro, evitando señales redundantes.

Más información: [Flujo de operación](https://github.com/GabrielNavi/vac/wiki/ES_Flujo)

---

## Sistema de extras

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

Con `EXTRAS_TTL=86400`, las claves sin actualizar en >24 h se eliminan con `[WARN]` (detecta productores silenciados).

Más información: [Extras](https://github.com/GabrielNavi/vac/wiki/ES_Extras)

---

## Paralelización

Un equipo puede registrarse en múltiples VAS con UUIDs distintos y estado independiente:

```bash
vac-sub-instance --create samba --vas 10.0.1.5
vac-sub-instance --list
# NOMBRE   VAS_HOST        ENABLED  ESTADO
# samba    10.0.1.5:8000   sí       activa
systemctl restart vac   # con PARALLEL_MODE=both
```

`PARALLEL_MODE`: `both` · `only_parallel` · `only_main`. El supervisor deja de reiniciar una instancia tras 5 fallos duros consecutivos.

Más información: [Sub-instancias](https://github.com/GabrielNavi/vac/wiki/ES_Sub-instancias)

---

## Servicio

```bash
sudo systemctl status vac
sudo systemctl restart vac
journalctl -u vac -f
journalctl -u vac | grep '\[SELFCHECK\]'
journalctl -u vac | grep '\[PARALLEL\]'
journalctl -u vac | grep '\[ERROR\]'
```

---

## Wiki

[Instalación](https://github.com/GabrielNavi/vac/wiki/ES_Instalacion) · [Configuración](https://github.com/GabrielNavi/vac/wiki/ES_Configuracion) · [Flujo de operación](https://github.com/GabrielNavi/vac/wiki/ES_Flujo) · [Extras](https://github.com/GabrielNavi/vac/wiki/ES_Extras) · [Sub-instancias](https://github.com/GabrielNavi/vac/wiki/ES_Sub-instancias) · [Logging](https://github.com/GabrielNavi/vac/wiki/ES_Logging)

---

## Licencia

[Apache License 2.0](LICENSE)
