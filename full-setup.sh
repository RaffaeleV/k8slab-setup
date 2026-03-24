#!/usr/bin/env bash
set -euo pipefail

# full-setup.sh
# K8s lab: MicroK8s + OpenEBS/ZFS + MinIO + Online Boutique
#           + Pac-Man + WordPress + Kasten K10


# ---------------------------------------------------------------------------
# INITIAL CONFIGURATION -- change VM hostname and IP if needed
# ---------------------------------------------------------------------------

DETECTED_IP=$(hostname -I | awk '{print $1}')
DETECTED_HOSTNAME=$(hostname)

echo "--- VM Configuration ---"
echo "  Detected hostname : $DETECTED_HOSTNAME"
echo "  Detected IP       : $DETECTED_IP"
echo ""

read -rp "Hostname to use  [enter = $DETECTED_HOSTNAME]: " INPUT_HOSTNAME
read -rp "VM IP address    [enter = $DETECTED_IP]: "       INPUT_IP

VM_HOSTNAME="${INPUT_HOSTNAME:-$DETECTED_HOSTNAME}"
VMIP="${INPUT_IP:-$DETECTED_IP}"

if [[ "$VM_HOSTNAME" != "$DETECTED_HOSTNAME" ]]; then
  echo "==> Setting hostname: $VM_HOSTNAME"
  sudo hostnamectl set-hostname "$VM_HOSTNAME"
  sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$VM_HOSTNAME/" /etc/hosts
fi

if [[ "$VMIP" != "$DETECTED_IP" ]]; then
  echo "WARN: IP manually set to $VMIP -- make sure the network is configured accordingly."
fi

echo ""
echo "  VM hostname : $VM_HOSTNAME"
echo "  VM IP       : $VMIP"
echo ""


# ---------------------------------------------------------------------------
# PART 1 -- KUBERNETES + STORAGE + MINIO + ONLINE BOUTIQUE
# ---------------------------------------------------------------------------

ZFSDISK=/dev/sdb

if [ ! -b "$ZFSDISK" ]; then
  echo "ERROR: ZFS disk $ZFSDISK not found"; exit 1
fi

VMIP_BASE=$(echo "$VMIP" | cut -d. -f1-3)
VMIP_LAST=$(echo "$VMIP" | cut -d. -f4)
FIRSTIP="${VMIP_BASE}.$((VMIP_LAST + 1))"
LASTIP="${VMIP_BASE}.$((VMIP_LAST + 10))"

echo "MetalLB range     : $FIRSTIP - $LASTIP"
read -rp "Press ENTER to confirm, or type a custom range (e.g. 192.168.1.50-192.168.1.60): " CUSTOM_RANGE

if [[ -n "$CUSTOM_RANGE" ]]; then
  FIRSTIP=$(echo "$CUSTOM_RANGE" | cut -d- -f1 | tr -d ' ')
  LASTIP=$(echo "$CUSTOM_RANGE"  | cut -d- -f2 | tr -d ' ')
  echo "Using custom range: $FIRSTIP - $LASTIP"
fi


sudo apt-get update -y && sudo apt-get install -y jq zfsutils-linux

wget -qO- https://get.helm.sh/helm-v3.17.0-linux-amd64.tar.gz | tar -xz
sudo mv ./linux-amd64/helm /usr/local/bin/helm

