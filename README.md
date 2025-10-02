# odds-and-ends

A collection of utility scripts and tools for managing Kubernetes workloads and infrastructure.

## Scripts

### Kubernetes Workload Management

- **patch-all-deployments.sh** - Batch update deployments with node affinity and tolerations for workload types
- **add-spot-tolerations.sh** - Add spot instance tolerations to deployments with spot affinity
- **remove-system-node-affinity.sh** - Remove system node affinity and tolerations from deployments
- **show-workload-types.sh** - Display current workload-type assignments across deployments
- **k8s-batch-operation-template.sh** - Template for batch Kubernetes operations

### Namespace and Service Mesh

- **init_namespace.sh** - Initialize a new Kubernetes namespace with standard configuration
- **update_namespaces.sh** - Update namespace configurations across clusters
- **update_mesh.sh** - Update service mesh configurations

### Infrastructure

- **clone_all_atlantis_repos.sh** - Clone all Atlantis infrastructure repositories
- **clean_terraform.sh** - Clean up Terraform state and cache files
- **enable_cloud_trace.sh** - Enable Google Cloud Trace for services
- **set_workspace.sh** - Set Terraform workspace

### Configuration Files

- **nap-config.yaml** - Node Auto Provisioning configuration
- **node-affinity-patch.yaml** - Node affinity patch template

### Utilities

- **fix_dupes/** - Scripts and output for fixing duplicate resources

## Usage

Most scripts are designed to work with multiple Kubernetes clusters and namespaces. They typically support:

- Filtering by cluster context
- Filtering by namespace
- Dry-run mode for safe testing
- Batch operations across multiple resources

Refer to individual script help text for specific usage patterns.

## Requirements

- kubectl
- jq
- gh (GitHub CLI)
- Access to configured Kubernetes clusters
