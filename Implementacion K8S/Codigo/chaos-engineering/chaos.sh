#!/usr/bin/env bash
# chaos.sh: punto de entrada unico de los experimentos de caos de PharmaGo.
#
# Uso:    ./chaos.sh <experimento> [opciones]
# Ayuda:  ./chaos.sh --help
#
# Compatible con bash 3.2 (macOS): sin arrays asociativos ni mapfile.
# Blast radius: SOLO el namespace "pharmago" (CHAOS_NAMESPACE).

# shellcheck disable=SC2016
set -u

NS="${CHAOS_NAMESPACE:-pharmago}"
NETSHOOT_IMAGE="${CHAOS_NETSHOOT_IMAGE:-nicolaka/netshoot}"
DEBUG_EXTRA="${CHAOS_DEBUG_EXTRA_FLAGS:---attach}"
IFACE="${CHAOS_IFACE:-eth0}"
GATEWAY_URL="${CHAOS_GATEWAY_URL:-http://127.0.0.1:5000}"
TICK=5
ANNOT_REPLICAS="chaos.pharmago/orig-replicas"

EXP=""
DURATION=""
TARGET=""
MODE=""
RESTORE=0
DRY=0
FORCE=0
MB=""
REQUESTS=""
WORKERS=""
URL=""
PATH_REQ=""
METHOD=""
DELAY_MS=500
LOSS_PCT=30

ARMED=0
ABORTED=0
TMPD=""
T_START=0
DISC_OLD_PODS=""
RAM_RESTARTS_BEFORE=""

# ---------------------------------------------------------------- utilidades
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { err "$*"; exit 1; }

# Ejecuta (o solo imprime en --dry-run) un comando.
run() {
  if [ "$DRY" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

usage() {
  cat <<'EOF'
chaos.sh <experimento> [opciones]

Experimentos:
  requests     Inyeccion de requests (carga) contra el Gateway (requiere port-forward)
  cpu          Sobrecarga de CPU dentro de un pod
  ram          Sobrecarga de memoria dentro de un pod
  storage      Sobrecarga de storage (llena el disco efimero del contenedor)
  network      Interrupcion de red: latencia, perdida, particion total (tc netem) o corte de Service
  disconnect   Desconexion de un componente (scale a 0 o borrado del pod)
  restore-all  Boton de panico: deshace cualquier experimento sobre todos los componentes

Opciones:
  --target T     gateway | users | pharmacy | db | ui (o nombre exacto de un Deployment)
  --duration N   segundos que dura la falla (default: 60; requests 30)
  --mode M       network: delay | loss | partition | svc-cut   (default delay)
                 disconnect: scale | kill                      (default scale)
                 svc-cut NO corta el trafico del Gateway (ver aviso al usarlo); usar partition
  --mb N         ram/storage: MB a consumir (ram 250, storage 500)
  --requests N   requests: total de requests (si se omite, se usa --duration)
  --workers N    requests: concurrencia (default 20); cpu: procesos que queman CPU (default 4)
  --url U        requests: URL completa (default $CHAOS_GATEWAY_URL/api/login)
  --path P       requests: ruta en el Gateway, ej. /api/drug (usa GET salvo que se indique --method)
  --method M     requests: GET | POST (default POST para /api/login, GET para otras rutas)
  --delay-ms N   network delay: latencia agregada (default 500)
  --loss-pct N   network loss: porcentaje de paquetes perdidos (default 30)
  --restore      solo restaura (idempotente) el experimento indicado
  --dry-run      imprime lo que haria sin tocar el cluster
  --force        ignora la condicion de aborto previa (cluster no sano)
  -h, --help     esta ayuda

Targets por defecto: cpu/ram/storage = gateway, network = users, disconnect = pharmacy.

Variables de entorno: CHAOS_NAMESPACE (pharmago), CHAOS_GATEWAY_URL (http://127.0.0.1:5000),
  CHAOS_IFACE (eth0), CHAOS_NETSHOOT_IMAGE (nicolaka/netshoot), CHAOS_DEBUG_EXTRA_FLAGS (--attach).

Ejemplos:
  ./chaos.sh requests --duration 60 --workers 30
  ./chaos.sh requests --path /api/drug --duration 60   (pega en pharmacy y la DB, sin el rate limit del login)
  ./chaos.sh cpu --target gateway --duration 60
  ./chaos.sh ram --target users --mb 300 --duration 45
  ./chaos.sh storage --target gateway --mb 800 --duration 60
  ./chaos.sh network --target users --mode delay --delay-ms 800 --duration 60
  ./chaos.sh network --target pharmacy --mode partition --duration 45
  ./chaos.sh network --target users --mode svc-cut --duration 30
  ./chaos.sh disconnect --target pharmacy --duration 60
  ./chaos.sh disconnect --target db --mode kill
  ./chaos.sh network --target users --restore
  ./chaos.sh restore-all
EOF
}

# ------------------------------------------------------------------ cluster
kc() { kubectl "$@"; }

cluster_ok() { kubectl --request-timeout=5s get ns "$NS" >/dev/null 2>&1; }

# Nombre corto -> nombre de Deployment/Service/label app.
resolve_target() {
  case "$1" in
    gateway|api-gateway|pharmago-api-gateway) echo "pharmago-api-gateway" ;;
    users|users-service|pharmago-users-service) echo "pharmago-users-service" ;;
    pharmacy|pharmacy-service|pharmago-pharmacy-service) echo "pharmago-pharmacy-service" ;;
    db|database|pharmago-db) echo "pharmago-db" ;;
    ui|frontend|pharmago-ui) echo "pharmago-ui" ;;
    *) echo "$1" ;;
  esac
}

