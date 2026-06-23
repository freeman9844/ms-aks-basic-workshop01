output "resource_group_name" {
  description = "AKS/ACR가 위치한 워크로드 리소스 그룹"
  value       = azurerm_resource_group.workload.name
}

output "network_resource_group_name" {
  value = azurerm_resource_group.network.name
}

output "monitoring_resource_group_name" {
  value = azurerm_resource_group.monitoring.name
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "azure_monitor_workspace_id" {
  value = azurerm_monitor_workspace.this.id
}

output "grafana_resource_id" {
  value = azurerm_dashboard_grafana.this.id
}

output "grafana_endpoint" {
  value = azurerm_dashboard_grafana.this.endpoint
}

output "get_credentials_command" {
  value = "az aks get-credentials -g ${azurerm_resource_group.workload.name} -n ${azurerm_kubernetes_cluster.this.name} --overwrite-existing"
}
