# Script variables:
$resourceGroupName = "IoT-starter"
$location = "WestUS 2"
# start the interactive login
az login
az account set --subscription $Env:subscription

az group create -l $location -n $resourceGroupName
# az group delete --name $resourceGroupName

# Single turnkey resources from template. 
az deployment group create --resource-group $resourceGroupName --template-file "ARM/template.json" --parameters "ARM/parameters.json"
