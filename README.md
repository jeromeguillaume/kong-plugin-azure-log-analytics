# Kong plugin: send logs to Azure Log Analytics Workspace (as the `http-log` plugin)

## How create an Azure Log Analytics Workspace
1) Sign in to Azure Portal, [here](https://portal.azure.com/)
2) Look for **Log Analytics workspaces** on Azure services
3) Create a new Log Analytics workspace called for instance `kong-log-analytics-ws`
4) Once the WS is created, click on `Agents` menu on the left, collapse `Log Analytics agent instructions` in the middle and copy/paste the values of the `Workspace ID` and `Primary key`

![Alt text](/images/1-Azure-Log-Analytics-Workspace.png "Log Analytics Workspace")

## How deploy the `azure-log-analytics`
1) Log in to Kong Enterprise or Konnect
2) Open the plugins page
3) Add the `azure-log-analytics` plugin at the Global / Service / Route level
4) Configure at least these properties:
`Azure Http Endpoint`
https://<AZURE_WORKSPACE_ID>.ods.opinsights.azure.com
`Azure Workspace Id`
`Azure Primary Key`
Feel free changing `Azure Log Type`: it's the table name in the Analytics Workspace and the default value is `kong_DP_CL` (Kong Data Plane Custom Log)
5) Click on Save
6) Apply load on the Kong Gateway (i.e. request APIs via the Kong GW route)

**Azure can take a long time creating the 1st log in the Analytics Workspace.** It took 10 minutes on my side. After the 1st creation log, other logs appear in real time.

## How access to Kong Gateway logs in `kong-log-analytics-ws`
1) Open the `kong-log-analytics-ws` Azure Analytics Workspace
2) Click on `Logs` menu on the left
3) Close the popup `Queries` window
4) Access to the Query window and type:
```sql
kong_DP_CL
| order by TimeGenerated
```
5) Click on `Run`
Example of logs sent by Kong
![Alt text](/images/2-Azure-Log-Analytics-run-query.png "Query on kong_DP_CL")
Kong log detail and the complete list of properties is [here](https://docs.konghq.com/hub/kong-inc/http-log/#json-object-considerations):
![Alt text](/images/3-Azure-Log-Analytics-run-query.png "Query on kong_DP_CL")
As explained by Microsoft, Azure Monitor appends suffix depending on the property data type:
    - `_s` for String
    - `_d` for Double
    - etc.
[See Azure documentation](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api?tabs=powershell#record-type-and-properties)