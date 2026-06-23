# 07. 오토스케일링 (2) — NAP로 노드 자동 프로비저닝

이전 모듈 [06. KEDA](06-autoscaling-keda.md)에서 **Pod 수**를 늘렸습니다. 그런데 Pod가 늘다 보면 기존 노드의 CPU/메모리 **요청량(requests)** 합계가 노드 용량을 넘어, 더 이상 스케줄링되지 못하는 **Pending Pod**가 생깁니다. 이때 **노드 자체를 자동으로 추가**하는 것이 **NAP(Node Auto Provisioning)** 입니다.

| 항목 | 내용 |
|---|---|
| 무엇을 늘리나 | 클러스터의 **노드 수**(VM) |
| 트리거 기준 | **Pending Pod**의 리소스 **요청량(requests)** |
| 엔진 | **Karpenter**(오픈소스)의 AKS 통합 구현 |
| 제어 리소스 | `NodePool`(어떤 노드를 만들지) + `AKSNodeClass`(노드 OS/디스크 설정) |
| 활성화 | `nodeProvisioningProfile.mode = Auto` (이 워크샵은 모듈 02 마지막의 `az aks update --node-provisioning-mode Auto`로 설정) |

## 1) NAP 활성화 상태 확인

이 워크샵은 모듈 02 마지막 단계의 `az aks update --node-provisioning-mode Auto`로 NAP를 이미 켰습니다. 모드와 제어 리소스를 확인합니다.
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
> 위 `Requirements`를 보면 기본 NodePool은 **amd64 / linux / on-demand / D 계열 SKU** 노드만 만듭니다. Pending Pod가 이 제약과 맞지 않으면(예: arm64 요구, Spot 요구) 기본 NodePool로는 노드가 안 생기고, 4)의 심화처럼 **별도 NodePool**이 필요합니다.
> - `spec.limits.cpu`(이 예시엔 미설정)를 지정하면 이 NodePool이 만들 수 있는 **총 vCPU 상한**으로 노드 폭주를 막을 수 있습니다.
> - `Expire After`는 노드 최대 수명으로, 값을 주면(예: `168h`) 주기적 롤링 교체로 노드 OS/패치를 최신화합니다(기본 `Never`).

## 2) Pending Pod로 노드 부족 유발

> 시스템 노드풀은 `CriticalAddonsOnly` taint로 앱을 받지 않으므로, 아래 워크로드는 **NAP가 만든 user 노드(`aks-default-*`)에만** 스케줄링될 수 있습니다.

`pets` 앱 Pod들은 CPU 요청량이 매우 작아(전부 합쳐도 약 0.1 vCPU) user 노드에 여유가 많습니다. 그래서 **작은 Pod는 기존 노드에 그냥 들어가** Pending이 생기지 않습니다. 대신 **노드 한 대(최소사양 `Standard_D2s_v5` = 2 vCPU)에 담기지 않는 큰 Pod 하나**를 띄웁니다. 시스템과 user 노드가 taint로 분리돼 있으므로, 이 Pod 하나면 충분합니다.

- 기존 user 노드: **2 vCPU**짜리라 **3 vCPU 요청**을 담을 수 없고,
- 시스템 노드: `CriticalAddonsOnly` **taint로 막혀** 있어

갈 곳이 없어 `Pending`이 되고, NAP가 이 요청을 담을 수 있는 노드를 **딱 1개** 새로 만듭니다.
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
```bash
kubectl get pods -n pets -l app=nap-stress -o wide   # Pending 확인
```
예상(담을 노드가 없어 `Pending`):
```text
NAME                          READY   STATUS    NODE
nap-stress-xxxxxxxxx-aaaaa    0/1     Pending   <none>   ← 담을 노드 없음 → NAP 트리거
```
Pending 원인을 직접 확인합니다.
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

