## Tonic Fabricate (Helm + Terraform)

This repository contains a Helm chart that deploys Fabricate (web, worker, PDF sidecar, postgresql - optional, redis - optional), and optional Terraform templates for common cloud providers that provision the resources.

| Provider | Main resources Terraform creates |
|----------|----------------------------------|
| **AWS** (default) | EKS Auto Mode cluster, RDS PostgreSQL, ElastiCache Redis, S3 bucket, Bedrock API key, IAM roles, CloudWatch log groups |
| **GCP** | GKE Standard cluster, PostgreSQL and Redis |

#### Repository layout

```
Chart.yaml, templates/                             Helm chart (the chart root is the repo root)
values.example.yaml                                Chart default values (committed)
values.yaml                                        Your local copy of the defaults (gitignored, see below)
terraform/                                         Terraform root module (cluster + Helm releases)
terraform/aws/, terraform/gcp/                     Cloud modules (selected by the `cloud` variable)
terraform/aws.tfvars.example, gcp.tfvars.example   Variables templates
```

## Requirements

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.15
- [Helm](https://helm.sh/docs/intro/install/) 3.x
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (also used by Terraform to wait for the load balancer)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (for AWS) or [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) `gcloud` (for GCP)
- Quay pull credentials for the Fabricate images (username and password/token)

## Fabricate Requirements
- Cluster Nodes with Linux Kernel 6.2+ and Landlock ABI v3 support
- Cluster/Pod SecurityContext policy that allows the `SYS_PTRACE` capability
- Minimum: 2 CPU cores (amd64/arm64), 4 GiB RAM, 32 GiB persistent disk
- An external SMTP server (host, port, username, password and from address, set as `FABRICATE_MAIL_*`)
- LLM AI Provider (Anthropic, OpenAI, Amazon Bedrock, Azure AI Foundry, Gemini Enterprise Agent Platform)

## Deployment

- [Deploy to AWS EKS](#deploy-on-aws)
- [Deploy to GCP GKE](#deploy-on-gcp)

## Deploy on AWS

### 1. Authenticate and choose the region

```bash
aws configure                      # or: aws sso login --profile <profile>
aws sts get-caller-identity        # confirm the right account (avoid the root user)

export AWS_REGION=us-east-1        # must equal kube_region in terraform.tfvars
```

By default the cluster, RDS and ElastiCache use the account's **default VPC** (it must exist). To use another VPC set `kube_vpc_id` (and optionally `kube_subnet_ids`, in at least two AZs). If you don't set `kube_subnet_ids`, two subnets in two EKS-supported AZs are chosen automatically. **No NAT gateway is created**: nodes get public IPs from the subnets, so custom subnets must auto-assign public IPs and route to an internet gateway.

### 2. Configure variables

```bash
cp values.example.yaml values.yaml
cd terraform
cp aws.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` (gitignored):

```hcl
cloud        = "aws"
kube_region  = "us-east-1"
kube_cluster = "fabricate-eks"

fabricate_env = {
  FABRICATE_HOST           = "fabricate.example.com" # your domain, see step 4
  FABRICATE_ADMIN_EMAIL    = "admin@example.com"     # becomes the admin after sign-up
  FABRICATE_MAIL_ADDRESS   = "smtp.example.com"
  FABRICATE_MAIL_PORT      = "587"
  FABRICATE_MAIL_USER_NAME = "no-reply@example.com"
  FABRICATE_MAIL_PASSWORD  = "<smtp password>"
  FABRICATE_MAIL_FROM      = "no-reply@example.com"
}

fabricate_registry_host     = "quay.io"
fabricate_registry_username = "<username>"
```

Pass the registry password through the environment, not the file:

```bash
export TF_VAR_fabricate_registry_password='<password>'
```

You don't need to set database, Redis, S3 or Bedrock values: Terraform generates and wires them´,

### 3. Create everything

```bash
terraform init -upgrade
terraform plan
terraform apply
```

This provisions the AWS resources **and** installs the Helm chart, then waits (up to `wait_for_ingress_timeout`, default 900 s) for the load balancer and prints it as `fabricate_ingress_address`. The first apply takes roughly 20–30 minutes (EKS, RDS and ElastiCache are the slow parts). If Helm times out, raise `kube_helm_timeout` and re-run `terraform apply`. Don't run two Terraform commands at once (state lock).

When the apply succeeds, Terraform prints the outputs. The one you need is `fabricate_ingress_address`: the DNS name of the load balancer (ALB) that serves Fabricate. Point your domain at it with a CNAME record (see [step 4](#4-open-fabricate-dns)).

```
Outputs:

fabricate_database_password = <sensitive>
fabricate_ingress_address   = "k8s-fabricat-fabricat-xxxxxxxxxx-xxxxxxxxxx.us-east-1.elb.amazonaws.com"
fabricate_redis_password    = <sensitive>
fabricate_secret_key_base   = <sensitive>
```

Sensitive values are hidden in this output. Print any output later with `terraform output <name>`; add `-raw` for secrets, for example `terraform output -raw fabricate_database_password`. They are also in the Terraform state, so protect it (or use a remote backend with encryption).

Bedrock is configured automatically, but the models must be enabled in your AWS account: open the Bedrock console, Model access, in your region, and enable the Anthropic models you want. Otherwise model calls fail with access denied.

### 4. Open Fabricate (DNS)

```bash
terraform output fabricate_ingress_address     # the ALB DNS name
```

`FABRICATE_HOST` **must match the domain you browse to**, otherwise requests are rejected.

1. Create a DNS `CNAME` (for example `fabricate.example.com`) pointing at the ALB name.
2. Set `FABRICATE_HOST = "fabricate.example.com"` in `fabricate_env` in `terraform.tfvars`.
3. `terraform apply`.

For HTTPS set `FABRICATE_PROTOCOL = "https"` and add a certificate to the ALB through `fabricate_ingress` (for example the `alb.ingress.kubernetes.io/certificate-arn` annotation, or `ingress.tls` with cert-manager); see `ingress` in [values.yaml](values.yaml). Then browse to the URL and sign up with `FABRICATE_ADMIN_EMAIL`.

## Deploy on GCP

```bash
gcloud auth application-default login
gcloud services enable container.googleapis.com --project <project-id>

cp values.example.yaml values.yaml
cd terraform
cp gcp.tfvars.example terraform.tfvars      # set project_id, kube_region, SMTP, registry username
export TF_VAR_fabricate_registry_password='<password>'

terraform init -upgrade
terraform plan
terraform apply

gcloud container clusters get-credentials fabricate-gke --region us-central1 --project <project-id>
kubectl get pods -n fabricate
terraform output fabricate_ingress_address    # load balancer IP
```

On GCP, PostgreSQL and Redis run **in the cluster** (StatefulSets with PVCs); there is no managed database. GKE Standard with Ubuntu nodes is required because `deno_sandbox` needs Landlock (not available on Autopilot / COS). Node pools are Arm (`t2a-standard-*`) by default; the chart tolerates the `kubernetes.io/arch=arm64` taint. GKE-only settings are in [terraform/gcp/variables.tf](terraform/gcp/variables.tf). `skip_helm` works the same way as on AWS.

## What Terraform wires in (AWS)

Terraform builds the app configuration and the chart stores it in the Kubernetes Secret `<app>-<environment>-env` (default `fabricate-prod-env`). The pods read it as environment variables. It contains:

| Keys | Where they come from |
|------|----------------------|
| `FABRICATE_DATABASE_HOST`, `_PORT`, `_NAME`, `_USERNAME`, `_PASSWORD` | RDS (the password is generated) |
| `FABRICATE_REDIS_URL`, `FABRICATE_REDIS_PASSWORD` | ElastiCache (`rediss://`, TLS with an AUTH token; the password is generated) |
| `FABRICATE_STORAGE_SERVICE` (`amazon`), `FABRICATE_S3_BUCKET`, `FABRICATE_AWS_REGION` | S3 bucket created by Terraform; **no keys**, the pods use an IAM role (IRSA) |
| `FABRICATE_BEDROCK_API_KEY`, `FABRICATE_BEDROCK_REGION` | Bedrock API key created by Terraform (valid `bedrock_api_key_age_days`, default 365) and the model prefix derived from the region (`us`, `eu`, `apac`, else `global`; override with `bedrock_inference_prefix`) |
| `SECRET_KEY_BASE` | generated |
| `FABRICATE_SIDEKIQ_CONCURRENCY`, `FABRICATE_DB_POOL_SIZE` | `10` and `20`, sized for the single node and the small database |
| `FABRICATE_HOST`, `FABRICATE_ADMIN_EMAIL`, `FABRICATE_MAIL_*`, `FABRICATE_DEPLOYMENT`, ... | your `fabricate_env` in `terraform.tfvars` (anything you set there overrides the values above) |
| `FABRICATE_PROTOCOL`, `FABRICATE_PORT`, `FABRICATE_DATA_DIR`, `FABRICATE_LOG_LEVEL`, `FABRICATE_ORGANIZATION_NAME`, `FABRICATE_PDF_SOCKET_PATH` | chart defaults (override them in `fabricate_env` too) |

List the keys in your cluster (names only), or read one value:

```bash
kubectl get secret -n fabricate fabricate-prod-env -o json | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin)["data"])))'
kubectl get secret -n fabricate fabricate-prod-env -o jsonpath='{.data.FABRICATE_STORAGE_SERVICE}' | base64 -d
```

## Operations

Connect kubectl to the cluster and look around:

```bash
aws eks update-kubeconfig --region "$AWS_REGION" --name fabricate-eks   # your kube_cluster value
kubectl get nodes,pods,pvc -n fabricate
```

```bash
# apply changes to tfvars or chart files
terraform apply

# re-deploy the pods without other changes: bump FABRICATE_DEPLOYMENT in fabricate_env (for example "1" -> "2"),
# then terraform apply (the env Secret changes, so the pods roll)

# force Helm to re-create the release (this deletes the PVCs and their data!)
terraform apply -replace='helm_release.fabricate[0]'

# remove everything
terraform destroy
```

## Troubleshooting

Start here, then use the symptom list below:

```bash
kubectl get nodes,pods,pvc -n fabricate                 # is a node up? are pods Running / PVCs Bound?
kubectl describe pod -n fabricate <pod>                 # the Events at the bottom say why a pod is Pending or failing
kubectl logs -n fabricate deploy/fabricate-prod-web --tail=50          # also -worker; add --previous after a crash
aws logs tail /aws/eks/fabricate-eks/application --since 30m --region us-east-1   # same logs in CloudWatch (AWS)
```

**Release hangs / `terraform apply` is stuck on Helm.** The release waits for its pods to become ready. Find out why they aren't (Pending or crashing, see below). To unblock Terraform, run `helm uninstall fabricate -n fabricate` from another terminal, fix the cause and apply again.

**Pods are `Pending`: check node availability.** `kubectl get nodes` should show a node, and `kubectl describe pod` shows the reason.
- *No nodes (AWS):* `kubectl get nodepool,nodeclaim` and `kubectl describe nodeclass default`. The cluster IAM role needs the Auto Mode managed policies and `sts:TagSession`, and the node role needs `AmazonEKSWorkerNodeMinimalPolicy` and `AmazonEC2ContainerRegistryPullOnly` (Terraform sets these). Also check the node pool's instance type and CPU limit (`eks_instance_type`, `eks_node_count`).
- *"provisioner is not supported" or PVCs Pending (AWS):* the EBS StorageClass must use `ebs.csi.eks.amazonaws.com`. A StorageClass provisioner cannot be changed in place: uninstall the release and apply again.
- *"didn't match PersistentVolume's node affinity":* sibling pods share RWO volumes; keep `podColocation` on and use the WaitForFirstConsumer StorageClass (both set by Terraform). `storageClassName` on existing PVCs is immutable: delete the PVCs and let Helm recreate them.
- *Untolerated taints or no arm64 image:* check `kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'` and extend `tolerations`; if an image has no arm64 build, remove the `nodeSelector` entries in [terraform/aws/outputs.tf](terraform/aws/outputs.tf).

**Containers crash or restart (`CrashLoopBackOff`, `Error`).** Read the first lines of the logs (ignore the long stack trace) and the CloudWatch group `/aws/eks/<kube_cluster>/application`. Usual causes:
- `Not authorized to perform sts:AssumeRoleWithWebIdentity`: the service account name must equal the one the IAM role trusts (`<app>-<environment>-sa`). Terraform passes the same name to both; it differs only if you override `serviceAccount.name` or change `fabricate_app`/`fabricate_environment` without applying the role change.
- Cannot reach RDS or ElastiCache: both accept traffic only from the EKS cluster security group; check the security groups and subnets in the AWS console.
- `Permission denied` on a volume for one pod only: SELinux (Bottlerocket) labels a shared volume for the first pod that mounts it. The chart sets one `volumesSecurity.seLinuxLevel` on all three pods and a busybox init makes the volumes writable. Check: `kubectl exec -n fabricate deploy/fabricate-prod-worker -- sh -c 'cat /proc/self/attr/current; touch /mnt/fabricate/data/.w && echo writable'`. All three pods should show the same level (`s0:c100,c200`).

**502/503, or no load balancer address.**
- Address stays empty (AWS): EKS Auto Mode needs the `alb` IngressClass that Terraform creates through `additionalResources`. Check `kubectl get ingressclass` and `kubectl describe ingress -n fabricate`; the load balancer takes 2–5 minutes.
- 502/503 right after a deployment: web rolls one new pod at a time (`services.web.rollingUpdate`, probes and `preStopSleepSeconds` in [values.yaml](values.yaml)), so a few seconds of 502/503 can still occur while the ALB registers the new pod. Check `kubectl rollout status deploy/fabricate-prod-web -n fabricate` and the target health of the ALB in the AWS console.

**The admin console reports a problem.**
- *"No AI agent provider is configured":* Bedrock appears only when `FABRICATE_BEDROCK_API_KEY` is set (Terraform creates it) and the models are enabled in the Bedrock console. After the key expires, replace it: `terraform apply -replace='module.cluster.aws_iam_service_specific_credential.bedrock'`.
- *Storage is `local` or not writable:* `FABRICATE_STORAGE_SERVICE` must be `amazon` in the Secret. Check any value with `kubectl get secret -n fabricate fabricate-prod-env -o jsonpath='{.data.<NAME>}' | base64 -d`; values set in `env` override the chart defaults.
- *Script check fails (Landlock / `deno_sandbox`):* needs kernel 6.2+ with Landlock ABI v3. Test with `kubectl exec -n fabricate deploy/fabricate-prod-worker -- sh -c 'mkdir -p /mnt/fabricate/data/_sb && /usr/local/bin/deno_sandbox --current-dir /mnt/fabricate/data/_sb check --input /dev/null 2>&1 | head -5'`. If the node image lacks Landlock, Auto Mode is not usable for this app: use a self-managed node group on an image with Landlock (for example the Ubuntu EKS AMI).

**Terraform errors.**
- *`Error acquiring the state lock`:* another Terraform command is still running (or was killed). Wait for it; use `terraform force-unlock <ID>` only if nothing is running.
- *Helm `cannot re-use a name that is still in use`:* the release exists in the cluster but not in the state: `terraform import 'helm_release.fabricate[0]' 'fabricate/fabricate'`.
- *GKE `409 Already exists`:* import the cluster and node pool: `terraform import 'module.cluster.google_container_cluster.primary' 'projects/PROJECT/locations/REGION/clusters/CLUSTER'` and `terraform import 'module.cluster.google_container_node_pool.primary' 'projects/PROJECT/locations/REGION/clusters/CLUSTER/nodePools/CLUSTER-pool'`.
- *Changing `cloud` (aws ↔ gcp):* run `terraform init -reconfigure` and use a separate workspace (`terraform workspace new aws`), otherwise Terraform plans to delete the other cloud's resources.

## License

[BSD 3-Clause License](LICENSE).
