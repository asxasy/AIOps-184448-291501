#!/bin/bash
# Mide la autocuración (ítem 2 de la rúbrica) y el MTTR.
#
# Toma un pod READY del deployment, le provoca una falla y mide:
#   - cuánto tarda Kubernetes en devolverlo a READY (MTTR del componente);
#   - cuántas requests fallan mientras tanto vistas desde dentro del clúster
#     (MTTR percibido por el usuario; con 2 réplicas debería ser 0 o casi 0).
#
# Uso:
#   ./verificar-autocuracion.sh [deployment] [modo]
#     deployment: pharmago-users-service (defecto), pharmago-pharmacy-service,
#                 pharmago-api-gateway, pharmago-ui
#     modo:  crash  (defecto) mata el proceso principal (PID 1) del contenedor;
#                   el kubelet reinicia el contenedor (restartCount + 1).
#            delete borra el pod; el ReplicaSet crea uno nuevo.
#            freeze congela los procesos del contenedor (SIGSTOP) sin matarlos:
#                   el pod sigue Running pero no contesta, como una app colgada.
#                   Solo la liveness probe lo puede recuperar. Necesita minikube.
#
# Modo freeze, en detalle:
#   - La señal se manda desde el nodo (minikube ssh) a todos los procesos del
#     cgroup del contenedor. Con kubectl exec no sirve: adentro del contenedor
#     el proceso principal es el PID 1 de su espacio de procesos y el kernel
#     descarta SIGSTOP y SIGKILL que le lleguen desde adentro.
#   - Es el peor caso de colgado: el proceso tampoco atiende el SIGTERM del
#     kubelet, así que después de la decisión de la liveness se espera el
#     preStop y el resto de terminationGracePeriodSeconds hasta el SIGKILL.
#     Una app colgada que todavía atiende SIGTERM se recupera antes.
#   - Fallan requests hasta que la readiness saca el pod del Service (las que
#     van al pod congelado esperan el --max-time de la sonda). El criterio de
#     éxito es que la liveness lo reinicie y vuelva a READY; la ventana de
#     fallas se informa como dato.
#   - Si el script se corta (Ctrl-C) o no hay recuperación, descongela el pod.
#
# Variables opcionales: INTERVALO, LINEA_BASE (5), COLA (5), URLS, CURL_IMAGE, NS,
# MINIKUBE_PROFILE (por defecto, el contexto actual de kubectl).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib-sonda.sh"

DEPLOY="${1:-pharmago-users-service}"
MODO="${2:-crash}"
LINEA_BASE="${LINEA_BASE:-5}"
COLA="${COLA:-5}"
LIMITE=300

case "$MODO" in crash|delete|freeze) ;; *) echo "Modo inválido: $MODO (crash|delete|freeze)" >&2; exit 2 ;; esac
verificar_kubectl

POD=$(kubectl get pods -n "$NS" -l app="$DEPLOY" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' | head -1)
if [ -z "$POD" ]; then
    echo "Error: no hay pods Running con app=$DEPLOY en $NS." >&2
    exit 2
fi
RC0=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}')
DESEADAS=$(kubectl get deployment "$DEPLOY" -n "$NS" -o jsonpath='{.spec.replicas}')
echo "Deployment $DEPLOY ($DESEADAS réplicas). Pod víctima: $POD (restartCount=$RC0). Modo: $MODO"

# --- Modo freeze: congelar y descongelar desde el nodo ---------------------
PERFIL="${MINIKUBE_PROFILE:-$(kubectl config current-context)}"
NODO=""
CGROUP=""   # cgroup del contenedor congelado; vacío = nada que descongelar

en_nodo() {
    minikube -p "$PERFIL" ssh -n "$NODO" -- "$1" 2>/dev/null | tr -d '\r'
}

# Congela todos los procesos del contenedor. Imprime "<cgroup> <cantidad> <estados>".
congelar() {
    en_nodo "P=\$(sudo crictl inspect --output go-template --template '{{.info.pid}}' $1) && [ \"\$P\" -gt 0 ] \
&& CG=/sys/fs/cgroup\$(cut -d: -f3 /proc/\$P/cgroup) && PIDS=\$(cat \$CG/cgroup.procs) && sudo kill -STOP \$PIDS \
&& echo \"\$CG \$(echo \$PIDS | wc -w) \$(ps -o stat= -p \$(echo \$PIDS | tr ' ' ',') | sed 's/^ *//' | cut -c1 | sort -u | tr -d '\n')\""
}

