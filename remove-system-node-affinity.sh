#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 <environment> [--dry-run]"
    echo "Environments: daily, staging, production"
    echo "Options:"
    echo "  --dry-run    Show what would be changed without making modifications"
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

echo "=== System Namespace Node Affinity Remover ==="
echo "Environment: $ENVIRONMENT"
echo "GCP Project: $PROJECT"
echo "Clusters: ${CLUSTERS[*]}"
if [[ "$DRY_RUN" == true ]]; then
    echo "Mode: DRY RUN (no changes will be made)"
else
    echo "Mode: LIVE (changes will be applied)"
fi
echo ""

# Confirm with user (skip for dry run)
if [[ "$DRY_RUN" != true ]]; then
    read -p "Proceed with removing workload-type node affinity from system namespaces? (y/N): " -n 1 -r
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
    cleaned_deployments_file="/tmp/cleaned-deployments-${ENVIRONMENT}-${cluster}-$$.txt"
    skipped_deployments_file="/tmp/skipped-deployments-${ENVIRONMENT}-${cluster}-$$.txt"

    # Initialize temp files
    > "$cleaned_deployments_file"
    > "$skipped_deployments_file"

    # System namespaces to process
    SYSTEM_NAMESPACES=("kube-system" "kube-public" "kube-node-lease" "gke-system" "gke-managed-system" "istio-system" "gmp-system" "gmp-public" "config-management-system" "resource-group-system")

    # Function to create removal patch file
    create_removal_patch_file() {
        local patch_file="/tmp/remove-node-affinity-${ENVIRONMENT}-${cluster}-$$.yaml"

        cat > "$patch_file" << 'EOF'
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: "kubernetes.io/arch"
                operator: In
                values:
                - "amd64"
      tolerations: []
EOF
        echo "$patch_file"
    }

    # Function to check if deployment has workload-type node affinity
    check_workload_type_affinity() {
        local namespace=$1
        local deployment=$2

        # Check if the deployment has workload-type node affinity configured
        local has_affinity=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*].matchExpressions[?(@.key=="workload-type")]}')

        if [[ -n "$has_affinity" ]]; then
            return 0  # Has workload-type affinity
        else
            return 1  # Does not have workload-type affinity
        fi
    }

    # Function to check if deployment has workload-type tolerations
    check_workload_type_tolerations() {
        local namespace=$1
        local deployment=$2

        # Check if the deployment has workload-type tolerations
        local has_tolerations=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.tolerations[?(@.key=="workload-type")]}')

        if [[ -n "$has_tolerations" ]]; then
            return 0  # Has workload-type tolerations
        else
            return 1  # Does not have workload-type tolerations
        fi
    }

    # Process each system namespace
    for namespace in "${SYSTEM_NAMESPACES[@]}"; do
        echo ""
        echo "Processing system namespace: $namespace"

        # Check if namespace exists
        if ! kubectl --context="$cluster" get namespace "$namespace" >/dev/null 2>&1; then
            echo "  Namespace $namespace does not exist - skipping"
            continue
        fi

        # Get deployments in this namespace
        kubectl --context="$cluster" get deployments -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read deployment; do
            if [[ -z "$deployment" ]]; then
                continue
            fi

            echo "  Checking deployment $deployment..."

            has_affinity=false
            has_tolerations=false

            if check_workload_type_affinity "$namespace" "$deployment"; then
                has_affinity=true
            fi

            if check_workload_type_tolerations "$namespace" "$deployment"; then
                has_tolerations=true
            fi

            if [[ "$has_affinity" == true ]] || [[ "$has_tolerations" == true ]]; then
                echo "$namespace/$deployment" >> "$cleaned_deployments_file"
                if [[ "$DRY_RUN" == true ]]; then
                    echo "    → [DRY RUN] Would remove workload-type configuration"
                else
                    echo "    → Found workload-type configuration - removing..."

                    # Create removal patch file
                    patch_file=$(create_removal_patch_file)

                    if kubectl --context="$cluster" patch deployment "$deployment" -n "$namespace" --patch-file "$patch_file"; then
                        echo "    ✓ Successfully removed workload-type configuration"

                        # Wait for rollout and check for failures
                        echo "    → Waiting for rollout of $deployment in namespace $namespace"
                        if ! kubectl --context="$cluster" rollout status deployment "$deployment" -n "$namespace" --timeout=300s; then
                            echo "    ERROR: Rollout failed for deployment $deployment in namespace $namespace"
                            echo "    Pausing script execution. Please investigate before continuing."
                            read -p "    Press Enter to continue or Ctrl+C to exit..."
                        fi

                        # Clean up patch file
                        rm -f "$patch_file"

                        # Small pause between deployments
                        sleep 2
                    else
                        echo "    ✗ Failed to patch deployment $deployment in namespace $namespace"
                        rm -f "$patch_file"
                    fi
                fi
            else
                echo "    ✓ No workload-type configuration found - skipping"
                echo "$namespace/$deployment" >> "$skipped_deployments_file"
            fi
        done
    done

    # Read results from temp files
    cleaned_count=$(wc -l < "$cleaned_deployments_file" 2>/dev/null || echo "0")
    skipped_count=$(wc -l < "$skipped_deployments_file" 2>/dev/null || echo "0")

    echo ""
    echo "Summary for cluster $cluster:"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  Deployments that would be cleaned: $cleaned_count"
    else
        echo "  Deployments cleaned: $cleaned_count"
    fi
    echo "  Deployments skipped (no workload-type config): $skipped_count"

    if [[ "$cleaned_count" -gt 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Deployments that would be cleaned:"
        else
            echo "  Cleaned deployments:"
        fi
        while read -r deployment; do
            if [[ -n "$deployment" ]]; then
                echo "    - $deployment"
            fi
        done < "$cleaned_deployments_file"
    fi

    # Clean up temp files
    rm -f "$cleaned_deployments_file" "$skipped_deployments_file"

    echo "Completed cleaning system namespaces in cluster $cluster"
done

echo ""
echo "========================================="
echo "All clusters processed successfully!"
echo "========================================="