pods_of() {
  kc get pod -n "$NS" -l "app=$1" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null
}

running_pod() {
  kc get pod -n "$NS" -l "app=$1" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

container_of() {
  kc get pod -n "$NS" "$1" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null
}

ready_of() {
  local r
  r=$(kc get deploy -n "$NS" "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "${r:-0}"
}

desired_of() {
  kc get deploy -n "$NS" "$1" -o jsonpath='{.spec.replicas}' 2>/dev/null
}

# Replicas que pide el manifiesto aplicado: kubectl apply guarda la ultima
# configuracion en la anotacion last-applied-configuration.
applied_replicas_of() {
  kc get deploy -n "$NS" "$1" \
    -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' 2>/dev/null \
    | grep -o '"replicas":[0-9]*' | head -n 1 | cut -d: -f2
}

# Imprime " gateway=1/1 users=1/1 ..." y devuelve 1 si algun componente no esta listo.
steady_state() {
  local d ok=0 out="" rd ds
  for d in pharmago-api-gateway pharmago-users-service pharmago-pharmacy-service pharmago-db; do
    rd=$(ready_of "$d"); ds=$(desired_of "$d"); ds="${ds:-?}"
    out="$out ${d#pharmago-}=$rd/$ds"
    [ "$rd" = "$ds" ] || ok=1
  done
  echo "$out"
  return $ok
}

# Sonda sintetica contra el Gateway (si hay port-forward). No falla si no hay.
probe() {
  local o
  o=$(curl -s -o /dev/null -m 3 -w '%{http_code} %{time_total}s' "$GATEWAY_URL/test-health" 2>/dev/null)
  echo "gateway/test-health=${o:-000}"
}

# Espera N segundos mostrando el estado cada TICK. Condicion de aborto: la base
# de datos cae sin ser el objetivo (dano colateral fuera del blast radius previsto).
hold() {
  local secs="$1" start now el left
  start=$(date +%s)
  while :; do
    now=$(date +%s); el=$((now - start))
    [ "$el" -ge "$secs" ] && break
    log "t+${el}s/${secs}s |$(steady_state) | $(probe)"
    if [ "$TARGET" != "pharmago-db" ]; then
      if [ "$(ready_of pharmago-db)" != "$(desired_of pharmago-db)" ]; then
        log "ABORTO: la base de datos dejo de estar lista y no es el objetivo. Restaurando."
        ABORTED=1
        return 1
      fi
    fi
    left=$((secs - el))
    [ "$left" -gt "$TICK" ] && left=$TICK
    sleep "$left"
  done
  return 0
}

banner() {
  # $1 hipotesis, $2 que se rompe, $3 blast radius, $4 senales esperadas
  echo "=================================================================="
  log "EXPERIMENTO: $EXP  target=${TARGET:-n/a}  mode=${MODE:-n/a}  duracion=${DURATION:-n/a}s  namespace=$NS"
  log "Hipotesis de estado estable: $1"
  log "Que se rompe: $2"
  log "Blast radius: $3"
  log "Senales esperadas: $4"
  log "Alertas esperadas: las de latencia p95, tasa de 5xx, pod no listo y reinicios definidas en Prometheus/Grafana"
  echo "=================================================================="
}

# ------------------------------------------------------------ requests
inject_requests() {
  local url="${URL:-$GATEWAY_URL${PATH_REQ:-/api/login}}" w="${WORKERS:-20}" meth="${METHOD:-}" per_end="" per_count="" code i
  if [ -z "$meth" ]; then
    case "$url" in */api/login*) meth=POST ;; *) meth=GET ;; esac
  fi
  if [ -n "$REQUESTS" ]; then
    per_count=$(( (REQUESTS + w - 1) / w ))
  else
    per_end=$(( $(date +%s) + DURATION ))
  fi
  if [ "$DRY" -eq 1 ]; then
    log "[dry-run] $w workers hacen $meth $url ($( [ -n "$REQUESTS" ] && echo "$REQUESTS requests" || echo "${DURATION}s" ))"
    return 0
  fi
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null)
  [ "${code:-000}" = "000" ] && die "no hay respuesta en $url. Levanta el port-forward: k8s/port-forward.sh"
  log "Inyectando carga: $w workers -> $meth $url"
  i=0
  while [ "$i" -lt "$w" ]; do
    (
      n=0
      while :; do
        if [ -n "$per_count" ]; then
          [ "$n" -ge "$per_count" ] && break
        else
          [ "$(date +%s)" -ge "$per_end" ] && break
        fi
        curl -s -o /dev/null -m 10 -w '%{http_code} %{time_total}\n' -X "$meth" "$url" \
          -H 'Content-Type: application/json' -d '{"userName":"chaos","password":"chaos"}' \
          >> "$TMPD/req.$i" 2>/dev/null || echo "000 10" >> "$TMPD/req.$i"
        n=$((n + 1))
      done
    ) &
    i=$((i + 1))
  done
  if [ -z "$per_count" ]; then
    hold "$DURATION" || true
  fi
  wait
}