NAP/Karpenter가 Pending Pod를 감지하고 **NodeClaim → VM → Ready** 순으로 노드를 만드는 과정을 이벤트로 관찰합니다.
```bash
# Karpenter 이벤트 스냅샷(최근순). 몇 초 간격으로 반복 실행하면 진행 과정이 보입니다
kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp
# 연속 관찰을 원하면: watch -n 2 "kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp"
```
예상 이벤트(요지):
```text
default   Normal   Nominated     nodeclaim/default-xxxxx   ... created nodeclaim
default   Normal   Launched      nodeclaim/default-xxxxx   ... launched instance Standard_D4s_v5
default   Normal   Registered    node/aks-default-xxxxx    ... registered node
default   Normal   Ready         node/aks-default-xxxxx    ... node is ready
```
> NAP는 **Pending Pod의 요청량(3 vCPU)에 맞춰 노드 SKU를 고릅니다.** 최소사양 노드(`Standard_D2s_v5` = 2 vCPU)로는 3 vCPU를 담을 수 없으므로, NAP가 더 큰 SKU(예: 4 vCPU `Standard_D4s_v5`)를 자동 선택합니다. 이렇게 **워크로드에 맞게 노드를 right-sizing**하는 것이 NAP의 핵심입니다(고정 노드풀과의 차이). 만들 수 있는 SKU/용량은 `NodePool`의 `requirements`·`limits`로 제한할 수 있습니다(아래 4절).
NodeClaim과 노드 추가를 함께 확인합니다.
```bash
kubectl get nodeclaim                # 진행 중인 노드 요청
kubectl get nodes                    # 몇 초 간격으로 반복 실행 → 신규 aks-default-* 가 Ready 되는지 확인
```
`kubectl get nodes` 예상(신규 `aks-default-*` 노드 추가):
```text
NAME                             STATUS   ROLES    AGE   VERSION
aks-system-12345678-vmss000000   Ready    <none>   42m   v1.34.x
aks-system-12345678-vmss000001   Ready    <none>   42m   v1.34.x
aks-default-abcde                Ready    <none>   30m   v1.34.x   ← 앱용(모듈 04에서 생성)
aks-default-fghij                Ready    <none>   60s   v1.34.x   ← NAP가 방금 추가(4 vCPU)
```
> 신규 노드가 `Ready`가 되면 직전까지 `Pending`이던 `nap-stress` Pod이 자동으로 그 노드에 스케줄링됩니다. `kubectl get pods -n pets -l app=nap-stress -o wide`로 확인하세요. (VM 프로비저닝·이미지 풀로 보통 1~3분 소요됩니다.)

**생성된 노드의 머신 타입(VM SKU) 확인**

NAP가 워크로드 요청량에 맞춰 어떤 VM 크기를 골랐는지 직접 확인합니다. 노드의 `node.kubernetes.io/instance-type` 라벨에 실제 Azure VM SKU가 담겨 있습니다.
```bash
# 모든 노드의 VM SKU/용량유형/NodePool을 한눈에 확인
kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type,karpenter.sh/nodepool
```
출력 예시(NAP가 추가한 `aks-default-fghij`가 4 vCPU `Standard_D4s_v5`로 생성됨):
```text
NAME                             STATUS   ROLES    AGE   VERSION   INSTANCE-TYPE      CAPACITY-TYPE   NODEPOOL
aks-system-12345678-vmss000000   Ready    <none>   42m   v1.34.x   Standard_D2s_v5                    
aks-system-12345678-vmss000001   Ready    <none>   42m   v1.34.x   Standard_D2s_v5                    
aks-default-abcde                Ready    <none>   30m   v1.34.x   Standard_D2s_v5    on-demand       default
aks-default-fghij                Ready    <none>   60s   v1.34.x   Standard_D4s_v5    on-demand       default
```
> 시스템 노드(`aks-system-*`)는 NAP가 아니라 AKS가 관리하므로 `CAPACITY-TYPE`/`NODEPOOL`이 비어 있습니다. NAP 노드(`aks-default-*`)만 라벨이 채워집니다. 특정 노드 하나만 자세히 보려면 `kubectl describe node aks-default-fghij | grep -E 'instance-type|capacity-type|nodepool|sku'`를 사용하세요.
> `nap-stress`(3 vCPU 요청)를 담기 위해 2 vCPU 노드(`D2s_v5`) 대신 **4 vCPU 노드(`D4s_v5`)** 가 선택된 것이 NAP의 right-sizing 동작입니다.

