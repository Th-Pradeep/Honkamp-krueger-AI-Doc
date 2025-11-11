# Event Grid Setup - Quick Reference

## What Changed

For Azure Functions **Flex Consumption plan**, blob triggers require Event Grid. Here's what was added:

### 1. New Bicep Modules
- `infra/modules/storage/eventgrid-system-topic.bicep` - Creates Event Grid system topic for storage events
- `infra/modules/storage/eventgrid-subscription.bicep` - Subscribes function to blob events

### 2. Infrastructure Updates
- `infra/main.bicep` - Added Event Grid deployment after function app deployment (lines ~972-1001)

### 3. Function Code Updates  
- `pipeline/function_app.py` - Added `source="EventGrid"` parameter to blob trigger decorator (line 29)

### 4. Documentation
- `docs/eventGridConfiguration.md` - Complete Event Grid setup and troubleshooting guide

## Deployment

```powershell
# Deploy everything (infrastructure + code)
azd up

# Or deploy separately
azd provision  # Infrastructure only
azd deploy     # Function code only
```

## Verify Setup

After deployment, verify Event Grid is working:

```powershell
# 1. Check Event Grid System Topic
az eventgrid system-topic list --resource-group <your-rg> --output table

# 2. Check Event Grid Subscription
az eventgrid system-topic event-subscription list \
  --resource-group <your-rg> \
  --system-topic-name <storage-account>-topic \
  --output table

# 3. Test by uploading a file
az storage blob upload \
  --account-name <storage-account> \
  --container-name bronze \
  --name test.pdf \
  --file ./test.pdf \
  --auth-mode login
```

## Key Configuration

### In Bicep (`infra/main.bicep`)

```bicep
// Event Grid System Topic
module storageEventGridTopic './modules/storage/eventgrid-system-topic.bicep' = {
  params: {
    storageAccountId: storage.outputs.id
    // ...
  }
}

// Event Grid Subscription
module storageEventGridSubscription './modules/storage/eventgrid-subscription.bicep' = {
  params: {
    systemTopicName: storageEventGridTopic.outputs.name
    functionAppId: processingFunctionApp.outputs.id
    functionName: 'start_orchestrator_on_blob'
    containerFilters: ['bronze']  // ← Only monitor bronze container
    // ...
  }
}
```

### In Python (`pipeline/function_app.py`)

```python
@app.event_grid_trigger(arg_name="event")  # Event Grid trigger for Flex Consumption
@app.durable_client_input(client_name="client")
async def start_orchestrator_blob(
    event: func.EventGridEvent,  # Receives Event Grid events
    client: df.DurableOrchestrationClient,
):
    # Parse blob info from event
    event_data = event.get_json()
    blob_url = event_data.get('url')
```

**Important**: Use `@app.event_grid_trigger` NOT `@app.blob_trigger` for Flex Consumption plan.

## Customization

### Monitor Additional Containers

Edit `infra/main.bicep`:

```bicep
containerFilters: ['bronze', 'silver']  # Add more containers
```

### Filter by File Extension

Edit `infra/main.bicep`:

```bicep
subjectEndsWith: '.pdf'  # Only PDF files
```

### Adjust Retry Policy

Edit `infra/main.bicep`:

```bicep
maxDeliveryAttempts: 10          # Default: 30
eventTimeToLiveInMinutes: 60     # Default: 1440
```

## Troubleshooting

### Function Not Triggering?

1. **Check Event Grid metrics** (Azure Portal → System Topic → Metrics)
   - Look for "Publish Success Count" and "Delivery Success Count"

2. **Verify subscription status**:
   ```powershell
   az eventgrid system-topic event-subscription show \
     --resource-group <rg> \
     --system-topic-name <topic> \
     --name bronze-blob-events
   ```

3. **Check function logs** (Azure Portal → Function App → Monitor)
   - Look for invocations of `start_orchestrator_on_blob`

### Authorization Errors (401/403)?

Ensure the function auth level allows Event Grid:
- In `function_app.py`: `http_auth_level=func.AuthLevel.ANONYMOUS`

### Events Not Filtered Correctly?

Check the subject filter in Event Grid subscription:
- Subject format: `/blobServices/default/containers/<container>/blobs/<filename>`
- Container filter uses `StringContains` on subject

## Resources

- Full Documentation: [docs/eventGridConfiguration.md](./eventGridConfiguration.md)
- Azure Docs: [Blob Trigger with Event Grid](https://learn.microsoft.com/azure/azure-functions/functions-event-grid-blob-trigger)
- Azure Docs: [Flex Consumption Plan](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)
