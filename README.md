# vx-dga-l-vac

Paquete Debian para Vitalinux que instala Vitalinux Autoregistration Client (VAC) de forma global.

## Descripcion

Este paquete instala VAC en el sistema para su despliegue mediante Migasfree en entornos Vitalinux. VAC se ejecuta como servicio systemd en bucle, registra el equipo en VAS, consulta cambios de versión de configuración y aplica automáticamente la configuración de Veyon.

## Requisitos

- Sistema Vitalinux compatible con paquetes Debian.
- Dependencias de sistema en tiempo de ejecución:
  - bash
  - curl
  - jq
  - uuid-runtime
  - iproute2
  - veyon
- Conectividad de red con el servidor VAS.

## Informacion del Paquete

- Nombre: vx-dga-l-vac
- Version: 0.2-3
- Arquitectura: all
- Mantenedor: Gabriel Navia <correos@gabrielnav.es>
- Licencia: GPL-3.0+

## Archivos incluidos

- usr/bin/vac - Script principal del cliente en Bash
- etc/vac/vac.conf - Configuración editable del cliente
- lib/systemd/system/vac.service - Unidad systemd de VAC
- debian/postinst - Inicialización de ID persistente y arranque del servicio
- debian/prerm - Parada y deshabilitación del servicio al eliminar
- debian/postrm - Limpieza de estado en purge

## Funcionamiento de VAC

VAC implementa el flujo de autoregistro y sincronización continua:

1. Arranque
   - systemd ejecuta usr/bin/vac.
   - Carga configuración desde etc/vac/vac.conf.
   - Inicializa estado local en /var/lib/vac.
   - Genera UUID persistente en /etc/vac/vac-id si no existe.

2. Registro en VAS
   - Obtiene hostname, IP y MAC del equipo.
   - Envía datos al endpoint POST /register del servidor VAS.
   - Usa el UUID persistente como identificador principal.

3. Control de versión
   - Consulta GET /version en VAS.
   - Compara versión remota con la versión local almacenada.

4. Descarga y aplicación de configuración
   - Si la versión cambia, descarga GET /config.
   - Guarda el JSON en VEYON_CONFIG.
    - Convierte computers.json a CSV para compatibilidad con Veyon CLI.
   - Ejecuta importación con:
       - veyon-cli networkobjects remove <LOCATION_GESTIONADA>
       - veyon-cli networkobjects import <CSV> format "%type%;%name%;%host%;%mac%;%location%"

5. Reintentos
   - Si falla registro, versión o aplicación, VAC no avanza versión local y reintenta según la temporización configurada.

## Servicio systemd

- Nombre del servicio: vac.service
- Comandos de operación habituales:
  - sudo systemctl status vac
  - sudo systemctl restart vac
  - sudo journalctl -u vac -f

## Configuracion

Archivo de configuración: etc/vac/vac.conf

Sobreescrituras por subconfiguración: /etc/vac/vac.conf.d/*.conf

El orden de carga es:
1. /etc/vac/vac.conf
2. /etc/vac/vac.conf.d/*.conf (orden lexical)

Variables principales:

- VAS_HOST: URL base del servidor (ejemplo: http://192.168.1.149:8000)
- RETRY_SECONDS: espera entre reintentos cuando hay fallo
- CHECK_SECONDS: intervalo de comprobación de versión
- VEYON_CONFIG: ruta local del archivo JSON descargado
- VEYON_ROOM: location de destino para importación en Veyon
- CONFIG_ENDPOINT: endpoint remoto de configuración (normalmente /config)

Ejemplo típico:

VAS_HOST="http://192.168.1.149:8000"
RETRY_SECONDS=60
CHECK_SECONDS=300
VEYON_CONFIG="/etc/veyon/computers.json"
VEYON_ROOM="Autoregistrados"
CONFIG_ENDPOINT="/config"

## Construccion del paquete

Desde este directorio:

dpkg-buildpackage -us -uc -b