### 💡 노드를 계속 모니터링하면 일어나는 일 — 통합(Consolidation)으로 다시 축소

> **이 모듈에서 가장 중요한 동작입니다.** NAP는 노드를 **늘리기만** 하는 게 아니라, 부하가 줄면 **저활용 노드를 자동으로 비우고 제거(Consolidation)** 해 비용을 회수합니다. 확장(2~3절)과 이 자동 축소가 한 쌍으로 동작한다는 점이 핵심입니다.

노드가 2개로 늘어난 뒤 잠시 더 관찰하면, **노드 수가 다시 1개로 줄어드는 것**을 볼 수 있습니다. 이는 버그가 아니라 NAP의 **통합(Consolidation)** 동작으로, 저활용 노드를 비우고 제거해 비용을 회수하는 정상 과정입니다. 기본 NodePool 정책이 `consolidationPolicy: WhenEmptyOrUnderutilized` + `consolidateAfter: 0s`이기 때문입니다(1절의 `describe nodepool` 출력 참고).

```bash
# 노드 수 변화를 반복 조회 (2개로 늘었다가 다시 1개로 줄어드는지)
kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/nodepool
# 통합 과정의 이벤트를 최근순으로 확인
kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp
```
통합이 일어날 때 이벤트는 대략 아래 순서로 나타납니다.
```text
# 1) 새 노드가 떠서 워크로드를 더 적은 노드에 담을 수 있게 되자, 기존 노드를 저활용으로 판단
default  Normal   DisruptionTerminating   node/aks-default-dj77v   Disrupting Node: Underutilized
# 2) 기존 노드의 Pod들을 다른 노드로 쫓아내고(Evicted) 재배치(Nominated)
pets     Normal   Evicted     pod/mongodb-0          Evicted pod: Underutilized
pets     Normal   Nominated   pod/mongodb-0          Pod should schedule on: node/aks-default-v57bb
# 3) PodDisruptionBudget(PDB) 때문에 드레이닝이 잠시 막히거나 재시도될 수 있음
#    (아래 PDB 이름은 모듈 05를 따른 경우(app-routing/istiod) 예시입니다. 05.1(AGC)을
#     따랐다면 Istio가 설치되지 않아 aks-istio-system/istiod PDB 자체가 없으므로 이 줄은
#     아예 나타나지 않고 통합이 바로 진행될 수 있습니다(또는 kube-system의 alb-controller
#     PDB가 있으면 그것이 잠깐 차단 원인일 수 있습니다).)
default  Normal   DisruptionBlocked   nodeclaim/...   Pdb prevents pod evictions (PodDisruptionBudget=[aks-istio-system/istiod])
default  Warning  FailedDraining      node/...        Failed to drain node, N pods are waiting to be evicted
# 4) 드레이닝 완료 후 기존 노드 종료 → 노드 수 2→1로 복귀
default  Normal   Drained     nodeclaim/aks-default-dj77v   ...
default  Normal   Finalized   nodeclaim                     Finalized karpenter.sh/termination
# 5) 남은 노드는 더 싼 노드로 못 바꾼다고 판단해 그대로 유지
default  Normal   Unconsolidatable   node/aks-default-v57bb   Can't replace with a cheaper node
```
일어나는 일과 이유를 정리하면:

