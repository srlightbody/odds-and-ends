#!/bin/bash

# Check all Atlantis repos for proper namespace_labels ternary implementation

echo "Checking Atlantis repos for namespace_labels ternary implementation..."
echo "=========================================================================="
echo ""

repos_with_issues=()
repos_ok=()

for repo in ~/Projects/atlantis-*; do
    if [ ! -d "$repo" ]; then
        continue
    fi

    repo_name=$(basename "$repo")

    # Find all .tf files that contain google_gke_hub_namespace
    tf_files=$(find "$repo" -name "*.tf" -type f -exec grep -l "google_gke_hub_namespace" {} \;)

    if [ -z "$tf_files" ]; then
        continue
    fi

    # Check each file for namespace_labels with proper ternary
    has_namespace=false
    has_proper_ternary=false

    for tf_file in $tf_files; do
        if grep -q "google_gke_hub_namespace" "$tf_file"; then
            has_namespace=true

            # Check if namespace_labels has a ternary with enable_service_mesh
            if grep -A 5 "namespace_labels" "$tf_file" | grep -q "enable_service_mesh"; then
                has_proper_ternary=true
            fi
        fi
    done

    if [ "$has_namespace" = true ]; then
        if [ "$has_proper_ternary" = true ]; then
            repos_ok+=("$repo_name")
            echo "✓ $repo_name - OK"
        else
            repos_with_issues+=("$repo_name")
            echo "✗ $repo_name - MISSING TERNARY"

            # Show the actual namespace_labels implementation
            for tf_file in $tf_files; do
                if grep -q "namespace_labels" "$tf_file"; then
                    echo "  File: ${tf_file#$repo/}"
                    grep -A 3 "namespace_labels" "$tf_file" | sed 's/^/    /'
                fi
            done
            echo ""
        fi
    fi
done

echo ""
echo "=========================================================================="
echo "Summary:"
echo "  ✓ Repos with proper ternary: ${#repos_ok[@]}"
echo "  ✗ Repos with issues: ${#repos_with_issues[@]}"

if [ ${#repos_with_issues[@]} -gt 0 ]; then
    echo ""
    echo "Repos needing attention:"
    printf '  - %s\n' "${repos_with_issues[@]}"
fi
