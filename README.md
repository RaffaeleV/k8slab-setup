# K8s Lab — MicroK8s + OpenEBS/ZFS + MinIO + Kasten K10

> Inspired by the original work of **[tdewin](https://gist.github.com/tdewin)**. 
> Thank you for sharing your MicroK8s + Kasten setup script at
> https://gist.github.com/tdewin/46d0c5e81481fe91f5c84184cb21e949

A single script that builds a complete, ready-to-demo Kubernetes lab on a single Ubuntu VM.
It installs MicroK8s, ZFS-backed persistent storage via OpenEBS, MinIO as an S3 target,
three demo workloads, and Kasten K10 for backup and restore, all in one unattended run.

---

## What gets installed

| Component | Details |
|---|---|
| **MicroK8s 1.32** | Single-node Kubernetes cluster |
| **MetalLB** | LoadBalancer IP pool for bare-metal |
| **OpenEBS ZFS CSI** | Default StorageClass backed by a ZFS pool on `/dev/sdb` |
| **MinIO** | S3-compatible object storage (Kasten export target) |
| **Online Boutique** | Google microservices demo app |
| **Pac-Man** | Node.js + MongoDB demo (Kasten backup target) |
| **WordPress + MySQL** | Classic CMS stack (Kasten backup target) |
| **Kasten K10** | Kubernetes backup, restore and disaster recovery |

---

## Prerequisites

- Ubuntu VM (22.04 or 24.04 recommended)
- Minimum specs: **4 vCPU / 8 GB RAM**
- A dedicated disk at **`/dev/sdb`** (40 GB or more recommended) for the ZFS pool
- Internet access from the VM
- A user with `sudo` privileges
- A free IP range on the local network for MetalLB (10 addresses are enough)

---

## Usage

```bash
chmod +x full-setup.sh
./full-setup.sh
```

The script asks two questions at startup, then runs unattended for approximately 15–25 minutes.

### Question 1 — VM hostname and IP

```
--- VM Configuration ---
  Detected hostname : k8s-lab
  Detected IP       : 192.168.1.100

Hostname to use  [enter = k8s-lab]:
VM IP address    [enter = 192.168.1.100]:
```

Press **Enter** to accept the detected values, or type a custom hostname and/or IP.
If the hostname is changed, `hostnamectl` is called immediately and `/etc/hosts` is updated.

### Question 2 — MetalLB IP range

```
MetalLB range     : 192.168.1.101 - 192.168.1.110
Press ENTER to confirm, or type a custom range (e.g. 192.168.1.50-192.168.1.60):
```

Press **Enter** to use the proposed range (`VM_IP+1` through `VM_IP+10`),
or type a custom range. The range must be free on the local network.

---

## Accessing the lab

All external IPs are printed in the final summary at the end of the run.
They are LoadBalancer addresses assigned by MetalLB from the range you confirmed above.

| Service | URL | Credentials |
|---|---|---|
| Online Boutique | `http://<BOUTIQUE_IP>` | none |
| Pac-Man | `http://<PACMAN_IP>` | none |
| WordPress | `http://<WP_IP>` | set on first visit |
| MinIO Console | `http://<MINIO_IP>:9001` | `minioadmin` / `minioadmin` |
| MinIO S3 API | `http://<MINIO_IP>` | `minioadmin` / `minioadmin` |
| Kasten K10 | `https://<NODE_IP>/k10/#/` | bearer token (see below) |

### Kasten K10 login token

The bearer token is printed at the end of the script output.
To retrieve it at any time:

```bash
kubectl get secret kasten-sa-token -n kasten-io \
  -o jsonpath='{.data.token}' | base64 -d
```

The K10 dashboard uses a self-signed TLS certificate — accept the browser warning once on first visit.

---

## Kasten K10 backup/restore demo

The Pac-Man and WordPress namespaces are pre-configured as demo targets for K10.
A typical demo flow:

1. **Connect MinIO as a Location Profile** in the K10 dashboard.
   - Type: S3 Compatible
   - Endpoint: `http://minios3.minios3`
   - Access key / Secret: `minioadmin` / `minioadmin`
   - Create a bucket of your choice

2. **Create a Policy** targeting the `pacman` or `wordpress` namespace,
   using the `zfspv-snapclass` VolumeSnapshotClass.

3. **Run the policy** manually to take a snapshot and export it to MinIO.

4. **Simulate data loss** — delete the namespace:
   ```bash
   kubectl delete ns pacman
   ```

5. **Restore from the K10 dashboard** — the namespace, PVCs, deployments and all data
   are fully recovered from the exported snapshot.

---

## Useful commands

```bash
# All LoadBalancer IPs at a glance
kubectl get svc -A --field-selector spec.type=LoadBalancer

# K10 pod status
kubectl get pods -n kasten-io

# Ingress status
kubectl get ingress -n kasten-io

# Ingress controller logs
kubectl logs -n ingress ds/nginx-ingress-microk8s-controller

# Switch namespace context
kubens pacman
kubens wordpress
kubens kasten-io
```

---

## Architecture overview

```
VM (single node)
  MicroK8s 1.32
    MetalLB           -- assigns external IPs from your local range
    nginx Ingress     -- HTTPS termination for K10 dashboard
    OpenEBS ZFS CSI   -- PVC provisioner on /dev/sdb (zfspv-pool)
    |
    +-- minios3        (LoadBalancer)  S3 storage / K10 export target
    +-- boutique       (LoadBalancer)  Online Boutique demo
    +-- pacman         (LoadBalancer)  Pac-Man + MongoDB
    +-- wordpress      (LoadBalancer)  WordPress + MySQL
    +-- kasten-io      (Ingress/HTTPS) Kasten K10 dashboard
```

---

## License

This project is released for lab and educational use.

