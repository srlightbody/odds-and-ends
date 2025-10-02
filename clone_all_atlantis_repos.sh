#!/bin/bash
gh repo list onxmaps --limit 2000 | grep atlantis | while read -r repo _; do
    if [ ! -d `echo $repo | sed 's:.*/::'` ]; then
        gh repo clone $repo 
    fi
done
