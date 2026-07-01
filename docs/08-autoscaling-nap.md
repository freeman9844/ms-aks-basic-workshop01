# 08. 오토스케일링 (2) — NAP로 노드 자동 프로비저닝

> 🟢 **실행** = 직접 입력·수행 · 👁️ **예시** = 눈으로만(개념/발췌) · 📋 **예상 출력** = 비교용(입력 불필요)

이전 모듈 [07. KEDA](07-autoscaling-keda.md)에서 **Pod 수**를 늘렸습니다. 그런데 Pod가 늘다 보면 기존 노드의 CPU/메모리 **요청량(requests)** 합계가 노드 용량을 넘어, 더 이상 스케줄링되지 못하는 **Pending Pod**가 생깁니다. 이때 **노드 자체를 자동으로 추가**하는 것이 **NAP(Node Auto Provisioning)** 입니다.

| 항목 | 내용 |
|---|---|
| 무엇을 늘리나 | 클러스터의 **노드 수**(VM) |
| 트리거 기준 | **Pending Pod**의 리소스 **요청량(requests)** |
| 엔진 | **Karpenter**(오픈소스)의 AKS 통합 구현 |
| 제어 리소스 | `NodePool`(어떤 노드를 만들지) + `AKSNodeClass`(노드 OS/디스크 설정) |
| 활성화 | `nodeProvisioningProfile.mode = Auto` (이 워크샵은 모듈 02 마지막의 `az aks update --node-provisioning-mode Auto`로 설정) |

## 1) NAP 활성화 상태 확인

이 워크샵은 모듈 02 마지막 단계의 `az aks update --node-provisioning-mode Auto`로 NAP를 이미 켰습니다. 모드와 제어 리소스를 확인합니다.
🟢 **실행**
```bash
cd ~/ms-aks-basic-workshop01/terraform
RG=$(terraform output -raw resource_group_name)
AKS=$(terraform output -raw aks_cluster_name)

# 클러스터의 NAP 모드 (→ Auto)
az aks show -g "$RG" -n "$AKS" --query nodeProvisioningProfile.mode -o tsv

# Karpenter 제어 리소스(기본 프로필)
kubectl get nodepool,aksnodeclass
kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type
```
예상 출력:
```text
Auto

NAME                          AGE
nodepool.karpenter.sh/default   42m
NAME                                  AGE
aksnodeclass.karpenter.azure.com/default   42m

NAME                             STATUS   ROLES   AGE   VERSION   NODEPOOL   INSTANCE-TYPE
aks-system-12345678-vmss000000   Ready    <none>  42m   v1.34.x              Standard_D...
aks-system-12345678-vmss000001   Ready    <none>  42m   v1.34.x              Standard_D...
aks-default-abcde                Ready    <none>  30m   v1.34.x   default    Standard_D...
```
> 시스템 노드풀(`aks-system-*`)은 NAP가 아니라 AKS가 관리하며, **`CriticalAddonsOnly` taint로 시스템 Pod 전용**입니다(모듈 02 베스트 프랙티스). 그래서 `pets` 앱은 **NAP가 만든 user 노드(`aks-default-*`)** 에서 이미 돌고 있습니다(모듈 04에서 첫 배포 시 생성됨). NAP 노드는 `karpenter.sh/nodepool=default` 라벨이 붙고 이름이 `aks-default-*`입니다.

기본 `NodePool`이 어떤 제약으로 노드를 고르는지 살펴봅니다.
🟢 **실행**
```bash
kubectl describe nodepool default
```
출력 예시(주요 부분):
```text
Name:         default
API Version:  karpenter.sh/v1
Kind:         NodePool
Spec:
  Disruption:
    Budgets:
      Nodes:               30%                          # 한 번에 교체/통합 가능한 노드 비율 상한
    Consolidate After:     0s                           # 유휴 즉시 통합 시도
    Consolidation Policy:  WhenEmptyOrUnderutilized      # 비거나 저활용 노드 정리
  Template:
    Spec:
      Expire After:  Never                              # (v1) 노드 최대 수명 — 기본 무제한
      Node Class Ref:
        Group:  karpenter.azure.com
        Kind:   AKSNodeClass
        Name:   default
      Requirements:                                     # 노드 선택 제약(arch/os/용량유형/SKU)
        Key:       kubernetes.io/arch
        Operator:  In
        Values:    [ amd64 ]
        Key:       kubernetes.io/os
        Operator:  In
        Values:    [ linux ]
        Key:       karpenter.sh/capacity-type
        Operator:  In
        Values:    [ on-demand ]                        # 기본은 on-demand(Spot 아님)
        Key:       karpenter.azure.com/sku-family
        Operator:  In
        Values:    [ D ]                                # D 계열 SKU만 사용
Status:
  Conditions:
    Reason:  Ready
    Status:  True
    Type:    Ready                                      # NodePool 정상
  Nodes:     1                                          # 현재 이 NodePool이 만든 노드 수
  Resources:
    Cpu:     2                                          # 이 NodePool 노드들의 총 vCPU
    Memory:  4007656Ki
```
> 위 `Requirements`를 보면 기본 NodePool은 **amd64 / linux / on-demand / D 계열 SKU** 노드만 만듭니다. Pending Pod가 이 제약과 맞지 않으면(예: arm64 요구, Spot 요구) 기본 NodePool로는 노드가 안 생기고, 5)의 심화처럼 **별도 NodePool**이 필요합니다.
> - `spec.limits.cpu`(이 예시엔 미설정)를 지정하면 이 NodePool이 만들 수 있는 **총 vCPU 상한**으로 노드 폭주를 막을 수 있습니다.
> - `Expire After`는 노드 최대 수명으로, 값을 주면(예: `168h`) 주기적 롤링 교체로 노드 OS/패치를 최신화합니다(기본 `Never`).

