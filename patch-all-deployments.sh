#!/bin/bash

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

echo "=== Kubernetes Deployment Patcher ==="
echo "Environment: $ENVIRONMENT"
echo "GCP Project: $PROJECT"
echo "Clusters: ${CLUSTERS[*]}"
echo "Atlantis Repos Path: $ATLANTIS_PATH"
if [[ -n "$TARGET_DEPLOYMENT" ]]; then
    echo "Target: $TARGET_DEPLOYMENT (single deployment mode)"
fi
if [[ "$DRY_RUN" == true ]]; then
    echo "Mode: DRY RUN (showing deployment workload-types only)"
else
    echo "Mode: LIVE (changes will be applied)"
fi
echo ""

# Confirm with user (skip for dry run)
if [[ "$DRY_RUN" != true ]]; then
    read -p "Proceed with patching all deployments in both clusters? (y/N): " -n 1 -r
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

    # Function to create dynamic patch file
    create_patch_file() {
        local workload_type=$1
        local namespace=$2
        local deployment=$3
        local include_spot_toleration=$4
        local patch_file="/tmp/node-affinity-patch-${ENVIRONMENT}-${cluster}-${workload_type}-$$.yaml"

        # Get existing tolerations to preserve them
        local existing_tolerations=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o json 2>/dev/null | jq -c '.spec.template.spec.tolerations // []')

        # Build tolerations array - always include workload-type, preserve others, add spot if needed
        local tolerations='[{"key":"workload-type","operator":"Equal","value":"'$workload_type'"}]'

        # Add existing tolerations that aren't workload-type or gke-spot
        local other_tolerations=$(echo "$existing_tolerations" | jq -c '[.[] | select(.key != "workload-type" and .key != "cloud.google.com/gke-spot")]')
        tolerations=$(echo "$tolerations $other_tolerations" | jq -cs 'add')

        # Add spot toleration if needed
        if [[ "$include_spot_toleration" == "true" ]]; then
            tolerations=$(echo "$tolerations" | jq -c '. + [{"key":"cloud.google.com/gke-spot","operator":"Equal","value":"true","effect":"NoSchedule"}]')
        else
            # Preserve existing spot toleration if it exists
            local existing_spot=$(echo "$existing_tolerations" | jq -c '[.[] | select(.key == "cloud.google.com/gke-spot")]')
            if [[ "$existing_spot" != "[]" ]]; then
                tolerations=$(echo "$tolerations $existing_spot" | jq -cs 'add')
            fi
        fi

        cat > "$patch_file" << EOF
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: "workload-type"
                operator: In
                values:
                - "$workload_type"
      tolerations: $(echo "$tolerations" | jq -c '.')
