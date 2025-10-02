#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 <environment>"
    echo "Environments: daily, staging, production"
    exit 1
}

# Check if environment is provided
if [ $# -ne 1 ]; then
    usage
fi

ENVIRONMENT=$1

# Validate environment
case $ENVIRONMENT in
    daily|staging|production)
        ;;
    *)
        echo "Error: Invalid environment '$ENVIRONMENT'"
        usage
        ;;
esac

# Set clusters based on environment
CLUSTERS=("$ENVIRONMENT-central1" "$ENVIRONMENT-west1")

echo "=== Current Workload Types ==="
echo "Environment: $ENVIRONMENT"
echo "Clusters: ${CLUSTERS[*]}"
echo ""

# Function to get expected nodepool from atlantis repo
get_expected_nodepool() {
    local namespace=$1
    local deployment=$2
    local atlantis_repo="atlantis-$namespace"

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

# Process each cluster
for cluster in "${CLUSTERS[@]}"; do
    echo "========================================="
    echo "Cluster: $cluster"
    echo "========================================="

    # Verify the context exists
    if ! kubectl config get-contexts "$cluster" >/dev/null 2>&1; then
        echo "Error: kubectl context '$cluster' not found"
        continue
    fi

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

    kubectl --context="$cluster" get deployments --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' | while read namespace deployment; do
        # Skip system namespaces
        if should_skip_namespace "$namespace"; then
            continue
        fi

        # Get current workload-type from affinity
        current_workload_type=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*].matchExpressions[?(@.key=="workload-type")].values[0]}' 2>/dev/null)

        # Get expected nodepool from atlantis repo
        expected_nodepool=$(get_expected_nodepool "$namespace" "$deployment")
        expected_workload_type="${expected_nodepool%%-*}"  # Extract workload-type from nodepool

        if [[ -n "$current_workload_type" ]]; then
            if [[ "$current_workload_type" == "$expected_workload_type" ]]; then
                echo "$namespace/$deployment → $current_workload_type ✓"
            else
                echo "$namespace/$deployment → $current_workload_type (expected: $expected_workload_type) ✗"
            fi
        else
            echo "$namespace/$deployment still using legacy label"
        fi
        # If no workload-type is set, omit the deployment (hasn't been processed yet)
    done

    echo ""
done
