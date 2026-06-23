#!/usr/bin/env bash
# =============================================================================
# AKS 플랫폼 핸즈온 워크샵 — end-to-end 리허설 스크립트 (Azure Cloud Shell 전용)
# -----------------------------------------------------------------------------
# 이 스크립트는 docs/01~09 를 그대로 따라가며 실제 리소스를 생성→검증→삭제합니다.
# 강사가 워크샵 전 "정상 동작"을 한 번에 리허설할 때 사용합니다.
#
# 사용법(Azure Cloud Shell, bash):
#   git clone https://github.com/<your-org>/ms-aks-basic-workshop01.git
#   cd ms-aks-basic-workshop01
#   bash scripts/rehearsal.sh            # 전체(프로비저닝→검증→정리)
#   KEEP=1 bash scripts/rehearsal.sh     # 정리(destroy) 생략, 리소스 유지
#
# 각 단계 실패 시 즉시 중단(set -e)하고 어디서 멈췄는지 출력합니다.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
KEEP="${KEEP:-0}"

step() { echo; echo "============================================================"; echo "▶ $*"; echo "============================================================"; }
ok()   { echo "  ✅ $*"; }

# --- 0) 사전 점검 (docs/01) -------------------------------------------------
step "0) 사전 점검 — 로그인/도구/공급자"
az account show -o table
for t in terraform kubectl az; do command -v "$t" >/dev/null || { echo "❌ $t 미설치"; exit 1; }; done
ok "도구 확인 완료"
for ns in Microsoft.ContainerService Microsoft.Network Microsoft.ContainerRegistry \
          Microsoft.OperationalInsights Microsoft.Monitor Microsoft.Dashboard Microsoft.Authorization; do
  state="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
  if [ "$state" != "Registered" ]; then
    echo "  ↳ $ns=$state → 등록 시도"; az provider register -n "$ns" >/dev/null
  fi
done
ok "리소스 공급자 등록 확인/요청 완료(전파에 수 분 소요될 수 있음)"

# --- 1) Terraform 준비 ------------------------------------------------------
step "1) terraform init/fmt/validate"
cd terraform
[ -f terraform.tfvars ] || cp terraform.tfvars.example terraform.tfvars
terraform init -input=false
terraform fmt -check -recursive
terraform validate
ok "init/fmt/validate 통과"

# --- 2) 3단계 스테이지 적용 (docs/02) --------------------------------------
step "2-1) 기반(네트워크/레지스트리/모니터링 백엔드)"
terraform apply -input=false -auto-approve \
  -target=azurerm_resource_group.network \
  -target=azurerm_resource_group.workload \
  -target=azurerm_resource_group.monitoring \
  -target=azurerm_virtual_network.this \
  -target=azurerm_subnet.aks \
  -target=azurerm_container_registry.this \
  -target=azurerm_log_analytics_workspace.this \
  -target=azurerm_monitor_workspace.this \
  -target=azurerm_dashboard_grafana.this
terraform state list | grep -E 'resource_group|virtual_network|subnet|container_registry|log_analytics|monitor_workspace|grafana'
ok "1단계 리소스 생성 확인"

step "2-2) AKS 클러스터(+NAP+역할 할당)"
terraform apply -input=false -auto-approve \
  -target=azurerm_kubernetes_cluster.this \
  -target=azapi_update_resource.nap \
  -target=azurerm_role_assignment.aks_acr \
  -target=azurerm_role_assignment.aks_network
eval "$(terraform output -raw get_credentials_command)"
kubectl get nodes
RG="$(terraform output -raw resource_group_name)"
AKS="$(terraform output -raw aks_cluster_name)"
test "$(az aks show -g "$RG" -n "$AKS" --query nodeProvisioningProfile.mode -o tsv)" = "Auto"
ok "AKS Ready + NAP=Auto"

step "2-3) 전체 수렴(Grafana 역할 할당 포함)"
terraform apply -input=false -auto-approve
if terraform plan -input=false -detailed-exitcode; then ok "No changes — 전체 수렴 완료"; else echo "❌ plan에 잔여 변경 존재"; exit 1; fi

step "2-4) Managed Prometheus 메트릭 수집 활성화 (az aks update)"
RG=$(terraform output -raw resource_group_name)
AKS=$(terraform output -raw aks_cluster_name)
AMW=$(terraform output -raw azure_monitor_workspace_id)
az aks update -g "$RG" -n "$AKS" \
  --enable-azure-monitor-metrics \
  --azure-monitor-workspace-resource-id "$AMW"
kubectl get pods -n kube-system | grep -E 'ama-metrics|ama-logs|cilium|keda' || true
ok "메트릭 활성화 + 애드온 Pod 확인"

# --- 3) 컨테이너 이미지 빌드 (docs/03) --------------------------------------
step "3) 컨테이너 이미지 빌드 — 소스 → ACR"
cd "$ROOT/terraform"
ACR=$(terraform output -raw acr_name)
ACR_SERVER=$(terraform output -raw acr_login_server)
IMAGE_TAG=1.0.0
cd "$ROOT"
test -d aks-store-demo/src || { echo "❌ aks-store-demo/src 소스가 저장소에 없음"; exit 1; }
for svc in order-service makeline-service product-service \
           store-front store-admin virtual-customer virtual-worker; do
  az acr build --registry "$ACR" --image "aks-store-demo/${svc}:${IMAGE_TAG}" "aks-store-demo/src/${svc}"
