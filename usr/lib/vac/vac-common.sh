# vac-common.sh — Funciones compartidas entre vac y vac-register.
#
# Uso: source /usr/lib/vac/vac-common.sh
#
# El script que carga esta librería debe definir LOG_TAG antes del source
# para distinguir los mensajes en journalctl:
#   LOG_TAG="[VAC]"          → bucle principal
#   LOG_TAG="[VAC-REGISTER]" → registro puntual
#
# Variables de configuración (sobreescritas por load_conf / load_all_conf):
#   VAS_HOST, RETRY_SECONDS, CHECK_SECONDS, EXTRAS_ENABLED,
#   EXEC_IMPERATIVE, EXEC_INFORMATIVE, EXTRA_IMPERATIVE_SCRIPT,
#   EXTRA_INFORMATIVE_SCRIPT, SYNC_CLIENTS, LOG_LEVEL, LOG_FILE.

# ---------------------------------------------------------------------------
# Rutas
# ---------------------------------------------------------------------------
CONF_FILE="${CONF_FILE:-/etc/vac/vac.conf}"
CONF_DIR="${CONF_DIR:-/etc/vac/vac.conf.d}"
ID_FILE="${ID_FILE:-/etc/vac/vac-id}"
STATE_DIR="${STATE_DIR:-/var/lib/vac}"

VERSION_FILE="${STATE_DIR}/version"
CLIENTS_FILE="${STATE_DIR}/clients.json"
TMP_CLIENTS="${STATE_DIR}/clients.json.tmp"
IDENTITY_FILE="${STATE_DIR}/identity.json"
TMP_IDENTITY="${STATE_DIR}/identity.json.tmp"
EXTRAS_IMP_FILE="${STATE_DIR}/extras_imperative.json"
EXTRAS_INF_FILE="${STATE_DIR}/extras_informative.json"

# ---------------------------------------------------------------------------
# Valores por defecto de configuración
# ---------------------------------------------------------------------------
VAS_HOST=""
RETRY_SECONDS=60
CHECK_SECONDS=300
EXTRAS_ENABLED=false
EXTRAS_TTL=86400
EXTRAS_IMPERATIVE_HOOKS_DIR="/etc/vac/extras_imperative.d"
EXTRAS_INFORMATIVE_HOOKS_DIR="/etc/vac/extras_informative.d"
SYNC_CLIENTS=true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# LOG_LEVEL:
#   no     → silencio total (ni stdout ni fichero)
#   normal → eventos importantes: arranque, registros, cambios de versión, errores
#   debug  → además: detalles de config, comparaciones campo a campo, heartbeat OK
#
# LOG_FILE:
#   vacío  → solo stdout (capturado por journald cuando corre como servicio)
#   ruta   → además escribe en el archivo con timestamp ISO-8601 UTC como prefijo
# ---------------------------------------------------------------------------
LOG_LEVEL="${LOG_LEVEL:-normal}"
LOG_FILE="${LOG_FILE:-}"
LOG_TAG="${LOG_TAG:-[VAC]}"

# Escribe un mensaje a stdout y, si LOG_FILE está configurado, al fichero.
# El fichero incluye timestamp; stdout no (journald lo añade).
_log_write() {
    echo "$*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# Mensaje de nivel normal: visible con LOG_LEVEL=normal o debug.
log() {
    [[ "$LOG_LEVEL" == "no" ]] && return 0
    _log_write "$LOG_TAG $*"
}

# Mensaje de nivel debug: solo visible con LOG_LEVEL=debug.
# Prefijo [DEBUG] para filtrar con:  journalctl -u vac | grep '\[DEBUG\]'
log_debug() {
    [[ "$LOG_LEVEL" != "debug" ]] && return 0
    _log_write "$LOG_TAG [DEBUG] $*"
}

# ---------------------------------------------------------------------------
# Carga de configuración
# ---------------------------------------------------------------------------

# Parser seguro: lee clave=valor sin ejecutar código del fichero.
# Solo acepta las variables conocidas; el resto se ignora.
load_conf() {
    local file="$1"
    [ -f "$file" ] || return 0

    local loaded=0
    while IFS='=' read -r key val; do
        key="$(echo "$key" | xargs 2>/dev/null || true)"
        val="$(echo "$val" | xargs 2>/dev/null | sed 's/^"//; s/"$//' || true)"
        [ -z "$key" ] && continue

        case "$key" in
            VAS_HOST)                 VAS_HOST="$val";                 (( ++loaded )) ;;
            RETRY_SECONDS)            RETRY_SECONDS="$val";            (( ++loaded )) ;;
            CHECK_SECONDS)            CHECK_SECONDS="$val";            (( ++loaded )) ;;
            EXTRAS_ENABLED)              EXTRAS_ENABLED="$val";              (( ++loaded )) ;;
            EXTRAS_TTL)                  EXTRAS_TTL="$val";                  (( ++loaded )) ;;
            EXTRAS_IMPERATIVE_HOOKS_DIR) EXTRAS_IMPERATIVE_HOOKS_DIR="$val"; (( ++loaded )) ;;
            EXTRAS_INFORMATIVE_HOOKS_DIR) EXTRAS_INFORMATIVE_HOOKS_DIR="$val"; (( ++loaded )) ;;
            SYNC_CLIENTS)                SYNC_CLIENTS="$val";                (( ++loaded )) ;;
            LOG_LEVEL)                LOG_LEVEL="$val";                (( ++loaded )) ;;
            LOG_FILE)                 LOG_FILE="$val";                 (( ++loaded )) ;;
        esac
    done < <(grep -v '^\s*#' "$file" | grep '=' || true)

    log_debug "Config cargada desde $file: $loaded clave(s)"
}

