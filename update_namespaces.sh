#!/bin/bash

# Default to dry run mode
DRY_RUN=true
SPECIFIC_REPO=""
BLACKLIST=""
DEBUG=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --execute)
            DRY_RUN=false
            shift
            ;;
        --repo)
            SPECIFIC_REPO="$2"
            shift 2
            ;;
        --blacklist)
            BLACKLIST="$2"
            shift 2
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--execute] [--repo <repo_name>] [--blacklist <repo1,repo2,repo3>] [--debug]"
            echo "  --execute         Actually perform the migration (default is dry run)"
            echo "  --repo <n>     Process only the specified repo (e.g., atlantis-api)"
            echo "  --blacklist <...> Skip these repos (comma-separated, e.g., atlantis-api,atlantis-web)"
            echo "  --debug           Enable debug output"
            echo "  --help            Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [[ "$DRY_RUN" == "false" ]]; then
    echo "EXECUTE MODE - Changes will be made"
else
    echo "DRY RUN MODE - No changes will be made (use --execute to run for real)"
fi

if [[ "$DEBUG" == "true" ]]; then
    echo "DEBUG MODE - Extra output enabled"
fi

# Find repositories to process
if [[ -n "$SPECIFIC_REPO" ]]; then
    REPOS=("$HOME/Projects/$SPECIFIC_REPO")
    echo "Processing single repo: $SPECIFIC_REPO"
else
    REPOS=(~/Projects/atlantis-*)
    echo "Processing all atlantis-* repositories"
fi

if [[ -n "$BLACKLIST" ]]; then
    echo "Blacklisted repos: $BLACKLIST"
fi

# Workspaces to process
WORKSPACES=("onx-daily" "onx-staging" "onx-production")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# New namespace.tf content
NEW_NAMESPACE_CONTENT='# ####
# # Shared K8S namespace
# ####

resource "google_gke_hub_namespace" "fleet_namespace" {
  scope_namespace_id = local.namespace
  scope_id           = replace(module.onx_metadata.teams[local.team].programmatic_label, "_", "-")
  scope              = "projects/${tofu.workspace}/locations/global/scopes/${replace(module.onx_metadata.teams[local.team].programmatic_label, "_", "-")}"
}
'

# Function to update deployments.tf
update_deployments_file() {
    local file="$1"
    local temp_file=$(mktemp)
    
    if [[ "$DEBUG" == "true" ]]; then
        echo "DEBUG: Updating deployments.tf with sed commands"
        echo "DEBUG: Input file: $file"
        echo "DEBUG: Temp file: $temp_file"
    fi
    
    # Replace namespace references - handle both with and without "resource." prefix
    sed -e 's/namespace.*= kubernetes_namespace\.deployment_namespace_central1\.metadata\[0\]\.name/namespace = resource.google_gke_hub_namespace.fleet_namespace.scope_namespace_id/g' \
        -e 's/namespace.*= kubernetes_namespace\.deployment_namespace_west1\.metadata\[0\]\.name/namespace = resource.google_gke_hub_namespace.fleet_namespace.scope_namespace_id/g' \
        -e 's/namespace.*= resource\.kubernetes_namespace\.deployment_namespace_central1\.metadata\[0\]\.name/namespace = resource.google_gke_hub_namespace.fleet_namespace.scope_namespace_id/g' \
        -e 's/namespace.*= resource\.kubernetes_namespace\.deployment_namespace_west1\.metadata\[0\]\.name/namespace = resource.google_gke_hub_namespace.fleet_namespace.scope_namespace_id/g' \
        -e 's/namespace.*= resource\.kubernetes_namespace\.deployment_namespace_central1\.metadata\[0\]\.name/namespace = local.namespace/g' \
        "$file" > "$temp_file"
    
    if [[ "$DEBUG" == "true" ]]; then
        echo "DEBUG: Comparing original and updated files:"
        echo "DEBUG: Lines changed:"
        diff "$file" "$temp_file" | head -10 || true
    fi
    
    mv "$temp_file" "$file"
    
    if [[ "$DEBUG" == "true" ]]; then
        echo "DEBUG: deployments.tf updated successfully"
    fi
}