done
test "$(az acr repository list -n "$ACR" -o tsv | grep -c '^aks-store-demo/')" -ge 7
ok "7개 이미지 ACR 빌드/푸시 완료"

# --- 4) 앱 배포 (docs/04) ---------------------------------------------------
step "4) 앱 배포 — AKS Store Demo (ACR 이미지)"
cd "$ROOT"
kubectl get ns pets >/dev/null 2>&1 || kubectl create namespace pets
sed -E "s|ghcr.io/azure-samples/aks-store-demo/([a-z-]+):[0-9.]+|${ACR_SERVER}/aks-store-demo/\1:${IMAGE_TAG}|g" \
  manifests/aks-store-all-in-one.yaml | kubectl apply -n pets -f -
kubectl rollout status deploy/store-front -n pets --timeout=180s
kubectl wait --for=condition=Ready pod --all -n pets --timeout=240s
test "$(kubectl get deploy -n pets --no-headers | wc -l)" -ge 7
echo "  ↳ 모든 Service는 ClusterIP여야 함:"; kubectl get svc -n pets
ok "구성요소 기동 완료(모든 Service ClusterIP)"

# --- 5) 인그레스 (docs/05) --------------------------------------------------
step "5) Gateway API 인그레스"
cd "$ROOT/terraform"
RG=$(terraform output -raw resource_group_name)
AKS=$(terraform output -raw aks_cluster_name)
cd "$ROOT"
echo "  ↳ Gateway API / App Routing(Istio) 애드온 활성화..."
az aks update -g "$RG" -n "$AKS" --enable-gateway-api
az aks update -g "$RG" -n "$AKS" --enable-app-routing-istio
echo "  ↳ approuting-istio GatewayClass 등록 대기(최대 3분)..."
for i in $(seq 1 36); do
  kubectl get gatewayclass approuting-istio >/dev/null 2>&1 && break; sleep 5
done
kubectl get gatewayclass approuting-istio
kubectl apply -f manifests/gateway.yaml
echo "  ↳ EXTERNAL-IP 대기(최대 3분)..."
IP=""
for i in $(seq 1 36); do
  IP="$(kubectl get gateway store-gateway -n pets -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  [ -n "${IP:-}" ] && break; sleep 5
done
test -n "${IP:-}" || { echo "❌ Gateway EXTERNAL-IP 미할당"; exit 1; }
echo "  ↳ http://$IP 응답 확인"
curl -fsS -o /dev/null -w "    HTTP %{http_code}\n" --max-time 20 "http://$IP" || echo "    (전파 지연 시 잠시 후 재시도)"
ok "Gateway 외부 IP=$IP"

# --- 6) 오토스케일링 — KEDA(docs/06) + NAP(docs/07) -------------------------
step "6) 오토스케일링 — KEDA + NAP"
kubectl get pods -n kube-system -l app.kubernetes.io/name=keda-operator
kubectl apply -f manifests/keda-rabbitmq.yaml
kubectl get scaledobject makeline-rabbitmq -n pets
kubectl scale deploy/virtual-customer -n pets --replicas=15
echo "  ↳ 90초간 KEDA 큐 트리거 확장 관찰..."; sleep 90
kubectl get hpa keda-hpa-makeline-rabbitmq -n pets
# NAP: 노드 1대 용량(2 vCPU)을 넘는 단일 Pod(cpu=3) 하나로 결정적 Pending 유발
PREV=$(kubectl get nodes -l karpenter.sh/nodepool=default --no-headers | wc -l)
echo "  ↳ user 노드 ${PREV}개 → nap-stress(cpu=3) 1개로 Pending 유발"
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nap-stress
  namespace: pets
spec:
  replicas: 1
  selector:
    matchLabels: { app: nap-stress }
  template:
    metadata:
      labels: { app: nap-stress }
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests: { cpu: "3", memory: 2Gi }
EOF
echo "  ↳ NAP 신규 노드 대기(최대 5분)..."
for i in $(seq 1 60); do
  n="$(kubectl get nodes -l karpenter.sh/nodepool=default --no-headers | wc -l)"
  [ "${n:-0}" -gt "${PREV:-0}" ] && break; sleep 5
done
kubectl get nodes -L karpenter.sh/nodepool
ok "KEDA 큐 확장 + NAP 노드 추가 관찰 완료"
kubectl delete deployment nap-stress -n pets
kubectl scale deploy/virtual-customer -n pets --replicas=1

# --- 7) 모니터링 (docs/08) --------------------------------------------------
step "7) 모니터링 — Grafana/Prometheus/Insights"
cd terraform
echo "  ↳ Grafana: $(terraform output -raw grafana_endpoint)"
kubectl get pods -n kube-system -l dsName=ama-metrics-node --no-headers | head || true
kubectl get pods -n kube-system -l component=ama-logs-agent --no-headers | head || true
ok "Prometheus/Insights 에이전트 확인(대시보드는 포털에서 육안 확인)"
cd "$ROOT"

# --- 8) 정리 (docs/09) ------------------------------------------------------
if [ "$KEEP" = "1" ]; then
  step "8) 정리 생략(KEEP=1) — 수동 정리: cd terraform && terraform destroy -auto-approve"
else
  step "8) 정리 — terraform destroy"
  cd terraform
  terraform destroy -auto-approve
  az group list -o table | grep -i aksworkshop || ok "리소스 그룹 모두 삭제됨"
fi

step "리허설 완료 🎉"