# Carga vac.conf y todos los overlays en vac.conf.d en orden léxico.
load_all_conf() {
    load_conf "$CONF_FILE"
    if [[ -d "$CONF_DIR" ]]; then
        for cfg in "$CONF_DIR"/*.conf; do
            [[ -f "$cfg" ]] || continue
            load_conf "$cfg"
        done
    fi
}

# ---------------------------------------------------------------------------
# Datos de red
# ---------------------------------------------------------------------------

get_hostname() {
    hostname -f 2>/dev/null || hostname
}

# Devuelve la IP de salida usando la tabla de rutas (consulta local, no necesita
# conectividad real a 1.1.1.1).
get_ip() {
    ip route get 1.1.1.1 2>/dev/null \
        | awk '/src/ { for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit } }' \
        || true
}

# Devuelve la MAC de la primera interfaz física detectada (eth, ens, enp, wlan, wlp).
get_mac() {
    ip link show 2>/dev/null \
        | awk '/^[0-9]+: (eth|ens|enp|wlan|wlp)/ { iface=1; next }
               iface && /link\/ether/ { print $2; exit }
               /^[0-9]+:/ { iface=0 }' \
        || true
}

# ---------------------------------------------------------------------------
# Identity local
# ---------------------------------------------------------------------------

# Escribe identity.json de forma atómica con los datos proporcionados.
#
# Uso: save_identity host ip mac extra_imp extra_inf
#
# extra_imp / extra_inf: JSON string, "{}" (borrar campo en VAS) o "" (vacío →
#   se guarda null, indica que no se envió dato; el selfcheck en modo delegate
#   no compara este campo).
save_identity() {
    local host="$1" ip="$2" mac="$3" extra_imp="${4:-}" extra_inf="${5:-}"

    jq -n \
        --arg     hostname  "$host"               \
        --arg     ip        "$ip"                 \
        --arg     mac       "$mac"                \
        --argjson extra_imp  "${extra_imp:-null}"  \
        --argjson extra_inf  "${extra_inf:-null}"  \
        '{
            hostname:          $hostname,
            ip:                $ip,
            mac:               $mac,
            extra_imperative:  $extra_imp,
            extra_informative: $extra_inf
        }' > "$TMP_IDENTITY" 2>/dev/null \
    && mv "$TMP_IDENTITY" "$IDENTITY_FILE" \
    || {
        log "[IDENTITY] Error escribiendo $IDENTITY_FILE"
        rm -f "$TMP_IDENTITY"
        return 1
    }

    log_debug "[IDENTITY] Guardado: $IDENTITY_FILE"
}

# Lee identity.json y exporta las variables IDENTITY_HOST, IDENTITY_IP,
# IDENTITY_MAC, IDENTITY_IMP, IDENTITY_INF.
# Devuelve 1 si el fichero no existe o no es JSON válido.
load_identity() {
    if [[ ! -f "$IDENTITY_FILE" ]]; then
        log_debug "[IDENTITY] $IDENTITY_FILE no encontrado."
        return 1
    fi

    IDENTITY_HOST="$(jq -r '.hostname          // empty' "$IDENTITY_FILE" 2>/dev/null)"
    IDENTITY_IP="$(  jq -r '.ip                // empty' "$IDENTITY_FILE" 2>/dev/null)"
    IDENTITY_MAC="$( jq -r '.mac               // empty' "$IDENTITY_FILE" 2>/dev/null)"
    IDENTITY_IMP="$( jq -c '.extra_imperative  // empty' "$IDENTITY_FILE" 2>/dev/null)"
    IDENTITY_INF="$( jq -c '.extra_informative // empty' "$IDENTITY_FILE" 2>/dev/null)"

    if [[ -z "$IDENTITY_HOST" && -z "$IDENTITY_IP" ]]; then
        log "[IDENTITY] $IDENTITY_FILE inválido o vacío."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Registro y heartbeat
# ---------------------------------------------------------------------------

# Envía POST /register con los datos del equipo.
#
# Uso: register_client host ip mac extra_imp extra_inf
#
# extra_imp / extra_inf: JSON string, "{}" (borrar) o "" (vacío → null → COALESCE en VAS).
# Imprime la respuesta JSON del servidor y devuelve 0 si tuvo éxito.
register_client() {
    local host="$1" ip="$2" mac="$3" extra_imp="${4:-}" extra_inf="${5:-}"
    local payload response

    # Describir brevemente los extras para el log sin volcar blobs JSON grandes.
    local imp_desc inf_desc
    if   [[ -z "$extra_imp" ]];     then imp_desc="(null/COALESCE)"
    elif [[ "$extra_imp" == "{}" ]]; then imp_desc="(borrado explícito)"
    else imp_desc="JSON"; fi

    if   [[ -z "$extra_inf" ]];     then inf_desc="(null/COALESCE)"
    elif [[ "$extra_inf" == "{}" ]]; then inf_desc="(borrado explícito)"
    else inf_desc="JSON"; fi

    log_debug "[REGISTER] Datos: hostname=$host ip=${ip:-(vacía)} mac=${mac:-(vacía)} imp=$imp_desc inf=$inf_desc"

    if [[ -z "$ip" ]]; then
        log "[REGISTER] IP vacía — sin red activa. Abortando registro."
        return 1
    fi

    [[ -z "$mac" ]] && log "[REGISTER] MAC vacía (interfaz virtual o sin detección). Registrando sin MAC."

    payload="$(jq -n \
        --arg     id        "$CLIENT_ID"           \
        --arg     hostname  "$host"                \
        --arg     ip        "$ip"                  \
        --arg     mac       "$mac"                 \
        --argjson extra_imp  "${extra_imp:-null}"   \
        --argjson extra_inf  "${extra_inf:-null}"   \
        '{
            id:                $id,
            hostname:          $hostname,
            ip:                $ip,
            mac:               $mac,
            extra_imperative:  $extra_imp,
            extra_informative: $extra_inf
        }')"

    log "[REGISTER] Enviando POST ${VAS_HOST%/}/register ..."

    response="$(curl -fsS \
        --max-time 10 --connect-timeout 5 \
        -X POST "${VAS_HOST%/}/register" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)" || response=""

    if [[ -n "$response" ]]; then
        log_debug "[REGISTER] Respuesta VAS: $response"
        echo "$response"
        return 0
    else
        log "[REGISTER] Sin respuesta de VAS (timeout o error de red)."
        return 1
    fi
}

# Envía POST /heartbeat con solo el UUID del cliente.
# Devuelve 0 si VAS respondió OK.
# Devuelve 1 si no hubo respuesta (timeout/red) o 404 (cliente no registrado → re-registrar).
# En ambos casos de fallo VAC tomará la misma acción: intentar POST /register.
heartbeat_client() {
    local response

    log_debug "[HEARTBEAT] Enviando POST ${VAS_HOST%/}/heartbeat ..."

    response="$(curl -fsS \
        --max-time 10 --connect-timeout 5 \
        -X POST "${VAS_HOST%/}/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"$CLIENT_ID\"}" 2>/dev/null)" || response=""

    if [[ -n "$response" ]]; then
        log_debug "[HEARTBEAT] OK: $response"
        return 0
    else
        log "[HEARTBEAT] Sin respuesta (timeout, error de red o cliente no registrado)."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Descarga de inventario
# ---------------------------------------------------------------------------

# Descarga GET /clients y guarda clients.json de forma atómica.
# Devuelve 0 si tuvo éxito, 1 si falló (CLIENTS_FILE no se modifica).
download_clients() {
    log "[SYNC] Descargando inventario: ${VAS_HOST%/}/clients"

    if curl -fsS --max-time 15 --connect-timeout 5 \
        "${VAS_HOST%/}/clients" -o "$TMP_CLIENTS" 2>/dev/null; then

        local count
        count="$(jq '.clients | length' "$TMP_CLIENTS" 2>/dev/null || echo '?')"
        mv "$TMP_CLIENTS" "$CLIENTS_FILE"
        log "[SYNC] Inventario guardado: $CLIENTS_FILE ($count equipo(s))"
        return 0
    else
        log "[SYNC-ERROR] Error descargando inventario. CLIENTS_FILE no modificado."
        rm -f "$TMP_CLIENTS"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Gestión de extras multi-fuente
# ---------------------------------------------------------------------------
#
# Estado interno: dos ficheros JSON en STATE_DIR con estructura por clave:
#   { "key": { "timestamp": "YYYYMMDDHHMMSS", "data": { ... } }, ... }
#
# upsert_extra_key FILE KEY DATA_JSON
#   Inserta o actualiza KEY con timestamp UTC y DATA_JSON como data.
#   Escritura atómica. Claves ordenadas lexicalmente.
#
# delete_extra_key FILE KEY
#   Elimina KEY del fichero. No-op si la clave o el fichero no existen.
#
# expire_extras FILE
#   Elimina claves cuyo timestamp supera EXTRAS_TTL segundos.
#   EXTRAS_TTL=0 → expiración desactivada.
#
# build_extras_merge FILE
#   Devuelve JSON plano { key: data } para enviar a VAS (sin timestamps).
#   Sin fichero  → "" (null → COALESCE en VAS)
#   0 claves     → "{}" (borrado explícito)
#   Con claves   → { key: data, ... }
# ---------------------------------------------------------------------------

upsert_extra_key() {
    local file="$1" key="$2" data="$3"
    local ts tmp current
    # Timestamp formato YYYYMMDDHHMMSS — 14 dígitos, mismo espacio que la versión VAS.
    ts="$(date -u +%Y%m%d%H%M%S)"
    tmp="${file}.tmp"
    current="{}"
    [[ -f "$file" ]] && current="$(cat "$file")"

    # Insertar/actualizar la clave y reordenar lexicalmente para diff determinista.
    jq -c --arg key "$key" --arg ts "$ts" --argjson data "$data" \
        '.[$key] = {"timestamp": $ts, "data": $data} | to_entries | sort_by(.key) | from_entries' \
        <<< "$current" > "$tmp" \
    && mv "$tmp" "$file" \
    || { rm -f "$tmp"; return 1; }
}

delete_extra_key() {
    local file="$1" key="$2" tmp
    [[ ! -f "$file" ]] && return 0
    tmp="${file}.tmp"
    jq -c --arg key "$key" \
        'del(.[$key]) | to_entries | sort_by(.key) | from_entries' \
        "$file" > "$tmp" \
    && mv "$tmp" "$file" \
    || { rm -f "$tmp"; return 1; }
}

expire_extras() {
    local file="$1"
    [[ ! -f "$file" ]] && return 0
    # TTL=0 desactiva la expiración por diseño explícito.
    [[ "${EXTRAS_TTL:-0}" -eq 0 ]] && return 0

    local now key ts ts_epoch age
    now="$(date +%s)"
    local expired=()

    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        ts="$(jq -r --arg k "$key" '.[$k].timestamp // empty' "$file" 2>/dev/null)"
        # Ignorar entradas con timestamp ausente o formato incorrecto.
        [[ -z "$ts" || ! "$ts" =~ ^[0-9]{14}$ ]] && continue
        # Convertir YYYYMMDDHHMMSS → epoch para comparar con el reloj actual.
        ts_epoch="$(date -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}" +%s 2>/dev/null)" || continue
        age=$(( now - ts_epoch ))
        if [[ "$age" -gt "$EXTRAS_TTL" ]]; then
            log "[WARN] [EXTRAS] Clave '$key' expirada (${age}s > TTL ${EXTRAS_TTL}s) — eliminada."
            expired+=("$key")
        fi
    done < <(jq -r 'keys[]' "$file" 2>/dev/null)

    [[ "${#expired[@]}" -eq 0 ]] && return 0

    local tmp="${file}.tmp"
    # Construir array JSON de claves a eliminar y pasarlo como argumento a jq
    # para evitar inyección si los nombres contienen caracteres especiales.
    local keys_json
    keys_json="$(printf '%s\n' "${expired[@]}" | jq -R . | jq -sc .)"
    jq -c --argjson keys "$keys_json" \
        'del(.[$keys[]]) | to_entries | sort_by(.key) | from_entries' \
        "$file" > "$tmp" \
    && mv "$tmp" "$file" \
    || { rm -f "$tmp"; return 1; }
}

build_extras_merge() {
    local file="$1"
    # Sin fichero: null → VAS aplica COALESCE (conserva valor previo en BD).
    if [[ ! -f "$file" ]]; then
        echo ""
        return 0
    fi
    local count
    count="$(jq 'keys | length' "$file" 2>/dev/null || echo 0)"
    # Fichero vacío (0 claves): {} → VAS pone NULL explícito en BD.
    if [[ "$count" -eq 0 ]]; then
        echo "{}"
        return 0
    fi
    # Con claves: extraer solo .data de cada entrada, sin los metadatos internos.
    jq -c 'to_entries | map({key: .key, value: .value.data}) | from_entries' "$file" 2>/dev/null || echo ""
}
