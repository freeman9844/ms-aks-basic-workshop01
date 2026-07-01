# 10. 정리

> 🟢 **실행** = 직접 입력·수행 · 👁️ **예시** = 눈으로만(개념/발췌) · 📋 **예상 출력** = 비교용(입력 불필요)

비용 누적 방지를 위해 실습 직후 리소스를 삭제합니다.

- 예상 소요: **약 10–20분**(대부분 AKS·노드 RG 삭제 대기). `terraform destroy`는 완료까지 대기하고, `az group delete --no-wait`는 요청 후 즉시 반환하지만 실제 삭제는 백그라운드로 수 분~십수 분 더 진행됩니다.

## 1) Terraform으로 전체 삭제 (약 10–15분)
🟢 **실행**
```bash
cd ~/ms-aks-basic-workshop01/terraform
# destroy 후에는 terraform output을 읽을 수 없으므로, 확인용 RG 이름을 미리 저장해 둡니다.
RG=$(terraform output -raw resource_group_name)
RG_NET=$(terraform output -raw network_resource_group_name)
RG_MON=$(terraform output -raw monitoring_resource_group_name)

terraform destroy -auto-approve
```
> NAP·Managed Prometheus·역할 할당 등 Terraform이 만든 모든 리소스는 `destroy`로 함께 삭제됩니다(분리한 **3개 RG: network/aks/monitoring** 모두 제거). 인그레스 애드온은 클러스터에 종속되어 AKS 삭제 시 자동 제거됩니다 — **모듈 05(app routing/Istio)** 를 따랐다면 `--enable-app-routing-istio` 애드온이, **옵션 모듈 05.1(AGC)** 을 따랐다면 ALB 컨트롤러 애드온이 해당합니다. 별도 리소스 그룹이 남지 않았는지 포털에서 확인하세요.
>
> 🔀 **옵션 모듈 05.1(Application Gateway for Containers)을 따랐다면 위 `terraform destroy`를 실행하기 전에 아래 [1-B) AGC 인그레스 자원 먼저 정리](#1-b-옵션-agc-모듈-051-인그레스를-사용한-경우--destroy-전에-먼저-정리)를 먼저 수행하세요.** 차단 원인은 *빈 서브넷의 존재*가 아니라, **AGC association**(= `ApplicationLoadBalancer` CR)이 위임 서브넷 `subnet-alb`에 만든 **serviceAssociationLink**입니다. CR을 남겨 두면 association이 서브넷을 점유해 VNet 삭제가 실패(`SubnetWithExternalResourcesCannotBeUsedByOtherResources`)하고, 결과적으로 네트워크 RG 삭제가 막힙니다. CR을 먼저 지우면 association/링크가 제거되어, `terraform destroy`가 VNet을 지울 때 (이제 비어 있는) `subnet-alb`도 함께 cascade 삭제됩니다.
>
> 💡 **참고(Terraform state 밖의 자동 생성 리소스):** 배포 마지막 단계의 `az aks update --enable-azure-monitor-metrics`가 만든 **Managed Prometheus 파이프라인(MSProm DCE/DCR + 레코딩 룰 6종)** 은 Terraform state 밖에 있고 **워크로드 RG**(`rg-<workload>-aks-...`)에 생성됩니다. 기본 설정에서는 `destroy` 시 워크로드 RG에 이들이 남아 *"the Resource Group still contains Resources"* 오류로 RG 삭제가 막힐 수 있습니다. 본 워크숍의 `providers.tf`는 `features.resource_group.prevent_deletion_if_contains_resources = false`를 설정해 이 잔여 자원까지 teardown에서 함께 정리하도록 했습니다(아래 트러블슈팅 참고). 참고로 **Container Insights 로그 DCR/DCRA(`MSCI-...`)는 Terraform이 직접 관리**하므로 `destroy`가 명시적으로 삭제하며, **MSI 인증에서는 과거의 `ContainerInsights(law-...)` 솔루션이 생성되지 않습니다**(모니터링 RG엔 LAW/AMW/Grafana만 존재).

예상 출력(마지막 줄):
```text
azurerm_kubernetes_cluster.aks: Destroying...
...
Destroy complete! Resources: 17 destroyed.
```

## 1-A) (옵션) az CLI로 인프라를 만든 경우 — 리소스 그룹 직접 삭제 (요청 즉시 / 백그라운드 수 분~십수 분)

[02.1 (옵션) az aks CLI](02.1-provision-option-azcli.md) 경로로 인프라를 만들었다면 **Terraform 상태가 없으므로 `terraform destroy`를 쓸 수 없습니다.** 대신 모듈 02.1에서 만든 **3개 리소스 그룹을 직접 삭제**합니다(RG를 지우면 그 안의 AKS·ACR·VNet·모니터링 백엔드·역할 할당이 모두 함께 제거됩니다).

🟢 **실행**
```bash
# 02.1 (0) 블록에서 설정했던 변수와 동일(같은 셸이면 그대로 사용,
# 새 터미널이면 02.1의 변수 설정 블록을 다시 실행)
RG="rg-${WORKLOAD}-aks-${RG_SUFFIX}"          # 워크로드(AKS/ACR)
RG_NET="rg-${WORKLOAD}-network-${RG_SUFFIX}"  # 네트워크(VNet/Subnet)
RG_MON="rg-${WORKLOAD}-monitoring-${RG_SUFFIX}" # 모니터링(LAW/AMW/Grafana)

# 워크로드 RG를 먼저 삭제(AKS가 네트워크/모니터링을 참조하므로),
# 그다음 네트워크/모니터링 RG 삭제
az group delete -n "$RG"     --yes --no-wait
az group delete -n "$RG_NET" --yes --no-wait
az group delete -n "$RG_MON" --yes --no-wait
```
- `--no-wait`: 삭제 요청만 보내고 즉시 반환합니다(백그라운드로 진행, 수 분 소요).
- 변수 값이 기억나지 않으면 이름/태그로 찾아 지울 수 있습니다.
  ```bash
  az group list --query "[?tags.workload=='aksworkshop'].name" -o tsv   # 대상 RG 이름 확인(workload 변수를 바꿨다면 그 값으로 교체)
  # 또는 접두사로: az group list -o table | grep -i aksworkshop
  ```
- AKS가 자동 생성한 **노드 RG(`MC_...`)** 는 워크로드 RG(AKS) 삭제 시 함께 제거됩니다.

> ℹ️ 이 옵션은 **az CLI 경로 전용**입니다. Terraform(모듈 02)으로 만들었다면 위 **1) `terraform destroy`** 를 사용하세요(상태 파일과 실제 리소스를 일관되게 정리).