summary_requests() {
  [ "$DRY" -eq 1 ] && return 0
  cat "$TMPD"/req.* 2>/dev/null > "$TMPD/all" || true
  [ -s "$TMPD/all" ] || { log "Sin resultados."; return 0; }
  log "Resultado por codigo HTTP (cantidad):"
  awk '{c[$1]++} END{for(k in c) printf "    %s: %d\n", k, c[k]}' "$TMPD/all" | sort
  awk '{print $2}' "$TMPD/all" | sort -n | awk '
    {a[NR]=$1; s+=$1}
    END{ if(NR){ p=int(NR*0.95); if(p<1)p=1; printf "    total=%d  latencia media=%.3fs  p50=%.3fs  p95=%.3fs  max=%.3fs\n", NR, s/NR, a[int((NR+1)/2)], a[p], a[NR] } }'
}

restore_requests() {
  local p
  for p in $(jobs -p 2>/dev/null); do kill "$p" 2>/dev/null; done
  return 0
}

# ----------------------------------------------------------------- cpu
inject_cpu() {
  local pod c w="${WORKERS:-4}" inner
  pod=$(running_pod "$TARGET"); c=$(container_of "$pod")
  if [ "$DRY" -eq 1 ]; then pod="${pod:-<pod>}"; c="${c:-<container>}"; fi
  # Procesos que queman CPU + watchdog que los mata a los DURATION segundos
  # (el pod se auto-limpia aunque se corte el script).
  inner="rm -f /tmp/chaos-cpu.pids; i=0; while [ \$i -lt $w ]; do (while :; do :; done) & echo \$! >> /tmp/chaos-cpu.pids; i=\$((i+1)); done; (sleep $DURATION; kill \$(cat /tmp/chaos-cpu.pids) 2>/dev/null; rm -f /tmp/chaos-cpu.pids) &"
  log "Quemando CPU en $pod con $w procesos (limite del contenedor 500m: se vera throttling)"
  run kubectl exec -n "$NS" "$pod" -c "$c" -- sh -c 'sh -c "$0" >/dev/null 2>&1 </dev/null &' "$inner"
}

