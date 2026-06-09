# DryvIQ SysCheck

![DryvIQ Logo](https://img.shields.io/badge/DryvIQ-SysCheck-blue?style=for-the-badge)

A comprehensive system verification tool for DryvIQ deployments across different Kubernetes environments. This tool validates system requirements, network connectivity, security policies, and deployment readiness for DryvIQ platform installations.

## Quick Start

```bash
cd dryviq-system-check
find . -name "*.sh" -type f -exec chmod +x {} +
./syscheck.sh
```

## Overview

The DryvIQ SysCheck performs automated validation of your Kubernetes environment to ensure it meets all requirements for a successful DryvIQ deployment. It supports three deployment environments:

- **AKS** (Azure Kubernetes Service)
- **EKS** (Amazon Elastic Kubernetes Service)  
- **K3s** (On-premises Kubernetes)

## Features

- **Interactive or Non-Interactive**: Prompt-driven, or fully scriptable via flags/env for repeatable/CI runs
- **Kubernetes Context Management**: Automatically detect and switch between kubectl contexts
- **Comprehensive Health Checks**: 16 validation categories covering networking, storage, DNS, time sync, and cloud config
- **Color-coded Output**: Easy-to-read status indicators (PASS/WARN/FAIL/SKIP/INFO)
- **Summary Reporting**: Final summary table with all check results
- **Verbose and Debug Modes**: Additional logging for troubleshooting

## System Checks

The tool performs the following checks in sequence:

| Check | Script | Environment | Description |
|-------|--------|-------------|-------------|
| 🛡️ **Firewall** | `check_firewall.sh` | K3s only | Validates network ports are open for K3s communication:<br/>• **TCP**: 6443 (API), 10250 (kubelet), 443/80 (ingress), 179 (Calico BGP)<br/>• **UDP**: 4789 (Calico VXLAN)<br/>• **Optional**: 2379-2380 (etcd HA) |
| ⏱️ **Time Sync** | `check_time_sync.sh` | K3s only | Verifies the node clock is NTP-synchronized (timedatectl/chrony/ntpd). Clock skew breaks TLS, etcd quorum, and token auth. Managed by the provider on AKS/EKS. |
| 🖥️ **Machine Types** | `check_instances.sh` | All | Validates compute resources and configurations:<br/>• **K3s**: Hardware requirements (master: 8c/16GB/512GB, pg: 8c/32GB/1TB, etc.)<br/>• **AKS/EKS**: Node pool configurations and instance types |
| 📊 **Node Capacity** | `check_capacity.sh` | All | Node Ready state, MemoryPressure/DiskPressure/PIDPressure, approximate allocatable CPU/RAM, and blocking ResourceQuota/LimitRange in the target namespace. |
| 🏷️ **Node Labels** | `check_node_labels.sh` | All | Validates node labeling for workload scheduling:<br/>• **AKS**: Required pools (migration, discover, dryviqpool, clickhouse, proxy)<br/>• **EKS/K3s**: Custom node labels and taints/tolerations |
| ⚙️ **Tool Versions** | `check_versions.sh` | All | Verifies CLI tools meet minimum versions:<br/>• **kubectl client + cluster server**: ≥ v1.29<br/>• **helm**: ≥ v3.0<br/>• **Cloud CLIs**: az (AKS), aws (EKS) presence |
| 🔤 **DNS** | `check_dns.sh` | All | CoreDNS/kube-dns pod health and replica count, in-cluster service resolution (`kubernetes.default.svc.cluster.local`), and external resolution from inside a pod. |
| 🌐 **Networking** | `check_networking.sh` | All | Tests external egress to required endpoints. In-cluster for AKS/EKS, host-path for K3s; honors proxy env, classifies failures (DNS/TCP/TLS interception), optional tooling endpoints WARN instead of FAIL. |
| 📥 **Image Pull** | `check_image_pull.sh` | All | Validates the real pull path: registry Docker v2 API + blob/layer host reachability, with an optional live in-cluster pull (`PREFLIGHT_TEST_IMAGE`/`PREFLIGHT_PULL_SECRET`). |
| ☁️ **Cloud Network** | `check_cloud_network.sh` | AKS/EKS only | **AKS**: outbound type (flags userDefinedRouting), private API server, managed outbound IP/SNAT capacity.<br/>**EKS**: subnet free-IP count (VPC-CNI exhaustion), API endpoint access, VPC endpoints for ECR/S3/STS. |
| 🔗 **On-Prem Network** | `check_onprem_network.sh` | K3s only | Validates inter-node communication:<br/>• Pod→Pod overlay, Pod→Service, Pod→Node paths<br/>• Exercises VXLAN/BGP and kube-proxy routing |
| 🔀 **Load Balancer** | `check_loadbalancer.sh` | AKS/EKS only | Provisions a temporary `Service type=LoadBalancer` and waits for an external address; checks for an IngressClass. Catches subnet/SNAT exhaustion, missing annotations, missing ingress controller. |
| 💾 **Storage** | `check_storage.sh` | All | Confirms a default StorageClass and live-provisions a PVC + pod to verify the CSI/provisioner actually binds and mounts (then cleans up). |
| 🧩 **Admission Constraints** | `check_constraints.sh` | All | Validates Kubernetes security and admission policies:<br/>• Pod Security Standards (PSA) enforcement<br/>• Gatekeeper/Kyverno policies<br/>• Server-side dry-run probes for common admission blocks |
| 🚧 **Network Policies** | `check_network_policies.sh` | All | Examines network policies affecting DryvIQ:<br/>• Lists existing NetworkPolicy resources<br/>• Detects namespace-wide default-deny patterns<br/>• Surfaces Calico global policies |
| 📦 **Database Connectivity** | `check_db_connectivity.sh` | AKS/EKS only | Tests in-cluster connectivity to external databases:<br/>• Deploys temporary test pods for validation<br/>• Tests TCP connectivity to PostgreSQL/Aurora endpoints<br/>• Uses busybox + netcat for lightweight testing<br/>• Automatically cleans up test resources |

## Usage

### Basic Usage
```bash
./syscheck.sh
```

### With Verbose Output
```bash
./syscheck.sh --verbose
```

### With Debug Information
```bash
./syscheck.sh --debug
```

### Combined Options
```bash
./syscheck.sh --verbose --debug
```

### Non-Interactive / Scripted Usage
All prompts can be supplied up front via flags (or the equivalent env vars
`ENVIRONMENT`, `RESOURCE_GROUP`, `CLUSTER_NAME`, `DB_ENDPOINTS`), making runs
repeatable and CI-friendly:

```bash
# AKS, no prompts
./syscheck.sh --non-interactive \
  --env aks --context my-aks-ctx \
  --resource-group my-rg --cluster my-cluster \
  --db-endpoints "pg.example.com:5432"

# K3s, current context
./syscheck.sh -y --env k3s
```

## Interactive Prompts

The script will prompt you for:

1. **Environment Selection**: Choose between AKS (1), EKS (2), or K3s (3)
2. **Kubernetes Context**: Select from available kubectl contexts
3. **Cloud-Specific Information**:
   - **AKS**: Resource Group and Cluster Name
   - **EKS**: Cluster Name
   - **K3s**: Node information (manual input)
4. **Database Endpoints** (optional): PostgreSQL/Aurora endpoints for connectivity testing

## Output Format

Each check produces status indicators:

- **[PASS]** ✅ - Check completed successfully
- **[WARN]** ⚠️ - Check passed with warnings
- **[FAIL]** ❌ - Check failed, requires attention
- **[SKIP]** ⏭️ - Check skipped (not applicable to environment)

### Example Output
```
🛡️  FIREWALL
    [PASS] All required ports are accessible
    [WARN] Optional port 2380 not accessible (not needed for single-node)

🖥️  MACHINE TYPES  
    [PASS] All node pools meet minimum requirements
    [PASS] Sufficient compute resources available

🌐  NETWORKING
    [PASS] stackgres.io reachable
    [PASS] dryviq.azurecr.io reachable
    [FAIL] api.portalarchitects.com not reachable
```

## Environment Variables

The following environment variables are used internally and set based on user input:

- `ENVIRONMENT`: Target environment (aks/eks/k3s)
- `RESOURCE_GROUP`: Azure resource group (AKS only)
- `CLUSTER_NAME`: Kubernetes cluster name
- `DB_ENDPOINTS`: Database endpoints for connectivity testing

## File Structure

```
dryviq-system-check/
├── syscheck.sh              # Main script
└── checks/                  # Individual check scripts
    ├── common.sh                  # Shared helpers + centralized endpoint lists
    ├── check_firewall.sh          # Firewall/port validation (K3s)
    ├── check_time_sync.sh         # NTP/clock-sync validation (K3s)
    ├── check_instances.sh         # Instance/hardware validation
    ├── check_capacity.sh          # Node Ready/pressure + quota validation
    ├── check_node_labels.sh       # Node labeling validation
    ├── check_versions.sh          # Tool/cluster/cloud-CLI version checks
    ├── check_dns.sh               # CoreDNS health + resolution tests
    ├── check_networking.sh        # External egress tests
    ├── check_image_pull.sh        # Registry pull-path validation
    ├── check_cloud_network.sh     # AKS/EKS VPC/outbound config
    ├── check_onprem_network.sh    # On-prem intra-cluster network tests
    ├── check_loadbalancer.sh      # LoadBalancer/Ingress provisioning (AKS/EKS)
    ├── check_storage.sh           # StorageClass + PVC provisioning test
    ├── check_constraints.sh       # Security/admission policies
    ├── check_network_policies.sh  # Network policy validation
    └── check_db_connectivity.sh   # Database connectivity tests
```

### Tuning via Environment Variables

Several checks accept overrides (sensible defaults otherwise):

| Variable | Used by | Purpose |
|----------|---------|---------|
| `PREFLIGHT_TEST_IMAGE` / `PREFLIGHT_PULL_SECRET` | image pull | Do a live in-cluster pull of a real image |
| `PREFLIGHT_REGISTRY` / `PREFLIGHT_BLOB_HOST` | image pull | Override registry / layer host |
| `PREFLIGHT_MIN_FREE_IPS` | cloud network | Subnet free-IP threshold (EKS) |
| `PREFLIGHT_CURL_MAX_TIME` | networking, image pull | Per-request egress timeout |
| `PREFLIGHT_LB_TIMEOUT_SECS` | load balancer | Wait time for an external address |
| `PREFLIGHT_PVC_TIMEOUT_SECS` | storage | Wait time for PVC to bind |
| `TARGET_NAMESPACE` | constraints, capacity | Namespace DryvIQ will deploy into |

## Troubleshooting

### Common Issues

1. **kubectl not found**
   ```bash
   # Install kubectl
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   chmod +x kubectl && sudo mv kubectl /usr/local/bin/
   ```

2. **Wrong kubectl context**
   ```bash
   # List available contexts
   kubectl config get-contexts
   
   # Switch context
   kubectl config use-context <context-name>
   ```

3. **Permission denied**
   ```bash
   chmod +x syscheck.sh
   chmod +x checks/*.sh
   ```

4. **Network connectivity failures**
   - Check firewall rules
   - Verify DNS resolution
   - Test connectivity manually: `curl -I https://endpoint.com`

### Debug Mode

Use `--debug` flag for detailed troubleshooting information:
```bash
./syscheck.sh --debug
```

This provides:
- Execution timestamps
- File permissions and paths
- Environment variable values
- Detailed command output
- Script execution flow

## Prerequisites

- **kubectl** (v1.29+)
- **helm** (v3.0+)
- **bash** shell
- Network access to target Kubernetes cluster
- Appropriate cloud CLI tools (az for AKS, aws for EKS)

## License

This tool is part of the DryvIQ platform deployment toolkit.

## Support

For issues or questions regarding the DryvIQ SysCheck:

1. Check the debug output with `--debug` flag
2. Review the specific failing check script in the `checks/` directory
3. Ensure all prerequisites are met
4. Contact your DryvIQ support team with the full output

---

*This tool ensures your environment is ready for a successful DryvIQ deployment. Run it before beginning any installation process.*