## 1-B) (옵션) AGC(모듈 05.1) 인그레스를 사용한 경우 — `destroy` 전에 먼저 정리

[05.1 (옵션) Application Gateway for Containers](05.1-ingress-option-agc.md) 경로로 인그레스를 구성했다면, AGC 관련 자원은 **Terraform state 밖**(AGC 리소스, 위임 서브넷 `subnet-alb`, 역할 할당, 애드온)에 있습니다. 핵심은 **`ApplicationLoadBalancer`(CR)를 먼저 지우는 것**입니다 — CR이 만든 **AGC association**이 위임 서브넷 `subnet-alb`에 **serviceAssociationLink**를 걸어 두기 때문에, CR이 남아 있으면 `terraform destroy`(또는 RG 삭제)가 VNet을 지우지 못해 막힙니다. CR을 지우면 association/링크가 제거되고, 그 뒤 `terraform destroy`가 VNet을 삭제할 때 비어 있는 `subnet-alb`도 함께 정리되므로 **destroy 전에 아래 1)~2)를 먼저 실행**하세요(아래 3) 수동 서브넷 삭제는 선택 사항).

🟢 **실행**
```bash
cd ~/ms-aks-basic-workshop01/terraform
RG=$(terraform output -raw resource_group_name)
AKS=$(terraform output -raw aks_cluster_name)
NET_RG=$(terraform output -raw network_resource_group_name)
VNET=$(terraform output -raw vnet_name)

# 1) Gateway/HTTPRoute 제거 → AGC Frontend 제거
kubectl delete -f manifests/gateway-agc.yaml

# 2) ApplicationLoadBalancer 제거 → Azure의 AGC 리소스/association 삭제
kubectl delete applicationloadbalancer alb-test -n alb-test-infra
kubectl delete namespace alb-test-infra

# 3) (선택) 위임 서브넷 수동 제거 — terraform destroy가 VNet과 함께 정리하므로 보통 불필요
az network vnet subnet delete -g "$NET_RG" --vnet-name "$VNET" --name subnet-alb

# 4) (선택) 애드온 비활성화
az aks update -g "$RG" -n "$AKS" --disable-application-load-balancer
```
예상 출력:
```text
$ kubectl delete -f manifests/gateway-agc.yaml
gateway.gateway.networking.k8s.io "store-gateway" deleted
httproute.gateway.networking.k8s.io "store-front" deleted

$ kubectl delete applicationloadbalancer alb-test -n alb-test-infra
applicationloadbalancer.alb.networking.azure.io "alb-test" deleted

$ kubectl delete namespace alb-test-infra
namespace "alb-test-infra" deleted
```
> AGC Azure 리소스는 `ApplicationLoadBalancer`(CR)의 수명에 종속됩니다. CR을 지우면 Azure 리소스와 **subnet-alb의 serviceAssociationLink(association)** 가 함께 제거됩니다(약 1~2분). 1)~2)가 끝난 뒤 **1) `terraform destroy`** 를 진행하면 VNet이 삭제되며 비어 있는 `subnet-alb`도 cascade로 정리되어 네트워크 RG가 정상 삭제됩니다(3) 수동 서브넷 삭제는 선택). CR 삭제 직후 association 정리에 시간이 걸려 destroy가 `SubnetWithExternalResourcesCannotBeUsedByOtherResources`로 실패하면, 10~15분 후 다시 실행하세요. (az CLI 경로(1-A)였다면 1)~2) 후 1-A의 RG 삭제를 진행하세요.)

