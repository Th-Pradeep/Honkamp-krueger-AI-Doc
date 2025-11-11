# Event Grid Setup Summary

## What Was Done

This guide documents the Event Grid configuration added to enable blob triggers for Azure Functions Flex Consumption plan.

## Files Created

### 1. Infrastructure Modules

#### `infra/modules/storage/eventgrid-system-topic.bicep`
- **Purpose**: Reusable Bicep module to create an Event Grid System Topic
- **What it does**: Monitors a storage account for blob events (BlobCreated, BlobDeleted, etc.)
- **Parameters**: 
  - Storage account ID (source of events)
  - Topic name, location, tags
  - Topic type (Microsoft.Storage.StorageAccounts)

#### `infra/modules/storage/eventgrid-subscription.bicep`
- **Purpose**: Reusable Bicep module to create an Event Grid Subscription
- **What it does**: Routes blob events from the System Topic to your Azure Function
- **Parameters**:
  - Function App ID and function name
  - Container filters (which containers to monitor)
  - Event types (BlobCreated, BlobDeleted, etc.)
  - Retry policy settings

### 2. Documentation

#### `docs/eventGridConfiguration.md`
Comprehensive guide covering:
- Why Event Grid is required for Flex Consumption
- Architecture overview
- Deployment steps
- Testing procedures
- Troubleshooting common issues
- Configuration options
- Event Grid vs polling comparison

#### `docs/eventGrid-QuickStart.md`
Quick reference guide with:
- Summary of changes
- Deployment commands
- Verification steps
- Common customizations
- Quick troubleshooting tips

## Files Modified

### 1. `infra/main.bicep`
**Location**: Lines ~972-1001

**Added**:
```bicep
// Event Grid System Topic for Storage Account Blob Events
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

// Event Grid Subscription to connect blob events to Function App
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

**What this does**:
1. Creates Event Grid System Topic that monitors your storage account
2. Creates subscription that sends bronze container events to your function
3. Automatically deployed when you run `azd up` or `azd provision`

### 2. `pipeline/function_app.py`
**Location**: Lines ~23-50

**Changed**:
```python
# Before: Blob trigger (doesn't work with Event Grid subscription)
@app.blob_trigger(
    arg_name="blob",
    path="bronze/{name}",
    connection="DataStorage",
)
async def start_orchestrator_blob(
    blob: func.InputStream,
    client: df.DurableOrchestrationClient,
):

# After: Event Grid trigger (required for Flex Consumption plan)
@app.event_grid_trigger(arg_name="event")
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

**What this does**:
- Changes from blob trigger to Event Grid trigger (required for Event Grid subscriptions)
- Parses blob information from the Event Grid event payload
- Extracts container and blob name from the event subject

### 3. `README.md`
**Added**:
- Common issue #2: Blob trigger not firing on Flex Consumption plan
- Link to Event Grid documentation
- New "Documentation" section with links to Event Grid guides

## How Event Grid Works

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  1. File uploaded to bronze container                          │
│                                                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  2. Storage Account emits BlobCreated event                    │
│                                                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  3. Event Grid System Topic receives event                     │
│                                                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  4. Event Grid Subscription filters event                      │
│     - Container: bronze ✓                                      │
│     - Event type: BlobCreated ✓                                │
│                                                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  5. Event delivered to Function: start_orchestrator_on_blob    │
│                                                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  6. Durable Functions orchestrator processes the document      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Benefits of Event Grid

### Performance
- **Near real-time**: Events delivered within seconds vs. 5-60 second polling intervals
- **No cold starts from polling**: Function only runs when events occur

### Cost
- **No continuous polling**: Don't pay for constant storage API calls
- **Pay per event**: Event Grid charges ~$0.60 per million operations

### Reliability
- **Built-in retries**: Automatic retry up to 30 times (configurable)
- **Dead-letter queue**: Failed events can be captured for inspection
- **Event delivery guarantees**: At-least-once delivery semantics

### Scalability
- **High throughput**: Event Grid can handle millions of events per second
- **No polling overhead**: Doesn't slow down with high file volumes

## Next Steps

### 1. Deploy the Changes
```powershell
azd up
```

### 2. Test the Setup
```powershell
# Upload a test file
az storage blob upload \
  --account-name <storage-account-name> \
  --container-name bronze \
  --name test-document.pdf \
  --file ./test-document.pdf \
  --auth-mode login
```

### 3. Monitor Function Execution
- Azure Portal → Function App → Functions → start_orchestrator_on_blob → Monitor
- Or use Application Insights to query traces

### 4. Verify Event Grid Metrics
- Azure Portal → Event Grid System Topics → <storage-account>-topic → Metrics
- Look for "Publish Success Count" and "Delivery Success Count"

## Customization Examples

### Monitor Multiple Containers
Edit `infra/main.bicep`:
```bicep
containerFilters: ['bronze', 'silver', 'gold']
```

### Filter by File Type
Edit `infra/main.bicep`:
```bicep
subjectEndsWith: '.pdf'  // Only PDFs
```

### Add Multiple Event Types
Edit `infra/main.bicep`:
```bicep
includedEventTypes: [
  'Microsoft.Storage.BlobCreated'
  'Microsoft.Storage.BlobDeleted'
]
```

### Adjust Retry Policy
Edit `infra/main.bicep`:
```bicep
maxDeliveryAttempts: 10
eventTimeToLiveInMinutes: 60
```

## Troubleshooting Quick Checks

If blob trigger doesn't fire:

1. ✅ Event Grid System Topic exists?
   ```powershell
   az eventgrid system-topic list --resource-group <rg>
   ```

2. ✅ Event Grid Subscription provisioned successfully?
   ```powershell
   az eventgrid system-topic event-subscription show \
     --resource-group <rg> \
     --system-topic-name <topic> \
     --name bronze-blob-events
   ```

3. ✅ Function has `source="EventGrid"` parameter?
   Check `pipeline/function_app.py` line 29

4. ✅ Event Grid delivering events?
   Azure Portal → System Topic → Metrics → "Delivery Success Count"

5. ✅ Function receiving invocations?
   Azure Portal → Function App → start_orchestrator_on_blob → Monitor

## Additional Resources

- [Full Event Grid Configuration Guide](./eventGridConfiguration.md)
- [Event Grid Quick Start](./eventGrid-QuickStart.md)
- [Azure Docs: Flex Consumption Plan](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)
- [Azure Docs: Event Grid Blob Events](https://learn.microsoft.com/azure/event-grid/event-schema-blob-storage)
