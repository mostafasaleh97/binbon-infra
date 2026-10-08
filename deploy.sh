#!/usr/bin/env bash
#
# Binbon dev — one-shot automation. Run from inside the Terraform folder.
#
#   ./deploy.sh up      build+push image, apply, wait, test  (default)
#                       (the DB secret is created + filled by Terraform itself)
#   ./deploy.sh test    just re-run the endpoint checks against the live ALB
#   ./deploy.sh down     terraform destroy (tear everything down)
#
#   SKIP_IMAGE=1 ./deploy.sh up    skip the docker build/push (image already in ECR)
#
set -euo pipefail

# --------------------------- config ---------------------------
REGION="eu-north-1"
ACCOUNT="007924090369"
REPO="binbon/demo"
TAG="v1"
APP_DIR="../binbon-demo"     # where the app's Dockerfile lives (sibling folder)

ECR_URL="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${REPO}"
CMD="${1:-up}"

# --------------------------- helpers ---------------------------
build_push() {
  if [[ "${SKIP_IMAGE:-0}" == "1" ]]; then
    echo "==> SKIP_IMAGE=1, not building/pushing (assuming image is already in ECR)"
    return 0
  fi
  if [[ ! -d "$APP_DIR" ]]; then
    echo "==> app dir '$APP_DIR' not found; skipping build (image must already be in ECR)"
    return 0
  fi
  echo "==> building & pushing image ${ECR_URL}:${TAG}"
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
  (
    cd "$APP_DIR"
    docker build --platform linux/amd64 -t "${REPO}:${TAG}" .
    docker tag "${REPO}:${TAG}" "${ECR_URL}:${TAG}"
    # ECR DNS/network blips are transient; push resumes, so retry a few times
    for attempt in 1 2 3 4 5; do
      if docker push "${ECR_URL}:${TAG}"; then
        break
      fi
      if [[ "$attempt" == "5" ]]; then
        echo "    push failed after 5 attempts — check your network/DNS"
        exit 1
      fi
      echo "    push attempt $attempt failed (often transient DNS) — retrying in 10s"
      sleep 10
    done
  )
}

tf_init() {
  echo "==> terraform init"
  terraform init -input=false
}

wait_for_health() {
  local url="http://$1/health"
  echo "==> waiting for the app to become healthy ($url)"
  for _ in $(seq 1 60); do          # up to ~5 minutes
    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      echo "    app is healthy."
      return 0
    fi
    printf '.'
    sleep 5
  done
  echo
  echo "    WARNING: app not healthy in time — check the ECS console / CloudWatch logs"
  return 0
}

run_tests() {
  local alb="$1"
  echo
  echo "===================== endpoint checks ====================="
  echo "--- /health"; curl -s "http://$alb/health"; echo
  echo "--- /config"; curl -s "http://$alb/config"; echo

  echo "--- /db (retries up to ~1 min while Postgres boots)"
  for _ in $(seq 1 12); do
    resp="$(curl -s --max-time 5 "http://$alb/db" || true)"
    echo "$resp"
    echo "$resp" | grep -q '"ok":true' && break
    sleep 5
  done

  echo "--- /upload"; curl -s -X POST "http://$alb/upload"; echo
  echo "--- /s3";     curl -s "http://$alb/s3"; echo
  echo "--- /secret"; curl -s "http://$alb/secret"; echo

  # the /status page live-checks Postgres, Redis, S3 and Secrets Manager at once
  echo "--- /status"
  if curl -s --max-time 15 "http://$alb/status" | grep -q "All systems operational"; then
    echo "all systems operational"
  else
    echo "WARNING: some services failing -- open http://$alb/status for details"
  fi
  echo "==========================================================="
}

get_alb() { terraform output -raw alb_dns_name; }

# --------------------------- main ---------------------------
case "$CMD" in
  up)
    tf_init
    # 1) create ONLY the ECR repo first, so there's somewhere to push to
    echo "==> creating ECR repo first"
    terraform apply -auto-approve -target=aws_ecr_repository.demo
    # 2) build + push the image into the now-existing repo
    build_push
    # 3) apply the rest -- ECS tasks find the image already present
    echo "==> applying the rest of the stack"
    terraform apply -auto-approve
    ALB="$(get_alb)"
    wait_for_health "$ALB"
    run_tests "$ALB"
    echo
    echo "App URL:  http://$ALB"
    echo "Tear down when done:  ./deploy.sh down"
    ;;
  test)
    run_tests "$(get_alb)"
    ;;
  down)
    echo "==> terraform destroy"
    terraform destroy -auto-approve
    echo "    all resources destroyed."
    ;;
  *)
    echo "usage: $0 [up|test|down]"
    exit 1
    ;;
esac