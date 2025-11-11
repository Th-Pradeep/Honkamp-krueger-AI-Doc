# Event Grid Configuration for Azure Functions Flex Consumption Plan

## Overview

This document explains the Event Grid configuration required for blob triggers to work properly with Azure Functions Flex Consumption plan in this AI Document Processor accelerator.

## Why Event Grid is Required

Azure Functions Flex Consumption plan **requires Event Grid** for blob triggers instead of the traditional polling mechanism used by other hosting plans (Consumption/Premium). This provides:

- **Better Performance**: Near real-time event delivery instead of polling intervals
- **Lower Costs**: No continuous polling overhead
- **Scalability**: Event Grid handles high-volume scenarios efficiently
- **Reliability**: Built-in retry policies and dead-lettering

## Architecture

```
Storage Account (bronze container)
    ↓ (Blob Created Event)
Event Grid System Topic
    ↓ (Event Subscription)
Function App: start_orchestrator_on_blob
    ↓
Durable Functions Orchestrator
```

## Components Deployed

### 1. Event Grid System Topic
**File**: `infra/modules/storage/eventgrid-system-topic.bicep`

Creates a system topic that monitors the storage account for blob events.

**Key Properties**:
- **Source**: The storage account resource ID
- **Topic Type**: `Microsoft.Storage.StorageAccounts`
- **Location**: Must match the storage account location

### 2. Event Grid Subscription
**File**: `infra/modules/storage/eventgrid-subscription.bicep`

Subscribes the function app to receive blob events from the system topic.

**Key Properties**:
- **Destination**: Azure Function endpoint (`start_orchestrator_on_blob`)
- **Container Filter**: Only triggers for `bronze` container
- **Event Types**: `Microsoft.Storage.BlobCreated`
- **Retry Policy**: 30 max attempts, 1440 minute TTL

### 3. Infrastructure Deployment
**File**: `infra/main.bicep` (lines ~972-1001)

Deploys both Event Grid resources and connects them:

```bicep
module storageEventGridTopic './modules/storage/eventgrid-system-topic.bicep' = {
  scope: resourceGroup
  name: 'storage-eventgrid-topic'
  params: {
    name: '${storageAccountName}-topic'
    location: location
    tags: tags
    storageAccountId: storage.outputs.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

module storageEventGridSubscription './modules/storage/eventgrid-subscription.bicep' = {
  scope: resourceGroup
  name: 'storage-eventgrid-subscription'
  params: {
    name: 'bronze-blob-events'
    systemTopicName: storageEventGridTopic.outputs.name
    functionAppId: processingFunctionApp.outputs.id
    functionName: 'start_orchestrator_on_blob'
    containerFilters: ['bronze']
    includedEventTypes: ['Microsoft.Storage.BlobCreated']
    eventDeliverySchema: 'EventGridSchema'
  }
}
```

### 4. Function App Configuration
**File**: `pipeline/function_app.py` (lines ~23-30)

The function uses an Event Grid trigger instead of a blob trigger:

```python
@app.function_name(name="start_orchestrator_on_blob")
@app.event_grid_trigger(arg_name="event")  # Event Grid trigger, not blob trigger
@app.durable_client_input(client_name="client")
async def start_orchestrator_blob(
    event: func.EventGridEvent,
    client: df.DurableOrchestrationClient,
):
    # Parse blob information from Event Grid event
    event_data = event.get_json()
    blob_url = event_data.get('url')
    blob_subject = event.subject
```

**Key Point**: For Flex Consumption plan with Event Grid, you must use `@app.event_grid_trigger` instead of `@app.blob_trigger`. The blob information is parsed from the Event Grid event payload.

## Deployment Steps

### 1. Deploy Infrastructure

```powershell
# Deploy all infrastructure including Event Grid
azd up
```

Or deploy infrastructure only:

```powershell
azd provision
```

### 2. Verify Event Grid System Topic

```powershell
# Check if system topic was created
az eventgrid system-topic list --resource-group <your-resource-group>
```

### 3. Verify Event Grid Subscription

```powershell
# List subscriptions for the system topic
az eventgrid system-topic event-subscription list \
  --resource-group <your-resource-group> \
  --system-topic-name <storage-account-name>-topic
```

### 4. Deploy Function App

```powershell
# Deploy the function app code
azd deploy
```

## Testing

### 1. Upload a File to Bronze Container

```powershell
# Using Azure CLI
az storage blob upload \
  --account-name <storage-account-name> \
  --container-name bronze \
  --name test-document.pdf \
  --file ./test-document.pdf \
  --auth-mode login
```

