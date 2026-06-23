variable "prefix" {
  type        = string
  description = "리소스 이름 접두사 (소문자/숫자)"
  default     = "akshol"
}

variable "location" {
  type        = string
  description = "Azure 리전"
  default     = "koreacentral"
}

variable "system_node_vm_size" {
  type        = string
  description = "시스템 노드풀 VM 크기"
  default     = "Standard_D2s_v5"
}

variable "system_node_count" {
  type        = number
  description = "시스템 노드 수"
  default     = 2
}

# --- WAF/CAF: 환경 및 태깅 ---
variable "environment" {
  type        = string
  description = "배포 환경 (dev/test/prod). CAF 명명 규칙 및 태그에 사용"
  default     = "dev"
}

variable "workload" {
  type        = string
  description = "워크로드(애플리케이션) 식별자. CAF 명명 규칙 및 태그에 사용"
  default     = "aksworkshop"
}

variable "owner" {
  type        = string
  description = "리소스 소유자/담당자 (태그)"
  default     = "platform-team"
}

variable "cost_center" {
  type        = string
  description = "비용 센터 (태그)"
  default     = "workshop"
}

variable "extra_tags" {
  type        = map(string)
  description = "추가로 부여할 사용자 정의 태그"
  default     = {}
}

# --- BYO 네트워크: AKS가 사용할 VNet/Subnet ---
variable "vnet_address_space" {
  type        = list(string)
  description = "VNet 주소 공간. 서비스 CIDR(10.0.0.0/16), Pod 오버레이 CIDR(10.244.0.0/16)와 겹치지 않게 설정"
  default     = ["10.224.0.0/16"]
}

variable "aks_subnet_address_prefixes" {
  type        = list(string)
  description = "AKS 노드 서브넷 주소 범위"
  default     = ["10.224.0.0/24"]
}