restore_cpu_pod() {
  kc exec -n "$NS" "$1" -c "$(container_of "$1")" -- sh -c \
    'kill $(cat /tmp/chaos-cpu.pids 2>/dev/null) 2>/dev/null; rm -f /tmp/chaos-cpu.pids; true' >/dev/null 2>&1
}

restore_cpu() {
  local p
  for p in $(pods_of "$TARGET"); do log "Restaurando CPU en $p"; run restore_cpu_pod "$p"; done
}

# ----------------------------------------------------------------- ram
inject_ram() {
  local pod c mb="${MB:-250}" inner
  pod=$(running_pod "$TARGET"); c=$(container_of "$pod")
  if [ "$DRY" -eq 1 ]; then pod="${pod:-<pod>}"; c="${c:-<container>}"; fi
  RAM_RESTARTS_BEFORE=$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  # tail sobre un flujo sin saltos de linea retiene todo en memoria hasta el EOF;
  # el EOF llega cuando termina el sleep, asi la memoria se mantiene DURATION segundos.
  # (/dev/shm esta limitado a 64MB en los pods, por eso no se usa dd ahi.)
  inner="(head -c ${mb}M /dev/zero; sleep $DURATION) | tail >/dev/null & echo \$! > /tmp/chaos-ram.pid"
  log "Reteniendo ${mb}MB de memoria en $pod (limite del contenedor 384Mi)"
  run kubectl exec -n "$NS" "$pod" -c "$c" -- sh -c 'sh -c "$0" >/dev/null 2>&1 </dev/null &' "$inner"
}

restore_ram_pod() {
  kc exec -n "$NS" "$1" -c "$(container_of "$1")" -- sh -c \
    'kill $(cat /tmp/chaos-ram.pid 2>/dev/null) 2>/dev/null; rm -f /tmp/chaos-ram.pid; true' >/dev/null 2>&1
}

restore_ram() {
  local p
  for p in $(pods_of "$TARGET"); do log "Liberando memoria en $p"; run restore_ram_pod "$p"; done
}

summary_ram() {
  [ "$DRY" -eq 1 ] && return 0
  local pod rc reason
  pod=$(pods_of "$TARGET" | head -n 1)
  rc=$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  reason=$(kc get pod -n "$NS" "$pod" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)
  log "Reinicios del contenedor: antes=${RAM_RESTARTS_BEFORE:-?} ahora=${rc:-?} (ultima terminacion: ${reason:-ninguna})"
}

# -------------------------------------------------------------- storage
fill_path() {
  if [ "$TARGET" = "pharmago-db" ]; then echo "/var/opt/mssql/chaos_fill"; else echo "/tmp/chaos_fill"; fi
}

inject_storage() {
  local pod c mb="${MB:-500}" f
  pod=$(running_pod "$TARGET"); c=$(container_of "$pod"); f=$(fill_path)
  if [ "$DRY" -eq 1 ]; then pod="${pod:-<pod>}"; c="${c:-<container>}"; fi
  if [ "$mb" -gt 2000 ] && [ "$FORCE" -ne 1 ]; then
    die "--mb $mb supera 2000: puede llenar el disco del nodo de Minikube. Usa --force si es a proposito."
  fi
  log "Escribiendo ${mb}MB en $pod:$f (disco efimero del contenedor = disco del nodo)"
  run kubectl exec -n "$NS" "$pod" -c "$c" -- sh -c "dd if=/dev/zero of=$f bs=1M count=$mb 2>&1 | tail -n 1; df -h \$(dirname $f) | tail -n 1"
}

restore_storage() {
  local p f
  f=$(fill_path)
  for p in $(pods_of "$TARGET"); do
    log "Borrando $f en $p"
    run kubectl exec -n "$NS" "$p" -c "$(container_of "$p")" -- sh -c "rm -f $f; true"
  done
}

# -------------------------------------------------------------- network
# Ejecuta un comando en un contenedor efimero netshoot que comparte el
# namespace de red del pod (kubectl debug --profile=netadmin da NET_ADMIN).
net_exec() {
  local pod="$1" c="$2" cmd="$3"
  # shellcheck disable=SC2086
  kubectl debug -n "$NS" "$pod" --image="$NETSHOOT_IMAGE" --image-pull-policy=IfNotPresent \
    --profile=netadmin --target="$c" -q $DEBUG_EXTRA -- sh -c "$cmd"
}