| 이벤트 | 의미 | 이유 |
|---|---|---|
| `DisruptionTerminating: Underutilized` | 저활용 노드를 비우기 시작 | 새 노드가 생겨 워크로드를 더 적은 노드에 bin-packing 가능 → 작은 노드가 불필요 |
| `Evicted: Underutilized` → `Nominated` | 해당 노드의 Pod를 다른 노드로 이주 | 노드를 비워야 안전하게 제거 가능. KEDA/Deployment가 Pod를 다시 띄움 |
| `DisruptionBlocked: Pdb prevents pod evictions` | 드레이닝이 일시 차단 | `istiod`(모듈 05) 등에 **PodDisruptionBudget**이 걸려 동시 축출 수를 제한(가용성 보호). 잠시 후 재시도로 진행. *05.1(AGC) 사용 시엔 `istiod` PDB가 없어 이 차단이 나타나지 않을 수 있으며, `kube-system`의 `alb-controller`에 PDB가 있으면 그것이 차단 원인일 수 있음* |
| `FailedDraining: N pods waiting` | 드레이닝 일시 실패 | 위 PDB·종료 유예(graceful termination) 때문에 일시적. 재시도로 해소되는 정상 현상 |
| `Drained` / `Finalized` | 노드 비움 완료 후 삭제 | 모든 Pod 이주 완료 → VM 회수(비용 절감) |
| `Unconsolidatable: Can't replace with a cheaper node` | 더 통합/교체할 게 없음 | 남은 노드가 이미 최적. 안정 상태 도달 |
| `VMEventScheduled ... IMDS unavailable` | (무해) 예약 유지보수 이벤트 조회 실패 | IMDS 일시 불가. 노드 동작과 무관, 무시 가능 |

> 핵심: NAP는 Pending이 생기면 **확장(노드 추가)**, 노드가 저활용이면 **통합(노드 제거)** 으로 **양방향 right-sizing**을 자동 수행합니다. 그래서 부하 테스트 직후 노드가 잠깐 늘었다가 다시 줄어드는 것은 의도된 비용 최적화 동작입니다. (통합 정책을 직접 바꿔 보는 실습은 아래 [4) 심화 — 예시 B](#4-심화--nodepool--aksnodeclass-커스터마이징)에서 다룹니다.)

## 4) 심화 — NodePool / AKSNodeClass 커스터마이징

NAP의 동작은 두 리소스로 제어합니다. 실제 운영에서는 기본 프로필을 그대로 쓰기보다, 워크로드 특성에 맞춰 `NodePool`을 추가/수정합니다.

- **`NodePool`** — *어떤* 노드를 만들지: 허용 SKU/아키텍처/용량유형(`requirements`), 우선순위(`weight`), 총량 상한(`limits`), 통합·수명 정책(`disruption`), 적용 대상 제한(`taints`).
- **`AKSNodeClass`** — *어떻게* 만들지: OS 디스크 크기/타입, 노드 이미지 등.

### 예시 A — Spot + Arm64 비용 최적화 NodePool

배치/내결함성 워크로드를 저렴한 **Spot** 또는 **Arm64(Ampere)** 노드에 우선 배치합니다.

**A-1) NodePool 적용**
```bash
kubectl apply -f - <<'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-arm
spec:
  weight: 50                       # 기본(default)보다 먼저 평가
  template:
    spec:
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type     # Spot 우선
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch             # Arm64
          operator: In
          values: ["arm64"]
        - key: karpenter.azure.com/sku-family
          operator: In
          values: ["D"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
  limits:
    cpu: "100"                      # 이 NodePool 총 vCPU 상한
EOF
```
> **핵심:** 이 NodePool은 `weight: 50`으로 기본 `default`(weight 0)보다 **먼저 평가**됩니다. 그리고 **taint를 두지 않았기 때문에**, 특별한 toleration/nodeSelector가 없는 **일반 워크로드도** NAP가 노드를 새로 만들 때 이 NodePool(=Spot/Arm64)을 우선 선택합니다. 즉 앱 변경 없이 신규 노드를 저렴한 Spot으로 유도할 수 있습니다.
> Spot 노드는 Azure가 회수(축출)할 수 있으므로 중단을 견디는 워크로드에 적합합니다. 또한 Arm64 노드를 쓰므로 컨테이너 이미지가 멀티아키(arm64)를 지원해야 합니다(미지원 이미지는 아래 fallback 참고).

