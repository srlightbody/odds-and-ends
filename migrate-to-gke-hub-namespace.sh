#!/usr/bin/env zsh

# Migrate repos from kubernetes_namespace to google_gke_hub_namespace
#
# Usage: ./migrate-to-gke-hub-namespace.sh [OPTIONS] [PATH]
#
# Arguments:
#   PATH                Path to projects directory (default: ~/Projects)
#
# Options:
#   --repo REPO_NAME    Only process this specific repo
#   --dry-run           Show what would be done without making changes
#   --help              Show this help message

set -e

PROJECTS_DIR="$HOME/Projects"
DRY_RUN=false
SPECIFIC_REPO=""

# Set Cloudsmith token for terraform module access
set_cloudsmith_token() {
    if [[ -z "$TF_TOKEN_terraform_cloudsmith_io" ]]; then
        export TF_TOKEN_terraform_cloudsmith_io="onxmaps-6aJ/terraform-modules/$(gcloud --project=onx-ci secrets versions access latest --secret='cloudsmith_samuel-lightbody')"
    fi
}

# Set token at start
set_cloudsmith_token

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --repo)
            SPECIFIC_REPO="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            grep "^#" "$0" | grep -v "#!/" | sed 's/^# //'
            exit 0
            ;;
        *)
            # If it doesn't start with --, treat it as the path argument
            if [[ ! "$1" =~ ^-- ]]; then
                PROJECTS_DIR="$1"
                shift
            else
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
            fi
            ;;
    esac
done

# Validate projects directory
if [[ ! -d "$PROJECTS_DIR" ]]; then
    echo "Error: Directory $PROJECTS_DIR does not exist"
    exit 1
fi

NEW_NAMESPACE_CONTENT='# ####
# # Shared K8S namespace
# ####

resource "google_gke_hub_namespace" "fleet_namespace" {
  scope_namespace_id = local.namespace
  scope_id           = replace(module.onx_metadata.teams[local.team].programmatic_label, "_", "-")
  scope              = "projects/${tofu.workspace}/locations/global/scopes/${replace(module.onx_metadata.teams[local.team].programmatic_label, "_", "-")}"
  namespace_labels = local.enable_service_mesh ? {
    team             = module.onx_metadata.teams[local.team].programmatic_label,
    project          = data.google_project.project.project_id
    repository       = local.repository
    istio-injection  = "enabled"
    } : {
    team       = module.onx_metadata.teams[local.team].programmatic_label,
    project    = data.google_project.project.project_id
    repository = local.repository
  }

}
'

# Target tfvars/workspaces to check
TFVARS_FILES=(
    "onx-daily.tfvars"
    "onx-staging.tfvars"
    "onx-production.tfvars"
    "onx-content-daily.tfvars"
    "onx-content-staging.tfvars"
    "onx-content-production.tfvars"
)

# Workspace mapping (tfvars filename -> workspace name)
declare -A WORKSPACE_MAP=(
    ["onx-daily.tfvars"]="onx-daily"
    ["onx-staging.tfvars"]="onx-staging"
    ["onx-production.tfvars"]="onx-production"
    ["onx-content-daily.tfvars"]="onx-content-daily"
    ["onx-content-staging.tfvars"]="onx-content-staging"
    ["onx-content-production.tfvars"]="onx-content-production"
)