inject_network() {
  local m="${MODE:-delay}" pod c tcargs=""
  case "$m" in
    svc-cut)
      log "AVISO: svc-cut NO es una tecnica fiable de corte: YARP reutiliza conexiones keep-alive ya abiertas al pod y el selector solo afecta conexiones nuevas, asi que el Gateway puede seguir llegando al pod. Para cortar el trafico usa --mode partition."
      log "Cortando el Service $TARGET: selector -> app=chaos-disconnected (sin endpoints)"
      run kubectl patch svc -n "$NS" "$TARGET" -p '{"spec":{"selector":{"app":"chaos-disconnected"}}}'
      [ "$DRY" -eq 1 ] || kc get endpoints -n "$NS" "$TARGET"
      return 0 ;;
    delay) tcargs="delay ${DELAY_MS}ms $((DELAY_MS / 5))ms" ;;
    loss) tcargs="loss ${LOSS_PCT}%" ;;
    partition) tcargs="loss 100%" ;;
  esac
  pod=$(running_pod "$TARGET"); c=$(container_of "$pod")
  if [ "$DRY" -eq 1 ]; then pod="${pod:-<pod>}"; c="${c:-<container>}"; fi
  log "tc netem en $pod ($IFACE): $tcargs (afecta el trafico que SALE del pod)"
  if [ "$DRY" -eq 1 ]; then
    printf '[dry-run] kubectl debug -n %s %s --image=%s --profile=netadmin --target=%s -- tc qdisc replace dev %s root netem %s\n' \
      "$NS" "$pod" "$NETSHOOT_IMAGE" "$c" "$IFACE" "$tcargs"
    return 0
  fi
  net_exec "$pod" "$c" "tc qdisc replace dev $IFACE root netem $tcargs && tc qdisc show dev $IFACE" \
    || die "no se pudo aplicar tc (revisa version de kubectl/cluster y que la imagen $NETSHOOT_IMAGE este cargada en minikube)"
}

restore_network() {
  local m="${MODE:-}" p has svc_sel
  # Corte de Service: restaura el selector si esta cortado (idempotente).
  svc_sel=$(kc get svc -n "$NS" "$TARGET" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
  if [ "$svc_sel" = "chaos-disconnected" ]; then
    log "Restaurando selector del Service $TARGET -> app=$TARGET"
    run kubectl patch svc -n "$NS" "$TARGET" -p "{\"spec\":{\"selector\":{\"app\":\"$TARGET\"}}}"
  fi
  [ "$m" = "svc-cut" ] && return 0
  # tc: solo si el pod tuvo contenedores efimeros (si no, no hay nada que borrar).
  for p in $(pods_of "$TARGET"); do
    has=$(kc get pod -n "$NS" "$p" -o jsonpath='{.spec.ephemeralContainers[*].name}' 2>/dev/null)
    if [ -n "$has" ] || [ "$DRY" -eq 1 ]; then
      log "Quitando reglas tc de $p"
      if [ "$DRY" -eq 1 ]; then
        printf '[dry-run] kubectl debug ... -- tc qdisc del dev %s root\n' "$IFACE"
      else
        net_exec "$p" "$(container_of "$p")" "tc qdisc del dev $IFACE root 2>/dev/null; tc qdisc show dev $IFACE" \
          || err "no se pudo limpiar tc en $p; alternativa segura: kubectl delete pod -n $NS $p"
      fi
    fi
  done
}

# ----------------------------------------------------------- disconnect
inject_disconnect() {
  local m="${MODE:-scale}" cur
  case "$m" in
    scale)
      cur=$(desired_of "$TARGET")
      if [ "${cur:-1}" != "0" ]; then
        run kubectl annotate deploy -n "$NS" "$TARGET" "$ANNOT_REPLICAS=${cur:-1}" --overwrite
      fi
      log "Desconectando $TARGET: scale --replicas=0 (antes: ${cur:-?})"
      run kubectl scale deploy -n "$NS" "$TARGET" --replicas=0 ;;
    kill)
      DISC_OLD_PODS=$(pods_of "$TARGET" | tr '\n' ' ')
      log "Borrando pods de $TARGET: ${DISC_OLD_PODS:-<pods>} (self-healing del ReplicaSet)"
      run kubectl delete pod -n "$NS" -l "app=$TARGET" --wait=false ;;
  esac
}