## 2) Pending Pod로 노드 부족 유발

> 시스템 노드풀은 `CriticalAddonsOnly` taint로 앱을 받지 않으므로, 아래 워크로드는 **NAP가 만든 user 노드(`aks-default-*`)에만** 스케줄링될 수 있습니다.

`pets` 앱 Pod들은 CPU 요청량이 매우 작아(전부 합쳐도 약 0.1 vCPU) user 노드에 여유가 많습니다. 그래서 **작은 Pod는 기존 노드에 그냥 들어가** Pending이 생기지 않습니다. 대신 **노드 한 대(최소사양 `Standard_D2s_v5` = 2 vCPU)에 담기지 않는 큰 Pod 하나**를 띄웁니다. 시스템과 user 노드가 taint로 분리돼 있으므로, 이 Pod 하나면 충분합니다.

- 기존 user 노드: **2 vCPU**짜리라 **3 vCPU 요청**을 담을 수 없고,
- 시스템 노드: `CriticalAddonsOnly` **taint로 막혀** 있어

갈 곳이 없어 `Pending`이 되고, NAP가 이 요청을 담을 수 있는 노드를 **딱 1개** 새로 만듭니다.

먼저 기존 user 노드의 **VM 크기(머신 타입)** 와 vCPU를 확인해 둡니다. 아래 요청량(3 vCPU)이 한 대에 담기지 않는다는 전제를 검증하는 단계입니다.
🟢 **실행**
```bash
# 노드별 VM 크기 라벨 확인 (2 vCPU 예상)
kubectl get nodes -L node.kubernetes.io/instance-type,kubernetes.azure.com/agentpool
```
예상 출력:
```text
$ kubectl get nodes -L node.kubernetes.io/instance-type,kubernetes.azure.com/agentpool
NAME                             STATUS   ROLES    AGE    VERSION   INSTANCE-TYPE      AGENTPOOL
aks-default-svl76                Ready    <none>   98m    v1.35.5   Standard_D2as_v6
aks-system-19747041-vmss000000   Ready    <none>   122m   v1.35.5   Standard_D2s_v5    system
aks-system-19747041-vmss000001   Ready    <none>   122m   v1.35.5   Standard_D2s_v5    system
```
> user 노드(`aks-default-*`)가 2 vCPU(예: `Standard_D2as_v6`)임을 확인했으면, 3 vCPU 요청은 한 대에 담기지 않아 반드시 `Pending`이 됩니다.
🟢 **실행**
```bash
# 노드 1대 용량을 넘는 Pod '하나' — replicas/안티-어피니티 불필요
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
            requests:
              cpu: "3"            # 2 vCPU 노드에 담기지 않는 요청 → 반드시 Pending
              memory: 2Gi
EOF
```
Pod가 담길 노드가 없어 `Pending` 상태인지 확인합니다.
🟢 **실행**
```bash
kubectl get pods -n pets -l app=nap-stress -o wide   # Pending 확인
```
예상(담을 노드가 없어 `Pending`):
```text
NAME                          READY   STATUS    NODE
nap-stress-xxxxxxxxx-aaaaa    0/1     Pending   <none>   ← 담을 노드 없음 → NAP 트리거
```
Pending 원인을 직접 확인합니다.
🟢 **실행**
```bash
kubectl describe pod -n pets -l app=nap-stress | grep -A5 Events
```
예상 출력(스케줄링 실패 이유):
```text
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  10s   default-scheduler  0/3 nodes are available:
    2 node(s) had untolerated taint {CriticalAddonsOnly: true},   ← 시스템 노드 2대
    1 Insufficient cpu.                                            ← 기존 user 노드(2 vCPU)
```
> 메시지가 핵심입니다: **시스템 노드는 taint로, 기존 user 노드는 CPU 부족(`Insufficient cpu`)** 으로 막혀 단 하나의 Pod도 갈 곳이 없습니다. 그래서 Pod를 여러 개 만들 필요 없이, **노드 용량을 넘는 요청 1개**면 NAP가 트리거됩니다. (요청량을 노드 여유 용량보다 작게 주면 기존 user 노드에 그냥 스케줄링돼 Pending이 생기지 않으니 주의하세요.)

