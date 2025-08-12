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

- **Interactive Environment Selection**: Choose your target deployment environment
- **Kubernetes Context Management**: Automatically detect and switch between kubectl contexts
- **Comprehensive Health Checks**: 9 different validation categories
- **Color-coded Output**: Easy-to-read status indicators (PASS/WARN/FAIL/SKIP)
- **Summary Reporting**: Final summary table with all check results
- **Verbose and Debug Modes**: Additional logging for troubleshooting

## System Checks

The tool performs the following checks in sequence:

| Check | Script | Environment | Description |
|-------|--------|-------------|-------------|
| 🛡️ **Firewall** | `check_firewall.sh` | K3s only | Validates network ports are open for K3s communication:<br/>• **TCP**: 6443 (API), 10250 (kubelet), 443/80 (ingress), 179 (Calico BGP)<br/>• **UDP**: 4789 (Calico VXLAN)<br/>• **Optional**: 2379-2380 (etcd HA) |
| 🖥️ **Machine Types** | `check_instances.sh` | All | Validates compute resources and configurations:<br/>• **K3s**: Hardware requirements (master: 8c/16GB/512GB, pg: 8c/32GB/1TB, etc.)<br/>• **AKS/EKS**: Node pool configurations and instance types |
| 🌐 **Networking** | `check_networking.sh` | All | Tests external connectivity to required endpoints:<br/>• **StackGres**: stackgres.io<br/>• **DryvIQ**: skysync.azurecr.io, api.portalarchitects.com, skysyncblob.blob.core.windows.net<br/>• **K3s**: get.k3s.io, rpm.rancher.io, update.k3s.io<br/>• **Tools**: webinstall.dev/k9s |
| 🔗 **On-Prem Network** | `check_onprem_network.sh` | K3s only | Validates inter-node communication:<br/>• Tests connectivity between cluster nodes<br/>• Verifies network policies don't block traffic<br/>• Checks DNS resolution between nodes |
| 🏷️ **Node Labels** | `check_node_labels.sh` | All | Validates node labeling for workload scheduling:<br/>• **AKS**: Required pools (migration, discover, dryviqpool, clickhouse, proxy)<br/>• **EKS/K3s**: Custom node labels and taints/tolerations |
| ⚙️ **Tool Versions** | `check_versions.sh` | All | Verifies CLI tools meet minimum versions:<br/>• **kubectl**: ≥ v1.29<br/>• **helm**: ≥ v3.0<br/>• **Cloud CLIs**: az (AKS), aws (EKS) as needed |
| 🧩 **Admission Constraints** | `check_constraints.sh` | All | Validates Kubernetes security and admission policies:<br/>• Pod Security Standards (PSA) enforcement<br/>• Security contexts and resource quotas<br/>• Admission controllers and policy violations |
| 🛡️ **Network Policies** | `check_network_policies.sh` | All | Examines network policies affecting DryvIQ:<br/>• Lists existing NetworkPolicy resources<br/>• Validates inter-pod communication rules<br/>• Identifies overly restrictive policies |
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
    [PASS] skysync.azurecr.io reachable
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
    ├── check_firewall.sh    # Firewall/port validation
    ├── check_instances.sh   # Instance/hardware validation  
    ├── check_networking.sh  # External connectivity tests
    ├── check_onprem_network.sh    # On-prem network tests
    ├── check_node_labels.sh       # Node labeling validation
    ├── check_versions.sh          # Tool version checks
    ├── check_constraints.sh       # Security/admission policies
    ├── check_network_policies.sh  # Network policy validation
    └── check_db_connectivity.sh   # Database connectivity tests
```

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