### 2. Monitor Event Grid Delivery

```powershell
# Check event delivery metrics
az monitor metrics list \
  --resource <system-topic-resource-id> \
  --metric "PublishSuccessCount,DeliverySuccessCount"
```

### 3. Check Function Execution

```powershell
# View function logs
az monitor app-insights query \
  --app <app-insights-name> \
  --analytics-query "traces | where message contains 'start_orchestrator_blob' | order by timestamp desc"
```

Or view in Azure Portal:
1. Navigate to your Function App
2. Go to Functions → `start_orchestrator_on_blob` → Monitor
3. Check for invocation logs

## Troubleshooting

### Blob Trigger Not Firing

**Symptom**: Files uploaded to bronze container don't trigger the function

**Solutions**:

1. **Verify Event Grid Subscription Status**
   ```powershell
   az eventgrid system-topic event-subscription show \
     --resource-group <rg-name> \
     --system-topic-name <topic-name> \
     --name bronze-blob-events
   ```
   
   Check: `provisioningState` should be "Succeeded"

2. **Check Function App Settings**
   - Ensure `AzureWebJobsStorage` or `DataStorage` connection string is properly configured
   - For managed identity: verify storage account permissions

3. **Verify Event Grid System Topic**
   ```powershell
   az eventgrid system-topic show \
     --resource-group <rg-name> \
     --name <topic-name>
   ```

4. **Test Event Grid Endpoint**
   - In Azure Portal, go to Event Grid System Topic
   - Check "Metrics" blade for delivery attempts
   - Look for "Delivery Failed Events" or "Dead Lettered Events"

### Function Returns 401/403 Errors

**Symptom**: Event Grid shows delivery failures with authorization errors

**Solutions**:

1. **Grant Event Grid Permissions**
   ```powershell
   # Assign EventGrid Data Sender role to system topic
   az role assignment create \
     --assignee <system-topic-principal-id> \
     --role "EventGrid Data Sender" \
     --scope <function-app-resource-id>
   ```

2. **Check Function Auth Level**
   - Ensure the function auth level is `ANONYMOUS` or properly configured for Event Grid
   - In `function_app.py`: `http_auth_level=func.AuthLevel.ANONYMOUS`

### Events Not Reaching Bronze Container

**Symptom**: Event Grid receives events but function doesn't process bronze container files

**Solutions**:

1. **Verify Container Filter**
   - Check subscription filter in `infra/modules/storage/eventgrid-subscription.bicep`
   - Ensure `containerFilters: ['bronze']` is correctly set

2. **Check Subject Filter**
   - Event Grid subject should match: `/blobServices/default/containers/bronze/blobs/<filename>`

## Configuration Options

### Customize Container Filters

To monitor multiple containers, update `main.bicep`:

```bicep
module storageEventGridSubscription './modules/storage/eventgrid-subscription.bicep' = {
  params: {
    containerFilters: ['bronze', 'silver', 'gold'] // Multiple containers
    // ... other params
  }
}
```

### Add File Type Filters

To filter by file extension, update the subscription:

```bicep
params: {
  subjectEndsWith: '.pdf' // Only PDF files
  // or
  subjectEndsWith: '.docx' // Only DOCX files
}
```

### Adjust Retry Policy

Modify retry settings in the subscription module call:

```bicep
params: {
  maxDeliveryAttempts: 10 // Default: 30
  eventTimeToLiveInMinutes: 60 // Default: 1440 (24 hours)
}
```

## Event Grid vs Polling Comparison

| Feature | Event Grid (Flex Consumption) | Polling (Other Plans) |
|---------|------------------------------|----------------------|
| Trigger Latency | Near real-time (~seconds) | 5-60 seconds (configurable) |
| Cost | Pay per event delivery | Continuous polling overhead |
| Scalability | Native event-driven scaling | Limited by polling frequency |
| Reliability | Built-in retries & DLQ | Manual retry logic needed |
| Setup Complexity | Requires Event Grid resources | Automatic, no extra setup |

## Additional Resources

- [Azure Functions Flex Consumption Plan](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)
- [Event Grid Blob Storage Events](https://learn.microsoft.com/azure/event-grid/event-schema-blob-storage)
- [Azure Functions Blob Trigger with Event Grid](https://learn.microsoft.com/azure/azure-functions/functions-event-grid-blob-trigger)
- [Event Grid System Topics](https://learn.microsoft.com/azure/event-grid/system-topics)

## Support

For issues specific to this accelerator, please file an issue in the repository.

For Azure Functions or Event Grid issues, refer to Microsoft documentation or Azure Support.
