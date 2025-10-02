#!/bin/bash

# =============================================================================
# Atlantis Deployment Script Template
# =============================================================================
# This template provides a reusable framework for working with all deployments
# across atlantis-managed infrastructure. Customize the check and patch
# functions for your specific needs.
#
# Usage: Copy this template and modify the following functions:
#   - check_deployment_status()    - Check if deployment needs patching
#   - apply_patch()                - Apply changes to deployment
#   - get_deployment_summary()     - Generate summary message
# =============================================================================

# Function to display usage
usage() {
    echo "Usage: $0 <environment> [--dry-run] [--deployment <namespace/deployment>] [--only-missing] [--atlantis-path <path>]"
    echo "Environments: daily, staging, production"
    echo "Options:"
    echo "  --dry-run                          Show what would be changed without making modifications"
    echo "  --deployment <namespace/deployment> Target a specific deployment (e.g., --deployment foo/bar)"
    echo "  --only-missing                     Only show deployments missing required configurations (dry-run only)"
    echo "  --atlantis-path <path>             Path to directory containing atlantis-* repos (default: current directory)"
    exit 1
}

# Parse arguments
DRY_RUN=false
ENVIRONMENT=""
TARGET_DEPLOYMENT=""
ONLY_MISSING=false
ATLANTIS_PATH="."

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --deployment)
            TARGET_DEPLOYMENT=$2
            shift 2
            ;;
        --only-missing)
            ONLY_MISSING=true
            shift
            ;;
        --atlantis-path)
            ATLANTIS_PATH=$2
            shift 2
            ;;
        daily|staging|production)
            ENVIRONMENT=$1
            shift
            ;;
        *)
            echo "Error: Unknown argument '$1'"
            usage
            ;;
    esac
done

# Check if environment is provided
if [ -z "$ENVIRONMENT" ]; then
    echo "Error: Environment is required"
    usage
fi

# Validate environment
case $ENVIRONMENT in
    daily|staging|production)
        ;;
    *)
        echo "Error: Invalid environment '$ENVIRONMENT'"
        usage
        ;;
esac

# Set project and clusters based on environment
PROJECT="onx-$ENVIRONMENT"
CLUSTERS=("$ENVIRONMENT-central1" "$ENVIRONMENT-west1")

echo "=== Kubernetes Deployment Processor ==="
echo "Environment: $ENVIRONMENT"
echo "GCP Project: $PROJECT"
echo "Clusters: ${CLUSTERS[*]}"
echo "Atlantis Repos Path: $ATLANTIS_PATH"
if [[ -n "$TARGET_DEPLOYMENT" ]]; then
    echo "Target: $TARGET_DEPLOYMENT (single deployment mode)"
fi
if [[ "$DRY_RUN" == true ]]; then
    echo "Mode: DRY RUN (showing deployment status only)"
else
    echo "Mode: LIVE (changes will be applied)"
fi
echo ""

# Confirm with user (skip for dry run)
if [[ "$DRY_RUN" != true ]]; then
    read -p "Proceed with processing all deployments in both clusters? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# =============================================================================
# UTILITY FUNCTIONS - Generally useful across scripts
# =============================================================================

# System namespaces to skip
SYSTEM_NAMESPACES=("kube-system" "kube-public" "kube-node-lease" "gke-system" "gke-managed-system" "istio-system" "gmp-system" "gmp-public" "config-management-system" "resource-group-system")

# Function to check if namespace should be skipped
should_skip_namespace() {
    local namespace=$1
    for sys_ns in "${SYSTEM_NAMESPACES[@]}"; do
        if [[ "$namespace" == "$sys_ns" ]]; then
            return 0  # Skip this namespace
        fi
    done
    return 1  # Don't skip
}