process_repo() {
    local repo=$1
    local repo_path="$PROJECTS_DIR/$repo"

    echo "=========================================="
    echo "Processing: $repo"
    echo "=========================================="

    # Check if namespace.tf exists
    if [[ ! -f "$repo_path/namespace.tf" ]]; then
        echo "❌ No namespace.tf found, skipping"
        return
    fi

    # Check if still using kubernetes_namespace
    if ! grep -q 'resource.*"kubernetes_namespace"' "$repo_path/namespace.tf"; then
        echo "✓ Already migrated to google_gke_hub_namespace"
        return
    fi

    # Check for enable_service_mesh variable
    echo "Checking for enable_service_mesh variable..."
    if ! grep -rq "enable_service_mesh" "$repo_path"/*.tf; then
        echo "⚠️  enable_service_mesh variable not found, will add it to locals.tf"

        # Determine default value based on presence of onx-content-*.tfvars files
        local default_value="true"
        if ls "$repo_path"/onx-content-*.tfvars 2>/dev/null | grep -q .; then
            default_value="false"
            echo "   Found onx-content-*.tfvars files, setting default to false"
        else
            echo "   No onx-content-*.tfvars files found, setting default to true"
        fi

        if [[ "$DRY_RUN" == "false" ]]; then
            # Check if locals.tf exists
            if [[ ! -f "$repo_path/locals.tf" ]]; then
                echo "❌ ERROR: locals.tf not found, cannot add enable_service_mesh"
                return
            fi

            # Add enable_service_mesh to locals.tf
            echo "Adding enable_service_mesh = $default_value to locals.tf..."

            # Find the locals block and add the variable
            # This adds it before the closing brace of the locals block
            if grep -q "^locals {" "$repo_path/locals.tf"; then
                # Add the variable (look for last closing brace and add before it)
                awk -v val="$default_value" '
                    /^}/ && !added {
                        print "  enable_service_mesh = " val
                        added=1
                    }
                    {print}
                ' "$repo_path/locals.tf" > "$repo_path/locals.tf.tmp" && mv "$repo_path/locals.tf.tmp" "$repo_path/locals.tf"

                echo "✓ Added enable_service_mesh to locals.tf"
            else
                echo "❌ ERROR: Could not find locals block in locals.tf"
                return
            fi
        else
            echo "   [DRY RUN] Would add: enable_service_mesh = $default_value to locals.tf"
        fi
    else
        echo "✓ Found enable_service_mesh variable"
    fi

    # Find which tfvars files exist
    local workspaces=()
    for tfvars in "${TFVARS_FILES[@]}"; do
        if [[ -f "$repo_path/$tfvars" ]]; then
            workspaces+=("${WORKSPACE_MAP[$tfvars]}")
        fi
    done

    if [[ ${#workspaces[@]} -eq 0 ]]; then
        echo "❌ No target tfvars files found"
        return
    fi

    echo "Found workspaces: ${workspaces[@]}"

    # Get list of kubernetes_namespace resources to remove
    echo ""
    echo "Finding kubernetes_namespace resources to remove from state..."
    local resources=($(grep 'resource "kubernetes_namespace"' "$repo_path/namespace.tf" | awk '{print $3}' | tr -d '"'))

    if [[ ${#resources[@]} -eq 0 ]]; then
        echo "❌ No kubernetes_namespace resources found"
        return
    fi

    echo "Resources to remove:"
    for resource in "${resources[@]}"; do
        echo "  - kubernetes_namespace.$resource"
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo "[DRY RUN] Would perform the following actions:"
        echo ""

        # Check if enable_service_mesh needs to be added
        if ! grep -rq "enable_service_mesh" "$repo_path"/*.tf; then
            local default_value="true"
            if ls "$repo_path"/onx-content-*.tfvars 2>/dev/null | grep -q .; then
                default_value="false"
            fi
            echo "1. Add enable_service_mesh = $default_value to locals.tf"
            echo ""
        fi

        echo "2. Update namespace.tf with new google_gke_hub_namespace resource"
        echo ""

        if [[ -f "$repo_path/deployments.tf" ]]; then
            echo "3. Update deployments.tf namespace references:"
            echo "     sed 's|resource.kubernetes_namespace.*.metadata[0].name|resource.google_gke_hub_namespace.fleet_namespace.scope_namespace_id|g'"
            echo ""
        fi

        echo "4. Remove old state and apply new resource for each workspace:"
        for workspace in "${workspaces[@]}"; do
            echo "   Workspace: $workspace"
            for resource in "${resources[@]}"; do
                echo "     tofu workspace select $workspace"
                echo "     tofu state rm 'kubernetes_namespace.$resource'"
            done
            echo "     tofu apply -target=google_gke_hub_namespace.fleet_namespace -auto-approve"
        done
        echo ""
        echo "5. Commit changes to git:"
        echo "     git add namespace.tf"
        if [[ -f "$repo_path/deployments.tf" ]]; then
            echo "     git add deployments.tf"
        fi
        if ! grep -rq "enable_service_mesh" "$repo_path"/*.tf; then
            echo "     git add locals.tf"
        fi
        echo "     git commit -m 'SRE-6189 switch to fleet namespace'"
    else
        echo ""
        read "?Proceed with migration? (y/N) " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Skipping $repo"
            return
        fi

        # Update namespace.tf
        echo "Updating namespace.tf..."
        echo "$NEW_NAMESPACE_CONTENT" > "$repo_path/namespace.tf"

        # Update deployments.tf to reference the new resource
        if [[ -f "$repo_path/deployments.tf" ]]; then
            echo "Updating deployments.tf namespace references..."

            # Replace kubernetes_namespace references with google_gke_hub_namespace
            sed -i 's|resource\.kubernetes_namespace\.[^.]*\.metadata\[0\]\.name|resource.google_gke_hub_namespace.fleet_namespace.scope_namespace_id|g' "$repo_path/deployments.tf"

            echo "✓ Updated deployments.tf"
        fi

        # Remove state and apply new resource for each workspace
        cd "$repo_path"
        migration_failed=false

        # Initialize tofu with upgrade to ensure backend is ready
        echo ""
        echo "Initializing tofu..."
        local init_tfvars=$(find . -maxdepth 1 -name "*.tfvars" | head -n1)
        if [[ -z "$init_tfvars" ]]; then
            echo "❌ ERROR: No tfvars file found for init"
            echo "Skipping $repo"
            return
        fi

        echo "Running: tofu init --upgrade -var-file=\"$init_tfvars\""
        if ! tofu init --upgrade -var-file="$init_tfvars"; then
            echo "❌ ERROR: Failed to initialize tofu (see output above)"
            echo "Skipping $repo"
            return
        fi
        echo "✓ Initialized with $init_tfvars"

        for workspace in "${workspaces[@]}"; do
            echo ""
            echo "Processing workspace: $workspace"

            if ! tofu workspace select "$workspace" 2>/dev/null; then
                echo "⚠️  Warning: Could not select workspace $workspace, skipping"
                migration_failed=true
                continue
            fi

            # Remove old resources from state
            for resource in "${resources[@]}"; do
                echo "  Removing kubernetes_namespace.$resource from state..."
                if tofu state rm "kubernetes_namespace.$resource" 2>/dev/null; then
                    echo "  ✓ Removed"
                else
                    # Try with index
                    if tofu state rm "kubernetes_namespace.${resource}[0]" 2>/dev/null; then
                        echo "  ✓ Removed [0]"
                    else
                        echo "  ⚠️  Could not remove (may not exist in this workspace)"
                    fi
                fi
            done

            # Apply the new google_gke_hub_namespace resource
            echo ""
            echo "  Applying new google_gke_hub_namespace.fleet_namespace..."
            if tofu apply -target=google_gke_hub_namespace.fleet_namespace -auto-approve; then
                echo "  ✓ Applied successfully"
            else
                echo "  ❌ ERROR: Failed to apply google_gke_hub_namespace.fleet_namespace"
                echo "  You may need to manually apply this workspace"
                migration_failed=true
            fi
        done

        if [[ "$migration_failed" == "true" ]]; then
            echo ""
            echo "⚠️  Migration completed with errors for $repo"
            echo "  Skipping git commit due to errors"
        else
            echo ""
            echo "✓ Migration complete for $repo"

            # Commit changes to git
            echo ""
            echo "Committing changes to git..."

            # Add modified files
            git add namespace.tf

            # Add deployments.tf if it exists
            if [[ -f "$repo_path/deployments.tf" ]]; then
                git add deployments.tf
            fi

            # Check if locals.tf was modified (check git status)
            if git status --porcelain locals.tf 2>/dev/null | grep -q "^.M"; then
                git add locals.tf
            fi

            # Commit
            if git commit -m "SRE-6189 switch to fleet namespace"; then
                echo "✓ Changes committed to git"

                # Push changes
                if git push; then
                    echo "✓ Changes pushed to remote"
                else
                    echo "⚠️  Git push failed"
                fi
            else
                echo "⚠️  Git commit failed or no changes to commit"
            fi
        fi
    fi

    echo ""
}

# Main execution
if [[ -n "$SPECIFIC_REPO" ]]; then
    # Process single repo
    if [[ ! -d "$PROJECTS_DIR/$SPECIFIC_REPO" ]]; then
        echo "Error: Repository $SPECIFIC_REPO not found"
        exit 1
    fi
    process_repo "$SPECIFIC_REPO"
else
    # Process all repos that need migration
    echo "Finding repos that need migration..."
    echo ""

    repos_to_process=()
    for repo in $(ls "$PROJECTS_DIR" | grep "^atlantis-"); do
        namespace_file="$PROJECTS_DIR/$repo/namespace.tf"
        [[ ! -f "$namespace_file" ]] && continue
        grep -q 'resource.*"kubernetes_namespace"' "$namespace_file" || continue

        has_tfvars=false
        for tfvars in "${TFVARS_FILES[@]}"; do
            if [[ -f "$PROJECTS_DIR/$repo/$tfvars" ]]; then
                has_tfvars=true
                break
            fi
        done

        if [[ "$has_tfvars" == "true" ]]; then
            repos_to_process+=("$repo")
        fi
    done

    echo "Found ${#repos_to_process[@]} repos to migrate:"
    for repo in "${repos_to_process[@]}"; do
        echo "  - $repo"
    done
    echo ""

    if [[ "$DRY_RUN" == "false" ]]; then
        read "?Process all repos? (y/N) " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            exit 0
        fi
    fi

    for repo in "${repos_to_process[@]}"; do
        process_repo "$repo"
    done
fi

echo ""
echo "Done!"
