```
kubectl create serviceaccount billmanh-user -n default
```


```
kubectl create clusterrolebinding billmanh-user-binding --clusterrole cluster-admin --serviceaccount default:billmanh-user
```

```
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: billmanh-user-secret
  annotations:
    kubernetes.io/service-account.name: billmanh-user
type: kubernetes.io/service-account-token
EOF
```

```
TOKEN=$(kubectl get secret billmanh-user-secret -o jsonpath='{$.data.token}' | base64 -d | sed 's/$/\n/g')
```