## 3) NAP 노드 자동 프로비저닝 관찰

NAP/Karpenter가 Pending Pod를 감지하고 **NodeClaim → VM → Ready** 순으로 노드를 만드는 과정을 관찰합니다. **① 먼저 이벤트로 진행 과정을 보고 → ② `kubectl get nodes`로 신규 노드가 Ready 되는지 확인**하는 순서가 보기 편합니다.

**① 이벤트로 노드 생성 과정 확인**
🟢 **실행**
```bash
# Karpenter 이벤트 스냅샷(최근순). 몇 초 간격으로 반복 실행하면 진행 과정이 보입니다
kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp
# 연속 관찰을 원하면: watch -n 2 "kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp"
```
예상 이벤트:
```text
pets       10m     Normal   Nominated           pod/nap-stress-74cf596db6-w4566   Pod should schedule on: nodeclaim/default-rp626
default    10m     Normal   DisruptionBlocked   nodeclaim/default-rp626           Nodeclaim does not have an associated node
default    10m     Normal   Launched            nodeclaim/default-rp626           Status condition transitioned, Type: Launched, Status: Unknown -> True, Reason: Launched
default    9m      Normal   Registered          nodeclaim/default-rp626           Status condition transitioned, Type: Registered, Status: Unknown -> True, Reason: Registered
default    8m53s   Normal   DisruptionBlocked   node/aks-default-rp626            Node isn't initialized
default    8m48s   Normal   Ready               node/aks-default-rp626            Status condition transitioned, Type: Ready, Status: False -> True, Reason: KubeletReady, Message: kubelet is posting ready status
default    8m32s   Normal   Initialized         nodeclaim/default-rp626           Status condition transitioned, Type: Initialized, Status: Unknown -> True, Reason: Initialized
default    8m32s   Normal   Ready               nodeclaim/default-rp626           Status condition transitioned, Type: Ready, Status: Unknown -> True, Reason: Ready
```
> Pending이던 `nap-stress` Pod가 새 NodeClaim에 **Nominated**되고 → VM이 **Launched** → 노드 **Registered/Ready** → NodeClaim **Initialized** 순으로 진행됩니다. 중간의 `DisruptionBlocked`(*Nodeclaim does not have an associated node* / *Node isn't initialized*)는 **부팅 중이라 아직 통합 대상이 아니라는 정상 메시지**로, 노드가 Ready되면 사라집니다.
> NAP는 **Pending Pod의 요청량(3 vCPU)에 맞춰 노드 SKU를 고릅니다.** 최소사양 노드(`Standard_D2as_v6` = 2 vCPU)로는 3 vCPU를 담을 수 없으므로, NAP가 더 큰 SKU(예: 4 vCPU `Standard_D4als_v6`)를 자동 선택합니다. 이렇게 **워크로드에 맞게 노드를 right-sizing**하는 것이 NAP의 핵심입니다(고정 노드풀과의 차이). 만들 수 있는 SKU/용량은 `NodePool`의 `requirements`·`limits`로 제한할 수 있습니다(아래 5절).

**② NodeClaim·신규 노드 확인**

`Ready` 이벤트가 보이면 `kubectl get nodes`로 실제 노드 추가를 확인합니다.
🟢 **실행**
```bash
kubectl get nodeclaim                # 진행 중인 노드 요청
kubectl get nodes                    # 몇 초 간격으로 반복 실행 → 신규 aks-default-* 가 Ready 되는지 확인
```
`kubectl get nodes` 예상(신규 `aks-default-*` 노드 추가):
```text
NAME                             STATUS   ROLES    AGE    VERSION
aks-system-19747041-vmss000000   Ready    <none>   136m   v1.35.5
aks-system-19747041-vmss000001   Ready    <none>   136m   v1.35.5
aks-default-svl76                Ready    <none>   112m   v1.35.5   ← 앱용(모듈 04에서 생성)
aks-default-rp626                Ready    <none>   24s    v1.35.5   ← NAP가 방금 추가(4 vCPU)
```
> 신규 노드가 `Ready`가 되면 직전까지 `Pending`이던 `nap-stress` Pod이 자동으로 그 노드에 스케줄링됩니다. `kubectl get pods -n pets -l app=nap-stress -o wide`로 확인하세요. (VM 프로비저닝·이미지 풀로 보통 1~3분 소요됩니다.)

**생성된 노드의 머신 타입(VM SKU) 확인**

NAP가 워크로드 요청량에 맞춰 어떤 VM 크기를 골랐는지 직접 확인합니다. 노드의 `node.kubernetes.io/instance-type` 라벨에 실제 Azure VM SKU가 담겨 있습니다.
🟢 **실행**
```bash
# 모든 노드의 VM SKU/용량유형/NodePool을 한눈에 확인
kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type,karpenter.sh/nodepool
```
출력 예시(NAP가 추가한 신규 노드 `aks-default-rp626`가 4 vCPU `Standard_D4als_v6`로 생성됨):
```text
$ kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type,karpenter.sh/nodepool
NAME                             STATUS   ROLES    AGE    VERSION   INSTANCE-TYPE       CAPACITY-TYPE   NODEPOOL
aks-default-rp626                Ready    <none>   24s    v1.35.5   Standard_D4als_v6   on-demand       default
aks-default-svl76                Ready    <none>   112m   v1.35.5   Standard_D2as_v6    on-demand       default
aks-system-19747041-vmss000000   Ready    <none>   136m   v1.35.5   Standard_D2s_v5
aks-system-19747041-vmss000001   Ready    <none>   136m   v1.35.5   Standard_D2s_v5
```
> 시스템 노드(`aks-system-*`)는 NAP가 아니라 AKS가 관리하므로 `CAPACITY-TYPE`/`NODEPOOL`이 비어 있습니다. NAP 노드(`aks-default-*`)만 라벨이 채워집니다. 특정 노드 하나만 자세히 보려면 `kubectl describe node aks-default-rp626 | grep -E 'instance-type|capacity-type|nodepool|sku'`를 사용하세요.
> `nap-stress`(3 vCPU 요청)를 담기 위해 2 vCPU 노드(`D2as_v6`) 대신 **4 vCPU 노드(`D4als_v6`)** 가 선택된 것이 NAP의 right-sizing 동작입니다.

## 4) 노드 축소(scale-in / consolidation) 관찰

부하(`nap-stress`)를 제거하면 방금 만든 4 vCPU 노드가 **비게 되어(Empty)** NAP가 회수합니다. 빈 노드 회수는 다른 노드의 Pod를 축출하지 않으므로 `istiod` PDB와 무관하게 **결정적으로** 진행됩니다(보통 `consolidateAfter: 0s` + 종료 유예로 30초~수 분). 확장 때와 똑같이 **① 이벤트로 회수 과정을 보고 → ② `kubectl get nodes`로 노드가 사라지는지 확인**합니다.

🟢 **실행**
```bash
kubectl delete deployment nap-stress -n pets   # 부하 제거 → 노드가 비워짐
```

**① 이벤트로 노드 회수 과정 확인**
🟢 **실행**
```bash
# Karpenter가 빈 노드를 회수하는 과정 스냅샷(최근순) — 몇 초 간격으로 반복 실행
kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp   # Disrupted/Deleted 이벤트
```
예상 이벤트:
```text
default    34s    Normal   DisruptionTerminating   nodeclaim/default-ntmx4   Disrupting NodeClaim: Empty
default    34s    Normal   DisruptionTerminating   node/aks-default-ntmx4    Disrupting Node: Empty
default    24s    Normal   DisruptionBlocked       node/aks-default-ntmx4    Node is deleting or marked for deletion
default    24s    Normal   DisruptionBlocked       nodeclaim/default-ntmx4   Node is deleting or marked for deletion
default    18s    Normal   Drained                 nodeclaim/default-ntmx4   Status condition transitioned, Type: Drained, Status: Unknown -> True, Reason: Drained
default    17s    Normal   Finalized               nodeclaim                 Finalized karpenter.sh/termination
default    17s    Normal   Finalized               node                      Finalized karpenter.sh/termination
```
> `nap-stress`가 사라져 노드가 비면 NAP가 **Empty**로 판단해 `DisruptionTerminating`을 시작하고, 노드를 **Drained**(남은 Pod 비움) → **Finalized**(정리 완료) 순으로 회수합니다(노드 수 2→1). 종료 중 나타나는 `DisruptionBlocked`(*Node is deleting or marked for deletion*)는 **이미 삭제 중이라 추가 통합 대상이 아니라는 정상 메시지**입니다.

**② 노드 축소 확인**

`Deleted` 이벤트가 보이면 `kubectl get nodes`로 노드가 실제로 줄었는지 확인합니다.
🟢 **실행**
```bash
kubectl get nodes                    # 몇 초 간격으로 반복 실행 → aks-default-* 가 사라지는지 확인
# 연속 관찰을 원하면: watch -n 2 kubectl get nodes
```
- 유휴 노드는 NAP가 **수 분 내** 회수해 `aks-default-*` 노드가 사라집니다(시스템 노드풀은 유지).
- 이때 07 모듈의 KEDA Pod 축소(`virtual-customer` 축소)도 함께 진행했다면, Pod·노드가 동시에 줄어드는 2계층 scale-in을 확인할 수 있습니다.

> **참고 — "빈 노드 회수"와 "저활용 통합(bin-packing)"은 다릅니다.** 여기서 본 축소는 부하를 제거해 노드가 **비었기 때문**에 일어나는 **Empty 회수**라, 다른 노드의 Pod를 건드리지 않아 PDB가 막지 않습니다. 반면 여러 노드에 흩어진 워크로드를 더 적은 노드로 **모으는** 저활용 통합에서는 NAP가 기존 노드의 Pod를 **축출(Evict)** 해야 하는데, `istiod`(모듈 05)처럼 **PDB가 걸린 단일 레플리카**는 축출이 **영구 차단**됩니다(`replicas=1`, `minAvailable=1`이면 한 개도 못 내림). 그 경우 이벤트에 `DisruptionBlocked: Pdb prevents pod evictions (PodDisruptionBudget=[aks-istio-system/istiod])`가 반복되고 해당 노드는 통합되지 않습니다. *05.1(AGC)을 따랐다면 Istio가 없어 이 차단이 없을 수 있으며, `kube-system`의 `alb-controller` PDB가 있으면 그것이 차단 원인일 수 있습니다.* 커스텀 `NodePool`을 **taint로 격리**해 기존 워크로드 이주 없이 안전하게 만들고 빈 노드만 회수하는 실습은 아래 [5) 심화](#5-심화--nodepool--aksnodeclass-커스터마이징)에서 다룹니다.

> **두 계층의 협력 정리:** KEDA가 부하에 맞춰 **Pod**를 늘리면 → 노드 용량이 부족해져 Pending이 생기고 → NAP가 **노드**를 추가합니다. 부하가 사라지면 KEDA가 Pod를(큐 트리거는 0까지), NAP가 빈 노드를 차례로 회수합니다.

## 5) 심화 — NodePool / AKSNodeClass 커스터마이징

NAP의 동작은 두 리소스로 제어합니다. 실제 운영에서는 기본 프로필을 그대로 쓰기보다, 워크로드 특성에 맞춰 `NodePool`을 추가/수정합니다.

- **`NodePool`** — *어떤* 노드를 만들지: 허용 SKU/아키텍처/용량유형(`requirements`), 우선순위(`weight`), 총량 상한(`limits`), 통합·수명 정책(`disruption`), 적용 대상 제한(`taints`).
- **`AKSNodeClass`** — *어떻게* 만들지: OS 디스크 크기/타입, 노드 이미지 등.

### 시나리오 — taint로 격리한 커스텀 NodePool에 전용 워크로드 배치

> **왜 격리(taint)가 필요한가:** 커스텀 `NodePool`에 **taint를 두지 않으면**, 그 NodePool이 더 저렴하거나 `weight`가 높을 때 NAP가 **기존 앱 Pod(mongodb·rabbitmq·store-front 등)까지 그 노드로 이주(Consolidation)** 시킬 수 있습니다. 상태 저장 워크로드가 축출/이주되면 **순단·데이터 장애**가 발생합니다. 그래서 이 실습은 **taint로 NodePool을 격리**하고 **전용 테스트 워크로드만 `toleration`+`nodeSelector`로 옵트인**합니다. 이렇게 하면 **기존 워크로드는 절대 이동하지 않고**, 정리 단계에서도 영향이 없습니다.

**5-1) 커스텀 AKSNodeClass 생성 (노드를 *어떻게* 만들지: OS 이미지·디스크)**

