#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 <environment> [--dry-run]"
    echo "Environments: daily, staging, production"
    echo "Options:"
    echo "  --dry-run    Show what would be changed without making modifications"
    echo ""
    echo "This script adds GKE spot tolerations to deployments that have spot node affinity preference."
    exit 1
}

# Parse arguments
DRY_RUN=false
ENVIRONMENT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
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

echo "=== GKE Spot Toleration Patcher ==="
echo "Environment: $ENVIRONMENT"
echo "GCP Project: $PROJECT"
echo "Clusters: ${CLUSTERS[*]}"
if [[ "$DRY_RUN" == true ]]; then
    echo "Mode: DRY RUN (showing deployments that would be patched)"
else
    echo "Mode: LIVE (changes will be applied)"
fi
echo ""

# Confirm with user (skip for dry run)
if [[ "$DRY_RUN" != true ]]; then
    read -p "Proceed with adding GKE spot tolerations to deployments with spot affinity? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

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
    no_spot_affinity_deployments=()

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

    # Function to check if deployment has spot node affinity preference
    has_spot_affinity() {
        local namespace=$1
        local deployment=$2

        # Get the full deployment spec and check for spot affinity using jq
        local deployment_spec=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o json 2>/dev/null)

        if [[ -z "$deployment_spec" ]]; then
            return 1  # Deployment not found
        fi

        # Check for spot preference in preferredDuringSchedulingIgnoredDuringExecution
        # Look for both possible keys: "cloud.google.com/gke-provisioning" and "workload-type"
        local spot_preference=$(echo "$deployment_spec" | jq -r '.spec.template.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[]?.preference.matchExpressions[]? | select((.key == "cloud.google.com/gke-provisioning" or .key == "workload-type") and (.values[]? == "spot")) | .key' 2>/dev/null)

        if [[ -n "$spot_preference" ]]; then
            return 0  # Has spot affinity
        fi

        # Also check requiredDuringSchedulingIgnoredDuringExecution for spot
        local spot_required=$(echo "$deployment_spec" | jq -r '.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]? | select((.key == "cloud.google.com/gke-provisioning" or .key == "workload-type") and (.values[]? == "spot")) | .key' 2>/dev/null)

        if [[ -n "$spot_required" ]]; then
            return 0  # Has spot affinity
        fi

        return 1  # No spot affinity
    }

    # Function to check if deployment already has GKE spot toleration
    has_gke_spot_toleration() {
        local namespace=$1
        local deployment=$2

        # Get the full deployment spec and check for GKE spot toleration using jq
        local deployment_spec=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o json 2>/dev/null)

        if [[ -z "$deployment_spec" ]]; then
            return 1  # Deployment not found
        fi

        # Check if the deployment already has the GKE spot toleration
        local has_toleration=$(echo "$deployment_spec" | jq -r '.spec.template.spec.tolerations[]? | select(.key == "cloud.google.com/gke-spot" and .operator == "Equal" and .value == "true" and .effect == "NoSchedule") | .key' 2>/dev/null)

        if [[ -n "$has_toleration" ]]; then
            return 0  # Already has GKE spot toleration
        else
            return 1  # Does not have GKE spot toleration
        fi
    }

    # Function to create patch file for adding GKE spot toleration
    create_spot_toleration_patch() {
        local patch_file="/tmp/gke-spot-toleration-patch-${ENVIRONMENT}-${cluster}-$$.yaml"

        cat > "$patch_file" << 'EOF'
spec:
  template:
    spec:
      tolerations:
      - key: cloud.google.com/gke-spot
        operator: Equal
        value: "true"
        effect: NoSchedule
EOF
        echo "$patch_file"
    }

    kubectl --context="$cluster" get deployments --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' | while read namespace deployment; do
        # Skip system namespaces
        if should_skip_namespace "$namespace"; then
            continue
        fi

        # Check if deployment has spot node affinity
        if has_spot_affinity "$namespace" "$deployment"; then
            if [[ "$DRY_RUN" == true ]]; then
                # Check if already has GKE spot toleration
                if has_gke_spot_toleration "$namespace" "$deployment"; then
                    echo "$namespace/$deployment → has spot affinity ✓ (already has GKE spot toleration)"
                    skipped_deployments+=("$namespace/$deployment")
                else
                    echo "$namespace/$deployment → has spot affinity → needs GKE spot toleration"
                    patched_deployments+=("$namespace/$deployment")
                fi
            else
                echo "Checking deployment $deployment in namespace $namespace..."

                if has_gke_spot_toleration "$namespace" "$deployment"; then
                    echo "  ✓ Already has GKE spot toleration - skipping"
                    skipped_deployments+=("$namespace/$deployment")
                else
                    echo "  → Has spot affinity but missing GKE spot toleration"
                    echo "  → Adding GKE spot toleration"

                    # Create patch file
                    patch_file=$(create_spot_toleration_patch)

                    # Apply the patch using strategic merge
                    kubectl --context="$cluster" patch deployment "$deployment" -n "$namespace" --type='strategic' --patch-file "$patch_file"

                    if [ $? -eq 0 ]; then
                        patched_deployments+=("$namespace/$deployment")
                        ((counter++))
                        echo "  ✓ Successfully added GKE spot toleration"

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

                    # Clean up patch file
                    rm -f "$patch_file"
                fi
            fi
        else
            # Deployment does NOT have spot affinity
            if [[ "$DRY_RUN" == true ]]; then
                echo "$namespace/$deployment → no spot affinity"
            fi
            no_spot_affinity_deployments+=("$namespace/$deployment")
        fi
    done

    echo ""
    echo "Summary for cluster $cluster:"
    echo "  Deployments patched: ${#patched_deployments[@]}"
    echo "  Deployments skipped (already have toleration): ${#skipped_deployments[@]}"
    echo "  Deployments without spot affinity: ${#no_spot_affinity_deployments[@]}"

    if [[ ${#patched_deployments[@]} -gt 0 ]]; then
        echo "  Patched deployments:"
        for patched in "${patched_deployments[@]}"; do
            echo "    - $patched"
        done
    fi

    if [[ ${#skipped_deployments[@]} -gt 0 ]]; then
        echo "  Skipped deployments:"
        for skipped in "${skipped_deployments[@]}"; do
            echo "    - $skipped"
        done
    fi

    if [[ ${#no_spot_affinity_deployments[@]} -gt 0 ]]; then
        echo "  Deployments without spot affinity:"
        for no_spot in "${no_spot_affinity_deployments[@]}"; do
            echo "    - $no_spot"
        done
    fi

    # Clean up any remaining temporary patch files
    rm -f /tmp/gke-spot-toleration-patch-${ENVIRONMENT}-${cluster}-$$.yaml

    echo "Completed processing cluster $cluster"
done

echo ""
echo "========================================="
echo "All clusters processed successfully!"
echo "========================================="