**A-2) NodePool 등록 확인**
```bash
kubectl get nodepool                       # spot-arm 이 보이는지
kubectl describe nodepool spot-arm | grep -A12 'Requirements\|Disruption\|Limits'
```
```text
NAME       NODECLASS   NODES   READY   AGE
default    default     2       True    62m
spot-arm   default     0       True    10s     ← 방금 추가(아직 노드 0개)
```

**A-3) 일반 워크로드가 weight로 Spot 노드에 자동 배치됨**

섹션 2와 **완전히 같은 일반 Pod**(toleration·nodeSelector 없음)를 띄웁니다. 기존 노드에 담기지 않는 **큰 요청(3 vCPU)** 이라 `Pending`이 되고 NAP가 새 노드를 만드는데, 이때 **`spot-arm` NodePool의 weight(50)가 default(0)보다 높아** NAP가 **Spot(Arm64) 노드를 선택**합니다. 앱에는 아무 Spot 관련 설정이 없는데도 비용 최적화 노드로 가는 것이 핵심입니다.
```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spot-arm-demo
  namespace: pets
spec:
  replicas: 1
  selector:
    matchLabels: { app: spot-arm-demo }
  template:
    metadata:
      labels: { app: spot-arm-demo }
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9   # 멀티아키(arm64 지원)
          resources:
            requests:
              cpu: "3"             # 2 vCPU 노드에 담기지 않는 요청 → 반드시 Pending → NAP
              memory: 2Gi
EOF
```
배포 직후 Pod가 `Pending` 상태인지 확인합니다.
```bash
kubectl get pods -n pets -l app=spot-arm-demo -o wide   # 처음엔 Pending
```
예상(담을 노드가 없어 `Pending` → 잠시 후 신규 Spot 노드에 배치):
```text
NAME                          READY   STATUS    NODE
spot-arm-demo-xxxxxxxxx-aaaaa 0/1     Pending   <none>   ← 담을 노드 없음 → NAP 트리거
```

**A-4) Spot Arm64 노드 생성 관찰**
```bash
# Karpenter가 spot-arm NodePool로 노드를 만드는지 이벤트 스냅샷으로 확인(최근순)
kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp
kubectl get nodeclaim -L karpenter.sh/nodepool,karpenter.sh/capacity-type,kubernetes.io/arch
```
```text
NAME             TYPE              CAPACITY   NODEPOOL   READY   AGE   NODEPOOL   CAPACITY-TYPE   ARCH
spot-arm-abcde   Standard_D2pls_v5 spot       spot-arm   True    70s   spot-arm   spot            arm64
```

**A-5) 배치 결과 검증 — Pod가 Spot/Arm64 노드에 떴는지**
```bash
NODE=$(kubectl get pods -n pets -l app=spot-arm-demo -o jsonpath='{.items[0].spec.nodeName}')
echo "scheduled on: $NODE"
kubectl get node "$NODE" -L karpenter.sh/capacity-type,kubernetes.io/arch
```
```text
scheduled on: aks-spot-arm-abcde
NAME                  STATUS   ROLES   AGE   VERSION   CAPACITY-TYPE   ARCH
aks-spot-arm-abcde    Ready    <none>  60s   v1.34.x   spot            arm64
```
> `CAPACITY-TYPE=spot`, `ARCH=arm64`면 weight 우선순위에 따라 의도대로 비용 최적화 노드에 배치된 것입니다. **(가용성 주의)** 일부 리전/구독은 Spot+Arm64 재고가 없을 수 있습니다. 노드가 안 만들어지고 `kubectl describe nodeclaim`에 용량 부족 오류가 보이면, `spot-arm` NodePool의 `kubernetes.io/arch` 요구사항을 `["amd64"]`로 바꾸거나 제거(= Spot만)한 뒤 다시 적용(A-1)하고 재시도하세요(테스트 Pod는 그대로 두면 됩니다).

