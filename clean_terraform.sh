#!/bin/bash
ROOT=$(pwd)
for i in $(ls | grep atlantis-); do
    echo "Cleaning $i"
    cd $i
    rm -rf ./.terraform/providers/registry\.terraform\.io
    cd $ROOT
done
