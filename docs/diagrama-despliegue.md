# Diagrama de despliegue de PharmaGo

El diagrama principal está en notación UML de despliegue, adaptado del diagrama inicial del docente (versión Docker Compose) a la versión final en Kubernetes. Lleva:

- nodos con componentes estereotipados;
- el `Dockerfile` de cada imagen que construimos, con su dependencia `«manifests»`;
- el protocolo de cada conexión;
- zonas por señal: métricas, trazas y logs.

La caja `«node» minikube` es la única máquina. Las cajas 3D de adentro son los Deployments y DaemonSets, que en UML también son nodos (entornos de ejecución).

![Diagrama de despliegue UML de PharmaGo en Minikube](img/diagrama-despliegue-uml.png)

Debajo, tres vistas de detalle: el despliegue actual en Minikube (un nodo), el flujo de telemetría y la topología multinodo objetivo para la que quedan preparados los manifiestos. Manifiestos en `Implementacion K8S/Codigo/k8s/`.

## 1. Despliegue actual en Minikube

Un solo nodo (driver docker, 4 CPU, 6 GB) etiquetado `node-type=all`, de modo que la `nodeAffinity` de todos los componentes se cumple en el mismo nodo. Las `podAntiAffinity` son `preferred` y no impiden el scheduling.

```mermaid
flowchart TB
    host["Host Mac M2 · Docker Desktop<br/>navegador + kubectl port-forward"]

    subgraph node["Nodo minikube · label node-type=all · 4 CPU · 6 GB"]
        direction TB
        subgraph ns["Namespace pharmago"]
            direction TB

            subgraph fe["Frontend · pharmago/tier=frontend"]
                svcUi["Service pharmago-ui<br/>NodePort :80"]
                ui1["Pod pharmago-ui 1/2<br/>nginx :80"]
                ui2["Pod pharmago-ui 2/2<br/>nginx :80"]
            end

            subgraph be["Microservicios · pharmago/tier=backend"]
                svcGw["Service pharmago-api-gateway<br/>ClusterIP :80 · sessionAffinity ClientIP"]
                gw1["Pod api-gateway 1/2<br/>YARP + rate limit + breaker :80"]
                gw2["Pod api-gateway 2/2<br/>YARP + rate limit + breaker :80"]
                svcUs["Service pharmago-users-service<br/>ClusterIP :80"]
                us1["Pod users-service 1/2 :80"]
                us2["Pod users-service 2/2 :80"]
                svcPh["Service pharmago-pharmacy-service<br/>ClusterIP :80"]
                ph1["Pod pharmacy-service 1/2 :80"]
                ph2["Pod pharmacy-service 2/2 :80"]
            end

            subgraph datos["Datos · punto único de falla asumido"]
                svcDb["Service pharmago-db<br/>ClusterIP :1433"]
                db["Pod pharmago-db<br/>SQL Server 2019 Express, amd64 emulado<br/>1 réplica · strategy Recreate"]
            end

            subgraph obs["Observabilidad"]
                otel["Deployment otlp-collector<br/>:4317 OTLP gRPC · :8889 métricas"]
                jaeger["Deployment jaeger<br/>ClusterIP :16686 UI · :4317 ingesta"]
                prom["Deployment prometheus<br/>NodePort :9090"]
                graf["Deployment grafana<br/>NodePort :3000"]
                es["Deployment elasticsearch<br/>ClusterIP :9200"]
                kib["Deployment kibana<br/>NodePort :5601"]
                fb["DaemonSet fluent-bit :2020"]
                ne["DaemonSet node-exporter :9100"]
            end

            pdb["PodDisruptionBudget minAvailable 1<br/>gateway · users · pharmacy · ui"]
        end

        subgraph pv["PersistentVolumes hostPath /mnt/data · StorageClass local-storage"]
            pvSql["sql-pv 10Gi"]
            pvEs["elasticsearch-pv 10Gi"]
            pvProm["prometheus-pv 10Gi"]
            pvGraf["grafana-pv 5Gi"]
        end
    end

    host -->|"port-forward 4200"| svcUi
    host -->|"port-forward 5000 · apiUrl del frontend"| svcGw
    svcUi --> ui1
    svcUi --> ui2
    svcGw --> gw1
    svcGw --> gw2
    gw1 -->|"/api/users, roles, login, invitations"| svcUs
    gw2 --> svcUs
    gw1 -->|"/api/drug, pharmacy, purchases, stockrequest, ..."| svcPh
    gw2 --> svcPh
    svcUs --> us1
    svcUs --> us2
    svcPh --> ph1
    svcPh --> ph2
    us1 --> svcDb
    us2 --> svcDb
    ph1 --> svcDb
    ph2 --> svcDb
    svcDb --> db
    db --- pvSql
    es --- pvEs
    prom --- pvProm
    graf --- pvGraf
```

