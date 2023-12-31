# Kong plugin: send Kong Gateway log data to Azure Log Analytics 
This plugin sends Kong Gateway log data directly to Azure Log Analytics  with the [Azure HTTP Data Collector REST API](https://learn.microsoft.com/en-us/rest/api/loganalytics/create-request).

It's based on the [http-log](https://docs.konghq.com/hub/kong-inc/http-log/) plugin capacity.

The [http-log](https://docs.konghq.com/hub/kong-inc/http-log/) plugin and this plugin can be configured simultaneously and work together.

## How to create an Azure Log Analytics Workspace
1) Sign in to Azure Portal, [here](https://portal.azure.com/)
2) Look for **Log Analytics workspaces** on Azure services
3) Create a new Log Analytics workspace called for instance `kong-log-analytics-ws`
4) Once the WS is created, click on `Agents` menu on the left, expand `Log Analytics agent instructions` in the middle and copy/paste the values of the `Workspace ID` and `Primary key`

![Alt text](/images/1-Azure-Log-Analytics-Workspace.png "Log Analytics Workspace")

## How to deploy the `azure-log-analytics` plugin
1) Log in to Kong Enterprise or Konnect
2) Open the plugins page
3) Add the `azure-log-analytics` plugin at the Global / Service / Route level
4) Configure at least these properties:
    - `Azure Http Endpoint`: replace <AZURE_WORKSPACE_ID> with the `Workspace ID` value copied on previous steps. The result looks like: https://57a1fb14-70ce-49c3-9d28-5e3dc3459f6f.ods.opinsights.azure.com
    - `Azure Primary Key`: put the `Primary key` value copied on previous steps
    - `Azure Log Type`: feel free changing the value. It's the table name in the Analytics Workspace and the default value is `kong_DP_CL` (for Kong Data Plane Custom Log)
5) Click on Save
6) Apply load on the Kong Gateway (i.e. request some APIs via the Kong Gateway route)

**Azure can take a long time creating the 1st log in the Analytics Workspace.** It took 10 minutes on my side. After the 1st creation log, other logs appear almost in real time.

## How to access to Kong Gateway logs in the Log Analytics Workspace
1) Open the `kong-log-analytics-ws` Azure Analytics Workspace
2) Click on `Logs` menu on the left
3) Close the popup `Queries` window
4) Access to the Query window and type:
```sql
kong_DP_CL
| order by TimeGenerated
```
5) Click on `Run`. 
Example of logs sent by Kong:
![Alt text](/images/2-Azure-Log-Analytics-run-query.png "Query on kong_DP_CL")
Kong log detail below. For instance, we easily retrieve the Consumer's request via Kong GW (`request_url_s`) or Consumer's IP address (`client_ip_s`).
The documentation of all Kong log properties is [here](https://docs.konghq.com/hub/kong-inc/http-log/#json-object-considerations).
![Alt text](/images/3-Azure-Log-Analytics-run-query.png "Query on kong_DP_CL")
As explained by Microsoft, Azure Monitor appends suffix depending on the property data type:
    - `_s` for String
    - `_d` for Double
    - etc.

[See Azure documentation](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api?tabs=powershell#record-type-and-properties)

## Data privacy
You can configure the plugin to avoid sending private data, private key, etc.
Let's consider a Consumer calling an API via Kong with an `apikey` HTTP header.
1) Open the plugins page on Kong Enterprise or Konnect
2) Edit the `azure-log-analytics` plugin
3) Set a new property in `Custom Fields By Lua` with value `request.headers.apikey`
4) Click on `+ Add config.custom_fiels_by_lua` and set the following value:
```Lua
return "***blocked by Kong logging plugin***"
```
See the expected configuration:
![Alt text](/images/4-dataPrivacy-azure-log-analytics-plugin.png "Data privacy configuration")

5) Click on Save
6) Apply load on the Kong Gateway by passing an `apikey` HTTP header
7) Go on Azure page, execute the Query and see the column `request.headers.apikey_s`
![Alt text](/images/5-dataPrivacy-azure-log-analytics-result.png "Data privacy result")

## Advanced configuration of `azure-log-analytics` plugin
For other properties like retry, timeout, batch size, ... see [http-log](https://docs.konghq.com/hub/kong-inc/http-log/configuration/) plugin configuration