# 07. 오토스케일링 (1) — KEDA로 Pod 확장

> 🟢 **실행** = 직접 입력·수행 · 👁️ **예시** = 눈으로만(개념/발췌) · 📋 **예상 출력** = 비교용(입력 불필요)

오토스케일링은 **두 계층**으로 나뉩니다. 이 모듈에서는 **KEDA**로 *Pod 수*를 자동 조절하고, 다음 모듈 [08. NAP](08-autoscaling-nap.md)에서 *노드 수*를 자동 조절합니다. 두 계층이 어떻게 협력하는지 이해하는 것이 핵심입니다.

| 계층 | 무엇을 늘리나 | 트리거 기준 | 도구 | scale-to-zero | 모듈 |
|---|---|---|---|---|---|
| **KEDA** (Pod 오토스케일러) | Deployment의 **Pod 복제본 수** | **CPU 사용률**, **큐 길이**, 이벤트 수 등 | KEDA 애드온(내부적으로 HPA 자동 생성) | 가능(이벤트 트리거) | **07 (이 문서)** |
| **NAP** (노드 오토스케일러) | 클러스터의 **노드 수** | Pending Pod의 **CPU 요청량(requests)** | Karpenter | — | 08 |

> **왜 HPA가 아니라 KEDA인가?** 표준 HPA는 CPU/메모리 같은 **리소스 메트릭**만 봅니다. **KEDA**(Kubernetes Event-Driven Autoscaler)는 그 위에서 **메시지 큐 길이, 이벤트 수, 외부 메트릭** 등 60종 이상의 스케일러를 제공하고, 트래픽이 없을 때 **0개로 축소(scale-to-zero)** 까지 할 수 있습니다. KEDA는 `ScaledObject`를 적용하면 **내부적으로 HPA를 자동 생성**하므로, CPU 기반 확장은 HPA와 동일하게 동작하면서 이벤트 기반 확장까지 한 도구로 통합합니다. 이 클러스터는 Terraform에서 KEDA 애드온이 이미 활성화되어 있습니다(`workload_autoscaler_profile.keda_enabled`).

> **KEDA vs NAP 트리거 차이:** KEDA의 큐(이벤트) 트리거는 "큐 길이/이벤트 수", NAP는 "요청량(requests)"으로 동작합니다. 그래서 부하를 주는 방식이 서로 다릅니다(이 문서 = 큐 길이 부하, 08 모듈 = 요청량 부하).

```mermaid
flowchart LR
    subgraph keda["Pod 계층 — KEDA (이 모듈)"]
        q[RabbitMQ orders 큐 ↑] --> so[ScaledObject<br/>rabbitmq 트리거]
        so --> hpa[자동 생성 HPA] --> rep[Pod 0→N]
    end
    subgraph nap["노드 계층 — NAP (08 모듈)"]
        pend[Pending Pod<br/>요청량 초과] --> napc[NAP / Karpenter] --> node[신규 노드 추가]
    end
    rep -. 자원 부족 시 .-> pend
```

## 1) KEDA 애드온 확인

Terraform으로 활성화된 KEDA 컨트롤러가 동작 중인지 확인합니다.
🟢 **실행**
```bash
cd ~/ms-aks-basic-workshop01
kubectl get pods -n kube-system -l app.kubernetes.io/name=keda-operator
kubectl api-resources | grep keda.sh   # ScaledObject/TriggerAuthentication CRD 확인
```
예상 출력:
```text
NAME                             READY   STATUS    RESTARTS   AGE
keda-operator-7d9c5b6f8-abcde    1/1     Running   0          40m

scaledobjects        keda.sh/v1alpha1   true    ScaledObject
triggerauthentications keda.sh/v1alpha1 true    TriggerAuthentication
```
> CRD가 안 보이면 KEDA 애드온이 아직 준비 중입니다. `az aks show -g "$RG" -n "$AKS" --query workloadAutoScalerProfile.keda.enabled -o tsv` 가 `true`인지 확인하세요(`02` 모듈에서 설정).

