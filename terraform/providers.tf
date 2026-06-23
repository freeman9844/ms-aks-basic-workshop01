terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    # 배포 마지막 단계의 `az aks update --enable-azure-monitor-metrics`가 만드는
    # Managed Prometheus 파이프라인(MSProm DCE/DCR + 레코딩 룰)은 Terraform state 밖에서
    # 워크로드 RG에 생성됩니다. destroy 시 이 잔여 자원이 남아 RG 삭제를 막지 않도록,
    # 아래 플래그로 RG 내 잔여 리소스까지 함께 정리하도록 허용합니다(모듈 09 참고).
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
