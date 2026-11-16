# Obligatorio de AIOps: PharmaGo en Kubernetes

Este repositorio es el obligatorio de AIOps (electiva de Ingeniería y Licenciatura en Sistemas, ORT, 2026). Partimos de PharmaGo, una aplicación de farmacias con microservicios .NET, frontend Angular y SQL Server, y la operamos en Kubernetes sobre Minikube con alta disponibilidad, despliegues sin cortes, telemetría con OpenTelemetry, alertas y experimentos de caos.

Integrantes: Maria Noel Layerle, N.º de estudiante 184448, y Romina Piria, N.º de estudiante 291501. Docente: Juan Ignacio Irabedra.

Dónde está cada cosa:

- `Implementacion K8S/Codigo/k8s/`: manifiestos de Kubernetes y scripts para construir, desplegar y acceder (`build-images.sh`, `apply-k8s.sh`, `port-forward.sh`, `cleanup.sh`).
- `Implementacion K8S/Codigo/Backend/` y `Implementacion K8S/Codigo/Frontend/`: código de la aplicación.
- `Implementacion K8S/Codigo/chaos-engineering/`: el script de caos (`chaos.sh`) con los experimentos.
- `deteccion-anomalias/`: la notebook del laboratorio de detección de anomalías.
- `docs/`: plan de contención de incidentes operacionales.

## Cómo levantarlo

Guía para levantar esta versión del obligatorio desde cero en una máquina con Docker. Todos los comandos se corren desde `Implementacion K8S/Codigo/k8s/`, salvo que se indique otra cosa. La guía original del docente está en `Implementacion K8S/Codigo/k8s/README-k8s.md`; esta agrega lo que cambiamos y un paso que la original no menciona (los datos de prueba).

## Requisitos

- Docker Desktop con al menos 8 GB de memoria. En Mac con chip M, Rosetta activado (Settings, General): la imagen de SQL Server solo existe para Intel y corre emulada.
- Minikube y kubectl.
- Al menos 15 GB libres en disco. El clúster con todas las imágenes ocupa unos 8 GB, y quedarse sin disco durante un build deja imágenes corruptas dentro del nodo (ver el post-mortem en `docs/plan-de-contencion.md`).

## Pasos

### 1. Código

```bash
git clone https://github.com/asxasy/AIOps-184448-291501.git
cd AIOps-184448-291501
git checkout feature/k8s
cd "Implementacion K8S/Codigo/k8s"
```

### 2. Clúster

```bash
minikube start --driver=docker --memory=6144 --cpus=4
kubectl config current-context    # tiene que decir minikube
```

6 GB alcanzan: los requests de memoria de todos los pods suman unos 4,6 GB.

### 3. Imágenes de la aplicación

```bash
./build-images.sh
```

Compila users, pharmacy, gateway y UI con `docker build` y las carga en el nodo con `minikube image load`. Los manifiestos usan `imagePullPolicy: Never`, así que Kubernetes solo usa las imágenes que ya están en el nodo. La primera vez tarda varios minutos.

El build deja en Docker una caché de unos 4 GB. Si después de este paso quedan menos de 8 GB libres, conviene liberarla antes de seguir con `docker builder prune -af`, que no borra las imágenes ya cargadas en el nodo.

### 4. Despliegue

```bash
./apply-k8s.sh
```

Además de lo que hacía el script original (etiquetar el nodo, namespace, secrets, configmaps, volúmenes, base de datos, observabilidad, backend y frontend), ahora:

- crea los configmaps del dashboard de golden signals y de las 9 alertas antes de Grafana, que los monta como volumen;
- despliega Jaeger antes del OTel Collector, que le exporta las trazas;
- aplica los PodDisruptionBudgets;
- reinicia Prometheus, porque monta su configuración con `subPath` y no la recarga sola.

Tarda unos 5 minutos, casi todo esperando a SQL Server y a Elasticsearch la primera vez que se bajan sus imágenes.

### 5. Esperar a que todo esté listo

```bash
kubectl wait --for=condition=Ready pods --all -n pharmago --timeout=600s
kubectl get pods -n pharmago -o wide
```

Tienen que quedar 17 pods en `1/1 Running`: 2 réplicas de gateway, users, pharmacy y UI, y uno de cada componente de la base de datos y la observabilidad (incluido Jaeger).

