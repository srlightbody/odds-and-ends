#!/bin/bash
cp ~/Projects/atlantis-template-simple/namespace.tf ~/Projects/$1/
if ! grep google_project ~/Projects/$1/data.tf; then
    sed -i '1idata "google_project" "project" {}\n' ~/Projects/$1/data.tf
fi
if ! grep namespace ~/Projects/$1/locals.tf; then
    sed -i 's/}/  namespace = replace(local.repository, "atlantis-","")\n}/' ~/Projects/$1/locals.tf
fi

echo "

# moved {
#   from = module.deployments_central1_new
#   to = module.deployments_central1
# }
# moved {
#   from = module.deployments_west1_new
#   to = module.deployments_west1
# }

">> ~/Projects/$1/deployments.tf