## 2) KEDA로 큐(이벤트) 기반 스케일링 — RabbitMQ

KEDA의 진짜 강점은 **외부 이벤트** 기반 확장입니다. AKS Store는 주문을 `rabbitmq`의 `orders` 큐에 쌓고 `makeline-service`가 소비합니다. 큐가 쌓이면 워커를 늘리고, 비면 **0개까지 축소**하도록 `ScaledObject`를 적용합니다.

`manifests/keda-rabbitmq.yaml`은 세 가지를 정의합니다.
- **Secret**(`keda-rabbitmq-secret`): AMQP 접속 문자열 `amqp://username:password@rabbitmq.pets.svc.cluster.local:5672/` (앱의 `rabbitmq-secrets`와 동일한 자격증명).
- **TriggerAuthentication**(`keda-rabbitmq-auth`): ScaledObject가 위 host를 안전하게 참조하도록 연결.
- **ScaledObject**(`makeline-rabbitmq`): `orders` 큐 길이 기준, 메시지 5개당 Pod 1개, 0~15개.

👁️ **예시**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: makeline-rabbitmq, namespace: pets }
spec:
  scaleTargetRef: { name: makeline-service }
  minReplicaCount: 0           # scale-to-zero
  maxReplicaCount: 15
  cooldownPeriod: 30
  pollingInterval: 5
  advanced:                      # (선택) 데모용 빠른 축소
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 30   # HPA 기본 300초(5분) → 30초
  triggers:
    - type: rabbitmq
      metadata:
        protocol: amqp
        queueName: orders
        mode: QueueLength      # 큐 길이 기준
        value: "5"             # 메시지 5개당 Pod 1개
      authenticationRef: { name: keda-rabbitmq-auth }
```

적용하고 큐 트리거를 관찰합니다.
🟢 **실행**
```bash
kubectl apply -f manifests/keda-rabbitmq.yaml
kubectl get scaledobject makeline-rabbitmq -n pets
```

큐에 메시지를 쌓아 확장을 유발합니다. **이 트리거는 CPU와 무관하게 큐 길이만 보므로, KEDA를 가장 안정적·저비용으로 보여주는 방법입니다.** `makeline-service`는 `minReplicaCount: 0`이라 평소 0개로 떠 있고, 소비자가 0인 동안에는 **소수의 virtual-customer만으로도** `orders` 큐가 빠르게 쌓입니다.

먼저 **확장 전 현재 상태**를 확인해 기준점을 잡습니다. 소비자(`makeline-service`)가 0개로 떠 있고 큐(TARGETS)가 0인 상태에서 시작해야 0→N 변화를 명확히 볼 수 있습니다.
🟢 **실행**
```bash
# 현재 HPA(큐 길이 TARGETS, 목표 REPLICAS)와 makeline-service Pod 개수 확인
kubectl get hpa keda-hpa-makeline-rabbitmq -n pets
kubectl get pods -n pets -l app=makeline-service
```
출력 예시(확장 전 — Pod 0개, 큐 비어 있음):
```text
NAME                                REFERENCE                    TARGETS             MINPODS   MAXPODS   REPLICAS
keda-hpa-makeline-rabbitmq          Deployment/makeline-service  0/5 (avg)           1         15        0