# Function to process a single repository
process_repo() {
    local repo_path="$1"
    local repo_name=$(basename "$repo_path")
    
    echo -e "${BLUE}=== Processing: $repo_name ===${NC}"
    
    cd "$repo_path" || return 1
    
    # Check if repo has been initialized with tofu - do this FIRST
    if [[ ! -d ".terraform" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY RUN] Would run initial tofu init (repo not initialized)"
        else
            echo "Repo not initialized - running tofu init..."
            tofu init || return 1
        fi
    fi
    
    if [[ "$DEBUG" == "true" ]]; then
        echo "DEBUG: Current directory: $(pwd)"
        echo "DEBUG: Files in directory: $(ls -la *.tf 2>/dev/null || echo 'No .tf files')"
    fi
    
    # Check if this repo is blacklisted
    if [[ -n "$BLACKLIST" ]]; then
        IFS=',' read -ra BLACKLIST_ARRAY <<< "$BLACKLIST"
        for blacklisted in "${BLACKLIST_ARRAY[@]}"; do
            if [[ "$repo_name" == "$blacklisted" ]]; then
                echo -e "${YELLOW}Repo $repo_name is blacklisted - skipping${NC}"
                return 0
            fi
        done
    fi
    
    # Check if this repo has namespace config at all
    if [[ ! -f namespace.tf ]] && [[ ! -f namespaces.tf ]]; then
        echo -e "${YELLOW}No namespace config found in $repo_name - skipping${NC}"
        return 0
    fi
    
    # Check if this repo has kubernetes_namespace resources (indicating it's a repo we should migrate)
    if ! rg -q "resource.*kubernetes_namespace" . --type tf 2>/dev/null; then
        echo -e "${YELLOW}No kubernetes_namespace resources found in $repo_name - skipping${NC}"
        return 0
    fi
    
    # Check if this repo has unexpected workspaces (should only have default and our 3 workspaces)
    allowed_workspaces=("default" "onx-daily" "onx-staging" "onx-production")
    mapfile -t all_workspaces < <(tofu workspace list | sed 's/^[* ] *//')
    
    for workspace in "${all_workspaces[@]}"; do
        # Skip empty lines
        [[ -z "$workspace" ]] && continue
        
        found=false
        for allowed in "${allowed_workspaces[@]}"; do
            if [[ "$workspace" == "$allowed" ]]; then
                found=true
                break
            fi
        done
        
        if [[ "$found" == "false" ]]; then
            echo -e "${YELLOW}Repo $repo_name has unexpected workspace '$workspace' - skipping for safety${NC}"
            echo -e "${YELLOW}Found workspaces: ${all_workspaces[*]}${NC}"
            return 0
        fi
    done
    
    if [[ "$DEBUG" == "true" ]]; then
        echo "DEBUG: Workspace check passed. Found workspaces: ${all_workspaces[*]}"
    fi
    
    # Check if migration already done
    if [[ -f namespace.tf ]] && rg -q "google_gke_hub_namespace" namespace.tf; then
        echo -e "${YELLOW}Migration already completed for $repo_name - skipping${NC}"
        return 0
    fi
    
    # Check if we have the old namespaces.tf (plural) file
    if [[ -f namespaces.tf ]] && [[ ! -f namespace.tf ]]; then
        echo "Found namespaces.tf, will rename to namespace.tf during migration"
    fi
    
    # Step 1: Git pull
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would pull latest changes..."
    else
        echo "Pulling latest changes..."
        git pull || return 1
    fi
    
    # Step 2: Update files
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would update namespace.tf"
        if [[ -f deployments.tf ]]; then
            echo "[DRY RUN] Would update deployments.tf"
        else
            echo "[DRY RUN] No deployments.tf found"
        fi
        echo "[DRY RUN] Would run: tofu init -upgrade"
    else
        echo "$NEW_NAMESPACE_CONTENT" > namespace.tf
        echo "Updated namespace.tf"
        if [[ -f deployments.tf ]]; then
            echo "Found deployments.tf, updating..."
            update_deployments_file deployments.tf
            echo "Updated deployments.tf"
        else
            echo "No deployments.tf found in this repo"
        fi
        # Run init -upgrade once for the repo
        echo "Running tofu init -upgrade..."
        tofu init -upgrade || return 1
    fi
    
    # Step 3: Process each workspace (only the ones that exist)
    for workspace in "${WORKSPACES[@]}"; do
        # Check if workspace exists
        if ! tofu workspace list | rg -q "^[* ]*${workspace}$"; then
            echo -e "${YELLOW}Workspace $workspace does not exist in $repo_name - skipping${NC}"
            continue
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY RUN] Would process workspace $workspace..."
            echo "[DRY RUN] Would run: tofu workspace select $workspace"
            echo "[DRY RUN] Would run: tofu plan and apply for fleet namespace"
            echo "[DRY RUN] Would remove kubernetes_namespace resources from state"
        else
            echo "Processing workspace $workspace..."
            tofu workspace select "$workspace" || return 1
            
            # Run plan first to check what will change
            echo "Checking what changes will be made..."
            tofu plan -target=google_gke_hub_namespace.fleet_namespace -var-file="${workspace}.tfvars" -out=temp.tfplan || return 1
            
            # Check if the plan only contains the fleet namespace creation or no changes
            plan_output=$(tofu show -no-color temp.tfplan)
            if echo "$plan_output" | rg -q "Plan: 0 to add, 0 to change, 0 to destroy"; then
                echo "Plan shows no changes - applying..."
                tofu apply temp.tfplan || return 1
            elif echo "$plan_output" | rg -q "Plan: 1 to add, 0 to change, 0 to destroy" && echo "$plan_output" | rg -q "google_gke_hub_namespace.fleet_namespace" && ! echo "$plan_output" | rg -q "(will be (updated|destroyed|replaced))"; then
                echo "Plan looks good - only adding the fleet namespace, auto-approving..."
                tofu apply temp.tfplan || return 1
            else
                echo -e "${YELLOW}Plan contains unexpected changes:${NC}"
                tofu show temp.tfplan
                echo
                echo "Continue with apply? (y/N)"
                read -r confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    tofu apply temp.tfplan || return 1
                else
                    echo "Skipping apply for $workspace"
                    rm -f temp.tfplan
                    continue
                fi
            fi
            
            rm -f temp.tfplan
            
            # Only remove the specific kubernetes_namespace resources we created
            if tofu state show kubernetes_namespace.deployment_namespace_central1 &>/dev/null; then
                tofu state rm kubernetes_namespace.deployment_namespace_central1
            fi
            if tofu state show kubernetes_namespace.deployment_namespace_west1 &>/dev/null; then
                tofu state rm kubernetes_namespace.deployment_namespace_west1
            fi
        fi
    done
    
    # Step 4: Commit and push
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would commit and push changes..."
        echo "[DRY RUN] Would run: git add ."
        echo "[DRY RUN] Would run: git commit -m 'SRE-5487 switch to fleet namespace, all environments'"
        echo "[DRY RUN] Would run: git push"
    else
        echo "Committing and pushing changes..."
        git add .
        git commit -m "SRE-5487 switch to fleet namespace, all environments"
        git push || return 1
    fi
    
    echo -e "${GREEN}Completed: $repo_name${NC}"
    return 0
}

# Main execution
for repo in "${REPOS[@]}"; do
    process_repo "$repo"
done
