#!/usr/bin/env bash

set -euo pipefail

# Default values
FORCE=false
SEARCH_PATH="$HOME/Projects"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        *)
            SEARCH_PATH="$1"
            shift
            ;;
    esac
done

# Check if gh is installed
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed"
    echo "Install it from: https://cli.github.com/"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo "Error: Not authenticated with GitHub CLI"
    echo "Run: gh auth login"
    exit 1
fi

echo "Checking repositories in: $SEARCH_PATH"
echo ""

# Array to store archived repositories
archived_repos=()

# Find all git repositories
while read -r git_dir; do
    repo_path=$(dirname "$git_dir")
    repo_name=$(basename "$repo_path")

    cd "$repo_path"

    # Get remote URL
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")

    if [[ -z "$remote_url" ]]; then
        echo "⊘ $repo_name: No remote origin configured"
        continue
    fi

    # Extract owner/repo from URL
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        full_name="$owner/$repo"

        # Check if archived using gh api
        archived=$(gh api "repos/$full_name" --jq '.archived' 2>/dev/null || echo "error")

        if [[ "$archived" == "error" ]]; then
            echo "⚠ $repo_name: Could not fetch repository info"
            continue
        fi

        if [[ "$archived" == "true" ]]; then
            echo "📦 $repo_name: ARCHIVED ($full_name)"
            archived_repos+=("$repo_path|$repo_name|$full_name")
        else
            echo "✓ $repo_name: Active"
        fi
    else
        echo "⊘ $repo_name: Not a GitHub repository"
    fi
done < <(find "$SEARCH_PATH" -maxdepth 2 -name ".git" -type d)

echo ""

# Summary and cleanup
if [[ ${#archived_repos[@]} -eq 0 ]]; then
    echo "No archived repositories found."
else
    echo "Found ${#archived_repos[@]} archived repository/repositories:"
    echo ""
    for entry in "${archived_repos[@]}"; do
        IFS='|' read -r path name full <<< "$entry"
        echo "  - $name ($full)"
    done
    echo ""

    if [[ "$FORCE" == "true" ]]; then
        echo "Removing all archived repositories..."
        for entry in "${archived_repos[@]}"; do
            IFS='|' read -r path name full <<< "$entry"
            rm -rf "$path"
            echo "  ✓ Removed $name"
        done
    else
        read -p "Remove all archived repositories? (y/N): " -n 1 -r < /dev/tty
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for entry in "${archived_repos[@]}"; do
                IFS='|' read -r path name full <<< "$entry"
                rm -rf "$path"
                echo "  ✓ Removed $name"
            done
        else
            echo "Skipped removal."
        fi
    fi
fi

echo ""
echo "Done!"
