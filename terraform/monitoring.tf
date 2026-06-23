# --- 관측: Log Analytics / Azure Monitor Workspace / Grafana (모니터링 RG) ---
resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${local.name}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_monitor_workspace" "this" {
  name                = "amw-${local.name}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  tags                = local.common_tags
}

resource "azurerm_dashboard_grafana" "this" {
  name                  = "graf-${local.name}"
  resource_group_name   = azurerm_resource_group.monitoring.name
  location              = azurerm_resource_group.monitoring.location
  grafana_major_version = 12
  tags                  = local.common_tags

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }
}

# Managed Prometheus 메트릭 수집 파이프라인(DCE/DCR/DCRA)은 Terraform에서 만들지 않습니다.
# 배포 마지막 단계에서 `az aks update --enable-azure-monitor-metrics
#   --azure-monitor-workspace-resource-id <AMW>` 명령으로 활성화하면 CLI가 내부적으로
# DCE/DCR/DCRA(+레코딩 룰)를 자동 생성하고 위 AMW에 연결합니다. (docs/02 마지막 단계 참고)

# --- Container Insights 로그 수집 파이프라인(DCR + DCRA) ---
# aks.tf의 oms_agent { msi_auth_for_monitoring_enabled = true } 는 addon(ama-logs) 활성화 +
# AAD(MSI) 인증 설정 + LAW 연결까지만 합니다. MSI 인증에서는 컨테이너 로그가 '키 직접 push'가 아니라
# **DCR을 통해서만** LAW로 전송되므로, 아래 DCR + DCRA가 없으면 ama-logs가 보낼 경로가 없어
# ContainerLogV2/Logs by Volume가 빈 결과가 됩니다(메트릭은 별도 MSProm DCR로 흐르므로 정상).
# 따라서 MSI 인증 Container Insights는 이 DCR/DCRA를 명시적으로 선언해야 합니다.
resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = "MSCI-${var.location}-${azurerm_kubernetes_cluster.this.name}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  kind                = "Linux"
  tags                = local.common_tags

  destinations {
    log_analytics {
      name                  = "la-workspace"
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
    }
  }

  data_flow {
    streams      = ["Microsoft-ContainerInsights-Group-Default"]
    destinations = ["la-workspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = ["Microsoft-ContainerInsights-Group-Default"]
      # enableContainerLogV2 = true → stdout/stderr 로그가 ContainerLogV2 스키마로 적재
      # (PodNamespace/PodName/LogMessage 컬럼 제공 — 모듈 08 KQL이 이 스키마 사용)
      extension_json = jsonencode({
        dataCollectionSettings = {
          enableContainerLogV2 = true
        }
      })
    }
  }
}

# DCR을 AKS 클러스터에 연결(DCRA) → ama-logs가 이 규칙을 따라 LAW로 로그 전송
resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
}

# Grafana -> Monitor Workspace 메트릭 읽기
resource "azurerm_role_assignment" "grafana_reader" {
  scope                = azurerm_monitor_workspace.this.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this.identity[0].principal_id
}

# 실습자 -> Grafana 관리자 로그인
resource "azurerm_role_assignment" "grafana_admin" {
  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