`AKSNodeClass`는 노드의 **OS 이미지 종류**와 **OS 디스크**를 정의합니다. 기본 `default`(Ubuntu)를 그대로 쓰지 않고, **Azure Linux 이미지 + 64GB OS 디스크**를 사용하는 전용 NodeClass를 만듭니다.

🟢 **실행**
```bash
kubectl apply -f - <<'EOF'
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: batch-nodeclass
spec:
  imageFamily: AzureLinux          # 노드 OS 이미지(Ubuntu | AzureLinux). 기본 default는 Ubuntu
  osDiskSizeGB: 64                 # 노드 OS 디스크 크기(GB). 기본 128 → 64로 축소
EOF
```

🟢 **실행**
```bash
kubectl get aksnodeclass
```

```text
NAME              AGE
batch-nodeclass   5s
default           60m              ← NAP가 만든 기본 NodeClass(Ubuntu, 그대로 둠)
```

> `AKSNodeClass`(*어떻게* 만들지)와 `NodePool`(*무엇을* 만들지)은 분리돼 있어, 같은 NodeClass를 여러 NodePool이 공유하거나 NodePool마다 다른 이미지/디스크를 줄 수 있습니다. 여기서는 `batch-pool`만 이 커스텀 NodeClass를 쓰므로 **기존 노드의 OS/디스크에는 영향이 없습니다.**

