param name string
param location string = resourceGroup().location

@description('Tags.')
param tags object

// Classic Consumption plan (Dynamic)
resource hostingPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: name
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  tags: tags
}

output id string = hostingPlan.id
output name string = hostingPlan.name
output location string = hostingPlan.location
output skuName string = hostingPlan.sku.name