## 2) 확인 (약 1–2분)
🟢 **실행**
```bash
# 위 1)에서 미리 저장한 $RG/$RG_NET/$RG_MON를 그대로 사용합니다(같은 셸 세션).
for g in "$RG" "$RG_NET" "$RG_MON"; do az group show -n "$g" 2>&1 | head -1; done
```
> 같은 셸을 유지하지 못했거나 az CLI 경로(1-A)로 삭제했다면, 위 1-A의 `$RG`·`$RG_NET`·`$RG_MON`를 다시 정의해 사용하세요(`terraform destroy` 후에는 `terraform output`이 비어 있습니다). `--no-wait`로 지웠다면 삭제가 끝나기까지 수 분간 `Deleting` 상태로 보일 수 있습니다.

예상: 세 리소스 그룹이 모두 더 이상 존재하지 않음(`ResourceGroupNotFound`).
```text
(ResourceGroupNotFound) Resource group 'rg-aksworkshop-aks-dev-krc-12345' could not be found.
(ResourceGroupNotFound) Resource group 'rg-aksworkshop-network-dev-krc-12345' could not be found.
(ResourceGroupNotFound) Resource group 'rg-aksworkshop-monitoring-dev-krc-12345' could not be found.
```

## 검증 및 완료 체크리스트

아래 항목이 모두 충족되면 워크숍 환경이 깨끗하게 정리된 것입니다.

- [ ] `terraform destroy` 출력에 `Destroy complete! Resources: 17 destroyed.`
- [ ] RG 3종(network/aks/monitoring)이 모두 `ResourceGroupNotFound`
- [ ] 노드 RG(`MC_...`)도 함께 제거됨(포털에서 확인)
- [ ] 포털 비용/리소스 목록에 잔여 과금 리소스가 없음

---

## 트러블슈팅
| 증상 | 원인 | 진단 | 조치 |
|---|---|---|---|
| `destroy`가 역할 할당/네트워크에서 멈춤 | 리소스 삭제 순서·의존성 일시 충돌 | `terraform destroy` 출력의 에러 리소스 확인 | `terraform destroy -auto-approve` 재실행(이어서 진행) |
| `destroy`가 서브넷/VNet에서 실패 | AKS가 만든 잔여 LB/NIC가 서브넷 참조 | 포털에서 노드 RG(`MC_...`) 확인 | 노드 RG 리소스 제거 후 재실행, 또는 수 분 대기 후 재시도 |
| RG가 포털에 계속 보임 | 노드 RG(`MC_...`)는 별도 | `az group list -o table \| grep -i $RG` | AKS 삭제 시 자동 제거됨, 남으면 수동 삭제 |
| 워크로드 RG 삭제 실패: `the Resource Group still contains Resources` | CLI가 만든 Managed Prometheus 파이프라인(`MSProm-...` DCE/DCR·`*RecordingRulesRuleGroup`)이 **워크로드 RG**에 잔존(Terraform state 밖) | `az resource list -g <워크로드 RG> -o table` | `providers.tf`의 `prevent_deletion_if_contains_resources = false`로 해결됨. 구버전 설정이면 `az resource delete --ids <잔여 리소스 ID>` 후 `terraform destroy` 재실행 |
| `terraform output`이 빈 값 | 상태가 이미 일부 삭제됨 | `terraform state list` | 포털에서 3개 RG(network/aks/monitoring) 직접 삭제로 마무리 |
| 비용이 계속 발생 | 일부 리소스 잔존 | `az resource list -g <RG> -o table` | 세 RG가 모두 삭제됐는지 확인(모듈 2) 확인 절차 참고) |

수고하셨습니다! 🎉 전체 워크숍 흐름과 핵심 개념은 [README](../README.md)에서 다시 확인할 수 있습니다.
