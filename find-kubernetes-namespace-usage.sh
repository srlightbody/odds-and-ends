#!/usr/bin/env zsh

# Find atlantis repos that still use kubernetes_namespace

PROJECTS_DIR="${1:-$HOME/Projects}"

found_count=0

for repo in $(ls "$PROJECTS_DIR" | grep "^atlantis-"); do
    namespace_file="$PROJECTS_DIR/$repo/namespace.tf"

    # Skip if no namespace.tf
    [[ ! -f "$namespace_file" ]] && continue

    # Skip if already using google_gke_hub_namespace
    grep -q 'resource.*"kubernetes_namespace"' "$namespace_file" || continue

    # Check for target tfvars files
    has_tfvars=false
    for tfvars in onx-daily.tfvars onx-staging.tfvars onx-production.tfvars onx-content-daily.tfvars onx-content-staging.tfvars onx-content-production.tfvars; do
        if [[ -f "$PROJECTS_DIR/$repo/$tfvars" ]]; then
            has_tfvars=true
            break
        fi
    done

    if [[ "$has_tfvars" == "true" ]]; then
        echo "$repo"
        ((found_count++))
    fi
done

echo ""
echo "Found: $found_count repos"