restore_disconnect() {
  local orig cur want
  orig=$(kc get deploy -n "$NS" "$TARGET" -o jsonpath="{.metadata.annotations.chaos\\.pharmago/orig-replicas}" 2>/dev/null)
  cur=$(desired_of "$TARGET")
  if [ -n "$orig" ]; then
    log "Restaurando $TARGET a $orig replicas"
    run kubectl scale deploy -n "$NS" "$TARGET" --replicas="$orig"
    run kubectl annotate deploy -n "$NS" "$TARGET" "$ANNOT_REPLICAS-"
  elif [ "$cur" = "0" ]; then
    want=$(applied_replicas_of "$TARGET")
    if [ -n "$want" ]; then
      log "Sin anotacion previa y replicas=0: se restaura a $want (las del manifiesto aplicado)"
    else
      want=1
      log "Sin anotacion previa ni manifiesto aplicado y replicas=0: se restaura a 1"
    fi
    run kubectl scale deploy -n "$NS" "$TARGET" --replicas="$want"
  else
    return 0
  fi
  if [ "$DRY" -ne 1 ]; then wait_ready "$TARGET" 300; fi
}

has_old_pod() {
  local p cur
  cur=" $(pods_of "$TARGET" | tr '\n' ' ')"
  for p in $DISC_OLD_PODS; do
    case "$cur" in *" $p "*) return 0 ;; esac
  done
  return 1
}

# Espera a que el Deployment vuelva a estar listo (y, tras un kill, sin los pods viejos).
wait_ready() {
  local d="$1" max="$2" t0 el
  t0=$(date +%s)
  log "Esperando a que $d este listo (max ${max}s)..."
  while :; do
    el=$(( $(date +%s) - t0 ))
    if [ "$(ready_of "$d")" = "$(desired_of "$d")" ] && [ "$(desired_of "$d")" != "0" ] && ! has_old_pod; then
      log "$d listo tras ${el}s (tiempo de recuperacion)"
      return 0
    fi
    if [ "$el" -ge "$max" ]; then err "$d no volvio a estar listo en ${max}s"; return 1; fi
    sleep 2
  done
}

# --------------------------------------------------------------- restore-all
restore_all() {
  local d saved_t="$TARGET" saved_m="$MODE"
  log "Restaurando todos los componentes del namespace $NS"
  for d in pharmago-api-gateway pharmago-users-service pharmago-pharmacy-service pharmago-db pharmago-ui; do
    TARGET="$d"; MODE=""
    if [ -n "$(pods_of "$d")" ]; then restore_cpu; restore_ram; restore_storage; fi
    restore_network
    restore_disconnect
  done
  TARGET="$saved_t"; MODE="$saved_m"
}

# ----------------------------------------------------------------- flujo
on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$ARMED" -eq 1 ] && [ "$DRY" -ne 1 ]; then
    ARMED=0
    echo
    log "Salida con experimento activo: restauracion automatica (trap)"
    case "$EXP" in
      requests) restore_requests ;;
      cpu) restore_cpu ;;
      ram) restore_ram ;;
      storage) restore_storage ;;
      network) restore_network ;;
      disconnect) restore_disconnect ;;
    esac
    log "Experimento $EXP terminado (restaurado por trap)"
  fi
  if [ -n "$TMPD" ]; then rm -rf "$TMPD"; fi
  exit $rc
}

need_arg() { [ $# -ge 2 ] || die "falta valor para $1"; }

parse_args() {
  [ $# -ge 1 ] || { usage; exit 1; }
  case "$1" in -h|--help) usage; exit 0 ;; esac
  EXP="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --duration) need_arg "$@"; DURATION="$2"; shift 2 ;;
      --target) need_arg "$@"; TARGET="$2"; shift 2 ;;
      --mode) need_arg "$@"; MODE="$2"; shift 2 ;;
      --mb) need_arg "$@"; MB="$2"; shift 2 ;;
      --requests) need_arg "$@"; REQUESTS="$2"; shift 2 ;;
      --workers) need_arg "$@"; WORKERS="$2"; shift 2 ;;
      --url) need_arg "$@"; URL="$2"; shift 2 ;;
      --path) need_arg "$@"; PATH_REQ="$2"; shift 2 ;;
      --method) need_arg "$@"; METHOD="$2"; shift 2 ;;
      --delay-ms) need_arg "$@"; DELAY_MS="$2"; shift 2 ;;
      --loss-pct) need_arg "$@"; LOSS_PCT="$2"; shift 2 ;;
      --restore) RESTORE=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --force) FORCE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "opcion desconocida: $1 (ver --help)" ;;
    esac
  done
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