> ⚠️ **주의 — 잠시 후 클러스터 전체가 Spot 노드로 쏠릴 수 있습니다(정상 동작).** 이 예시의 `spot-arm` NodePool은 "일반 Pod가 weight만으로 Spot에 뜨는 것"을 보여주려고 **taint를 일부러 뺐습니다.** 그 결과 NAP의 통합(Consolidation)이 `kubectl get events ... karpenter`에서 아래처럼 동작합니다.
> ```text
> ConsolidationCandidate  node/aks-default-xxxxx  replace: [aks-default-xxxxx] -> [1 replacement] (savings: $0.14)
> DisruptionTerminating   node/aks-default-xxxxx  Disrupting Node: Underutilized
> Evicted/Nominated       pod/...                 → node/aks-spot-arm-xxxxx
> ```
> 즉 **(1) Spot이 on-demand보다 싸고 (2) taint가 없어 일반 앱 Pod도 받을 수 있고 (3) weight=50으로 우선순위가 높아서**, NAP가 기존 on-demand 노드를 "더 싼 노드로 교체" 대상으로 보고 **모든 워크로드(mongodb·rabbitmq 포함)를 Spot 노드로 이주**시킵니다. 오작동이 아니라 비용 최적화 통합의 정상 결과입니다.
>
> **운영에서 전체 Spot 쏠림을 막으려면** Spot NodePool을 옵트인 방식으로 격리하세요.
> - `spot-arm`에 **taint** 추가(예: `spot=true:NoSchedule`) → Spot을 감수하는 워크로드만 `tolerations`로 옵트인. 일반 앱은 on-demand에 남습니다.
> - 또는 중요한 Pod에 `karpenter.sh/capacity-type: on-demand` nodeAffinity를 줘 Spot 배치를 금지.
> - **상태 저장(stateful)** 워크로드(mongodb·rabbitmq)는 Spot 축출(30초 예고 후 회수) 위험이 있으므로 on-demand 권장. (이 예시는 학습용이라 격리를 생략한 것입니다.)

**A-6) 정리**
```bash
kubectl delete deployment spot-arm-demo -n pets
kubectl delete nodepool spot-arm        # 빈 노드는 NAP가 곧 회수
```
> 정리 후에도 일부 워크로드가 잠깐 Spot 노드에 남아 있을 수 있습니다. `spot-arm` NodePool을 지우면 NAP가 해당 Spot 노드를 회수하고, 남은 Pod를 다시 기본(on-demand) 노드로 재배치합니다(수 분 소요).

### 예시 B — 통합(Consolidation)으로 비용 회수

저활용 노드를 NAP가 더 적은 노드로 **빈-패킹(bin-packing)** 해 비용을 회수하는 과정을 실습합니다.

**B-1) 적극적 통합 정책의 NodePool 적용**

`disruption` 설정만 다른 별도 NodePool을 만들어 동작을 관찰합니다(기본 `default` NodePool은 AKS가 관리하므로 직접 수정하지 않습니다).
```bash
kubectl apply -f - <<'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: consolidation-demo
spec:
  weight: 20
  template:
    spec:
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["Standard_D2s_v5"]   # 노드 크기를 2 vCPU로 고정 → 각 노드에 1.5 vCPU Pod 1개만 → 여러 노드로 흩어짐
      taints:
        - key: consolidation-demo
          value: "true"
          effect: NoSchedule
      expireAfter: 168h              # (v1) 노드 7일마다 롤링 교체 — template.spec 아래에 위치
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized  # 비거나 저활용 노드 정리
    consolidateAfter: 30s          # 유휴 30초 후 통합 시도
  limits:
    cpu: "100"
EOF
```
적용 후 NodePool이 정상 등록됐는지 확인합니다.
```bash
kubectl get nodepool consolidation-demo
kubectl describe nodepool consolidation-demo | grep -A6 Disruption
```
```text
NAME                 NODECLASS   NODES   READY   AGE
consolidation-demo   default     0       True    8s

Disruption:
  Consolidation Policy:  WhenEmptyOrUnderutilized
  Consolidate After:     30s
  Budgets:
    Nodes:  10%
```

