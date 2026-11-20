#!/bin/sh
kubectl label node k8s-w1.wuest.de hammerspace-tier0=enabled
kubectl label node k8s-w2.wuest.de hammerspace-tier0=enabled
kubectl label node k8s-w3.wuest.de hammerspace-tier0=enabled