Notas de la vista:

- Cada microservicio corre en su propio Deployment, con un contenedor por pod y su propio Service ClusterIP. El navegador llama al gateway en `127.0.0.1:5000` (port-forward); el gateway es el único punto de entrada a la API.
- `kubectl port-forward svc/...` se ata a un solo pod: si ese pod se reemplaza, el forward se corta. Por eso la disponibilidad se mide desde dentro del clúster (`k8s/scripts/`).
- Puertos: gateway, users, pharmacy y ui escuchan en 80; SQL Server en 1433. Prometheus, Grafana y Kibana se exponen como NodePort para acceso desde el host.

## 2. Flujo de telemetría

```mermaid
flowchart LR
    subgraph apps["Microservicios"]
        gw["api-gateway"]
        us["users-service"]
        ph["pharmacy-service"]
    end

    otel["otlp-collector<br/>recibe :4317 · expone :8889"]
    prom["prometheus :9090<br/>scrape cada 5 s"]
    ne["node-exporter :9100"]
    cad["kubelet cAdvisor<br/>vía API server"]
    graf["grafana :3000<br/>dashboards y 9 alertas"]
    logs["/var/log/containers/*.log<br/>stdout de todos los pods"]
    fb["fluent-bit<br/>multiline.parser docker, cri"]
    es["elasticsearch :9200<br/>pharmago-logs-* y pharmago-alerts"]
    kib["kibana :5601"]
    jaeger["jaeger :16686"]

    gw -->|"OTLP gRPC: métricas y trazas"| otel
    us -->|"OTLP gRPC: métricas y trazas"| otel
    ph -->|"OTLP gRPC: métricas y trazas"| otel
    otel -->|"trazas"| jaeger
    prom -->|"scrape :8889"| otel
    prom -.->|"solo la serie up"| apps
    prom -->|scrape| ne
    prom -->|scrape| cad
    graf -->|PromQL| prom
    graf -->|"webhook de alertas"| es
    apps -.->|"stdout JSON"| logs
    logs --> fb
    fb -->|":9200"| es
    es --> kib
```

Las métricas de la aplicación llegan solo por OTLP (el servicio de origen queda en el label `exported_job` y la réplica en `exported_instance`). Los jobs que scrapean `/metrics` a través de cada Service descartan las muestras y quedan solo para la serie `up`: con 2 réplicas, scrapear por el Service alternaba entre pods y mezclaba los contadores.

## 3. Topología multinodo objetivo

Las reglas de ubicación de los manifiestos sirven tal cual en un clúster de varios nodos: alcanza con etiquetar los nodos y aplicarles las taints. Pasar la anti-affinity a `required` convierte la separación en una garantía. Además, las imágenes locales y los volúmenes `hostPath` hay que reemplazarlos (detalle al final de esta sección).