**B-2) 여러 노드로 흩어지는 워크로드 배포(통합 대상 만들기)**

각 Pod가 노드 절반 이상의 CPU를 요구하도록 해 **여러 노드로 흩어지게** 합니다. Pod를 `consolidation-demo` NodePool에 고정(`nodeSelector`)해 다른 NodePool로 통합되지 않도록 합니다.
```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: consolidation-demo
  namespace: pets
spec:
  replicas: 2
  selector:
    matchLabels: { app: consolidation-demo }
  template:
    metadata:
      labels: { app: consolidation-demo }
    spec:
      nodeSelector:
        karpenter.sh/nodepool: consolidation-demo   # 이 NodePool 노드(D2s_v5)에만 배치 → 다른 NodePool로 통합 방지
      tolerations:
        - key: consolidation-demo
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "1500m"        # D2s_v5(2 vCPU) 노드당 1개만 들어감 → 노드 여러 대 생성
              memory: 256Mi
EOF
```
NAP가 워크로드를 담기 위해 노드를 여러 대 만드는지 확인합니다.
```bash
kubectl get nodes -L karpenter.sh/nodepool   # consolidation-demo 노드가 여러 대 생기는지
```
```text
NAME                           STATUS   ROLES   AGE   VERSION   NODEPOOL
aks-system-12345678-vmss000000 Ready    <none>  70m   v1.34.x
aks-system-12345678-vmss000001 Ready    <none>  70m   v1.34.x
aks-default-abcde              Ready    <none>  58m   v1.34.x   default
aks-consolidation-demo-aaaaa   Ready    <none>  90s   v1.34.x   consolidation-demo
aks-consolidation-demo-bbbbb   Ready    <none>  88s   v1.34.x   consolidation-demo
```
> 각 Pod가 1.5 vCPU를 요구하는데 D2s_v5(2 vCPU) 노드엔 하나만 들어가므로, replica 2개가 **노드 2대로 흩어집니다**(저활용 상태 = 통합 대상).
>
> ⚠️ **노드가 여러 대가 아니라 큰 노드 1대만 생기면?** NodePool의 `requirements`에 **노드 크기 제약이 없을 때**(예: `sku-family: D`만 지정) 발생합니다. 이 경우 Karpenter가 비용효율을 위해 **큰 D 노드 1대**(예: D8s_v5)에 Pod 2개를 모두 bin-packing 하기 때문입니다. 위처럼 `node.kubernetes.io/instance-type: ["Standard_D2s_v5"]`로 **노드 크기를 2 vCPU로 고정**해야 "노드당 Pod 1개 → 여러 노드"가 성립합니다. 또한 Pod에 `nodeSelector: karpenter.sh/nodepool: consolidation-demo`를 줘야 통합 시 다른(default) NodePool의 큰 노드로 합쳐지지 않습니다. 만약 `ConsolidationCandidate ... (part of N-node consolidation)` 이벤트와 함께 모두 한 노드로 합쳐졌다면 이 두 제약이 빠진 것입니다.

**B-3) 부하 축소 → 통합 관찰**

replica를 줄이면 노드가 저활용 상태가 되고, NAP가 남은 Pod를 더 적은 노드로 옮긴 뒤 빈 노드를 회수합니다.
```bash
kubectl scale deployment consolidation-demo -n pets --replicas=1
# 통합/노드 삭제 이벤트 스냅샷(최근순) — 몇 초 간격으로 반복 실행
kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp
kubectl get nodes -L karpenter.sh/nodepool                   # consolidation-demo 노드 수가 줄어드는지
```
```text
default   Normal   Disrupted   nodeclaim/consolidation-demo-xxxxx   ... disrupting via consolidation: underutilized
default   Normal   Deleted     node/aks-consolidation-demo-xxxxx    ... deleted node
```

**B-4) 정리**
```bash
kubectl delete deployment consolidation-demo -n pets
kubectl delete nodepool consolidation-demo
```