Si `kubectl wait` termina con `pods "prometheus-…" not found`, no es un problema: es el pod viejo de Prometheus que `apply-k8s.sh` reemplaza al final. Volver a correr el comando lo confirma. En el primer arranque también es normal que la base y algún servicio .NET muestren un reinicio en `RESTARTS`.

### 6. Datos de prueba

Los servicios crean las tablas al arrancar, pero la base queda vacía: sin este paso, cualquier login responde 404 "The user does not exist". Desde `Implementacion K8S/Codigo/`:

```bash
kubectl exec -i -n pharmago deploy/pharmago-db -c pharmago-db -- \
  sh -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C -b -i /dev/stdin' \
  < Backend/seed-data.sql
```

Tiene que terminar con "Datos iniciales insertados correctamente". Crea los usuarios admin, owner001 y empleado01 (la contraseña está en el mismo archivo) y algunos medicamentos. El script se puede correr más de una vez: no duplica datos.

### 7. Acceso

```bash
./port-forward.sh
```

| Servicio | Dirección |
|---|---|
| Aplicación (UI) | http://127.0.0.1:4200 |
| API Gateway | http://127.0.0.1:5000 |
| Grafana | http://127.0.0.1:3000 (admin / admin) |
| Prometheus | http://127.0.0.1:9090 |
| Kibana | http://127.0.0.1:5601 |
| Elasticsearch | http://127.0.0.1:9200 |
| Jaeger (trazas) | http://127.0.0.1:16686 |

Usar 127.0.0.1 y no localhost. Un port-forward se corta cuando se reemplaza el pod al que apunta (por ejemplo, después de un rollout del gateway): volver a correr el script.

### 8. Verificación

```bash
# login: devuelve token, y el header X-Trace-Id con el id de la traza
curl -si -X POST http://127.0.0.1:5000/api/login \
  -H 'Content-Type: application/json' -d '{"userName":"admin","password":"<la del seed>"}' | grep -iE '^HTTP|x-trace-id'

# medicamentos cargados por el seed
curl -s http://127.0.0.1:5000/api/drug
```

Además:

- **Prometheus**, Status, Targets: todos en verde.
- **Grafana**, Alerting: las 9 reglas cargadas. Dashboards: PharmaGo - Overview, PharmaGo - Infra y PharmaGo - Golden Signals.
- **Jaeger**: elegir el servicio `PharmaGo.ApiGateway` y abrir la traza del login (gateway, users-service y la consulta SQL).
- **Kibana**: la primera vez hay que crear la data view, en Stack Management, Data Views, Create data view, con el patrón `pharmago-logs-*` y el campo de tiempo `@timestamp`. Después, en Discover, se ven los logs con los campos separados (`LogLevel`, `Category`, `Message`, `Scopes.TraceId`).

## Antes de una demo o de la defensa

- Desplegar con tiempo, no durante la demo: cargar imágenes escribe cientos de MB en el nodo y dispara la alerta de disco por unos minutos.
- Vaciar los contadores del rate limit: `kubectl rollout restart deployment/pharmago-api-gateway -n pharmago`, y después volver a correr `./port-forward.sh`.

## Problemas conocidos

- **`ImagePullBackOff` o `ErrImageNeverPull`:** la imagen no está en el nodo. Volver a correr `./build-images.sh` y confirmar con `minikube image ls | grep pharmago`.
- **Los servicios .NET fallan con `exec format error`:** la imagen quedó corrupta dentro del nodo (pasó cuando se llenó el disco). Borrarla y recargarla no alcanza, porque containerd reusa las capas por hash: hay que recrear el clúster con `minikube delete` y `minikube start`.
- **SQL Server no arranca en un Mac con chip M:** activar Rosetta en Docker Desktop.
- **Errores de DNS al bajar imágenes:** es la red; esperar y reintentar.
- **El puerto 9200 está ocupado:** `ES_LOCAL_PORT=19200 ./port-forward.sh`.

## Apagar

```bash
./port-forward.sh --stop
minikube stop          # apaga el clúster y conserva todo
./cleanup.sh           # borra el namespace y los volúmenes (se pierden los datos)
```