needs_pod() {
  case "$EXP" in
    cpu|ram|storage) return 0 ;;
    network) [ "${MODE:-delay}" != "svc-cut" ] ;;
    *) return 1 ;;
  esac
}

validate() {
  local v
  for v in "$DURATION" "$MB" "$REQUESTS" "$WORKERS" "$DELAY_MS" "$LOSS_PCT"; do
    if [ -n "$v" ] && ! is_num "$v"; then die "valor numerico invalido: $v"; fi
  done
  case "$EXP" in
    requests|cpu|ram|storage|network|disconnect|restore-all) ;;
    *) die "experimento desconocido: $EXP (requests|cpu|ram|storage|network|disconnect|restore-all)" ;;
  esac
  case "$EXP" in
    network) case "${MODE:-delay}" in delay|loss|partition|svc-cut) ;; *) die "--mode de network: delay|loss|partition|svc-cut" ;; esac ;;
    disconnect) case "${MODE:-scale}" in scale|kill) ;; *) die "--mode de disconnect: scale|kill" ;; esac ;;
  esac
  if ! cluster_ok; then
    if [ "$DRY" -eq 1 ]; then
      log "AVISO: el cluster no responde; en --dry-run se omiten las validaciones contra el cluster."
      return 0
    fi
    die "el cluster no responde o el namespace '$NS' no existe. Revisa 'minikube status' y 'kubectl get ns'."
  fi
  if [ "$EXP" != "requests" ] && [ "$EXP" != "restore-all" ]; then
    kc get deploy -n "$NS" "$TARGET" >/dev/null 2>&1 || die "el Deployment '$TARGET' no existe en el namespace '$NS'."
    if [ "$RESTORE" -ne 1 ] && needs_pod; then
      [ -n "$(running_pod "$TARGET")" ] || die "no hay pods Running con app=$TARGET."
    fi
  fi
}

print_banner() {
  local net_what
  case "$EXP" in
    requests) banner "el Gateway responde con latencia p95 baja y 0% de 5xx bajo carga normal" \
        "satura el Gateway con requests concurrentes a /api/login (llegan a users-service y a la DB)" \
        "Gateway, users-service y DB, dentro del namespace" \
        "sube Throughput Total y Latencia. OJO /api/login: con credenciales invalidas responde 404 y el rate limit (10 logins/min por IP) devuelve 429 casi siempre, asi que mide sobre todo el rate limit; para saturar pharmacy y la DB usar --path /api/drug" ;;
    cpu) banner "con CPU saturada el servicio sigue respondiendo, con mayor latencia, y no se reinicia" \
        "$TARGET: procesos que consumen CPU hasta el limite (500m), CFS throttling" \
        "un solo pod ($TARGET); el resto comparte nodo pero tiene requests propios" \
        "panel 'CPU por pod' pegado al limite y latencia p95 arriba; sin reinicios (la CPU estrangula, no mata)" ;;
    ram) banner "con presion de memoria el servicio se degrada o se reinicia y Kubernetes lo recupera" \
        "$TARGET: se retienen ${MB:-250}MB (limite del contenedor 384Mi)" \
        "un solo pod ($TARGET)" \
        "panel 'Memoria por pod' cerca del limite; posible OOMKilled y restartCount+1 (depende de a quien mate el kernel)" ;;
    storage) banner "llenar el disco efimero de un pod no afecta a otros pods ni compromete al nodo" \
        "$TARGET: se escriben ${MB:-500}MB en $(fill_path)" \
        "un pod, pero el disco efimero es del nodo (unico en Minikube): tope de 2000MB sin --force" \
        "baja 'Disco disponible %' del nodo; con mucho volumen, evicciones por DiskPressure" ;;
    network)
      case "${MODE:-delay}" in
        delay) net_what="latencia +${DELAY_MS}ms en la salida del pod" ;;
        loss) net_what="${LOSS_PCT}% de paquetes perdidos en la salida del pod" ;;
        partition) net_what="100% de paquetes perdidos en la salida del pod (probes incluidas)" ;;
        svc-cut) net_what="el Service queda sin endpoints (solo afecta conexiones nuevas; no corta keep-alive de YARP)" ;;
      esac
      banner "con la red de $TARGET degradada (${MODE:-delay}) el Gateway falla rapido (503) o degrada sin colgarse, y al restaurar todo vuelve" \
        "$net_what" \
        "un pod o un Service ($TARGET)" \
        "latencia/timeouts y 5xx en el Gateway para las rutas de $TARGET; readiness en NotReady si se pierden paquetes; el resto de rutas sigue sano" ;;
    disconnect)
      if [ "${MODE:-scale}" = "kill" ]; then net_what="se borra el pod (self-healing)"; else net_what="se escala el Deployment a 0 durante ${DURATION}s"; fi
      banner "sin $TARGET el Gateway devuelve error rapido para sus rutas, las demas siguen sanas y K8s recrea el pod" \
        "modo ${MODE:-scale}: $net_what" \
        "las rutas que dependen de $TARGET" \
        "pods 0/1, 5xx/503 en esas rutas, readiness fallando; al volver, Ready y 2xx otra vez" ;;
  esac
}