**5-2) 커스텀 NodePool 생성 (requirements·taints·limits·disruption 한 번에)**

허용 SKU를 화이트리스트로 고정하고, on-demand로 안정성을 확보하며, **taint로 격리**하고, 위에서 만든 **`batch-nodeclass`를 참조**하는 NodePool을 만듭니다.

🟢 **실행**
```bash
kubectl apply -f - <<'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: batch-pool
spec:
  template:
    metadata:
      labels:
        workload: batch                 # 노드 식별/선택용 라벨(전용 워크로드가 nodeSelector로 사용)
    spec:
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: batch-nodeclass           # 5-1에서 만든 커스텀 NodeClass(AzureLinux/64GB) 참조
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]         # Spot 축출로 인한 순단 방지 → on-demand 고정
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["Standard_D2s_v5", "Standard_D4s_v5"]   # 허용 SKU 화이트리스트
      taints:
        - key: workload
          value: batch
          effect: NoSchedule            # ★ 격리: 이 taint를 tolerate하지 않는 Pod는 절대 못 옴(기존 앱 보호)
      expireAfter: 168h                 # (v1) 노드 7일마다 롤링 교체 — template.spec 아래에 위치
  disruption:
    consolidationPolicy: WhenEmpty      # ★ '빈 노드만' 회수 → 실행 중 Pod 축출(이주) 없음
    consolidateAfter: 30s
  limits:
    cpu: "20"                           # 이 NodePool 총 vCPU 상한(폭주 방지)
EOF
```

