#!/bin/bash

# store the current dir
CUR_DIR=$(pwd)

for i in `cat ./target_repos`; do
    
    echo "";
    echo $i;
    sed -i 's/enable_service_mesh = terraform.workspace == "onx-daily" ? true : false/enable_service_mesh = terraform.workspace == "onx-production" ? false : true/g' ./$i/locals.tf

    # We have to go to the .git parent directory to call the pull command
    cd "$i";
    git add ./locals.tf
    git commit -m 'SRE-4746 enable service mesh in staging'
    git push
    # lets get back to the CUR_DIR
    cd $CUR_DIR
done

echo "Complete!"