# Descongela releyendo el mismo cgroup. Si el contenedor ya fue reemplazado,
# el cgroup no existe y no hace nada.
descongelar() {
    [ -n "$CGROUP" ] || return 0
    en_nodo "[ -f $CGROUP/cgroup.procs ] && sudo kill -CONT \$(cat $CGROUP/cgroup.procs) && echo ok" | grep -q ok \
        && echo "Procesos de $POD descongelados (no hubo reinicio)."
    CGROUP=""
}

if [ "$MODO" = "freeze" ]; then
    if ! command -v minikube >/dev/null 2>&1; then
        echo "Error: el modo freeze necesita minikube (manda la señal desde el nodo)." >&2
        exit 2
    fi
    if [ -z "$(kubectl get deployment "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}')" ]; then
        echo "Error: $DEPLOY no tiene liveness probe; un pod congelado no se recuperaría." >&2
        exit 2
    fi
    NODO=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')
    CID=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].containerID}')
    CID=${CID#*://}
    IFS='|' read -r RP RF LP LF GR <<EOF
$(kubectl get deployment "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.periodSeconds}|{.spec.template.spec.containers[0].readinessProbe.failureThreshold}|{.spec.template.spec.containers[0].livenessProbe.periodSeconds}|{.spec.template.spec.containers[0].livenessProbe.failureThreshold}|{.spec.template.spec.terminationGracePeriodSeconds}')
EOF
    RP=${RP:-10}; RF=${RF:-3}; LP=${LP:-10}; LF=${LF:-3}; GR=${GR:-30}
    echo "Probes: readiness cada ${RP}s x ${RF} fallas; liveness cada ${LP}s x ${LF} fallas; gracia ${GR}s."
    echo "Esperable: sale del Service a ~$((RP * RF))s, la liveness decide a ~$((LP * LF))s y,"
    echo "como el proceso congelado no atiende SIGTERM, el SIGKILL llega ~${GR}s después."
    AFINIDAD=$(kubectl get svc -n "$NS" -o jsonpath="{range .items[?(@.spec.selector.app==\"$DEPLOY\")]}{.spec.sessionAffinity}{end}")
    if [ "$AFINIDAD" = "ClientIP" ]; then
        echo "Ojo: el Service tiene sessionAffinity ClientIP. La sonda queda atada a una réplica:"
        echo "verá fallar todas sus requests a este servicio hasta que actúe la readiness, o ninguna."
    fi
fi

# Ctrl-C o kill: sale por el EXIT, que descongela y borra la sonda.
limpiar() {
    descongelar
    sonda_borrar
}
trap limpiar EXIT
trap 'exit 130' INT TERM
sonda_iniciar
echo "Línea base de ${LINEA_BASE}s..."
sleep "$LINEA_BASE"

INICIO=$(date +%s)
T0=$(ahora)
if [ "$MODO" = "crash" ]; then
    # SIGTERM al PID 1: el proceso termina y el kubelet reinicia el contenedor.
    # (SIGKILL al PID 1 desde dentro del contenedor lo ignora el kernel.)
    kubectl exec -n "$NS" "$POD" -- sh -c 'kill 1' >/dev/null 2>&1
    echo "Proceso principal de $POD terminado en t=0"
elif [ "$MODO" = "freeze" ]; then
    salida=$(congelar "$CID")
    if [ -z "$salida" ]; then
        echo "Error: no se pudo congelar $POD desde el nodo $NODO (perfil $PERFIL)." >&2
        exit 2
    fi
    set -- $salida
    CGROUP=$1
    echo "Congelados $2 procesos de $POD en t=0 (estado: ${3:-?}, T = detenido)"
else
    kubectl delete pod "$POD" -n "$NS" --wait=false >/dev/null
    echo "Pod $POD borrado en t=0"
fi

T_NO_LISTO=""
T_REINICIO=""
T_LISTO=""
while :; do
    ahora_t=$(ahora)
    trans=$(restar "$ahora_t" "$T0")
    if awk -v t="$trans" -v l="$LIMITE" 'BEGIN { exit !(t > l) }'; then
        echo "Timeout: no se recuperó en ${LIMITE}s." >&2
        break
    fi
    if [ "$MODO" != "delete" ]; then
        estado=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount} {.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        rc=${estado% *}
        listo=${estado#* }
        if [ -z "$T_NO_LISTO" ] && [ "$listo" != "True" ]; then
            T_NO_LISTO=$trans
            echo "  t=${trans}s pod NotReady (sale del Service)"
        fi
        if [ -z "$T_REINICIO" ] && [ -n "$rc" ] && [ "$rc" -gt "$RC0" ]; then
            T_REINICIO=$trans
            CGROUP=""   # el contenedor congelado ya no existe
            echo "  t=${trans}s contenedor nuevo arrancado (restartCount=$rc)"
        fi
        if [ -n "$T_REINICIO" ] && [ "$listo" = "True" ]; then
            T_LISTO=$trans
            echo "  t=${trans}s READY otra vez"
            break
        fi
    else
        # Réplicas READY sin contar la víctima ni pods en terminación. No se
        # espera a que la víctima desaparezca: su apagado ordenado (preStop)
        # no es parte de la recuperación.
        listas=$(kubectl get pods -n "$NS" -l app="$DEPLOY" \
            -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status} {.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
            | awk -v p="$POD" '$1 != p && $2 == "True" && $3 == "" { n++ } END { print n + 0 }')
        if [ -z "$T_NO_LISTO" ] && [ "$listas" -lt "$DESEADAS" ]; then
            T_NO_LISTO=$trans
            echo "  t=${trans}s réplicas READY: $listas/$DESEADAS"
        fi
        if [ "$listas" -ge "$DESEADAS" ]; then
            T_LISTO=$trans
            echo "  t=${trans}s pod reemplazado: $listas/$DESEADAS réplicas READY"
            break
        fi
    fi
    sleep 0.5
done
descongelar   # solo actúa si hubo timeout con el pod todavía congelado

echo "Cola de ${COLA}s..."
sleep "$COLA"
LOG="$(mktemp "${TMPDIR:-/tmp}/sonda-autocuracion.XXXXXX")"
sonda_recolectar "$LOG"
sonda_borrar
trap - EXIT INT TERM

# Eventos del pod víctima desde t=0, en segundos relativos a t=0.
eventos_pod() {
    local filas
    filas=$(kubectl get events -n "$NS" --field-selector "involvedObject.name=$POD" \
        -o jsonpath='{range .items[*]}{.firstTimestamp}|{.lastTimestamp}|{.count}|{.reason}|{.message}{"\n"}{end}' 2>/dev/null)
    echo "$filas" | python3 -c '
import sys, datetime as d
t0 = float(sys.argv[1])
def ep(s):
    return d.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()
filas = []
for l in sys.stdin:
    p = l.rstrip("\n").split("|", 4)
    if len(p) < 5 or not p[1]:
        continue
    u = ep(p[1])
    if u < t0 - 1:
        continue
    filas.append((ep(p[0] or p[1]), u, p[2] or "1", p[3], p[4]))
# "antes": evento que ya venía ocurriendo antes de t=0 (el contador lo acumula).
for f, u, c, r, m in sorted(filas):
    desde = "%3.0fs" % (f - t0) if f >= t0 - 1 else "antes"
    print("  t=%5s a %3.0fs  x%-3s %-10s %s" % (desde, u - t0, c, r, m[:100]))
' "$T0" 2>/dev/null || echo "$filas"
}

echo
echo "=== Resultado (log completo en $LOG) ==="
if [ "$MODO" = "freeze" ]; then
    echo "Tiempo hasta salir del Service (readiness):       ${T_NO_LISTO:-no salió} s"
    echo "Tiempo hasta arrancar el contenedor nuevo:        ${T_REINICIO:-no arrancó} s"
fi
echo "Tiempo hasta volver a READY (MTTR del componente): ${T_LISTO:-no se recuperó} s"
kubectl get pods -n "$NS" -l app="$DEPLOY" \
    -o custom-columns='POD:.metadata.name,LISTO:.status.conditions[?(@.type=="Ready")].status,REINICIOS:.status.containerStatuses[0].restartCount,ÚLTIMA_TERMINACIÓN:.status.containerStatuses[0].lastState.terminated.reason,CÓDIGO:.status.containerStatuses[0].lastState.terminated.exitCode'
if [ "$MODO" = "freeze" ]; then
    echo
    echo "Eventos del pod desde t=0 (Unhealthy = probe fallida; Killing = decisión de reiniciar):"
    EVENTOS=$(eventos_pod)
    echo "$EVENTOS"
fi
echo
echo "Tráfico visto por la sonda (MTTR percibido = ventana con fallas):"
sonda_resumen "$LOG" "$INICIO"
RES=$?
[ -n "$T_LISTO" ] || exit 1
if [ "$MODO" = "freeze" ]; then
    echo
    if echo "$EVENTOS" | grep -q "Killing.*liveness"; then
        echo "OK: la liveness detectó el pod colgado, lo reinició y volvió a READY."
        echo "(En freeze se esperan fallas hasta que la readiness lo saca del Service.)"
        exit 0
    fi
    echo "FALLÓ: el pod volvió a READY pero no hay evento Killing por liveness." >&2
    exit 1
fi
exit $RES