# Function to get expected nodepool from atlantis repo (definitive source)
get_expected_nodepool() {
    local namespace=$1
    local deployment=$2
    local atlantis_repo="$ATLANTIS_PATH/atlantis-$namespace"

    if [[ ! -d "$atlantis_repo" ]]; then
        echo "core"  # Default if no atlantis repo
        return
    fi

    # Check tfvars file first
    local tfvars_file="$atlantis_repo/onx-$ENVIRONMENT.tfvars"
    if [[ -f "$tfvars_file" ]]; then
        # First try to find deployment-specific nodepool in deployments block
        local deployment_nodepool=$(awk -v dep="$deployment" '
            /deployments = {/ { in_deployments = 1; brace_count = 0 }
            in_deployments && ($0 ~ "\"" dep "\"[[:space:]]*=" || $0 ~ "[[:space:]]*" dep "[[:space:]]*=") {
                in_deployment = 1;
                brace_count = 1
            }
            in_deployment {
                # Count braces to find the actual end of this deployment
                for (i = 1; i <= length($0); i++) {
                    char = substr($0, i, 1)
                    if (char == "{") brace_count++
                    else if (char == "}") brace_count--
                }

                # Check for nodepool before checking if we are done
                if (/nodepool[[:space:]]*=[[:space:]]*"/) {
                    gsub(/.*nodepool[[:space:]]*=[[:space:]]*"/, "")
                    gsub(/".*/, "")
                    print $0
                    exit
                }

                # Exit when we have balanced braces (end of deployment)
                if (brace_count == 0) in_deployment = 0
            }
            in_deployments && /^}/ { in_deployments = 0 }
        ' "$tfvars_file")

        if [[ -n "$deployment_nodepool" ]]; then
            echo "$deployment_nodepool"
            return
        fi

        # Fall back to top-level nodepool variable
        local nodepool=$(grep -E '^[[:space:]]*nodepool[[:space:]]*=' "$tfvars_file" | sed 's/.*=[[:space:]]*"//' | sed 's/".*//' | head -1)
        if [[ -n "$nodepool" ]]; then
            echo "$nodepool"
            return
        fi
    fi

    # Check variables.tf for default
    local variables_file="$atlantis_repo/variables.tf"
    if [[ -f "$variables_file" ]]; then
        # Look for nodepool variable default in variables.tf
        local default_nodepool=$(grep -A 10 'variable "nodepool"' "$variables_file" | grep -E 'default[[:space:]]*=' | sed 's/.*=[[:space:]]*"//' | sed 's/".*//' | head -1)
        if [[ -n "$default_nodepool" ]]; then
            echo "$default_nodepool"
            return
        fi
    fi

    # Final fallback to core
    echo "core"
}

# Function to extract workload-type from nodepool name
get_workload_type_from_nodepool() {
    local nodepool=$1

    if [[ -z "$nodepool" ]]; then
        echo "core"  # Default to core if no nodepool specified
        return
    fi

    # Handle cases like "core", "core-spot", "prometheus", "prometheus-spot", etc.
    # Extract the part before the first dash (if any)
    local workload_type="${nodepool%%-*}"
    echo "$workload_type"
}

# Function to get atlantis repo path for a namespace
get_atlantis_repo_path() {
    local namespace=$1
    echo "$ATLANTIS_PATH/atlantis-$namespace"
}

# Function to check if atlantis repo exists for namespace
has_atlantis_repo() {
    local namespace=$1
    local atlantis_repo=$(get_atlantis_repo_path "$namespace")
    [[ -d "$atlantis_repo" ]]
}

# Function to get tfvars file path
get_tfvars_file() {
    local namespace=$1
    local atlantis_repo=$(get_atlantis_repo_path "$namespace")
    echo "$atlantis_repo/onx-$ENVIRONMENT.tfvars"
}

# =============================================================================
# CUSTOMIZABLE FUNCTIONS - Modify these for your specific use case
# =============================================================================

# Function to check deployment status
# Returns: 0 if needs patching, 1 if already correct
# Sets global variables:
#   - needs_patch: true/false
#   - status_msg: human-readable status message
check_deployment_status() {
    local cluster=$1
    local namespace=$2
    local deployment=$3

    # TODO: Implement your check logic here
    # Example: Check for specific labels, annotations, resource limits, etc.

    # Get some example data from the deployment
    local image=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    local replicas=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)

    # Example check: deployment exists and has replicas
    if [[ -n "$image" && -n "$replicas" ]]; then
        needs_patch=false
        status_msg="✓ Deployment OK (image: ${image##*/}, replicas: $replicas)"
        return 1  # No patch needed
    else
        needs_patch=true
        status_msg="✗ Deployment needs attention"
        return 0  # Needs patch
    fi
}

# Function to apply patch to deployment
# Returns: 0 on success, 1 on failure
apply_patch() {
    local cluster=$1
    local namespace=$2
    local deployment=$3

    # TODO: Implement your patch logic here
    # Example: kubectl patch, kubectl apply, etc.

    echo "  → Applying patch to $namespace/$deployment"

    # Example patch operation
    # kubectl --context="$cluster" patch deployment "$deployment" -n "$namespace" --type='json' -p='[{"op": "add", "path": "/metadata/labels/patched", "value": "true"}]'

    # For template: just return success
    return 0
}

# Function to generate summary message for deployment
get_deployment_summary() {
    local cluster=$1
    local namespace=$2
    local deployment=$3

    # TODO: Customize what information to show in summary
    # This is used for final reporting

    echo "$namespace/$deployment"
}

# =============================================================================
# MAIN PROCESSING LOOP - Generally should not need modification
# =============================================================================

# Process each cluster
for cluster in "${CLUSTERS[@]}"; do
    echo ""
    echo "========================================="
    echo "Processing cluster: $cluster"
    echo "========================================="

    # Use existing kubectl context that matches cluster name
    echo "Using kubectl context: $cluster"

    # Verify the context exists
    if ! kubectl config get-contexts "$cluster" >/dev/null 2>&1; then
        echo "Error: kubectl context '$cluster' not found"
        echo "Available contexts:"
        kubectl config get-contexts -o name
        continue
    fi

    counter=0
    patched_deployments=()
    skipped_deployments=()

    # Parse target deployment if specified
    TARGET_NS=""
    TARGET_DEP=""
    if [[ -n "$TARGET_DEPLOYMENT" ]]; then
        IFS='/' read -r TARGET_NS TARGET_DEP <<< "$TARGET_DEPLOYMENT"
        if [[ -z "$TARGET_NS" || -z "$TARGET_DEP" ]]; then
            echo "Error: Invalid deployment format. Use: namespace/deployment"
            exit 1
        fi
    fi

    kubectl --context="$cluster" get deployments --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' | while read namespace deployment; do
        # If targeting specific deployment, skip others
        if [[ -n "$TARGET_DEPLOYMENT" ]]; then
            if [[ "$namespace" != "$TARGET_NS" || "$deployment" != "$TARGET_DEP" ]]; then
                continue
            fi
        fi

        # Skip system namespaces (unless specifically targeted)
        if [[ -z "$TARGET_DEPLOYMENT" ]] && should_skip_namespace "$namespace"; then
            continue
        fi

        if [[ "$DRY_RUN" == true ]]; then
            # Dry run mode: check and report status
            needs_patch=false
            status_msg=""

            check_deployment_status "$cluster" "$namespace" "$deployment"

            # Only print if --only-missing is not set, or if it needs patch
            if [[ "$ONLY_MISSING" == false ]] || [[ "$needs_patch" == true ]]; then
                echo "$namespace/$deployment → $status_msg"
            fi

            if [[ "$needs_patch" == true ]]; then
                patched_deployments+=("$namespace/$deployment")
            else
                skipped_deployments+=("$namespace/$deployment")
            fi
        else
            # Live mode: check and apply patches
            echo "Checking deployment $deployment in namespace $namespace..."

            needs_patch=false
            status_msg=""

            check_deployment_status "$cluster" "$namespace" "$deployment"

            if [[ "$needs_patch" == false ]]; then
                echo "  ✓ Deployment already correct - skipping"
                skipped_deployments+=("$namespace/$deployment")
            else
                echo "  ⚠ Deployment needs patching: $status_msg"

                if apply_patch "$cluster" "$namespace" "$deployment"; then
                    patched_deployments+=("$namespace/$deployment")
                    ((counter++))

                    # Every 5 deployments, wait for rollouts to complete
                    if (( counter % 5 == 0 )); then
                        echo "Waiting for last batch of deployments to complete rollout..."

                        # Wait for the last 5 patched deployments to complete their rollout
                        for i in "${patched_deployments[@]: -5}"; do
                            IFS='/' read -r ns dep <<< "$i"
                            echo "Waiting for rollout of $dep in namespace $ns"
                            if ! kubectl --context="$cluster" rollout status deployment "$dep" -n "$ns" --timeout=300s; then
                                echo "ERROR: Rollout failed for deployment $dep in namespace $ns"
                                echo "Pausing script execution. Please investigate before continuing."
                                read -p "Press Enter to continue or Ctrl+C to exit..."
                            fi
                        done

                        echo "Batch complete. Pausing 10 seconds before next batch..."
                        sleep 10
                    fi
                else
                    echo "  ✗ Failed to patch deployment $deployment in namespace $namespace"
                    continue
                fi
            fi
        fi
    done

    echo ""
    echo "Summary for cluster $cluster:"
    echo "  Deployments processed: ${#patched_deployments[@]}"
    echo "  Deployments skipped (already correct): ${#skipped_deployments[@]}"

    if [[ ${#patched_deployments[@]} -gt 0 ]]; then
        echo "  Processed deployments:"
        for patched in "${patched_deployments[@]}"; do
            echo "    - $patched"
        done
    fi

    echo "Completed processing all deployments in cluster $cluster"
done

echo ""
echo "========================================="
echo "All clusters processed successfully!"
echo "========================================="