No resources found in pets namespace.
```
> `makeline-service` Pod가 0개(`No resources found`)인 것이 정상입니다 — `minReplicaCount: 0`이라 큐가 비면 소비자를 아예 0개로 내립니다(scale-to-zero). 큐가 쌓이면 아래 단계에서 깨어납니다.

이제 큐에 메시지를 쌓아 확장을 유발합니다. 먼저 생산자(`virtual-customer`)를 늘립니다.
🟢 **실행**
```bash
# 생산자(virtual-customer)를 늘려 orders 큐 적재 속도를 소비 속도보다 높임
kubectl scale deploy/virtual-customer -n pets --replicas=10
```
그런 다음 아래 두 명령을 몇 초 간격으로 반복 실행해 확장을 관찰합니다.
🟢 **실행**
```bash
# HPA 스냅샷으로 큐 길이(TARGETS)와 목표 복제본을, 실제 Pod 개수로 확장 결과를 확인
# (0→N으로 늘어나는 것이 보입니다)
kubectl get hpa keda-hpa-makeline-rabbitmq -n pets
kubectl get pods -n pets -l app=makeline-service
```
> **왜 10개인가?** 확장은 `orders` 큐 길이가 임계값(메시지 5개당 Pod 1개)을 넘을 때 일어납니다. `makeline-service`가 정상 기동해 빠르게 소비하면 생산자가 적을 때(예: 5개) 큐가 5를 넘지 못해 확장이 안 될 수 있습니다. 생산자를 **10개 이상**으로 늘려 소비 속도를 앞질러야 큐가 쌓이고 확장이 트리거됩니다. `TARGETS`가 `1/5`처럼 낮게 머물면 생산자를 더 늘리세요.

예상: `orders` 큐 길이가 늘면 `makeline-service` Pod가 0→N으로 증가하고, 큐가 비면 다시 0으로 축소됩니다.
```text
# HPA: TARGETS(현재/임계 큐 길이), REPLICAS(목표 복제본)
NAME                                REFERENCE                    TARGETS              MINPODS   MAXPODS   REPLICAS
keda-hpa-makeline-rabbitmq          Deployment/makeline-service  12/5 (avg)           1         15        3

# 실제 makeline-service Pod (위 REPLICAS만큼 생성됨)
NAME                                READY   STATUS    RESTARTS   AGE
makeline-service-5f9c8d7b6c-2xk9p   1/1     Running   0          40s
makeline-service-5f9c8d7b6c-7mwqz   1/1     Running   0          40s
makeline-service-5f9c8d7b6c-pl4tg   1/1     Running   0          40s
```
> `makeline-service` Pod 개수가 0개로 떨어졌다가 큐가 쌓이면 다시 깨어나는(scale-to-zero → 활성) 과정이 KEDA의 핵심 가치입니다. 표준 HPA로는 0개 축소가 불가능합니다.
> 연속 관찰을 원하면 `watch -n 2 kubectl get pods -n pets -l app=makeline-service`처럼 `watch`를 사용하세요(`kubectl -w`는 단일 리소스 타입만 추적 가능).

## 3) Pod 축소(scale-in) 관찰

부하를 제거하면 KEDA가 Pod를 줄입니다(이벤트 트리거는 0까지). 먼저 생산자를 줄입니다.
🟢 **실행**
```bash
kubectl scale deploy/virtual-customer -n pets --replicas=1
```
그런 다음 아래 두 명령을 몇 초 간격으로 반복 실행해 축소를 관찰합니다.
🟢 **실행**
```bash
# 큐가 비면서 HPA의 TARGETS가 0으로, makeline-service Pod 개수가 0개로 줄어드는지 확인
kubectl get hpa keda-hpa-makeline-rabbitmq -n pets
kubectl get pods -n pets -l app=makeline-service
```
- 큐 트리거(`makeline-rabbitmq`)는 `orders` 큐가 비면 `cooldownPeriod` 뒤 **0개**까지 축소됩니다(scale-to-zero). Pod가 모두 사라지면 `kubectl get pods`는 `No resources found`를 출력합니다.
- **축소는 확장보다 느립니다.** `TARGETS`가 `0/5`인데도 Pod가 한동안 그대로인 것은 정상입니다 — HPA는 메트릭이 떨어져도 **scale-down 안정화 윈도우** 동안 최근 최대 복제본을 유지(플래핑 방지)하기 때문입니다. 위 매니페스트는 이 윈도우를 기본 **300초(5분) → 30초**로 줄여 두었으므로, 큐가 빈 뒤 약 30초~1분이면 `N→1→0` 순서로 내려갑니다. (HPA는 1까지만 줄이고, `1→0`은 KEDA가 `cooldownPeriod` 뒤 직접 처리하므로 `MINPODS`는 항상 `1`로 표시됩니다.)

> 노드 축소(scale-in)는 다음 모듈 [08. NAP](08-autoscaling-nap.md)에서 노드 추가와 함께 다룹니다.

## 4) 시간 기반(cron) 트리거로 선제(proactive) 확장

2)·3)의 큐 트리거가 "이벤트 = 큐 길이"였다면, 여기서는 **"이벤트 = 시간"** 을 다룹니다. 표준 HPA는 부하가 **온 뒤에야** 반응하지만, KEDA의 **cron 스케일러**는 **알려진 패턴**(점심 러시, 업무 시작 시각, 배치 윈도우)에 맞춰 부하가 오기 **전에 미리** 확장합니다. 이로써 콜드스타트/지연을 피하고, 시간대가 지나면 다시 최소 복제본으로 내려 **비용을 절감**합니다.

`manifests/keda-cron.yaml`은 프런트엔드 `store-front`에 cron 트리거를 적용합니다.
- 대상은 2)에서 이미 ScaledObject가 걸린 `makeline-service`와 분리해 **`store-front` 전용** ScaledObject로 둡니다 — 한 Deployment는 하나의 ScaledObject/HPA만 가질 수 있습니다.
- **`minReplicaCount: 1`**: 프런트엔드는 항상 떠 있어야 하므로 0이 아닌 1을 유지합니다(scale-to-zero는 2)·3)에서 확인). 지정 시간대에만 **1 → 5**로 선제 확장.

👁️ **예시**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: store-front-cron, namespace: pets }
spec:
  scaleTargetRef: { name: store-front }
  minReplicaCount: 1            # 평상시 1개 유지
  maxReplicaCount: 5
  cooldownPeriod: 30
  triggers:
    - type: cron
      metadata:
        timezone: Asia/Seoul    # IANA 타임존 필수(미지정 시 UTC)
        start: "5 12 * * *"     # 매일 12:05 확장 시작(점심 러시 전)
        end:   "0 14 * * *"     # 14:00 종료 → 다시 1개
        desiredReplicas: "5"
```

