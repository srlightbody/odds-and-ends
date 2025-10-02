#!/bin/bash

# store the current dir
CUR_DIR=$(pwd)


# Find all git repositories and update it to the master latest revision
for i in $(find . -mindepth 1 -maxdepth 1 -type d -name "atlantis-*"); do
    echo "";
    echo $i;

    # We have to go to the .git parent directory to call the pull command
    cd "$i";
    terraform workspace select onx-production
    # lets get back to the CUR_DIR
    cd $CUR_DIR
done

echo "Complete!"
