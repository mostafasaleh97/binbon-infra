# binbon-infra

Terraform for the **dev** environment of [binbon-demo](https://github.com/mostafasaleh97/binbon-demo):
a FastAPI photo app on **ECS Fargate** behind an **ALB**, with **PostgreSQL** (as a Fargate task),
**ElastiCache Redis**, **S3**, **Secrets Manager** and a **GitHub Actions** deploy role.

This README explains **what every block does and why**, then shows how to create the same
resources **by hand in the AWS console**. Read it together with the app repo's README, which explains
the app and the CI/CD pipeline.

> This is a short-lived dev environment: create it, test it, destroy it the same day.
> The **NAT gateway**, the **ALB** and **ElastiCache** are billed per hour while they exist.

---

## Contents

1. [Architecture](#1-architecture)
2. [Quick start](#2-quick-start)
3. [Terraform in 5 minutes (how to read these files)](#3-terraform-in-5-minutes)
4. [IAM concepts used here](#4-iam-concepts-used-here)
5. [File-by-file, block-by-block](#5-file-by-file-block-by-block)
6. [Building the same thing in the AWS console](#6-building-the-same-thing-in-the-aws-console)
7. [Tear down](#7-tear-down)
8. [Troubleshooting (problems we actually hit)](#8-troubleshooting)

---

## 1. Architecture

```
                    Internet
                       │  HTTP :80
              ┌────────▼────────┐   public subnets 10.0.0.0/24, 10.0.1.0/24
              │       ALB       │   (also hosts the NAT gateway)
              └────────┬────────┘
                       │ :8000 (only from the ALB's security group)
   ┌───────────────────▼──────────────────────┐   app subnets 10.0.10.0/24, 10.0.11.0/24
   │ ECS Fargate                              │   (private; outbound via NAT)
   │  ┌──────────────┐     ┌───────────────┐  │
   │  │ app task     │────►│ postgres task │  │   found at postgres.binbon.local
   │  │ (binbon/demo)│:5432│ (postgres:16) │  │   (Cloud Map private DNS)
   │  └──┬────┬───┬──┘     └───────────────┘  │
   └─────┼────┼───┼───────────────────────────┘
         │    │   │ :6379
         │    │  ┌▼─────────────────┐   data subnets 10.0.20.0/24, 10.0.21.0/24
         │    │  │ ElastiCache Redis│   (private, NO internet route at all)
         │    │  └──────────────────┘
         │    └──► Secrets Manager  binbon/db  {"username","password"}
         └───────► S3  binbon-demo-<account-id>   (private bucket)

 GitHub Actions ──OIDC──► IAM role binbon-dev-github-actions ──► ECR push + ECS deploy
```

What each service is used for:

| Service | Used for |
|---|---|
| ALB | Public entry point; health-checks the app on `/health` |
| ECS Fargate | Runs the app container and the Postgres container (no servers to manage) |
| Cloud Map | Gives the Postgres task a stable DNS name: `postgres.binbon.local` |
| ElastiCache Redis | Login sessions and an upload counter |
| S3 | The uploaded photo files |
| Secrets Manager | The DB username and password (the single source of truth) |
| ECR | The app's Docker images |
| CloudWatch Logs | Container logs (`/ecs/binbon-demo`) |
| IAM | Who may do what (ECS agent, the app, GitHub Actions) |

Postgres runs as a container instead of RDS/Aurora to stay within the AWS free plan. Its data lives
**inside the container**: it survives while the task runs and is lost if the task restarts. That's
acceptable for a same-day dev environment.

---

## 2. Quick start

Prerequisites: Terraform ≥ 1.6, AWS CLI v2 logged in to account `007924090369` with admin rights,
Docker, and the app repo checked out next to this one (`../binbon-demo`).

```bash
./deploy.sh up     # create ECR → build & push image → create everything else → wait → smoke tests
./deploy.sh test   # re-run the smoke tests against the live ALB
./deploy.sh down   # destroy everything
```

What `deploy.sh up` does, and why in this order:

1. `terraform init`: downloads the AWS and random providers.
2. `terraform apply -target=aws_ecr_repository.demo` creates **only** the ECR repo first, so there is
   somewhere to push the image.
3. Builds the app image (`--platform linux/amd64`, matching the task's `X86_64` setting) and pushes it as `:v1`.
4. `terraform apply` creates the rest. The ECS service finds the image already in ECR.
5. Waits until `GET /health` on the ALB returns 200, then runs the smoke tests, including
   `/status`, which live-checks Postgres, Redis, S3 and Secrets Manager.

After this first bootstrap, **GitHub Actions** builds and deploys every push to `main` (see the app README).

**`terraform.tfstate`**: Terraform's record of what it created. Without it, `deploy.sh down` cannot
destroy anything. It also contains the generated DB password, so never commit it to git.

---

## 3. Terraform in 5 minutes

Everything in `*.tf` is one of these block types:

| Block | Meaning | Example here |
|---|---|---|
| `resource "TYPE" "NAME" {}` | Something Terraform **creates and owns** (and deletes on destroy) | `resource "aws_vpc" "main"` |
| `data "TYPE" "NAME" {}` | Something Terraform **reads or computes**; nothing is created | `data "aws_availability_zones" "available"` |
| `variable "NAME" {}` | An input with a default you can override (`-var region=...`) | `var.region` |
| `locals {}` | Named values computed inside the code, to avoid repetition | `local.name` = `"binbon-dev"` |
| `output "NAME" {}` | A value printed after `apply` (`terraform output alb_dns_name`) | `alb_dns_name` |
| `provider "aws" {}` | Configures the plugin that talks to AWS (region, default tags) | `provider.tf` |
| `terraform {}` | Required Terraform and provider versions | `versions.tf` |

How to read the syntax:

- **References**: `aws_vpc.main.id` means "the `id` attribute of the resource of type `aws_vpc`
  named `main`". Using a reference also tells Terraform the **order**: the VPC must exist before
  anything that references it. Terraform builds this dependency graph itself.
- **`count = var.az_count`** creates N copies of a resource (one per Availability Zone). Each copy
  is addressed as `aws_subnet.app[0]`, `aws_subnet.app[1]`, and `count.index` is 0, 1, ….
- **`aws_subnet.app[*].id`** (the splat) means "the list of ids of all copies".
- **`"${local.name}-alb"`** is string interpolation, giving `binbon-dev-alb`.
- **Nested blocks** like `ingress {}`, `statement {}` or `health_check {}` are structured arguments of
  their parent, not separate resources.
- **`jsonencode({...})`** turns a Terraform object into a JSON string. It's used for ECS container
  definitions and the ECR lifecycle policy, which AWS expects as JSON.
- **`depends_on = [...]`** sets an explicit order when there is no reference to infer it from.
- **`lifecycle { ignore_changes = [...] }`** tells Terraform to ignore drift in those attributes
  (used so GitHub Actions can own the app's running image; see `ecs.tf`).
- **`data "aws_iam_policy_document"`** creates nothing in AWS. It is a helper that
  **builds an IAM policy JSON** from readable HCL, so we can use references (bucket ARN, secret ARN)
  instead of hand-written JSON. The result is used as `data.aws_iam_policy_document.X.json`.

---

## 4. IAM concepts used here

IAM confuses most people at first. The terms used in this repo:

- **Role**: an identity that *something* (a service, a CI job) can temporarily become. A role has
  no password and no keys. Whoever assumes it gets short-lived credentials.
- **Trust policy** (`assume_role_policy`): **WHO may assume** the role. Example: "ECS tasks may
  assume this role" or "GitHub Actions from repo X, branch main, may assume this role".
- **Permission policy**: **WHAT the role may do once assumed**. Example: "PutObject on bucket X".
  - *AWS managed policy*: written by AWS and attached by ARN (`AmazonECSTaskExecutionRolePolicy`).
  - *Inline policy* (`aws_iam_role_policy`): written by us and part of that one role only.
- **ECS execution role** vs **ECS task role**. These are two different roles for two different users:

  | | Execution role (`binbon-dev-ecs-execution`) | Task role (`binbon-dev-ecs-task`) |
  |---|---|---|
  | Used by | The **ECS agent**, *before and around* your container | **Your code inside** the container (boto3) |
  | Does | Pull image from ECR, write logs, fetch secrets to inject as env vars | S3 uploads, reading the DB secret at runtime |
  | Attached to | Both task definitions | **Only** the app task definition |

  The Postgres task has **no task role**, so code running in it has no AWS permissions at all.
  That's how "only the app can reach S3" is enforced.
- **`iam:PassRole`**: to register a task definition that *uses* a role, the caller (GitHub Actions)
  must be allowed to "pass" that role to ECS. This stops someone from granting a container a
  powerful role they couldn't use themselves.
- **OIDC (OpenID Connect) federation**: lets GitHub Actions log in to AWS **without stored
  access keys**. On each run GitHub issues a signed token that says "I am repo X, branch main". AWS
  verifies the signature (via the OIDC provider registered in IAM) and checks the claims against the
  role's trust policy. If they match, AWS returns credentials that last about one hour.

---

## 5. File-by-file, block-by-block

### `versions.tf`, `provider.tf`, `variables.tf`

| Block | Purpose |
|---|---|
| `terraform { required_version, required_providers }` | Pins Terraform ≥ 1.6, AWS provider 6.x and random 3.x, so everyone gets the same behaviour |
| `provider "aws"` | Region = `var.region` (`eu-north-1`). `default_tags` puts `Project`, `Environment`, `ManagedBy` on every resource automatically |
| `provider "random"` | Used for `random_password` |
| `variable "region" / "project" / "environment" / "vpc_cidr" / "az_count"` | Inputs. `project`-`environment` build every name (`binbon-dev-…`) |

### `network.tf`: the private network

| Block | Purpose |
|---|---|
| `data "aws_availability_zones" "available"` | Reads the AZ names of the region, so none are hard-coded |
| `locals { name, azs, public_cidrs, app_cidrs, data_cidrs }` | `name = "binbon-dev"`. `cidrsubnet()` carves `/24`s out of the `/16`: public `10.0.0-1.0/24`, app `10.0.10-11.0/24`, data `10.0.20-21.0/24` |
| `aws_vpc.main` | The private network `10.0.0.0/16`. DNS support and hostnames are **required** for Cloud Map and ElastiCache DNS names |
| `aws_internet_gateway.main` | The VPC's door to the internet (used by public subnets) |
| `aws_subnet.public` (×2) | Public subnets, one per AZ: the ALB and the NAT gateway live here. `map_public_ip_on_launch` |
| `aws_subnet.app` (×2) | Private subnets for the Fargate tasks |
| `aws_subnet.data` (×2) | Private subnets for ElastiCache, with no internet route at all |
| `aws_eip.nat` + `aws_nat_gateway.main` | The NAT gateway lets **private** tasks make *outbound* connections (pull images from ECR/Docker Hub, call S3 and Secrets Manager APIs) while staying unreachable from the internet. Dev uses one NAT; production would use one per AZ. **Costs money per hour.** |
| `aws_route_table.public` + associations | `0.0.0.0/0 → internet gateway` |
| `aws_route_table.app` + associations | `0.0.0.0/0 → NAT gateway` (outbound only) |
| `aws_route_table.data` + associations | Only the implicit local route: isolated |

### `ecr.tf`: the image registry

| Block | Purpose |
|---|---|
| `aws_ecr_repository.demo` | Private Docker registry `binbon/demo`. `scan_on_push` runs a free vulnerability scan. `force_delete` lets destroy remove it even with images inside (dev only) |
| `aws_ecr_lifecycle_policy.demo` | Keeps only the last 5 images, so old builds don't pile up |

### `support.tf`: S3, the DB secret, logs

| Block | Purpose |
|---|---|
| `aws_s3_bucket.demo` | Photo storage, `binbon-demo-<account-id>` (bucket names are global, so the account ID makes it unique). `force_destroy` lets destroy empty it |
| `aws_s3_bucket_public_access_block.demo` | Blocks every form of public access. The app streams photos itself, so the bucket never needs to be public |
| `aws_s3_bucket_server_side_encryption_configuration.demo` | Encrypts objects at rest (SSE-S3 / AES256) |
| `aws_secretsmanager_secret.db` | The **container** for the secret `binbon/db` (name, metadata). `recovery_window_in_days = 0` deletes it immediately on destroy, so the next `up` can reuse the name |
| `aws_secretsmanager_secret_version.db` | The **value**: `{"username":"binbon_admin","password":"<random>"}`. Same shape as Aurora's managed secret, so the app needs no change for Aurora later |
| `aws_cloudwatch_log_group.demo` | `/ecs/binbon-demo`, 7-day retention (never leave logs on "never expire") |
| `data "aws_caller_identity" "current"` | Reads the account ID (for the bucket name) |

### `data.tf`: Postgres, Redis, service discovery

| Block | Purpose |
|---|---|
| `aws_security_group.postgres` | A **security group** is a stateful firewall attached to a network interface. Inbound **5432 only from the app's security group** (by SG ID, not by IP, so it keeps working as task IPs change). Outbound all, needed to pull the `postgres:16` image through the NAT |
| `aws_security_group.redis` | Inbound **6379 only from the app SG**. No egress block, because ElastiCache never initiates connections |
| `locals { db_name, db_user }` | `binbon` / `binbon_admin`, shared by the Postgres task, the secret and the app task |
| `random_password.db` | Generates a 20-character password **once**. It's stored in state and stable across applies; it only changes on destroy/recreate. `special = false` avoids characters that need escaping |
| `aws_service_discovery_private_dns_namespace.main` | Creates the private DNS zone `binbon.local` (Cloud Map, backed by Route 53) inside the VPC |
| `aws_service_discovery_service.postgres` | The name `postgres` in that zone. ECS registers the Postgres task's IP as an `A` record (TTL 10s), so the app always connects to `postgres.binbon.local` even after the task moves |
| `aws_ecs_task_definition.postgres` | The **recipe** for the Postgres container: image `postgres:16`, 0.25 vCPU / 512 MB, port 5432, logs to CloudWatch. `POSTGRES_DB`/`POSTGRES_USER` are plain env vars. **`POSTGRES_PASSWORD` comes from `secrets`**: at task start the ECS agent (using the execution role) reads key `password` of `binbon/db` and injects it. The task definition only contains the ARN, never the value. There is no `task_role_arn`, so the container has no AWS permissions |
| `aws_ecs_service.postgres` | Keeps **1** copy of that task running in the app subnets with the Postgres SG, and registers it in Cloud Map (`service_registries`). `depends_on` the secret version, so the secret has a value before the first task starts |
| `aws_elasticache_subnet_group.main` | Tells ElastiCache which subnets it may use (the data subnets) |
| `aws_elasticache_cluster.redis` | A single Redis 7 node, `cache.t4g.micro`, no TLS (the app sets `REDIS_TLS=false`) |
| `output "db_host" / "redis_endpoint"` | Printed after apply |

### `iam.tf`: the two ECS roles

| Block | Purpose |
|---|---|
| `data "aws_iam_policy_document" "ecs_assume"` | **Trust policy** JSON: "the service `ecs-tasks.amazonaws.com` may `sts:AssumeRole`". Used by both ECS roles |
| `aws_iam_role.execution` | The **execution role** (for the ECS agent) |
| `aws_iam_role_policy_attachment.execution_managed` | Attaches the AWS-managed `AmazonECSTaskExecutionRolePolicy`: ECR pull and CloudWatch Logs write |
| `data "aws_iam_policy_document" "execution_secrets"` + `aws_iam_role_policy.execution_secrets` | Inline policy: `secretsmanager:GetSecretValue` on **only** `binbon/db`. Without it, the Postgres task fails to start with `ResourceInitializationError: unable to pull secrets` |
| `aws_iam_role.task` | The **task role** (for the app's code) |
| `data "aws_iam_policy_document" "task"` + `aws_iam_role_policy.task` | Inline policy, scoped to exact ARNs: `s3:ListBucket` on the bucket (also used by `HeadBucket` on the status page); `GetObject`/`PutObject`/`DeleteObject` on `bucket/*`; `GetSecretValue` on `binbon/db` only |
| `output "execution_role_arn" / "task_role_arn"` | Printed after apply |

Why the bucket appears twice: `ListBucket` acts on the **bucket** (`arn:aws:s3:::name`), while
`Get/Put/DeleteObject` act on **objects** (`arn:aws:s3:::name/*`). IAM treats them as different resources.

### `ecs.tf`: load balancer, cluster, app

| Block | Purpose |
|---|---|
| `aws_security_group.alb` | Inbound **80 from anywhere**, outbound all (to reach the tasks) |
| `aws_security_group.app` | Inbound **8000 only from the ALB SG**. Outbound all (Postgres, Redis, and S3/Secrets/ECR via NAT) |
| `aws_lb.main` | The Application Load Balancer in the public subnets |
| `aws_lb_target_group.app` | The group of app task IPs the ALB forwards to (`target_type = "ip"` because Fargate tasks register by IP). Health check `GET /health` must return 200; it is healthy after 2 passes and unhealthy after 3 failures, every 15s. `/health` deliberately has no dependencies, so a slow database can't make ECS kill the app in a loop |
| `aws_lb_listener.http` | "On port 80, forward to the target group" |
| `aws_ecs_cluster.main` | `binbon-dev-cluster`, a logical group of services (Fargate means no EC2 instances) |
| `aws_ecs_task_definition.app` | The app recipe: image `…/binbon/demo:v1` (the bootstrap image), container name **`demo`** (the pipeline relies on this name), port 8000, 0.25 vCPU / 512 MB, `X86_64`, **both** roles. Env vars: `DB_HOST=postgres.binbon.local`, `DB_NAME`, **`DB_SECRET_ARN`** (the app reads username and password itself), Redis host and port, `REDIS_TLS=false`, `S3_BUCKET`. **No password anywhere** |
| `aws_ecs_service.app` | Keeps 1 app task running in the app subnets, registered in the target group. `health_check_grace_period_seconds = 60` gives the app time to boot before ALB checks count. **`lifecycle { ignore_changes = [task_definition] }`**: after bootstrap, GitHub Actions registers new revisions (new image tags) and moves the service to them. Without this, the next `terraform apply` would roll the service back to Terraform's old revision. Side effect: env-var changes made here only go live with the next pipeline deploy (or `aws ecs update-service --force-new-deployment`) |
| `output "alb_dns_name"` | The URL to open |

### `github.tf`: CI/CD access for GitHub Actions

| Block | Purpose |
|---|---|
| `variable "github_repo" / "github_owner_id" / "github_repo_id" / "github_branch"` | Which repo and branch may deploy. The numeric IDs come from `curl -s https://api.github.com/repos/<owner>/<repo>` (`owner.id`, `id`) |
| `locals { github_owner, github_repo_name }` | Splits `owner/name` |
| `aws_iam_openid_connect_provider.github` | Registers GitHub's token issuer `https://token.actions.githubusercontent.com` with audience `sts.amazonaws.com`. **One per AWS account**: if it already exists, import it instead of creating a second one |
| `data "aws_iam_policy_document" "github_assume"` | **Trust policy**: `sts:AssumeRoleWithWebIdentity` by that provider, only if `aud = sts.amazonaws.com` **and** `sub = repo:mostafasaleh97@118595619/binbon-demo@1410099885:ref:refs/heads/main`. GitHub includes the immutable owner and repo IDs in `sub`, so a deleted-and-recreated repo with the same name cannot assume the role |
| `aws_iam_role.github_actions` | `binbon-dev-github-actions`, the role the workflow assumes |
| `data "aws_iam_policy_document" "github_actions"` + `aws_iam_role_policy.github_actions` | What the pipeline may do, and nothing more: `ecr:GetAuthorizationToken` (`*`, AWS requires this); push and pull layers on **this ECR repo only**; `ecs:DescribeTaskDefinition`/`RegisterTaskDefinition` (`*`, because these actions don't support resource scoping); `ecs:UpdateService`/`DescribeServices` on **the app service only**; `iam:PassRole` on **only** the two ECS roles, and only to `ecs-tasks.amazonaws.com` |
| `output "github_actions_role_arn"` | Hard-coded in the app repo's workflow (`AWS_ROLE_ARN`) |

### `outputs.tf`

The VPC ID and subnet ID lists, for reference.

### `deploy.sh`

Covered in [Quick start](#2-quick-start). Config is at the top (`REGION`, `ACCOUNT`, `REPO`, `TAG`, `APP_DIR`).

---

## 6. Building the same thing in the AWS console

The same environment by hand, **in dependency order**. Region: **eu-north-1 (Stockholm)**.
Use the names shown so everything matches the app and the pipeline.

> Doing this by hand is great for learning. For repeatable environments, use Terraform: it creates
> about 50 resources in 15 minutes, and `destroy` removes all of them.

### 6.1 Network (VPC console)

1. **VPC → Your VPCs → Create VPC → "VPC only"**: name `binbon-dev-vpc`, IPv4 CIDR `10.0.0.0/16`.
   Then **Actions → Edit VPC settings** → enable **DNS resolution** and **DNS hostnames**.
2. **Subnets → Create subnet** (VPC = `binbon-dev-vpc`), six subnets:

   | Name | AZ | CIDR |
   |---|---|---|
   | `binbon-dev-public-a` | eu-north-1a | `10.0.0.0/24` |
   | `binbon-dev-public-b` | eu-north-1b | `10.0.1.0/24` |
   | `binbon-dev-app-a` | eu-north-1a | `10.0.10.0/24` |
   | `binbon-dev-app-b` | eu-north-1b | `10.0.11.0/24` |
   | `binbon-dev-data-a` | eu-north-1a | `10.0.20.0/24` |
   | `binbon-dev-data-b` | eu-north-1b | `10.0.21.0/24` |

   For both **public** subnets: **Actions → Edit subnet settings → Enable auto-assign public IPv4**.
3. **Internet gateways → Create**: `binbon-dev-igw` → **Actions → Attach to VPC**.
4. **NAT gateways → Create**: `binbon-dev-nat`, subnet `binbon-dev-public-a`, connectivity *Public*,
   **Allocate Elastic IP**. (Billing starts now.)
5. **Route tables → Create** three tables in the VPC:
   - `binbon-dev-public-rt`: route `0.0.0.0/0 → Internet gateway`. Subnet associations: both public subnets.
   - `binbon-dev-app-rt`: route `0.0.0.0/0 → NAT gateway`. Subnet associations: both app subnets.
   - `binbon-dev-data-rt`: no extra routes. Subnet associations: both data subnets.

### 6.2 Security groups (VPC → Security groups → Create)

Create them in this order, because later ones reference earlier ones:

| Name | Inbound rules | Outbound |
|---|---|---|
| `binbon-dev-alb-sg` | HTTP 80 from `0.0.0.0/0` | All traffic |
| `binbon-dev-app-sg` | Custom TCP 8000, source = **`binbon-dev-alb-sg`** | All traffic |
| `binbon-dev-postgres-sg` | PostgreSQL 5432, source = **`binbon-dev-app-sg`** | All traffic |
| `binbon-dev-redis-sg` | Custom TCP 6379, source = **`binbon-dev-app-sg`** | *(delete the default rule)* |

For the source, pick the **security group** (start typing `sg-` or the name), not an IP range.

### 6.3 S3 bucket (S3 console)

**Create bucket**: name `binbon-demo-<your-account-id>`, region eu-north-1. Keep **Block all
public access** ON. Default encryption: **SSE-S3**. Leave everything else at the defaults.

### 6.4 DB secret (Secrets Manager console)

1. Generate a password, e.g. in CloudShell:
   `aws secretsmanager get-random-password --password-length 20 --exclude-punctuation --query RandomPassword --output text`
2. **Store a new secret → Other type of secret** → key/value pairs:
   `username` = `binbon_admin`, `password` = *(the generated value)*.
3. Secret name **`binbon/db`**. **Do not enable rotation**: rotation would change the secret but
   not the password inside Postgres. Store it, then copy the **Secret ARN** (it ends with a random
   `-AbC123` suffix).

### 6.5 CloudWatch log group

**CloudWatch → Log groups → Create**: `/ecs/binbon-demo`, retention **1 week**.

### 6.6 ECR repository (and the first image)

1. **ECR → Private repositories → Create**: `binbon/demo`, enable **Scan on push**.
   Optional: **Lifecycle policy → Create rule**: "Image count more than 5 → expire".
2. Push the first image from your machine (the "View push commands" button shows the same steps):
   ```bash
   aws ecr get-login-password --region eu-north-1 | docker login --username AWS --password-stdin 007924090369.dkr.ecr.eu-north-1.amazonaws.com
   cd ../binbon-demo
   docker build --platform linux/amd64 -t 007924090369.dkr.ecr.eu-north-1.amazonaws.com/binbon/demo:v1 .
   docker push 007924090369.dkr.ecr.eu-north-1.amazonaws.com/binbon/demo:v1
   ```

### 6.7 IAM roles (IAM console)

**Execution role**
1. **Roles → Create role → AWS service → Elastic Container Service → "Elastic Container Service Task"**.
2. Attach **`AmazonECSTaskExecutionRolePolicy`**, name it `binbon-dev-ecs-execution`, create.
3. Open the role → **Add permissions → Create inline policy → JSON**, name it `binbon-dev-execution-secrets`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Sid": "ReadDbSecret",
       "Effect": "Allow",
       "Action": "secretsmanager:GetSecretValue",
       "Resource": "<binbon/db secret ARN>"
     }]
   }
   ```

**Task role** (for the app only)
1. Same wizard (**Elastic Container Service Task**), attach **nothing**, name it `binbon-dev-ecs-task`.
2. Inline policy `binbon-dev-task-policy`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Sid": "S3ListBucket", "Effect": "Allow", "Action": "s3:ListBucket",
         "Resource": "arn:aws:s3:::binbon-demo-<account-id>" },
       { "Sid": "S3Objects", "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
         "Resource": "arn:aws:s3:::binbon-demo-<account-id>/*" },
       { "Sid": "ReadDbSecret", "Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
         "Resource": "<binbon/db secret ARN>" }
     ]
   }
   ```

### 6.8 ElastiCache Redis

1. **ElastiCache → Subnet groups → Create**: `binbon-dev-cache-subnets`, VPC `binbon-dev-vpc`,
   subnets = the two **data** subnets.
2. **Redis OSS caches → Create**: choose **Design your own cache → node-based (not serverless)**,
   cluster mode **disabled**, name `binbon-dev-redis`, engine **Redis OSS 7.x**, node type
   **cache.t4g.micro**, **0 replicas**, Multi-AZ off, subnet group `binbon-dev-cache-subnets`,
   security group `binbon-dev-redis-sg`, **encryption in transit OFF** (the app uses `REDIS_TLS=false`).
3. When it's *Available*, copy the **primary endpoint** host name (without `:6379`).

### 6.9 ECS cluster and Cloud Map namespace

1. **ECS → Clusters → Create**: `binbon-dev-cluster`, infrastructure **AWS Fargate** only.
2. **Cloud Map → Create namespace**: name `binbon.local`, instance discovery
   **API calls and DNS queries in VPCs**, VPC `binbon-dev-vpc`.

### 6.10 Postgres: task definition and service

1. **ECS → Task definitions → Create new (form)**:
   - Family `binbon-dev-postgres`, launch type **Fargate**, OS/arch **Linux/X86_64**, CPU **0.25 vCPU**, memory **0.5 GB**.
   - Task role: **None**. Task execution role: **`binbon-dev-ecs-execution`**.
   - Container: name `postgres`, image `postgres:16`, essential, port **5432/TCP**.
   - Environment variables:
     - `POSTGRES_DB` = **Value** `binbon`
     - `POSTGRES_USER` = **Value** `binbon_admin`
     - `POSTGRES_PASSWORD` = **ValueFrom** `<binbon/db secret ARN>:password::`
       (the suffix `:password::` selects the JSON key `password` from the secret)
   - Logging: **awslogs**, group `/ecs/binbon-demo`, stream prefix `postgres`.
2. **Cluster → Services → Create**:
   - Compute: **Launch type → FARGATE**. Task definition `binbon-dev-postgres`, service name
     `binbon-dev-postgres`, desired tasks **1**.
   - Networking: VPC `binbon-dev-vpc`, subnets = the two **app** subnets, SG `binbon-dev-postgres-sg`,
     **Public IP off**.
   - **Service discovery**: turn it on, namespace `binbon.local`, service name `postgres`,
     DNS record type **A**, TTL **10**.
   - Wait until 1 task is *Running*.

### 6.11 Load balancer

1. **EC2 → Target groups → Create**: target type **IP addresses**, name `binbon-dev-tg`, protocol
   HTTP, port **8000**, VPC `binbon-dev-vpc`. Health check path **`/health`**. Advanced: healthy
   threshold 2, unhealthy 3, interval 15s, success codes 200. **Don't register targets**; ECS does that.
2. **Load balancers → Create → Application Load Balancer**: `binbon-dev-alb`, internet-facing, IPv4,
   VPC `binbon-dev-vpc`, both **public** subnets, SG `binbon-dev-alb-sg`, listener **HTTP:80 → forward
   to `binbon-dev-tg`**.

### 6.12 App: task definition and service

1. **Task definitions → Create new**:
   - Family `binbon-dev-demo`, Fargate, Linux/X86_64, 0.25 vCPU, 0.5 GB.
   - Task role **`binbon-dev-ecs-task`**, execution role **`binbon-dev-ecs-execution`**.
   - Container name **`demo`** (the pipeline expects this exact name), image
     `007924090369.dkr.ecr.eu-north-1.amazonaws.com/binbon/demo:v1`, port **8000/TCP**.
   - Environment variables (all **Value**):

     | Key | Value |
     |---|---|
     | `AWS_REGION` | `eu-north-1` |
     | `DB_HOST` | `postgres.binbon.local` |
     | `DB_PORT` | `5432` |
     | `DB_NAME` | `binbon` |
     | `DB_SECRET_ARN` | `<binbon/db secret ARN>` |
     | `REDIS_HOST` | `<redis primary endpoint host>` |
     | `REDIS_PORT` | `6379` |
     | `REDIS_TLS` | `false` |
     | `S3_BUCKET` | `binbon-demo-<account-id>` |

   - Logging: awslogs, group `/ecs/binbon-demo`, prefix `ecs`.
2. **Create service**: FARGATE, family `binbon-dev-demo`, service `binbon-dev-demo`, desired **1**,
   app subnets, SG `binbon-dev-app-sg`, public IP **off**. **Load balancing**: Application Load
   Balancer → existing `binbon-dev-alb`, existing listener 80, existing target group `binbon-dev-tg`,
   container `demo:8000`. Health check grace period **60s**.
3. When the target in `binbon-dev-tg` shows **healthy**, open
   `http://<alb-dns-name>/status`. All four services should be green.

### 6.13 GitHub Actions access (OIDC)

1. **IAM → Identity providers → Add provider → OpenID Connect**: provider URL
   `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
   (Skip this step if the provider already exists; there can only be one per account.)
2. **Roles → Create role → Web identity**: identity provider `token.actions.githubusercontent.com`,
   audience `sts.amazonaws.com`, fill in GitHub organization `mostafasaleh97`, repository
   `binbon-demo`, branch `main`. Attach nothing, name it **`binbon-dev-github-actions`**.
3. **Important:** open the role → **Trust relationships → Edit**, and make the `sub` condition use
   GitHub's current format with the numeric IDs. The wizard writes the old format, which no longer matches:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::007924090369:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
           "token.actions.githubusercontent.com:sub": "repo:mostafasaleh97@118595619/binbon-demo@1410099885:ref:refs/heads/main"
         }
       }
     }]
   }
   ```
4. Inline policy `binbon-dev-github-actions`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Sid": "EcrLogin", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
       { "Sid": "EcrPushThisRepo", "Effect": "Allow",
         "Action": ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
                    "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"],
         "Resource": "arn:aws:ecr:eu-north-1:007924090369:repository/binbon/demo" },
       { "Sid": "TaskDefinitions", "Effect": "Allow",
         "Action": ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"], "Resource": "*" },
       { "Sid": "DeployAppService", "Effect": "Allow",
         "Action": ["ecs:UpdateService", "ecs:DescribeServices"],
         "Resource": "arn:aws:ecs:eu-north-1:007924090369:service/binbon-dev-cluster/binbon-dev-demo" },
       { "Sid": "PassEcsRoles", "Effect": "Allow", "Action": "iam:PassRole",
         "Resource": ["arn:aws:iam::007924090369:role/binbon-dev-ecs-execution",
                      "arn:aws:iam::007924090369:role/binbon-dev-ecs-task"],
         "Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } } }
     ]
   }
   ```

The pipeline is now ready: every push to `main` in `binbon-demo` deploys (see that repo's README).

---

## 7. Tear down

**Terraform:** `./deploy.sh down` (or `terraform destroy`). Done.

**Console:** delete in roughly the reverse order, because AWS refuses to delete things that are still in use:

1. ECS services: set desired count to 0, then delete `binbon-dev-demo` and `binbon-dev-postgres`. Delete the cluster.
2. The ALB, then the target group.
3. The ElastiCache cluster, then its subnet group.
4. The Cloud Map namespace (after its `postgres` service is gone).
5. **The NAT gateway** (wait until *Deleted*), then **release the Elastic IP**. Both cost money while they exist.
6. Security groups (the app SG last, because others reference it), then the VPC (this removes subnets,
   route tables and the internet gateway).
7. Empty and delete the S3 bucket. Delete the secret (choose *without recovery* via the CLI:
   `aws secretsmanager delete-secret --secret-id binbon/db --force-delete-without-recovery`).
8. The ECR repository, the log group, the three IAM roles and the OIDC provider.
9. Optional: deregister old task definition revisions (they're free).

After teardown, a push to `binbon-demo` makes the pipeline fail at "Configure AWS credentials",
because the role no longer exists. That's expected. Disable the workflow in GitHub if you prefer.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pipeline: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The trust policy's `sub` doesn't match the token. Find the real value in **CloudTrail → Event history → `AssumeRoleWithWebIdentity`** (field `userIdentity.userName`) and copy it into the trust policy. GitHub now sends `repo:owner@<id>/repo@<id>:ref:refs/heads/main` |
| Postgres task stops with `ResourceInitializationError: unable to pull secrets` | The execution role can't read `binbon/db`. Check the `execution_secrets` policy and the secret ARN |
| `terraform apply` fails: secret *"is scheduled for deletion"* | A secret with that name was deleted with a recovery window. `aws secretsmanager delete-secret --secret-id binbon/db --force-delete-without-recovery` |
| `/status` shows Database red with `password authentication failed` | The secret and Postgres disagree, e.g. the secret was edited by hand. Restart the Postgres service so it re-initialises from the secret (its data is ephemeral anyway) |
| Users gone, error on upload after a while | The Postgres task restarted, so its in-container data was reset. Sign up again (old photo files stay in S3) |
| Changed an env var in `ecs.tf`, nothing happened | Expected, because of `ignore_changes`. Push to `main` or `aws ecs update-service --cluster binbon-dev-cluster --service binbon-dev-demo --force-new-deployment` |
| Target unhealthy / tasks restarting | **CloudWatch → `/ecs/binbon-demo`**, stream prefix `ecs/`. Also check the app SG allows 8000 from the ALB SG |
| `terraform destroy` can't find anything | `terraform.tfstate` is missing; delete by hand (section 7) |