> **cron 표현식 주의:** 표준 **분 단위 5필드**(`분 시 일 월 요일`)이며 **초 단위는 불가**합니다. `timezone`을 빼면 UTC로 동작하므로 한국 시간 기준이면 반드시 `Asia/Seoul`을 지정하세요.

### 실습용 시간 주입 (즉시 관찰)

실제 12:05까지 기다릴 수 없으므로, `start`/`end`를 "지금부터 약 +2분 ~ +5분"으로 바꿔 적용합니다. 이 **편집 + 적용** 단계만 **`scripts/keda-cron-demo.sh`** 로 자동화했습니다 — 스크립트가 현재 시각 기준으로 `manifests/keda-cron.yaml`의 `start`/`end`를 in-place 편집한 뒤 `kubectl apply`까지 수행합니다. (관찰은 아래에서 수동으로 진행)
🟢 **실행**
```bash
# manifests/keda-cron.yaml의 start/end를 현재 시각 +2분/+5분으로 편집 후 적용
bash scripts/keda-cron-demo.sh
# 시작/종료 시점(분)을 바꾸려면: START_OFFSET=1 END_OFFSET=4 bash scripts/keda-cron-demo.sh
kubectl get scaledobject store-front-cron -n pets
```
> 직접 편집하려면 현재 시각을 `date "+%H:%M (분=%M, 시=%H)"`로 확인해 `manifests/keda-cron.yaml`의 `start`/`end`를 수정(예: 현재 `15:37`이면 `start: "39 15 * * *"`, `end: "42 15 * * *"`)한 뒤 `kubectl apply -f manifests/keda-cron.yaml` 하세요.