KUBECTL_VER=$(wget -qO- https://dl.k8s.io/release/stable.txt)
sudo wget -qO /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl"
sudo chmod 755 /usr/local/bin/kubectl

for tool in kubens kubectx; do
  wget -qO- "https://github.com/ahmetb/kubectx/releases/download/v0.9.5/${tool}_v0.9.5_linux_x86_64.tar.gz" \
    | tar -xz "${tool}"
  sudo mv "./${tool}" /usr/local/bin/
done


sudo snap install microk8s --classic --channel=1.32/stable
sudo microk8s.start
sudo microk8s.status --wait-ready

sudo microk8s enable dns
sudo microk8s enable metallb:"$FIRSTIP-$LASTIP"
sudo microk8s enable ingress

sudo usermod -aG microk8s "$(whoami)"
sudo mkdir -p ~/.kube
sudo chown -R "$(whoami)" ~/.kube


sudo zpool create zfspv-pool "$ZFSDISK"
sudo zpool status


sudo su "$(whoami)" -c "microk8s config > ~/.kube/config"
chmod 600 ~/.kube/config

KUBENODE=$(kubectl get node -o jsonpath='{.items[0].metadata.name}')
echo "kubectl is working -- node: $KUBENODE"

kubectl label node "$KUBENODE" openebs.io/rack=rack1


wget -qO zfs-operator.yaml https://openebs.github.io/charts/zfs-operator.yaml
sed 's|/var/lib/kubelet/|/var/snap/microk8s/common/var/lib/kubelet/|g' \
  zfs-operator.yaml > zfs-operator-microk8s.yaml
kubectl apply -f zfs-operator-microk8s.yaml


kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-zfspv
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
parameters:
  recordsize: "4k"
  compression: "off"
  dedup: "off"
  fstype: "zfs"
  poolname: "zfspv-pool"
provisioner: zfs.csi.openebs.io
EOF

kubectl get sc


kubectl apply -f - <<EOF
kind: VolumeSnapshotClass
apiVersion: snapshot.storage.k8s.io/v1
metadata:
  name: zfspv-snapclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
driver: zfs.csi.openebs.io
deletionPolicy: Delete
EOF


kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: csi-zfspv
spec:
  storageClassName: openebs-zfspv
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 4Gi
EOF

echo "Waiting for PVC to be Bound..."
until [ "$(kubectl get pvc csi-zfspv -o jsonpath='{.status.phase}')" = "Bound" ]; do
  sleep 1
done
echo "PVC smoke-test passed"
kubectl get pvc
sleep 1
kubectl delete "$(kubectl get pvc -o name)"


kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: minios3
---
apiVersion: v1
kind: Service
metadata:
  name: minios3
  namespace: minios3
  labels:
    app: minios3
spec:
  type: LoadBalancer
  selector:
    app: minios3
  ports:
  - port: 80
    targetPort: 80
    name: api
  - port: 9001
    targetPort: 9001
    name: console
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: minios3
  namespace: minios3
spec:
  serviceName: minios3
  replicas: 1
  selector:
    matchLabels:
      app: minios3
  template:
    metadata:
      labels:
        app: minios3
    spec:
      containers:
      - name: minios3
        image: minio/minio:latest
        args: ["server", "/data", "--address", ":80", "--console-address", ":9001"]
        ports:
        - containerPort: 80
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 10Gi
EOF

echo "Waiting for MinIO pod to be ready..."
kubectl -n minios3 wait --for=condition=ready pod/minios3-0 --timeout=180s
MINIO_IP=$(kubectl get svc minios3 -n minios3 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')


kubectl create namespace boutique
kubectl apply -n boutique \
  -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml

echo "Waiting for Online Boutique pods to be ready..."
kubectl -n boutique wait --for=condition=ready pod --all --timeout=300s
BOUTIQUE_IP=$(kubectl get svc frontend-external -n boutique -o jsonpath='{.status.loadBalancer.ingress[0].ip}')


# ---------------------------------------------------------------------------
# PART 2 -- DEMO APP: PAC-MAN (Node.js + MongoDB)
# ---------------------------------------------------------------------------

PACMAN_NS=pacman

echo ""
echo "--- PART 2: Pac-Man demo ---"

kubectl create namespace "$PACMAN_NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pacman-clusterrole
rules:
- apiGroups: [""]
  resources: [nodes, services, endpoints, pods]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pacman-rolebinding
  namespace: ${PACMAN_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pacman-clusterrole
subjects:
- kind: ServiceAccount
  name: default
  namespace: ${PACMAN_NS}
EOF

echo "Deploying MongoDB..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mongo-storage
  namespace: ${PACMAN_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongo
  namespace: ${PACMAN_NS}
  labels:
    name: mongo
spec:
  replicas: 1
  selector:
    matchLabels:
      name: mongo
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        name: mongo
    spec:
      containers:
      - name: mongo
        image: mongo:4.4
        ports:
        - containerPort: 27017
          name: mongo
        volumeMounts:
        - name: mongo-db
          mountPath: /data/db
      volumes:
      - name: mongo-db
        persistentVolumeClaim:
          claimName: mongo-storage
---
apiVersion: v1
kind: Service
metadata:
  name: mongo
  namespace: ${PACMAN_NS}
  labels:
    name: mongo
spec:
  selector:
    name: mongo
  ports:
  - port: 27017
    targetPort: 27017
EOF

echo "Deploying Pac-Man frontend..."
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pacman
  namespace: ${PACMAN_NS}
  labels:
    name: pacman
spec:
  replicas: 1
  selector:
    matchLabels:
      name: pacman
  template:
    metadata:
      labels:
        name: pacman
    spec:
      containers:
      - name: pacman
        image: mbentley/pacman-nodejs
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http-server
        env:
        - name: MONGO_SERVICE_HOST
          value: mongo
        - name: MONGO_AUTH_USER
          value: ""
        - name: MONGO_AUTH_PWD
          value: ""
        - name: MONGO_DATABASE
          value: pacman
        - name: MY_MONGO_PORT
          value: "27017"
        - name: GET_HOSTS_FROM
          value: env
        - name: MY_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: MY_POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: MY_POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: MY_POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
---
apiVersion: v1
kind: Service
metadata:
  name: pacman
  namespace: ${PACMAN_NS}
  labels:
    name: pacman
spec:
  type: LoadBalancer
  selector:
    name: pacman
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
EOF

echo "    Waiting for MongoDB..."
kubectl rollout status deployment/mongo -n "$PACMAN_NS" --timeout=300s

echo "    Waiting for Pac-Man..."
kubectl rollout status deployment/pacman -n "$PACMAN_NS" --timeout=300s

echo -n "    Waiting for LoadBalancer IP ."
until kubectl get svc pacman -n "$PACMAN_NS" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null \
        | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; do
  sleep 3; echo -n "."; done
echo ""

PACMAN_IP=$(kubectl get svc pacman -n "$PACMAN_NS" \
              -o jsonpath='{.status.loadBalancer.ingress[0].ip}')


# ---------------------------------------------------------------------------
# PART 3 -- DEMO APP: WORDPRESS + MYSQL
# ---------------------------------------------------------------------------

WP_NS=wordpress
MYSQL_ROOT_PASSWORD=k10demo
MYSQL_PASSWORD=k10demo

echo ""
echo "--- PART 3: WordPress + MySQL demo ---"

kubectl create namespace "$WP_NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
  namespace: ${WP_NS}
stringData:
  root-password: "${MYSQL_ROOT_PASSWORD}"
  password:      "${MYSQL_PASSWORD}"
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
  namespace: ${WP_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: ${WP_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: root-password
        - name: MYSQL_DATABASE
          value: wordpress
        - name: MYSQL_USER
          value: wordpress
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: password
        ports:
        - containerPort: 3306
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
        readinessProbe:
          exec:
            command: ["mysqladmin", "ping", "-h", "localhost"]
          initialDelaySeconds: 20
          periodSeconds: 5
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: mysql-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: ${WP_NS}
spec:
  selector:
    app: mysql
  ports:
  - port: 3306
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wordpress-pvc
  namespace: ${WP_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress
  namespace: ${WP_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wordpress
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: wordpress
    spec:
      containers:
      - name: wordpress
        image: wordpress:6-apache
        env:
        - name: WORDPRESS_DB_HOST
          value: mysql
        - name: WORDPRESS_DB_NAME
          value: wordpress
        - name: WORDPRESS_DB_USER
          value: wordpress
        - name: WORDPRESS_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: password
        ports:
        - containerPort: 80
        volumeMounts:
        - name: data
          mountPath: /var/www/html
        readinessProbe:
          httpGet:
            path: /wp-login.php
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: wordpress-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: wordpress
  namespace: ${WP_NS}
spec:
  type: LoadBalancer
  selector:
    app: wordpress
  ports:
  - port: 80
    targetPort: 80
EOF

echo "    Waiting for MySQL..."
kubectl rollout status deployment/mysql -n "$WP_NS" --timeout=180s

echo "    Waiting for WordPress..."
kubectl rollout status deployment/wordpress -n "$WP_NS" --timeout=180s

echo -n "    Waiting for LoadBalancer IP ."
until kubectl get svc wordpress -n "$WP_NS" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null \
        | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; do
  sleep 3; echo -n "."; done
echo ""

WP_IP=$(kubectl get svc wordpress -n "$WP_NS" \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}')


# ---------------------------------------------------------------------------
# PART 4 -- KASTEN K10
# ---------------------------------------------------------------------------

K10_NS=kasten-io

echo ""
echo "--- PART 4: Kasten K10 ---"

echo "==> Checking prerequisites..."

if ! kubectl get nodes &>/dev/null; then
  echo "ERROR: kubectl cannot reach the cluster."; exit 1
fi

if ! kubectl get daemonset -n ingress nginx-ingress-microk8s-controller &>/dev/null; then
  echo "ERROR: MicroK8s ingress controller not found."
  echo "Run:  sudo microk8s enable ingress"
  exit 1
fi

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_IP=$(kubectl get node "$NODE_NAME" \
            -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

echo "    Node     : $NODE_NAME"
echo "    Node IP  : $NODE_IP  (this will be the HTTPS address)"
echo ""

echo "--- K10 Step 1/4: Installing Kasten K10 ---"

helm repo add kasten https://charts.kasten.io/ --force-update
helm repo update kasten

kubectl create namespace "$K10_NS" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install k10 kasten/k10 \
  --namespace "$K10_NS" \
  --set auth.tokenAuth.enabled=true \
  --wait --timeout=15m

echo ""
echo "    K10 pods:"
kubectl get pods -n "$K10_NS" --no-headers \
  | awk '{printf "      %-50s %s\n", $1, $3}'

echo ""
echo -n "    Checking internal 'gateway' service ... "
if ! kubectl get svc gateway -n "$K10_NS" &>/dev/null; then
  echo "FAIL -- available services:"
  kubectl get svc -n "$K10_NS"
  echo "ERROR: 'gateway' ClusterIP not found."; exit 1
fi
K10_PORT=$(kubectl get svc gateway -n "$K10_NS" \
             -o jsonpath='{.spec.ports[0].port}')
echo "OK  (port $K10_PORT)"

echo -n "    HTTP smoke-test on gateway:$K10_PORT ... "
TEST_POD=$(kubectl run k10-curl-test --image=curlimages/curl:latest \
             --restart=Never --rm -i -q \
             --namespace "$K10_NS" \
             -- curl -sS -o /dev/null -w "%{http_code}" \
                "http://gateway.${K10_NS}.svc.cluster.local:${K10_PORT}/k10/" \
             2>/dev/null || echo "failed")
echo "HTTP $TEST_POD"
if [[ "$TEST_POD" == "failed" ]]; then
  echo "    WARN: HTTP smoke-test failed. Check K10 pods before continuing."
fi

echo ""
echo "--- K10 Step 2/4: TLS certificate for IP $NODE_IP ---"

CERT_DIR=$(mktemp -d)
trap 'rm -rf "$CERT_DIR"' EXIT

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "$CERT_DIR/tls.key" \
  -out    "$CERT_DIR/tls.crt" \
  -subj   "/CN=$NODE_IP/O=Kasten-K10-Lab" \
  -addext "subjectAltName=IP:$NODE_IP" \
  2>/dev/null

echo "    SAN    : $(openssl x509 -in "$CERT_DIR/tls.crt" -noout -ext subjectAltName | tail -1)"
echo "    Expiry : $(openssl x509 -in "$CERT_DIR/tls.crt" -noout -enddate | cut -d= -f2)"

kubectl create secret tls kasten-tls \
  --cert="$CERT_DIR/tls.crt" \
  --key="$CERT_DIR/tls.key" \
  --namespace "$K10_NS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "    Secret 'kasten-tls' saved in namespace $K10_NS"

echo ""
echo "--- K10 Step 3/4: Creating Ingress resource ---"

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kasten-ingress
  namespace: ${K10_NS}
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-buffer-size: "256k"
spec:
  ingressClassName: public
  tls:
  - secretName: kasten-tls
  rules:
  - http:
      paths:
      - path: /k10
        pathType: Prefix
        backend:
          service:
            name: gateway
            port:
              number: ${K10_PORT}
EOF

echo "    Ingress 'kasten-ingress' created"
echo "    Waiting for ingress to be reconciled..."
sleep 5
kubectl get ingress kasten-ingress -n "$K10_NS"

echo ""
echo "--- K10 Step 4/4: Service account and login token ---"

kubectl create serviceaccount kasten-sa \
  --namespace "$K10_NS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create clusterrolebinding kasten-sa-binding \
  --clusterrole=cluster-admin \
  --serviceaccount="${K10_NS}:kasten-sa" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kasten-sa-token
  namespace: ${K10_NS}
  annotations:
    kubernetes.io/service-account.name: kasten-sa
type: kubernetes.io/service-account-token
EOF

echo -n "    Waiting for token ."
until kubectl get secret kasten-sa-token -n "$K10_NS" \
        -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; do
  sleep 2; echo -n "."; done
echo " OK"

KASTEN_TOKEN=$(kubectl get secret kasten-sa-token -n "$K10_NS" \
                 -o jsonpath='{.data.token}' | base64 -d)

kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: zfspv-snapclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
    k10.kasten.io/is-snapshot-class: "true"
driver: zfs.csi.openebs.io
deletionPolicy: Delete
EOF


# ---------------------------------------------------------------------------
# FINAL SUMMARY
# ---------------------------------------------------------------------------

cat <<SUMMARY

===========================================================================
SETUP COMPLETE
===========================================================================

Cluster
  Node              : $KUBENODE
  MetalLB range     : $FIRSTIP - $LASTIP

Storage
  ZFS pool          : zfspv-pool on $ZFSDISK
  StorageClass      : openebs-zfspv (default)

MinIO S3
  API               : http://$MINIO_IP
  Console           : http://$MINIO_IP:9001
  Internal DNS      : http://minios3.minios3
  Credentials       : minioadmin / minioadmin

Online Boutique
  URL               : http://$BOUTIQUE_IP

Pac-Man (Kasten backup demo)
  URL               : http://$PACMAN_IP
  Namespace         : pacman
  High scores       : MongoDB PVC mongo-storage (5Gi, ZFS snapshot)

WordPress + MySQL (Kasten backup demo)
  URL               : http://$WP_IP
  Namespace         : wordpress
  PVCs              : mysql-pvc (5Gi)  wordpress-pvc (5Gi)

Kasten K10
  Dashboard         : https://$NODE_IP/k10/#/
  TLS               : self-signed -- accept the browser warning once

K10 Login token:
SUMMARY

echo "$KASTEN_TOKEN"

cat <<SUMMARY2

===========================================================================
K10 Debug commands
===========================================================================
  kubectl get ingress -n kasten-io
  kubectl logs -n ingress ds/nginx-ingress-microk8s-controller

===========================================================================
All LoadBalancer services:
SUMMARY2

kubectl get svc -A --field-selector spec.type=LoadBalancer \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip,PORT:.spec.ports[*].port'