> **핵심 설계 포인트**
> - `taints` — 이 NodePool 노드는 `workload=batch` taint를 가집니다. **toleration이 없는 기존 앱 Pod는 여기로 스케줄/이주될 수 없습니다.** (격리)
> - `consolidationPolicy: WhenEmpty` — **완전히 빈 노드만** 회수합니다. `WhenEmptyOrUnderutilized`와 달리 **실행 중인 Pod를 다른 노드로 축출(Evict)하지 않으므로** 순단이 없습니다. (provisioning은 정책과 무관하게 Pending Pod가 생기면 일어납니다.)
> - `requirements`의 `instance-type` 화이트리스트 — NAP가 만들 노드 크기를 통제합니다(요청량에 맞춰 가장 작은 SKU 선택).
> - `limits.cpu` — 이 NodePool이 만들 수 있는 총 vCPU 상한.

NodePool이 등록됐는지 확인합니다(아직 노드는 0개).

🟢 **실행**
```bash
kubectl get nodepool batch-pool
```

```text
NAME         NODECLASS   NODES   READY   AGE
batch-pool   default     0       True    8s
```

**5-3) 전용 워크로드 배포 (opt-in: toleration + nodeSelector)**

`batch-pool`에만 올라가도록 **taint를 tolerate**하고 **`workload: batch` 노드를 `nodeSelector`로 지정**한 전용 Pod를 띄웁니다. 기존 노드엔 자리가 없고 다른 노드는 taint 때문에 못 가므로, NAP가 `batch-pool`에 새 노드를 만듭니다.

🟢 **실행**
```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: batch-demo
  namespace: pets
spec:
  replicas: 1
  selector:
    matchLabels: { app: batch-demo }
  template:
    metadata:
      labels: { app: batch-demo }
    spec:
      nodeSelector:
        workload: batch                 # batch-pool 노드(라벨)만 선택
      tolerations:
        - key: workload
          operator: Equal
          value: batch
          effect: NoSchedule            # taint 허용(이 워크로드만 옵트인)
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "1"                  # 화이트리스트(D2s_v5/D4s_v5) 중 NAP가 SKU 선택
              memory: 256Mi
EOF
```

NAP가 `batch-pool`에 노드를 만드는 과정을 관찰합니다. 여기서도 **① 이벤트로 진행 과정을 보고 → ② `kubectl get nodes`로 신규 노드를 확인**합니다.

