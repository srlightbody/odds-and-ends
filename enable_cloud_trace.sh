#!/bin/bash
cat <<EOF | kubectl apply -n istio-system -f -
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
   name: enable-cloud-trace
   namespace: istio-system
spec:
   tracing:
   - providers:
     - name: stackdriver
EOF