EOF
        echo "$patch_file"
    }

    # Function to check if deployment already has workload-type node affinity
    check_workload_type_affinity() {
        local namespace=$1
        local deployment=$2

        # Check if the deployment already has workload-type node affinity configured
        local has_affinity=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*].matchExpressions[?(@.key=="workload-type")]}')

        if [[ -n "$has_affinity" ]]; then
            return 0  # Already has workload-type affinity
        else
            return 1  # Does not have workload-type affinity
        fi
    }

    # Function to check if deployment has workload-type toleration
    check_workload_type_toleration() {
        local namespace=$1
        local deployment=$2

        local has_toleration=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.tolerations[?(@.key=="workload-type")]}')

        if [[ -n "$has_toleration" ]]; then
            return 0  # Has workload-type toleration
        else
            return 1  # Does not have workload-type toleration
        fi
    }

    # Function to check if deployment has spot node affinity preference
    check_spot_affinity() {
        local namespace=$1
        local deployment=$2

        # Check for cloud.google.com/gke-provisioning with value "spot" or cloud.google.com/gke-spot
        local affinity_json=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o json 2>/dev/null)

        # Check if has gke-provisioning=spot or gke-spot key
        local has_gke_provisioning=$(echo "$affinity_json" | jq -r '.spec.template.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[]?.preference.matchExpressions[]? | select(.key == "cloud.google.com/gke-provisioning" and (.values[]? == "spot"))' 2>/dev/null)
        local has_gke_spot=$(echo "$affinity_json" | jq -r '.spec.template.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[]?.preference.matchExpressions[]? | select(.key == "cloud.google.com/gke-spot")' 2>/dev/null)

        if [[ -n "$has_gke_provisioning" || -n "$has_gke_spot" ]]; then
            return 0  # Has spot affinity preference
        else
            return 1  # Does not have spot affinity
        fi
    }

    # Function to check if deployment has gke-spot toleration
    check_spot_toleration() {
        local namespace=$1
        local deployment=$2

        local has_spot_toleration=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.tolerations[?(@.key=="cloud.google.com/gke-spot")]}')

        if [[ -n "$has_spot_toleration" ]]; then
            return 0  # Has spot toleration
        else
            return 1  # Does not have spot toleration
        fi
    }

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
            echo "Skipping system namespace $namespace"
            continue
        fi

        if [[ "$DRY_RUN" == true ]]; then
            # Get expected nodepool from atlantis repo and determine workload-type
            expected_nodepool=$(get_expected_nodepool "$namespace" "$deployment")
            expected_workload_type=$(get_workload_type_from_nodepool "$expected_nodepool")

            # Check all conditions
            has_wt_affinity=false
            has_wt_toleration=false
            has_spot_affinity=false
            has_spot_toleration=false

            if check_workload_type_affinity "$namespace" "$deployment"; then
                has_wt_affinity=true
            fi
            if check_workload_type_toleration "$namespace" "$deployment"; then
                has_wt_toleration=true
            fi
            if check_spot_affinity "$namespace" "$deployment"; then
                has_spot_affinity=true
            fi
            if check_spot_toleration "$namespace" "$deployment"; then
                has_spot_toleration=true
            fi

            # Get current workload-type values if they exist
            current_affinity_workload_type=""
            current_toleration_workload_type=""
            if [[ "$has_wt_affinity" == true ]]; then
                current_affinity_workload_type=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*].matchExpressions[?(@.key=="workload-type")].values[0]}' 2>/dev/null)
            fi
            if [[ "$has_wt_toleration" == true ]]; then
                current_toleration_workload_type=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.tolerations[?(@.key=="workload-type")].value}' 2>/dev/null)
            fi

            # Determine status
            needs_patch=false
            status_msg=""

            if [[ "$current_affinity_workload_type" == "$expected_workload_type" ]] && [[ "$current_toleration_workload_type" == "$expected_workload_type" ]] && [[ "$has_wt_affinity" == true ]] && [[ "$has_wt_toleration" == true ]]; then
                # Check spot consistency: if has spot affinity, must have spot toleration
                if [[ "$has_spot_affinity" == true && "$has_spot_toleration" == false ]]; then
                    status_msg="affinity:✓ toleration:✓ spot-affinity:✓ spot-toleration:✗ (needs spot toleration)"
                    needs_patch=true
                elif [[ "$has_spot_affinity" == false && "$has_spot_toleration" == true ]]; then
                    status_msg="affinity:✓ toleration:✓ spot-affinity:✗ spot-toleration:✓ (needs spot affinity)"
                    needs_patch=true
                else
                    status_msg="affinity:✓ toleration:✓ spot:$(if [[ "$has_spot_affinity" == true ]]; then echo "✓"; else echo "N/A"; fi) (correct)"
                fi
            else
                # Something is wrong
                status_msg="affinity:$(if [[ "$has_wt_affinity" == true ]]; then echo "✓"; else echo "✗"; fi) toleration:$(if [[ "$has_wt_toleration" == true ]]; then echo "✓"; else echo "✗"; fi) spot-affinity:$(if [[ "$has_spot_affinity" == true ]]; then echo "✓"; else echo "✗"; fi) spot-toleration:$(if [[ "$has_spot_toleration" == true ]]; then echo "✓"; else echo "✗"; fi)"
                if [[ "$has_wt_affinity" == false || "$has_wt_toleration" == false ]]; then
                    status_msg="$status_msg (needs workload-type: $expected_workload_type)"
                elif [[ "$current_affinity_workload_type" != "$expected_workload_type" || "$current_toleration_workload_type" != "$expected_workload_type" ]]; then
                    status_msg="$status_msg (wrong value - affinity: $current_affinity_workload_type, toleration: $current_toleration_workload_type, should be: $expected_workload_type)"
                fi
                needs_patch=true
            fi

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
            echo "Checking deployment $deployment in namespace $namespace..."

            # Get expected nodepool from atlantis repo and determine workload-type
            expected_nodepool=$(get_expected_nodepool "$namespace" "$deployment")
            expected_workload_type=$(get_workload_type_from_nodepool "$expected_nodepool")

            # Check all conditions
            has_correct_affinity=false
            has_correct_toleration=false
            has_spot_affinity=false
            has_spot_toleration=false
            spot_consistent=true

            if check_workload_type_affinity "$namespace" "$deployment"; then
                current_workload_type=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*].matchExpressions[?(@.key=="workload-type")].values[0]}' 2>/dev/null)
                if [[ "$current_workload_type" == "$expected_workload_type" ]]; then
                    has_correct_affinity=true
                fi
            fi

            if check_workload_type_toleration "$namespace" "$deployment"; then
                current_toleration=$(kubectl --context="$cluster" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.template.spec.tolerations[?(@.key=="workload-type")].value}' 2>/dev/null)
                if [[ "$current_toleration" == "$expected_workload_type" ]]; then
                    has_correct_toleration=true
                fi
            fi

            if check_spot_affinity "$namespace" "$deployment"; then
                has_spot_affinity=true
            fi

            if check_spot_toleration "$namespace" "$deployment"; then
                has_spot_toleration=true
            fi

            # Check spot consistency: if has spot affinity, must have spot toleration
            if [[ "$has_spot_affinity" == true && "$has_spot_toleration" == false ]]; then
                spot_consistent=false
            fi

            if [[ "$has_correct_affinity" == true && "$has_correct_toleration" == true && "$spot_consistent" == true ]]; then
                echo "  ✓ Already has correct workload-type affinity and toleration ($expected_workload_type) - skipping"
                skipped_deployments+=("$namespace/$deployment")
            else
                if [[ "$has_correct_affinity" == false ]]; then
                    echo "  ⚠ Missing or incorrect workload-type affinity"
                fi
                if [[ "$has_correct_toleration" == false ]]; then
                    echo "  ⚠ Missing or incorrect workload-type toleration"
                fi
                if [[ "$spot_consistent" == false ]]; then
                    echo "  ⚠ Has spot affinity but missing spot toleration"
                fi
                echo "  → Expected nodepool (from atlantis): $expected_nodepool"
                echo "  → Target workload-type: $expected_workload_type"
                echo "  → Applying workload-type patch"

                # Create dynamic patch file with correct workload-type
                # Include spot toleration if deployment has spot affinity but missing spot toleration
                if [[ "$spot_consistent" == false ]]; then
                    echo "  → Including spot toleration in patch"
                    patch_file=$(create_patch_file "$expected_workload_type" "$namespace" "$deployment" "true")
                else
                    patch_file=$(create_patch_file "$expected_workload_type" "$namespace" "$deployment" "false")
                fi

                kubectl --context="$cluster" patch deployment "$deployment" -n "$namespace" --patch-file "$patch_file"

                if [ $? -eq 0 ]; then
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
    echo "  Deployments patched: ${#patched_deployments[@]}"
    echo "  Deployments skipped (already configured): ${#skipped_deployments[@]}"

    if [[ ${#skipped_deployments[@]} -gt 0 ]]; then
        echo "  Skipped deployments:"
        for skipped in "${skipped_deployments[@]}"; do
            echo "    - $skipped"
        done
    fi

    # Clean up temporary patch files
    rm -f /tmp/node-affinity-patch-${ENVIRONMENT}-${cluster}-*-$$.yaml

    echo "Completed patching all deployments in cluster $cluster"
done

echo ""
echo "========================================="
echo "All clusters processed successfully!"
echo "========================================="