**① 이벤트로 노드 생성 과정 확인**
🟢 **실행**
```bash
kubectl get pods -n pets -l app=batch-demo -o wide   # 처음엔 Pending → 곧 batch-pool 노드에 스케줄
kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp
```
예상 이벤트:
```text
default    106s   Normal   ImagesReady              aksnodeclass/batch-nodeclass   Status condition transitioned, Type: ImagesReady, Status: Unknown -> True, Reason: ImagesReady
default    106s   Normal   LocalDNSReady            aksnodeclass/batch-nodeclass   Status condition transitioned, Type: LocalDNSReady, Status: Unknown -> True, Reason: LocalDNSReady
default    106s   Normal   Ready                    aksnodeclass/batch-nodeclass   Status condition transitioned, Type: Ready, Status: Unknown -> True, Reason: Ready
default    106s   Normal   ValidationSucceeded      aksnodeclass/batch-nodeclass   Status condition transitioned, Type: ValidationSucceeded, Status: Unknown -> True, Reason: ValidationSucceeded
default    106s   Normal   SubnetsReady             aksnodeclass/batch-nodeclass   Status condition transitioned, Type: SubnetsReady, Status: Unknown -> True, Reason: SubnetsReady
default    106s   Normal   KubernetesVersionReady   aksnodeclass/batch-nodeclass   Status condition transitioned, Type: KubernetesVersionReady, Status: Unknown -> True, Reason: KubernetesVersionReady
default    90s    Normal   NodeClassReady           nodepool/batch-pool            Status condition transitioned, Type: NodeClassReady, Status: Unknown -> True, Reason: NodeClassReady
default    90s    Normal   ValidationSucceeded      nodepool/batch-pool            Status condition transitioned, Type: ValidationSucceeded, Status: Unknown -> True, Reason: ValidationSucceeded
default    90s    Normal   Ready                    nodepool/batch-pool            Status condition transitioned, Type: Ready, Status: Unknown -> True, Reason: Ready
pets       81s    Normal   Nominated                pod/batch-demo-f4d64fbbf-9kz45  Pod should schedule on: nodeclaim/batch-pool-tqv2l
default    77s    Normal   Launched                 nodeclaim/batch-pool-tqv2l     Status condition transitioned, Type: Launched, Status: Unknown -> True, Reason: Launched
default    76s    Normal   DisruptionBlocked        nodeclaim/batch-pool-tqv2l     Nodeclaim does not have an associated node
```
> 먼저 커스텀 `aksnodeclass/batch-nodeclass`가 **이미지·서브넷·K8s 버전 검증을 통과(Ready)** 하고, 이어 `nodepool/batch-pool`이 **NodeClassReady/Ready**가 됩니다. 그다음 `batch-demo` Pod가 `nodeclaim/batch-pool-tqv2l`에 **Nominated**되고 VM이 **Launched**되어, NAP가 **격리된 `batch-pool`에만** 새 노드를 만듭니다(이벤트 object가 모두 `batch-*`). 부팅 중 `DisruptionBlocked`(*Nodeclaim does not have an associated node*)는 정상 메시지입니다.

**② 신규 노드·OS 이미지 확인**

`Ready` 이벤트가 보이면 노드의 SKU와 OS 이미지를 확인합니다.
🟢 **실행**
```bash
kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/nodepool -o wide
```

예상 출력:
```text
$ kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/nodepool -o wide
NAME                             STATUS   ROLES    AGE     VERSION   ...   OS-IMAGE                    INSTANCE-TYPE      NODEPOOL
aks-batch-pool-mv4lb             Ready    <none>   4m32s   v1.35.5   ...   Microsoft Azure Linux 3.0   Standard_D4s_v5    batch-pool   ← batch-nodeclass 적용(Azure Linux)
aks-default-svl76                Ready    <none>   124m    v1.35.5   ...   Ubuntu 24.04.4 LTS          Standard_D2as_v6   default      ← 기존 앱 노드(그대로 유지)
aks-system-19747041-vmss000000   Ready    <none>   148m    v1.35.5   ...   Ubuntu 24.04.4 LTS          Standard_D2s_v5
aks-system-19747041-vmss000001   Ready    <none>   148m    v1.35.5   ...   Ubuntu 24.04.4 LTS          Standard_D2s_v5
```

> 새 노드의 `OS-IMAGE`가 **`Microsoft Azure Linux 3.0`** 으로 뜨면 커스텀 `AKSNodeClass`(`imageFamily: AzureLinux`)가 적용된 것입니다. 화이트리스트(`D2s_v5`/`D4s_v5`) 중 요청량에 맞는 SKU가 선택되며, 위 예시에서는 `Standard_D4s_v5`가 골라졌습니다. 어느 경우든 **기존 `default` 노드와 앱 Pod는 전혀 영향을 받지 않습니다.**

**5-4) 정리 — 빈 노드만 회수(기존 워크로드 무영향)**

전용 워크로드를 지우면 `batch-pool` 노드가 **완전히 비고**, `WhenEmpty` 정책에 따라 NAP가 그 노드만 회수합니다. 기존 앱 Pod는 이 노드에 올라간 적이 없으므로 **아무 것도 이동하지 않습니다.**

🟢 **실행**
```bash
kubectl delete deployment batch-demo -n pets   # batch-pool 노드가 Empty가 됨 → 잠시 후 회수
# (선택) NodePool과 커스텀 NodeClass도 제거 — 격리 노드만 사라지고 기존 노드/Pod에는 영향 없음
kubectl delete nodepool batch-pool
kubectl delete aksnodeclass batch-nodeclass    # NodePool이 참조 중이면 먼저 NodePool을 지운 뒤 삭제
```