> **동작 원리 요약:** Pending Pod가 생기면 NAP는 **모든** `NodePool`을 `weight` 순으로 평가해, 제약을 만족하면서 가장 비용효율적인 SKU를 골라 노드를 만듭니다. 부하가 줄면 `disruption` 정책에 따라 노드를 통합/회수합니다. 자세한 예시는 [aks-labs: Scaling with KEDA and Karpenter](https://azure-samples.github.io/aks-labs/docs/operations/scaling-with-keda-and-karpenter/)와 [AKS Node Auto Provisioning 문서](https://learn.microsoft.com/azure/aks/node-autoprovision)를 참고하세요.

## 5) 노드 축소(scale-in / consolidation) 관찰

부하를 제거하면 NAP가 빈 노드를 감지해 회수합니다.
```bash
kubectl delete deployment nap-stress -n pets
# Karpenter가 빈 노드를 회수하는 과정 스냅샷(최근순) — 몇 초 간격으로 반복 실행
kubectl get events -A --field-selector source=karpenter --sort-by=.lastTimestamp   # Disrupted/Deleted 이벤트
kubectl get nodes                                            # 반복 실행 → aks-default-* 가 사라지는지 확인
# 연속 관찰을 원하면: watch -n 2 kubectl get nodes
```
출력 예시:
```text
default   Normal   Disrupted   nodeclaim/default-xxxxx   ... disrupting via consolidation
default   Normal   Deleted     node/aks-default-xxxxx    ... deleted node
```
- 유휴 노드는 NAP가 **수 분 내** 회수해 `aks-default-*` 노드가 사라집니다(시스템 노드풀은 유지).
- 이때 06 모듈의 KEDA Pod 축소(`virtual-customer` 축소)도 함께 진행했다면, Pod·노드가 동시에 줄어드는 2계층 scale-in을 확인할 수 있습니다.

> **두 계층의 협력 정리:** KEDA가 부하에 맞춰 **Pod**를 늘리면 → 노드 용량이 부족해져 Pending이 생기고 → NAP가 **노드**를 추가합니다. 부하가 사라지면 KEDA가 Pod를(큐 트리거는 0까지), NAP가 빈 노드를 차례로 회수합니다.

## 검증 및 완료 체크리스트

다음 항목이 모두 충족되면 [08. 모니터링](08-monitoring.md)으로 진행하세요.

- [ ] `nodeProvisioningProfile.mode`가 `Auto`이고 기본 `nodepool`/`aksnodeclass`가 존재함을 확인함
- [ ] `nap-stress`(단일 Pod, `cpu: "3"`)로 노드 용량을 초과하는 요청을 만들어 Pending(`FailedScheduling`)을 확인함
- [ ] Karpenter 이벤트(`Launched`→`Ready`)와 함께 신규 노드(`aks-default-*`)가 추가되고 Pending Pod가 스케줄링됨
- [ ] `NodePool`/`AKSNodeClass`의 역할(requirements·disruption·limits)을 이해함
- [ ] 부하 제거 후 NAP가 빈 노드를 통합/회수(scale-in)함을 확인함
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
| `NodePool` 적용 시 `unknown field "spec.disruption.expireAfter"` | Karpenter `v1`에서 `expireAfter`는 `disruption`이 아니라 `spec.template.spec` 아래로 이동 | `kubectl explain nodepool.spec.template.spec.expireAfter`, `kubectl explain nodepool.spec.disruption` | `expireAfter`를 `spec.template.spec` 아래로 옮김(예시 B 참고). `disruption`에는 `consolidationPolicy`/`consolidateAfter`/`budgets`만 둠 |
| vCPU 쿼터 초과로 생성 실패 | 구독 리전 vCPU 한도 부족 | Karpenter 로그의 `QuotaExceeded`, `az vm list-usage -l koreacentral -o table` | 쿼터 증설 요청 또는 더 작은 SKU 허용하도록 `requirements` 조정 |

다음: [08. 모니터링](08-monitoring.md)
