# --- BYO 네트워크: AKS 전용 VNet/Subnet (네트워크 RG) ---
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.workload}-${var.environment}-${local.region_short}-${random_integer.suffix.result}"
  resource_group_name = azurerm_resource_group.network.name
  location            = azurerm_resource_group.network.location
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks-${var.environment}"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = var.aks_subnet_address_prefixes
}

# AKS 클러스터 ID -> BYO 서브넷 관리 (LB/네트워크 구성용)
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}
