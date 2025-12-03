"""
Azure IoT Operations REST API Asset Manager
Alternative approach using Azure REST APIs for bulk asset creation.
"""

import requests
import json
from typing import Dict, List, Any
from azure.identity import DefaultAzureCredential
from azure.core.credentials import AccessToken


class AzureIoTOpsRESTManager:
    """Manages assets via Azure REST API."""
    
    def __init__(self, subscription_id: str, resource_group: str, instance_name: str):
        self.subscription_id = subscription_id
        self.resource_group = resource_group
        self.instance_name = instance_name
        self.credential = DefaultAzureCredential()
        self.base_url = f"https://management.azure.com/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        
    def _get_access_token(self) -> str:
        """Get Azure access token."""
        token_info: AccessToken = self.credential.get_token("https://management.azure.com/.default")
        return token_info.token
    
    def _make_request(self, method: str, url: str, data: Dict = None) -> Dict:
        """Make authenticated REST API request."""
        headers = {
            'Authorization': f'Bearer {self._get_access_token()}',
            'Content-Type': 'application/json',
            'Accept': 'application/json'
        }
        
        try:
            if method.upper() == 'GET':
                response = requests.get(url, headers=headers)
            elif method.upper() == 'POST':
                response = requests.post(url, headers=headers, json=data)
            elif method.upper() == 'PUT':
                response = requests.put(url, headers=headers, json=data)
            
            response.raise_for_status()
            return response.json() if response.content else {"success": True}
            
        except requests.RequestException as e:
            print(f"❌ REST API Error: {e}")
            return {"error": str(e)}
    
    def create_asset_via_rest(self, asset_name: str, asset_config: Dict) -> bool:
        """Create asset using REST API."""
        asset_url = f"{self.base_url}/providers/Microsoft.DeviceRegistry/assets/{asset_name}?api-version=2024-11-01"
        
        asset_payload = {
            "location": "eastus",  # Adjust as needed
            "properties": {
                "displayName": asset_name,
                "description": asset_config["description"],
                "assetType": asset_config["asset_type"],
                "enabled": True,
                "dataPoints": [
                    {
                        "name": dp["name"],
                        "dataSource": dp["source"],
                        "observabilityMode": "none"
                    }
                    for dp in asset_config["data_points"]
                ],
                "defaultTopic": {
                    "path": asset_config["dataset"]["topic"],
                    "retain": "Never"
                }
            }
        }
        
        result = self._make_request("PUT", asset_url, asset_payload)
        return "error" not in result


# Example usage:
def create_assets_via_rest():
    """Example of using REST API approach."""
    manager = AzureIoTOpsRESTManager(
        subscription_id="your-subscription-id",
        resource_group="your-resource-group",
        instance_name="your-instance"
    )
    
    # This would use the same asset configurations as the CLI approach
    # but create them via REST API calls instead