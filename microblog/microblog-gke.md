
# Playing around in GKE

## Prerequisite

As a start, set the project ID: `export PROJECT_ID=neat-acre-382607`.

## Certificate management

### Integration with Cloud DNS

```bash
gcloud iam service-accounts create sa-dns01-solver --display-name "Kubernetes cert-manager DNS resolver"
gcloud projects add-iam-policy-binding $PROJECT_ID \
   --member serviceAccount:sa-dns01-solver@$PROJECT_ID.iam.gserviceaccount.com \
   --role roles/dns.admin
```

Alternatively, create a role with only the following permissions:

- dns.resourceRecordSets.*
- dns.changes.*
- dns.managedZones.list

Generate a key for the service account:

```bash
gcloud iam service-accounts keys create key.json \
  --iam-account sa-dns01-solver@$PROJECT_ID.iam.gserviceaccount.com
```

### Deploy cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.8.2/cert-manager.yaml
kubectl -n cert-manager get all
```

Create a Kubernetes secret out of the key:

```bash
kubectl -n cert-manager create secret generic \
  clouddns-dns01-solver-svc-acct --from-file=key.json
```

Generate the issuer:

```bash
MY_EMAIL=<email>

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${MY_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - dns01:
        cloudDNS:
          project: ${PROJECT_ID}
          serviceAccountSecretRef:
            name: clouddns-dns01-solver-svc-acct
            key: key.json
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${MY_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-production
    solvers:
    - dns01:
        cloudDNS:
          project: ${PROJECT_ID}
          serviceAccountSecretRef:
            name: clouddns-dns01-solver-svc-acct
            key: key.json
EOF
```

## Cluster

Create a small 2-node cluster in an manual-mode VPC. Enable [Dataplane v2](https://cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2), because eBPF FTW.

```bash
gcloud beta container clusters create demolopolis \
  --zone "europe-west3-a" \
  --network "europe-vpc" --subnetwork "west3" \
  --disk-size "50" \
  --metadata disable-legacy-endpoints=true \
  --num-nodes "1" --machine-type "e2-standard-4" \
  --no-enable-intra-node-visibility \
  --enable-dataplane-v2 \
  --addons HorizontalPodAutoscaling,GcePersistentDiskCsiDriver \
  --workload-pool "neat-acre-382607.svc.id.goog"

gcloud container clusters get-credentials demolopolis --region europe-west3-a
```

Ingress controller:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.7.1/deploy/static/provider/cloud/deploy.yaml
kubectl -n ingress-nginx get po
```

### Tools

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: netshoot
  labels:
    app.kubernetes.io/name: netshoot
spec:
  containers:
  - name: netshoot
    image: nicolaka/netshoot
    command: ['sh', '-c', 'while true; do sleep 5; done']
EOF
```

## Monitoring

### Prometheus and Grafana

Doc: <https://github.com/prometheus-operator/kube-prometheus>

```bash
mkdir ./work
docker run -it -v ${PWD}/work:/work -w /work alpine sh
apk add git
# clone using http so you don't have to install ssh
git clone --depth 1 https://github.com/prometheus-operator/kube-prometheus.git -b release-0.12 /tmp/
cp -Rp /tmp/manifests .
exit
```

Create the namespace and CRDs. Note that due to some CRD size we are using kubectl server-side apply feature:

```bash
kubectl apply --server-side -f ./work/manifests/setup
```

These are the things deployed by the setup manifests:

```log
customresourcedefinition.apiextensions.k8s.io/alertmanagerconfigs.monitoring.coreos.com serverside-applied
customresourcedefinition.apiextensions.k8s.io/alertmanagers.monitoring.coreos.com serverside-applied
customresourcedefinition.apiextensions.k8s.io/podmonitors.monitoring.coreos.com serverside-applied
customresourcedefinition.apiextensions.k8s.io/probes.monitoring.coreos.com serverside-applied
customresourcedefinition.apiextensions.k8s.io/prometheuses.monitoring.coreos.com serverside-applied
customresourcedefinition.apiextensions.k8s.io/prometheusrules.monitoring.coreos.com serverside-applied
customresourcedefinition.apiextensions.k8s.io/servicemonitors.monitoring.coreos.com serverside-applied
customresourcedefinition.apiextensions.k8s.io/thanosrulers.monitoring.coreos.com serverside-applied
namespace/monitoring serverside-applied
```

Deploy the stack:

```bash
# wait for the components to complete to avoid race condition
kubectl wait \
	--for condition=Established \
	--all CustomResourceDefinition \
	--namespace=monitoring

kubectl apply -f ./work/manifests/

kubectl -n monitoring get pods
```

node-exporter pods not being created:

```bash
┌─[lester@parrot]─[~/GitHub/microblog]
└──╼ $ kubectl -n monitoring get ds node-exporter
NAME            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
node-exporter   1         0         0       0            0           kubernetes.io/os=linux   23m
┌─[lester@parrot]─[~/GitHub/microblog]
└──╼ $ kubectl -n monitoring describe ds node-exporter | tail -4
  Type     Reason        Age                  From                  Message
  ----     ------        ----                 ----                  -------
  Warning  FailedCreate  23m (x9 over 23m)    daemonset-controller  Error creating: pods "node-exporter-" is forbidden: error looking up service account monitoring/node-exporter: serviceaccount "node-exporter" not found
  Warning  FailedCreate  114s (x10 over 23m)  daemonset-controller  Error creating: insufficient quota to match these scopes: [{PriorityClass In [system-node-critical system-cluster-critical]}]
┌─[lester@parrot]─[~/GitHub/microblog]
└──╼ $ 
```

Temporarily port-forward to test:

```bash
kubectl -n monitoring port-forward --address 0.0.0.0 svc/grafana 3000:3000
```

Define a network policy to allow Ingress and tools to reach the Prometheus and Grafana pods:

```bash
## Grafana
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  labels:
    app.kubernetes.io/component: grafana
    app.kubernetes.io/name: grafana
  name: allow-ingress-to-grafana
  namespace: monitoring
spec:
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          app.kubernetes.io/name: ingress-nginx
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: default
      podSelector:
        matchLabels:
          app.kubernetes.io/name: netshoot
    ports:
    - port: 3000
      protocol: TCP
  podSelector:
    matchLabels:
      app.kubernetes.io/component: grafana
      app.kubernetes.io/name: grafana
      app.kubernetes.io/part-of: kube-prometheus
  policyTypes:
  - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  labels:
    app.kubernetes.io/component: prometheus
    app.kubernetes.io/name: prometheus
  name: allow-ingress-to-prometheus
  namespace: monitoring
spec:
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          app.kubernetes.io/name: ingress-nginx
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: default
      podSelector:
        matchLabels:
          app.kubernetes.io/name: netshoot
    ports:
    - port: 9090
      protocol: TCP
  podSelector:
    matchLabels:
      app.kubernetes.io/component: prometheus
      app.kubernetes.io/instance: k8s
      app.kubernetes.io/name: prometheus
      app.kubernetes.io/part-of: kube-prometheus
  policyTypes:
  - Ingress
EOF

## verify that the rules have been created properly:
kubectl -n monitoring get networkpolicy allow-ingress-to-grafana -o jsonpath='{.spec.ingress[0].from[0]}' | jq ## first source
kubectl -n monitoring get networkpolicy allow-ingress-to-grafana -o jsonpath='{.spec.ingress[0].from[1]}' | jq ## second source
kubectl -n monitoring get networkpolicy allow-ingress-to-prometheus -o jsonpath='{.spec.ingress[0].from[0]}' | jq ## first source
kubectl -n monitoring get networkpolicy allow-ingress-to-prometheus -o jsonpath='{.spec.ingress[0].from[1]}' | jq ## second source

# test with netshoot
kubectl exec -it netshoot -- bash -c 'curl http://grafana.monitoring.svc.cluster.local:3000'
kubectl exec -it netshoot -- bash -c 'curl http://prometheus-k8s.monitoring.svc.cluster.local:9090'
```

Create the Ingress resource:

```bash
# get the port names
kubectl -n monitoring get svc grafana -o yaml
kubectl -n monitoring get svc prometheus-k8s -o yaml

IP=$(curl -s ipconfig.io)

# single resource, route to backend using the CNI in the request
# scenario: saving IP addresses
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: ${IP}
  name: monitoring
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
  - host: grafana.cloud.sreafterhours.com
    http:
      paths:
      - backend:
          service:
            name: grafana
            port:
              name: http
        path: /
        pathType: Prefix
  - host: prometheus.cloud.sreafterhours.com
    http:
      paths:
      - backend:
          service:
            name: prometheus-k8s
            port:
              name: web
        path: /
        pathType: Prefix
EOF
```

Create the A records in Cloud DNS:

```bash
EXT_IP=$(kubectl -n monitoring get ing monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
gcloud dns record-sets create grafana.cloud.sreafterhours.com. \
  --zone="cloud-sreafterhours-com" --type="A" --ttl="300" \
  --rrdatas="${EXT_IP}"
gcloud dns record-sets create prometheus.cloud.sreafterhours.com. \
  --zone="cloud-sreafterhours-com" --type="A" --ttl="300" \
  --rrdatas="${EXT_IP}"
```

Test:

```bash
curl -k https://grafana.cloud.sreafterhours.com/ -I
curl -k https://prometheus.cloud.sreafterhours.com/ -I
```

## Application

### Background

The application is called "microblog" and was used by [Miguel Griberg](https://github.com/miguelgrinberg) in his Flask Mega-Tutorial [blog](https://blog.miguelgrinberg.com/post/the-flask-mega-tutorial-part-i-hello-world). I cloned the repository [here](https://github.com/guerzon/microblog).

### Dockerize the application

Create the Docker Artifact Registry: <europe-west3-docker.pkg.dev/neat-acre-382607/demolopolis>

The application already had a `Dockerfile`, but there is 1 issue with the dependencies and I had some thoughts about a few things, so I recreated it as follows:

```Dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt requirements.txt
RUN pip install -r requirements.txt
RUN pip install gunicorn pymysql cryptography

COPY app app
COPY migrations migrations
COPY microblog.py config.py boot.sh ./
RUN chmod a+x boot.sh

ENV FLASK_APP microblog.py

EXPOSE 5000
ENTRYPOINT ["./boot.sh"]
```

### GitHub Actions

The following action builds the image and pushes it to Artifact Registry. One thing to note is the usage of git tag as the corresponding image tag:

```yaml
name: Release
on: 
  push:

jobs:
  docker-image-release:
    name: Build & push to Google Artifact Registry
    runs-on: ubuntu-latest
    if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags')

    steps:

      - name: Checkout
        id: checkout
        uses: actions/checkout@v3

      - name: Authenticate to Google Cloud
        id: auth
        uses: google-github-actions/auth@v0
        with:
          token_format: access_token
          credentials_json: '${{ secrets.B64_GCLOUD_SERVICE_ACCOUNT_JSON }}'

      - name: Login to the registry
        uses: docker/login-action@v1
        with:
          registry: europe-west3-docker.pkg.dev
          username: oauth2accesstoken
          password: '${{ steps.auth.outputs.access_token }}'

      - name: Get image tag
        id: get-image-tag
        run: echo ::set-output name=short_ref::${GITHUB_REF#refs/*/}

      - name: Build and push the image
        id: build-tag-push
        uses: docker/build-push-action@v2
        with:
          push: true
          tags: |
            europe-west3-docker.pkg.dev/neat-acre-382607/demolopolis/microblog:${{ steps.get-image-tag.outputs.short_ref }}
            europe-west3-docker.pkg.dev/neat-acre-382607/demolopolis/microblog:latest
```

### Deployment

The following command creates a namespace for the application, the deployment with 1 replica, and an nginx ingress resource.

The nginx resource is annotated to allow only my public IP address. This allows me to easily add some layer of security to my deployment while testing.

```bash
kubectl apply -f manifests/
```

Wait for the certificate to be signed and the Load-Balancer to allocate a public IP address:

```bash
kubectl -n microblog get cert,ing
```

Create the A record in Cloud DNS:

```bash
EXT_IP=$(kubectl -n microblog get ing microblog -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
gcloud dns record-sets create microblog.cloud.sreafterhours.com. \
  --zone="cloud-sreafterhours-com" --type="A" --ttl="300" \
  --rrdatas="${EXT_IP}"
```

Application is now available at <https://microblog.cloud.sreafterhours.com>.

## Cleanup

```bash
rm -rf ./work key.json
gcloud dns record-sets delete grafana.cloud.sreafterhours.com. --zone="cloud-sreafterhours-com" --type="A"
gcloud dns record-sets delete prometheus.cloud.sreafterhours.com. --zone="cloud-sreafterhours-com" --type="A"
gcloud dns record-sets delete microblog.cloud.sreafterhours.com. --zone="cloud-sreafterhours-com" --type="A"
gcloud container clusters delete demolopolis --region europe-west3-a
```