main() {
  local ss
  parse_args "$@"
  case "$EXP" in
    cpu|ram|storage) TARGET="${TARGET:-gateway}" ;;
    network) TARGET="${TARGET:-users}" ;;
    disconnect) TARGET="${TARGET:-pharmacy}" ;;
  esac
  if [ -n "$TARGET" ]; then TARGET=$(resolve_target "$TARGET"); fi
  case "$EXP" in
    requests) DURATION="${DURATION:-30}" ;;
    disconnect) if [ "${MODE:-scale}" = "kill" ]; then DURATION="${DURATION:-0}"; else DURATION="${DURATION:-60}"; fi ;;
    *) DURATION="${DURATION:-60}" ;;
  esac
  validate
  TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t chaos)
  trap 'exit 130' INT TERM
  trap on_exit EXIT

  if [ "$EXP" = "restore-all" ]; then restore_all; return 0; fi

  if [ "$RESTORE" -eq 1 ]; then
    log "Restaurando experimento '$EXP' sobre $TARGET"
    case "$EXP" in
      requests) log "Nada que restaurar (la carga termina sola)" ;;
      cpu) restore_cpu ;;
      ram) restore_ram ;;
      storage) restore_storage ;;
      network) restore_network ;;
      disconnect) restore_disconnect ;;
    esac
    log "Restauracion de $EXP terminada"
    return 0
  fi

  print_banner

  if [ "$DRY" -ne 1 ] && [ "$FORCE" -ne 1 ]; then
    if ! ss=$(steady_state); then
      err "estado base no sano:$ss. Condicion de aborto: no se inyecta una falla sobre un sistema ya degradado (usa --force)."
      exit 1
    fi
    log "Estado estable verificado:$ss"
  fi

  T_START=$(date +%s)
  ARMED=1
  log "INICIO de la inyeccion"
  case "$EXP" in
    requests) inject_requests; restore_requests; ARMED=0; summary_requests ;;
    cpu) inject_cpu; if [ "$DRY" -ne 1 ]; then hold "$DURATION" || true; fi; restore_cpu; ARMED=0 ;;
    ram) inject_ram; if [ "$DRY" -ne 1 ]; then hold "$DURATION" || true; fi; summary_ram; restore_ram; ARMED=0 ;;
    storage) inject_storage; if [ "$DRY" -ne 1 ]; then hold "$DURATION" || true; fi; restore_storage; ARMED=0 ;;
    network) inject_network; if [ "$DRY" -ne 1 ]; then hold "$DURATION" || true; fi; restore_network; ARMED=0 ;;
    disconnect)
      inject_disconnect
      if [ "${MODE:-scale}" = "kill" ]; then
        if [ "$DRY" -ne 1 ]; then wait_ready "$TARGET" 300 || true; fi
      else
        if [ "$DRY" -ne 1 ]; then hold "$DURATION" || true; fi
        restore_disconnect
      fi
      ARMED=0 ;;
  esac
  log "FIN del experimento $EXP tras $(( $(date +%s) - T_START ))s$( [ "$ABORTED" -eq 1 ] && echo ' (ABORTADO por condicion de aborto)' )"
  if [ "$DRY" -ne 1 ]; then log "Estado final:$(steady_state)"; fi
}

main "$@"