```mermaid
flowchart TB
    lb["Ingress / LoadBalancer<br/>reemplaza a port-forward"]

    subgraph cp["Control plane · 3 nodos · etcd en HA"]
        api["kube-apiserver · scheduler · controllers"]
    end

    subgraph fePool["Pool frontend · node-type=frontend · taint dedicated=frontend:NoSchedule"]
        f1["nodo fe-1<br/>pharmago-ui 1/2"]
        f2["nodo fe-2<br/>pharmago-ui 2/2"]
    end

    subgraph bePool["Pool backend · node-type=backend · taint dedicated=backend:NoSchedule"]
        b1["nodo be-1<br/>api-gateway 1/2"]
        b2["nodo be-2<br/>api-gateway 2/2"]
        b3["nodo be-3<br/>users-service 1/2"]
        b4["nodo be-4<br/>users-service 2/2"]
        b5["nodo be-5<br/>pharmacy-service 1/2"]
        b6["nodo be-6<br/>pharmacy-service 2/2"]
    end

    subgraph opsPool["Pool ops · node-type=ops · taint dedicated=ops:NoSchedule"]
        o1["nodo ops-1<br/>SQL Server o servicio gestionado"]
        o2["nodo ops-2<br/>elasticsearch · kibana"]
        o3["nodo ops-3<br/>prometheus · grafana · otlp-collector"]
    end

    ds["DaemonSets en todos los nodos<br/>fluent-bit · node-exporter<br/>con toleration operator Exists"]
    svcs["Services ClusterIP users y pharmacy<br/>kube-proxy reparte entre réplicas READY"]

    lb --> f1
    lb --> f2
    lb --> b1
    lb --> b2
    b1 --> svcs
    b2 --> svcs
    svcs --> b3
    svcs --> b4
    svcs --> b5
    svcs --> b6
    b3 --> o1
    b4 --> o1
    b5 --> o1
    b6 --> o1
    api -.-> bePool
    ds -.-> bePool
```

Reglas de colocación en esa topología:

| Regla | Mecanismo | Efecto |
|---|---|---|
| Backend solo en nodos backend | `nodeAffinity` required `node-type In [backend]` + taint `dedicated=backend:NoSchedule` + toleration en los pods backend | Ningún otro pod cae en esos nodos y el backend no sale de ellos |
| Microservicios distintos en nodos físicos distintos | `podAntiAffinity` **required** con `topologyKey: kubernetes.io/hostname` y selector `pharmago/tier=backend, app NotIn [propio]` | Cumple literalmente la rúbrica |
| Réplicas de un mismo microservicio separadas | `podAntiAffinity` required (o `topologySpreadConstraints` por zona) | La caída de un nodo deja viva la otra réplica |
| Frontend y ops aislados | mismas reglas con `frontend` y `ops`: `nodeAffinity` a su pool + toleration de su taint | Un pico de Elasticsearch no le quita CPU a la API |
| Logs y métricas de nodo en todos los nodos | DaemonSets fluent-bit y node-exporter con toleration `operator: Exists` | Atraviesan las taints de los tres pools |
| Datos persistentes que sobreviven a un cambio de nodo | PersistentVolumes de red con un StorageClass con provisioner (o cada PV atado a un nodo fijo con `kubernetes.io/hostname`); para la base, una gestionada o replicada | Si la base o Prometheus se reprograman en otra máquina, encuentran sus datos |

Con separación estricta entre microservicios y entre réplicas, el pool backend necesita 6 nodos (3 microservicios x 2 réplicas). Pueden ser chicos: cada pod pide 100m de CPU y 128Mi de memoria.

Qué cambia al pasar a esa topología:

- **En el clúster, no en los manifiestos:** crear los nodos, etiquetarlos y aplicarles las taints. Las tolerations y la `nodeAffinity` de todos los componentes ya están en los YAML, así que cada componente cae en su pool sin tocar las reglas de ubicación.
- **Anti-affinity:** pasarla de `preferred` a `required` en los tres Deployments de backend. Con `preferred` el scheduler separa si puede; con `required` la separación es una garantía, que es lo que pide la letra.
- **Volúmenes:** hoy son `hostPath` (una carpeta en el disco del nodo) atados a cualquier nodo `ops`. Con un solo nodo alcanza. Con varios, un pod que cambia de máquina encuentra la carpeta vacía, así que hay que reemplazarlos por almacenamiento de red.
- **Imágenes:** las cuatro propias (UI, gateway, users y pharmacy) se cargan hoy en el nodo con `minikube image load` y usan `imagePullPolicy: Never`. Con varios nodos tienen que estar en cada uno: lo normal es publicarlas en un registry y pasar a `IfNotPresent`, lo que cambia esos cuatro Deployments.
- **Acceso:** un Ingress o un LoadBalancer en lugar de `kubectl port-forward`.
