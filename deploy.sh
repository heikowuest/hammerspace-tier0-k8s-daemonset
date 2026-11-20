#!/bin/sh
kubectl create ns storage || true
kubectl apply -f knfsd-nfs3-daemonset.yaml
sleep 5
kubectl -n storage get ds,pods -o wide
#kubectl -n storage logs -l app=knfsd-nfs3-exporter --tail=200
