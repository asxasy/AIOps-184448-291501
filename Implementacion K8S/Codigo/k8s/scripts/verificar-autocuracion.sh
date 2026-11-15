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
#
# Variables opcionales: INTERVALO, LINEA_BASE (5), COLA (5), URLS, CURL_IMAGE, NS.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib-sonda.sh"

DEPLOY="${1:-pharmago-users-service}"
MODO="${2:-crash}"
LINEA_BASE="${LINEA_BASE:-5}"
COLA="${COLA:-5}"
LIMITE=300

case "$MODO" in crash|delete) ;; *) echo "Modo inválido: $MODO (crash|delete)" >&2; exit 2 ;; esac
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

trap sonda_borrar EXIT INT TERM
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
else
    kubectl delete pod "$POD" -n "$NS" --wait=false >/dev/null
    echo "Pod $POD borrado en t=0"
fi

T_NO_LISTO=""
T_LISTO=""
while :; do
    ahora_t=$(ahora)
    trans=$(restar "$ahora_t" "$T0")
    if awk -v t="$trans" -v l="$LIMITE" 'BEGIN { exit !(t > l) }'; then
        echo "Timeout: no se recuperó en ${LIMITE}s." >&2
        break
    fi
    if [ "$MODO" = "crash" ]; then
        estado=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount} {.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        rc=${estado% *}
        listo=${estado#* }
        if [ -z "$T_NO_LISTO" ] && [ "$listo" != "True" ]; then
            T_NO_LISTO=$trans
            echo "  t=${trans}s pod NotReady (sale del Service)"
        fi
        if [ -n "$rc" ] && [ "$rc" -gt "$RC0" ] && [ "$listo" = "True" ]; then
            T_LISTO=$trans
            echo "  t=${trans}s contenedor reiniciado (restartCount=$rc) y READY"
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

echo "Cola de ${COLA}s..."
sleep "$COLA"
LOG="$(mktemp "${TMPDIR:-/tmp}/sonda-autocuracion.XXXXXX")"
sonda_recolectar "$LOG"
sonda_borrar
trap - EXIT INT TERM

echo
echo "=== Resultado (log completo en $LOG) ==="
echo "Tiempo hasta volver a READY (MTTR del componente): ${T_LISTO:-no se recuperó} s"
kubectl get pods -n "$NS" -l app="$DEPLOY" \
    -o custom-columns='POD:.metadata.name,LISTO:.status.conditions[?(@.type=="Ready")].status,REINICIOS:.status.containerStatuses[0].restartCount,ÚLTIMA_TERMINACIÓN:.status.containerStatuses[0].lastState.terminated.reason'
echo
echo "Tráfico visto por la sonda (MTTR percibido = ventana con fallas):"
sonda_resumen "$LOG" "$INICIO"
RES=$?
[ -n "$T_LISTO" ] || exit 1
exit $RES