> `batch-demo`를 지우면 `batch-pool` 노드가 비어 **Drained → Finalized** 순으로 회수됩니다. NodePool/NodeClass까지 삭제하면 `WaitingOnNodeClaimTermination`(NodeClaim 종료 대기) 후 `aksnodeclass/nodeclaim/node`가 모두 **Finalized**됩니다. 종료 중 `DisruptionBlocked`(*Node is deleting or marked for deletion*)는 정상 메시지이며, 이벤트 object가 전부 `batch-*`라 **기존 노드·Pod는 전혀 건드리지 않습니다.**

> **동작 원리 요약:** Pending Pod가 생기면 NAP는 **모든** `NodePool`을 `weight` 순으로 평가해 `requirements`/`taints`를 만족하는 가장 비용효율적인 노드를 만듭니다. **taint로 격리하고 `consolidationPolicy: WhenEmpty`를 쓰면**, 커스텀 NodePool은 전용 워크로드만 받고 **빈 노드만 회수**하므로 기존 앱 Pod의 이주·순단 없이 안전하게 노드를 늘리고 줄일 수 있습니다. 더 다양한 옵션은 [AKS Node Auto Provisioning 문서](https://learn.microsoft.com/azure/aks/node-autoprovision)를 참고하세요.

## 검증 및 완료 체크리스트

다음 항목이 모두 충족되면 [09. 모니터링](09-monitoring.md)으로 진행하세요.

- [ ] `nodeProvisioningProfile.mode`가 `Auto`이고 기본 `nodepool`/`aksnodeclass`가 존재함을 확인함
- [ ] `nap-stress`(단일 Pod, `cpu: "3"`)로 노드 용량을 초과하는 요청을 만들어 Pending(`FailedScheduling`)을 확인함
- [ ] Karpenter 이벤트(`Launched`→`Ready`)와 함께 신규 노드(`aks-default-*`)가 추가되고 Pending Pod가 스케줄링됨
- [ ] 부하 제거 후 NAP가 빈 노드를 통합/회수(scale-in)함을 확인함
- [ ] `NodePool`(무엇을: requirements·disruption·limits·taints)과 `AKSNodeClass`(어떻게: imageFamily·osDiskSizeGB)의 역할을 이해하고, taint 격리로 기존 워크로드 이동 없이 커스텀 노드를 만들어 봄
- [ ] KEDA(요청량 무관·사용률/이벤트)와 NAP(요청량 기준) 트리거 차이를 이해함

---

## 트러블슈팅
| 증상 | 원인 | 진단 | 조치 |
|---|---|---|---|
| NAP가 노드를 추가하지 않음 | Pending Pod 없음 또는 NAP 비활성 | `kubectl get pods -n pets \| grep Pending`, `az aks show -g "$RG" -n "$AKS" --query nodeProvisioningProfile.mode -o tsv` (→ `Auto`) | `nap-stress`의 `cpu` 요청을 노드 1대 용량보다 크게(예: `cpu: "3"`) 올려 Pending 유발, `mode=Auto` 확인 |
| Pending인데도 노드가 안 생김 | `NodePool` 제약 불일치 또는 `limits` 도달 | `kubectl describe nodepool default`, `kubectl get nodeclaim`, `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter` | Pod의 arch/SKU/taint 요구가 `requirements`와 맞는지, `limits.cpu`가 남았는지 확인 |
| 노드 추가가 느림(수 분) | VM 프로비저닝·이미지 풀 시간 | `kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp` | 정상. `Launched`→`Ready` 이벤트까지 대기 |
| 신규 노드에 Pod가 안 올라감 | taint/toleration 또는 affinity 불일치 | `kubectl describe pod <pod> -n pets`(Events), `kubectl get node <node> -o jsonpath='{.spec.taints}'` | 워크로드에 맞는 toleration/affinity 추가 |
| 유휴 노드가 회수 안 됨(scale-in 안 됨) | 부하/Pending 잔존 또는 통합 정책 보수적 | `kubectl get pods -A -o wide \| grep aks-default`, `kubectl describe nodepool default` | `nap-stress` 삭제 확인, `consolidationPolicy`/`consolidateAfter` 점검 후 수 분 대기 |
| `NodePool` 적용 시 `unknown field "spec.disruption.expireAfter"` | Karpenter `v1`에서 `expireAfter`는 `disruption`이 아니라 `spec.template.spec` 아래로 이동 | `kubectl explain nodepool.spec.template.spec.expireAfter`, `kubectl explain nodepool.spec.disruption` | `expireAfter`를 `spec.template.spec` 아래로 옮김(5) 심화의 NodePool 예시 참고). `disruption`에는 `consolidationPolicy`/`consolidateAfter`/`budgets`만 둠 |
| vCPU 쿼터 초과로 생성 실패 | 구독 리전 vCPU 한도 부족 | Karpenter 로그의 `QuotaExceeded`, `az vm list-usage -l koreacentral -o table` | 쿼터 증설 요청 또는 더 작은 SKU 허용하도록 `requirements` 조정 |

다음: [09. 모니터링](09-monitoring.md)
