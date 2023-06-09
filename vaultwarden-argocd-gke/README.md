
# External DNS, cert-manager, nginx, Terraform, and Vaultwarden on GKE

..or how to run your own private password manager in the cloud.

## 1. Housekeeping

### 1.1 Introduction
In my previous [post](https://medium.com/@sreafterhours/playing-around-with-google-kubernetes-engine-57b333d5dc21), I shared how I set up a demo GKE cluster, installed some things, and deployed a sample application called `microblog`.

In this post, I will share how I do the following:

1. Build the VPC and the GKE cluster using Terraform.
2. Automate DNS provisioning with External DNS
3. Automate certificate mangement using External DNS.
4. Build a privately-accessible Cloud SQL PostgreSQL instance using Terraform.
5. Deploy nginx ingress controller.
6. Deploy [Vaultwarden](https://github.com/guerzon/vaultwarden) using Helm and [GKE Ingress](https://cloud.google.com/kubernetes-engine/docs/concepts/ingress).
7. Manage continuous deployment using [ArgoCD](https://argo-cd.readthedocs.io/en/stable/understand_the_basics/).

### 1.2 About the app

The application I am deploying is called `Vaultwarden`, which is written in [Rust](https://www.rust-lang.org/) and is an alternative implementation of the popular open source password manager [Bitwarden](https://bitwarden.com/). This server API has been designed to be compatible with the [upstream Bitwarden apps](https://bitwarden.com/download/).

### 1.3 Prerequisites

1. Install [Terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli).
2. Install `gcloud` and authenticate using [User Application Default Credentials](https://cloud.google.com/docs/authentication/provide-credentials-adc).

## 2. GKE cluster

### 2.1 Terraform

Create the Terraform files based on the provider documentation: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster>. The terraform manifests below would:

1. Create a new VPC and a subnet in the `europe-west3` region.
2. Create a zonal cluster in `europe-west3-a`.
3. Specify Dataplane v2 which is implemented using [Cilium](https://cilium.io/) and uses [eBPF](https://ebpf.io/what-is-ebpf/). Side note: I opened a [PR](https://github.com/GoogleCloudPlatform/magic-modules/pull/8093) to the Terraform provider regarding this topic.
4. Enable [VPC-native networking](https://cloud.google.com/kubernetes-engine/docs/concepts/alias-ips). This would create network endpoint groups (NEG's), the benefits of which were well-explained by [this](https://medium.com/google-cloud/nuts-and-bolts-of-negs-network-endpoint-groups-in-gcp-35b0d06f4691) post.
5. Create a new node pool with 2 `e2-medium` nodes.


`provider.tf`:

```tf
```

`main.tf`:

```tf
```

The single-use module is simplified for this task.

Run terraform init, fmt, validate.

```bash
# specify the project ID
export GOOGLE_PROJECT=neat-acre-382607

# build the VPC and the GKE cluster
terraform plan
terraform apply

# configure kubectl and create the vaultwarden namespace:
gcloud container clusters get-credentials demolopolis --zone europe-west3-a
kubectl create ns vaultwarden
```

### 2.2 Service account for ExternalDNS and cert-manager

Create a service account with static credentials as done [previously](https://medium.com/@sreafterhours/playing-around-with-google-kubernetes-engine-57b333d5dc21).

This service account would be used by ExternalDNS and cert-manager running inside the Kubernetes cluster to interact with Cloud DNS.

```bash
SA_NAME="cloud-dns-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts create $SA_NAME --display-name "ExternalDNS and cert-manager service account"

# assign the DNS administrator role (I'm feeling generous)
gcloud projects add-iam-policy-binding $PROJECT_ID --member serviceAccount:$SA_EMAIL --role roles/dns.admin

# create a key for the service account and export it as key.json
gcloud iam service-accounts keys create key.json --iam-account $SA_EMAIL
```

### 2.3 ExternalDNS

My subdomain `cloud.sreafterhours.com` has been delegated to Cloud DNS:

![](../assets-shared/images/cloud-dns-record.png)

ExternalDNS comes in handy to synchronize the endpoints (such as Ingress) with the records in Cloud DNS. In other words, when I (de-)provision and Ingress resource and a Google Cloud external HTTP(s) load balancer gets (de-)provisioned, I don't have to manually update the A records in my zone in Cloud DNS.

```bash
# create the external-dns namespace and create a secret in that namespace containing the service account key:
kubectl create ns external-dns
kubectl -n external-dns create secret generic ${SA_NAME}-creds --from-file=key.json

# finally, deploy ExternalDNS:
kubectl -n external-dns apply -f external-dns.yaml
```

`external-dns.yaml`:

```yaml

```

### 2.4 cert-manager

[cert-manager](https://cert-manager.io/docs) is a [CNCF project](https://landscape.cncf.io/) under incubation that helps us quickly provision SSL certificates to be consumed by Kubernetes endpoints such as the ones created by Ingress at a later step.

To solve ownership challenge, we give it access to my existing hosted DNS zone in Cloud DNS.

```bash
# deploy cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.8.2/cert-manager.yaml
kubectl -n cert-manager get all

# create the same secret as above, but inside the cert-manager namespace:
kubectl -n cert-manager create secret generic ${SA_NAME}-creds --from-file=key.json
rm -f ./key.json

# admin email for the ACME cert:
MY_EMAIL=guerzon@proton.me

# deploy a cluster issuer, specifying the project ID and the secret key containing the service account's key:
cat <<EOF | kubectl apply -f -
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
          project: ${GOOGLE_PROJECT}
          serviceAccountSecretRef:
            name: ${SA_NAME}-creds
            key: key.json
EOF

# verify readiness of the cluster issuer:
kubectl get clusterissuer
```

One advantage of authenticating to Cloud DNS with SA static credentials is that the Cloud DNS resource don't have to be in the same project as the GKE cluster.

Now, we're ready to create the certificate for vaultwarden:

```bash
cat <<EOF | kubectl apply -f -
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vaultwarden-tls
  namespace: vaultwarden
spec:
  secretName: vaultwarden-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
  - vault.cloud.sreafterhours.com
EOF
```

If you are familiar with PKI and the certificate creation process, you could expect that the certificate generation could take minutes. You could monitor the status of the request by following the trail:

```bash
kubectl -n vaultwarden get cert,certificaterequest,order,challenge
```

If done correctly, you should have shiny new SSL certificate stored as a Kubernetes secret:

```bash
kubectl -n vaultwarden get secret vaultwarden-tls -o yaml
```

### 2.5 ingress-nginx

Deploy ingress-nginx:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.7.1/deploy/static/provider/cloud/deploy.yaml

# verify:
kubectl -n ingress-nginx get po
```

## 3. Cloud SQL

We're going to create a PostgreSQL instance which will be used by the application for persistent storage.

As a best practice, we will not expose the database to the outside world. Instead, we will create configure it with a private IP.

To start, enable the required API:

```bash
gcloud services enable servicenetworking.googleapis.com
```

Allocate a `/20` private IP block. This will be used by the Cloud SQL instance later and will be peered to the VPC.

```tf
resource "google_compute_global_address" "private_ip_block" {
  name          = "private-ip-block"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  ip_version    = "IPV4"
  prefix_length = 20
  network       = google_compute_network.demolopolis_vpc.self_link
}
```

Configure [private services access](https://cloud.google.com/sql/docs/postgres/configure-private-services-access). This enables the Kubernetes nodes in the VPC `demolopolis-vpc` to reach the Cloud SQL instance VPC network via [VPC peering](https://cloud.google.com/vpc/docs/vpc-peering).

```tf
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.demolopolis_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_block.name]
}
```

![](./assets/dmo.png)

![](./assets/dmo2.png)

After running terraform apply again, you should have a running SQL instance:

![](./assets/dmo3.png)

Notice the IP address belonging to the private IP block allocated earlier.

Verify connection to the database by spawning a pod on the cluster:

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
pod/netshoot created

# exec to the pod:
kubectl exec -it netshoot -- bash

# install the postgresql client:
apk --update add postgresql14-client

# connect:
psql -h 10.15.48.3 -d vaultwarden -U appuser -c "\\l"
```

Result:

![](./assets/dmo4.png)

Fancy!

Now, let's save the database information to a Kubernetes secret:

```bash
# encode the credentials:
DB_STRING="postgresql://appuser:apppassword@10.15.48.3:5432/vaultwarden"

# create the secret:
kubectl -n vaultwarden create secret generic \
  prod-db-creds --from-literal=secret-uri=$DB_STRING
```

## 4. Vaultwarden

Clone the repository:

```bash
git clone https://github.com/guerzon/vaultwarden.git
cd vaultwarden
```

Store the SMTP credentials as a Kubernetes secret:

```bash
# create a secret with SMTP credentials:
U=$(echo -n username | base64)
P=$(echo -n password | base64)
kubectl -n vaultwarden create secret generic \
  smtpcreds --from-literal=MAIL_USER=$U --from-literal=MAIL_PASS=$P
```

Create the following values containing our deployment information as `values-gke.yaml`:

```yaml

domain: "https://vault.cloud.sreafterhours.com"
image:
  tag: "1.28.1"

adminToken:
  value: "khit9gYQV6ax9LKTTm+s6QbZi5oiuR+3s1PEn9q3IRmCl9IQn7LmBpmFCOYTb7Mr"

signupDomains: "cloud.sreafterhours.com"

smtp:
  existingSecret: "smtpcreds"
  host: smtp.gmail.com
  from: postmaster@vault.cloud.pidnull.io
  username:
    existingSecretKey: "MAIL_USER"
  password:
    existingSecretKey: "MAIL_PASS"

storage:
  enabled: true
  size: "20Gi"
  class: "standard-rwo"

database:
  type: "postgres"
  existingSecret: "prod-db-creds"
  existingSecretKey: "secret-uri"

ingress:
  enabled: true
  class: "nginx"
  hostname: "vault.cloud.sreafterhours.com"
  tls: true
  tlsSecret: "vaultwarden-tls"
```

There are a few things to unpack here:

1. We're specifying the domain name where the application is accessed.
2. We are specifying the administrative user's password.
3. Image tags of the application version we want to deploy.
4. List of domain names for user who are allowed to register. By default, user registration is allowed and users are required to verify their accounts.
4. SMTP credentials that allows the application to send emails, such as during the sign-up process. As you could tell, the SMTP details in these example are dummy and won't work.
5. Create a Cloud Storage disk of `20Gi` and attach to the `statefulset`. This is then mounted in the container as `/data` and will contain all persistent data, including attachments at `/data/attachments`.
6. The Cloud SQL database information including the secret from an earlier step.
7. Finally, ingress information. In this example, we are provisioning an ingress-nginx resource and telling it to use the secret containing the SSL certificate we requested earlier using cert-manager.

A more detailed Helm chart parameter documentation can be found here: <https://github.com/guerzon/vaultwarden/tree/main/charts/vaultwarden>

Deploy the chart:

```bash
# verify:
helm template -n vaultwarden vaultwarden charts/vaultwarden -f values-gke.yaml

# finally, deploy the chart:
helm upgrade -i -n vaultwarden vaultwarden charts/vaultwarden -f values-gke.yaml
```

Verify the pod is running:

```bash
kubectl -n vaultwarden get po,ing
```

DNS record in CloudDNS is automatically provisioned by ExternalDNS.

![](./assets/vaultwarden-1.png)

Visit the application:

![](./assets/vaultwarden.png)

Visit the admin page at `/admin` and login using the admin credentials specified in the values file earlier:

![](./assets/adminpage.png)

Here you could specify additional settings, view and invite users, and view application configuration information.

![](./assets/diag.png)

Congratulations! Now you also have a privately-managed open source password manager!

## 5. Final words

### 5.1 Limitations

1. The chart currently does not support running multiple replicas since this would require a few tweaks. Adding support for running [multiple replicas](https://github.com/guerzon/vaultwarden/issues/27) has been planned for a future update.
2. The application currently does not support object storage backends for persistent storage.

### 5.2 References

1. Where to find all the features of this application, including missing features that are available to the official Bitwarden server API: <https://github.com/dani-garcia/vaultwarden/wiki>
2. The application repository can be found here: <https://github.com/dani-garcia/vaultwarden>
3. The Helm chart can be found here: <https://github.com/guerzon/vaultwarden>

### 5.3 Cleanup

```bash
helm -n vaultwarden uninstall vaultwarden
kubectl -n vaultwarden delete pvc vaultwarden-data-vaultwarden-0

terraform destroy

gcloud projects remove-iam-policy-binding $GOOGLE_PROJECT \
   --member serviceAccount:sa-dns01-solver@$GOOGLE_PROJECT.iam.gserviceaccount.com \
   --role roles/dns.admin
gcloud iam service-accounts delete sa-dns01-solver@$GOOGLE_PROJECT.iam.gserviceaccount.com
```