확장 전 기준점을 확인한 뒤, 아래 두 명령을 몇 초 간격으로 반복 실행해 시간대 진입 시점의 변화를 관찰합니다.
🟢 **실행**
```bash
# cron 트리거의 활성 여부(ACTIVE)와 목표 복제본, 실제 store-front Pod 개수 확인
kubectl get hpa keda-hpa-store-front-cron -n pets
kubectl get pods -n pets -l app=store-front
```
예상: `start` 시각이 되면 `store-front`가 **1 → 5**로 증가하고, `end` 시각에는 **5 → 1**로 복귀합니다.
```text
# 시간대 진입 후 — HPA가 cron 메트릭으로 목표 복제본을 5로 올림
NAME                              REFERENCE                  TARGETS        MINPODS   MAXPODS   REPLICAS
keda-hpa-store-front-cron         Deployment/store-front     1/1 (avg)      1         5         5

NAME                             READY   STATUS    RESTARTS   AGE
store-front-7c8f9d6b5-2lq8n      1/1     Running   0          35s
store-front-7c8f9d6b5-7xk4p      1/1     Running   0          35s
store-front-7c8f9d6b5-9vm2t      1/1     Running   0          35s
store-front-7c8f9d6b5-pd6rw      1/1     Running   0          35s
store-front-7c8f9d6b5-xn3hz      1/1     Running   0          35s
```
> **큐 트리거와의 차이:** 큐 트리거는 "큐가 쌓여야" 확장되지만, cron 트리거는 **부하와 무관하게 시각만으로** 확장합니다. 트래픽이 예측 가능한 서비스(점심 피크, 출근 시간 등)에서 미리 용량을 확보하는 데 이상적입니다.

관찰을 마쳤으면 cron ScaledObject를 제거합니다. 단, **ScaledObject를 지워도 `store-front`는 마지막 복제본 수(예: 5개)로 그대로 남습니다** — KEDA가 만든 HPA만 사라질 뿐, 오토스케일러 제거가 Deployment를 자동으로 축소하지는 않기 때문입니다(표준 HPA도 동일). 따라서 원래대로 되돌리려면 **복제본을 직접 1개로 내려야** 합니다.
🟢 **실행**
```bash
kubectl delete -f manifests/keda-cron.yaml
# ScaledObject 삭제만으로는 5개가 유지되므로 명시적으로 원복
kubectl scale deploy/store-front -n pets --replicas=1
# 데모용으로 in-place 편집된 매니페스트를 원래 내용으로 원복(저장소 오염 방지)
git checkout manifests/keda-cron.yaml
kubectl get pods -n pets -l app=store-front
```

> (고급) 한 ScaledObject에 cron + CPU 트리거를 함께 두면 KEDA는 **각 트리거 목표의 최댓값**을 취합니다 — "기본은 시간 기반, 갑작스런 부하엔 CPU로 추가 확장"하는 하이브리드 구성이 가능합니다.

## 검증 및 완료 체크리스트

다음 항목이 모두 충족되면 [08. 오토스케일링 (2) — NAP](08-autoscaling-nap.md)로 진행하세요.

- [ ] KEDA 애드온(`keda-operator`)과 `ScaledObject`/`TriggerAuthentication` CRD가 동작함을 확인함
- [ ] 큐 기반 `ScaledObject`로 `makeline-service`가 `orders` 큐 길이에 따라 0↔N으로 확장/축소됨(scale-to-zero)
- [ ] 부하 제거 후 Pod가 0개까지 축소됨(큐→0)
- [ ] 시간 기반(cron) `ScaledObject`로 `store-front`가 지정 시간대에 1→N으로 선제 확장되고 시간대 종료 후 복귀함
- [ ] KEDA(이벤트/큐/시간)와 NAP(요청량) 트리거 차이를 이해함

---

