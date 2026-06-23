# --- 워크로드: ACR + AKS 클러스터 (워크로드 RG) ---
resource "azurerm_container_registry" "this" {
  name                = "acr${local.name}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.common_tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.name}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  dns_prefix          = "aks-${local.name}"

  # 베스트 프랙티스: 시스템 노드풀은 시스템(critical) Pod 전용으로 둡니다.
  # only_critical_addons_enabled = true → 노드에 CriticalAddonsOnly=true:NoSchedule taint가 붙어
  # 일반 앱 Pod는 이 풀에 스케줄링되지 않고, NAP(Node Auto Provisioning)가 만든 user 노드(aks-default-*)로 갑니다.
  # 이렇게 분리하면 폭주하는 앱 Pod가 시스템 Pod 자원을 빼앗아 클러스터를 불안정하게 만드는 것을 방지합니다.
  # 주의: 기존 클러스터에서 이 값을 바꾸면 노드풀이 재생성될 수 있으므로 신규 프로비저닝을 권장합니다.
  default_node_pool {
    name                         = "system"
    node_count                   = var.system_node_count
    vm_size                      = var.system_node_vm_size
    vnet_subnet_id               = azurerm_subnet.aks.id
    only_critical_addons_enabled = true
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    # BYO VNet(10.224.0.0/16)와 겹치지 않도록 서비스/Pod CIDR을 명시
    service_cidr   = "10.0.0.0/16"
    dns_service_ip = "10.0.0.10"
    pod_cidr       = "10.244.0.0/16"
  }

  # KEDA 워크로드 오토스케일러
  workload_autoscaler_profile {
    keda_enabled = true
  }

  # Container Insights (로그)
  # msi_auth_for_monitoring_enabled = true → 워크스페이스 키 대신 관리 ID(AAD) 인증 + DCR 기반 온보딩.
  # 이 경우 컨테이너 로그가 레거시 ContainerLog(V1)가 아니라 ContainerLogV2 스키마로 적재됩니다
  # (ContainerLogV2는 관리 ID 인증 온보딩의 기본 테이블 — PodNamespace/PodName/LogMessage 컬럼 제공).
  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  # Managed Prometheus(메트릭)는 Terraform이 아니라 배포 마지막 단계의
  # `az aks update --enable-azure-monitor-metrics --azure-monitor-workspace-resource-id <AMW>`
  # 명령으로 활성화합니다(DCE/DCR/DCRA + 레코딩 룰을 CLI가 자동 생성). docs/02 마지막 단계 참고.
  # 그 out-of-band 변경을 Terraform이 되돌리지 않도록 monitor_metrics 드리프트는 무시합니다.

  tags = local.common_tags

  lifecycle {
    ignore_changes = [monitor_metrics]
  }
}

# --- NAP(노드 자동 프로비저닝) ---
# nodeProvisioningProfile.mode = "Auto" (Karpenter 기반)는 AzureRM Provider에 인자가 없습니다.
# 과거에는 azapi_update_resource로 Terraform에서 켰지만, 그 경우 배포 마지막의
# `az aks update --enable-azure-monitor-metrics`(메트릭 활성화)가 클러스터를 전체 PUT으로
# 왕복하면서 nodeProvisioningProfile을 누락 → NAP가 기본값 Manual로 되돌아가는 문제가 있었습니다.
# (mode 미지정 시 기본값은 Manual.) 그래서 NAP는 Terraform에서 빼고, 배포 마지막 단계에서
# 메트릭과 '같은' az aks update 한 번에 --node-provisioning-mode Auto로 함께 켭니다(단일 PUT → 덮어쓰기 없음).
# docs/02 "3) NAP + Managed Prometheus 메트릭 수집 활성화" 참고.

# AKS kubelet -> ACR 이미지 pull
resource "azurerm_role_assignment" "aks_acr" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
