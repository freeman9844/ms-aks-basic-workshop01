data "azurerm_client_config" "current" {}

resource "random_integer" "suffix" {
  min = 10000
  max = 99999
}

locals {
  name = "${var.prefix}${random_integer.suffix.result}"

  # CAF: 리전 약어 (리소스 이름에 사용)
  region_abbreviations = {
    koreacentral = "krc"
    koreasouth   = "krs"
    eastus       = "eus"
    eastus2      = "eus2"
    westeurope   = "weu"
  }
  region_short = lookup(local.region_abbreviations, var.location, "reg")

  # WAF 운영 우수성: 모든 리소스에 일관된 태그 부여
  common_tags = merge({
    workload    = var.workload
    environment = var.environment
    owner       = var.owner
    costCenter  = var.cost_center
    managedBy   = "terraform"
  }, var.extra_tags)

  # CAF 명명: rg-<workload>-<purpose>-<env>-<region>-<instance>
  rg_suffix = "${var.environment}-${local.region_short}-${random_integer.suffix.result}"
}

# --- WAF/CAF: 수명주기·소유권별로 리소스 그룹 분리 ---
# 리소스 정의는 도메인별 파일에 분리되어 있습니다:
#   network.tf    - VNet/Subnet 및 네트워크 역할 할당
#   aks.tf        - ACR, AKS 클러스터, NAP, ACR 역할 할당
#   monitoring.tf - Log Analytics/AMW/Grafana, Prometheus 파이프라인, 모니터링 역할 할당

# (1) 네트워크 RG: VNet/Subnet 등 장수명·플랫폼 소유 리소스
resource "azurerm_resource_group" "network" {
  name     = "rg-${var.workload}-network-${local.rg_suffix}"
  location = var.location
  tags     = merge(local.common_tags, { layer = "network" })
}

# (2) 워크로드 RG: AKS 클러스터, ACR 등 애플리케이션 런타임
resource "azurerm_resource_group" "workload" {
  name     = "rg-${var.workload}-aks-${local.rg_suffix}"
  location = var.location
  tags     = merge(local.common_tags, { layer = "workload" })
}

# (3) 모니터링 RG: Log Analytics, AMW, Grafana 등 관측 스택
resource "azurerm_resource_group" "monitoring" {
  name     = "rg-${var.workload}-monitoring-${local.rg_suffix}"
  location = var.location
  tags     = merge(local.common_tags, { layer = "monitoring" })
}