## 트러블슈팅
| 증상 | 원인 | 진단 | 조치 |
|---|---|---|---|
| `ScaledObject` `READY=False` | KEDA 애드온 미기동 또는 CRD 미설치 | `kubectl get pods -n kube-system -l app.kubernetes.io/name=keda-operator`, `kubectl describe scaledobject <name> -n pets` | KEDA Pod `Running` 대기. `az aks show ... --query workloadAutoScalerProfile.keda.enabled` 가 `true`인지 확인 |
| 큐 트리거가 확장 안 함 | RabbitMQ 인증(host) 오류 또는 큐가 비어 있음 | `kubectl describe scaledobject makeline-rabbitmq -n pets`, `kubectl logs -n kube-system -l app.kubernetes.io/name=keda-operator` | `keda-rabbitmq-secret`의 host 값·`authenticationRef` 확인, `virtual-customer` 복제본 상향으로 큐 적재 |
| `TARGETS`가 `1/5`처럼 낮게 머물며 확장 안 됨 | 소비자(makeline)가 정상 기동해 생산 속도를 따라잡아 큐가 임계값(5)을 못 넘김 | `kubectl get hpa keda-hpa-makeline-rabbitmq -n pets`의 `TARGETS` 확인 | `virtual-customer`를 **10개 이상**으로 상향(`kubectl scale deploy/virtual-customer -n pets --replicas=10`)해 소비 속도를 앞지름 |
| `TARGETS`는 `0/5`인데 Pod가 한동안 줄지 않음 | (정상) HPA의 scale-down **안정화 윈도우**가 최근 최대 복제본을 유지(기본 300초) | `kubectl describe hpa keda-hpa-makeline-rabbitmq -n pets`의 `Behavior`/`Events` 확인 | 윈도우 경과 대기. 빠르게 보려면 ScaledObject에 `advanced.horizontalPodAutoscalerConfig.behavior.scaleDown.stabilizationWindowSeconds: 30`(본 매니페스트에 적용됨) |
| 큐 트리거가 0으로 안 떨어짐 | 큐에 메시지 잔존 또는 `cooldownPeriod`/안정화 윈도우 미경과 | `kubectl get hpa keda-hpa-makeline-rabbitmq -n pets`의 `TARGETS`로 큐 길이 확인 | 큐가 0이 될 때까지 대기(소비자가 모두 처리), `cooldownPeriod`·안정화 윈도우 경과 대기 |
| `makeline-service`가 `CrashLoopBackOff`(probe `context deadline exceeded`/`connection refused`) | CPU limit이 너무 낮아(기본 `5m`) 스로틀 → `/health`(startup/liveness) 응답 지연으로 probe 실패 | `kubectl describe pod -n pets -l app=makeline-service`의 `Limits`(`cpu: 5m`)와 Events의 probe 실패 확인 | 매니페스트의 makeline-service limit 상향(`cpu 200m/memory 128Mi`, 본 저장소 적용됨) 후 재적용. 임시로 `kubectl -n pets set resources deploy/makeline-service --requests=cpu=10m,memory=32Mi --limits=cpu=200m,memory=128Mi` |
| cron 트리거가 의도한 시각에 확장 안 함 | `timezone` 누락(UTC로 동작) 또는 `start`/`end` 분·시 값이 현재 시각과 어긋남 | `kubectl describe scaledobject store-front-cron -n pets`의 트리거/`date`로 현재 시각 대조 | `timezone: Asia/Seoul` 지정, `start`/`end`를 현재 시각 기준 +2분/+5분으로 재설정 후 재적용 |
| cron `end` 이후에도 안 줄어듦 | `cooldownPeriod`/HPA 안정화 윈도우 미경과, 또는 `start`/`end` 윈도우가 아직 안 끝남 | `kubectl get hpa keda-hpa-store-front-cron -n pets`의 `REPLICAS`, `date`로 윈도우 종료 확인 | `end` 시각 경과 + `cooldownPeriod` 대기. 윈도우가 자정을 넘기면 `start`/`end`를 같은 날 안에 들어오도록 설정 |
| ScaledObject 삭제 후에도 `store-front` Pod가 5개 그대로 | (정상) ScaledObject 삭제 시 HPA만 제거되고 Deployment의 현재 replica는 마지막 값으로 유지됨(오토스케일러 제거가 워크로드를 축소하지 않음) | `kubectl get deploy store-front -n pets`의 `READY/REPLICAS` 확인 | `kubectl scale deploy/store-front -n pets --replicas=1`로 명시적 원복 |

다음: [08. 오토스케일링 (2) — NAP](08-autoscaling-nap.md)
