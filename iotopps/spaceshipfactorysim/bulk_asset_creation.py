"""
Bulk Asset Creation for Spaceship Factory Simulation
Creates Azure IoT Operations assets and data points via Azure CLI automation.
"""

import json
import subprocess
import sys
import os
import shutil
from pathlib import Path
from typing import Dict, List, Any, Optional


class AzureIoTOpsAssetManager:
    """Manages bulk creation of Azure IoT Operations assets."""
    
    def __init__(self, resource_group: str, instance_name: str):
        self.resource_group = resource_group
        self.instance_name = instance_name
        self.assets_config = self._load_asset_definitions()
        self.az_path = self._find_azure_cli()
        self.device_name = "spaceship-factory-device"
        self.endpoint_name = "spaceship-factory-endpoint"
    
    def _load_asset_definitions(self) -> Dict[str, Any]:
        """Define asset configurations based on message structure."""
        return {
            "cnc_machines": {
                "asset_type": "cnc_machine",
                "count": 5,
                "description": "CNC Machine for precision part manufacturing",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "cycle_time", "name": "operation_cycle_time", "description": "Time to complete operation (seconds)"},
                    {"source": "quality", "name": "part_quality", "description": "Quality assessment (good/scrap)"},
                    {"source": "part_type", "name": "manufactured_part_type", "description": "Type of part being manufactured"},
                    {"source": "part_id", "name": "part_identifier", "description": "Unique part identifier"},
                    {"source": "station_id", "name": "station_location", "description": "Manufacturing station ID"}
                ],
                "dataset": {
                    "name": "cnc_telemetry",
                    "topic": "azure-iot-operations/data/cnc-machines",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            },
            "3d_printers": {
                "asset_type": "printer_3d",
                "count": 8,
                "description": "3D Printer for additive manufacturing",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "progress", "name": "print_progress", "description": "Print completion percentage (0-1)"},
                    {"source": "quality", "name": "part_quality", "description": "Quality assessment (good/scrap)"},
                    {"source": "part_type", "name": "printed_part_type", "description": "Type of part being printed"},
                    {"source": "part_id", "name": "part_identifier", "description": "Unique part identifier"},
                    {"source": "station_id", "name": "station_location", "description": "Manufacturing station ID"}
                ],
                "dataset": {
                    "name": "3dprinter_telemetry",
                    "topic": "azure-iot-operations/data/3d-printers",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            },
            "welding_stations": {
                "asset_type": "welding",
                "count": 4,
                "description": "Welding Station for assembly operations",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "last_cycle_time", "name": "weld_cycle_time", "description": "Last welding cycle time (seconds)"},
                    {"source": "quality", "name": "weld_quality", "description": "Weld quality assessment"},
                    {"source": "assembly_type", "name": "assembly_type", "description": "Type of assembly being welded"},
                    {"source": "assembly_id", "name": "assembly_identifier", "description": "Unique assembly identifier"},
                    {"source": "station_id", "name": "station_location", "description": "Welding station ID"}
                ],
                "dataset": {
                    "name": "welding_telemetry",
                    "topic": "azure-iot-operations/data/welding-stations",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            },
            "painting_booths": {
                "asset_type": "painting",
                "count": 3,
                "description": "Painting Booth for surface finishing",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "cycle_time", "name": "paint_cycle_time", "description": "Painting cycle time (seconds)"},
                    {"source": "quality", "name": "paint_quality", "description": "Paint quality assessment"},
                    {"source": "color", "name": "paint_color", "description": "Paint color hex code"},
                    {"source": "part_id", "name": "part_identifier", "description": "Unique part identifier"},
                    {"source": "station_id", "name": "station_location", "description": "Painting booth ID"}
                ],
                "dataset": {
                    "name": "painting_telemetry",
                    "topic": "azure-iot-operations/data/painting-booths",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            },
            "testing_rigs": {
                "asset_type": "testing",
                "count": 2,
                "description": "Testing Rig for quality assurance",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier", "description": "Unique machine ID"},
                    {"source": "status", "name": "machine_status", "description": "Current operational status"},
                    {"source": "test_result", "name": "test_result", "description": "Test outcome (pass/fail)"},
                    {"source": "issues_found", "name": "defect_count", "description": "Number of issues found"},
                    {"source": "target_type", "name": "test_target_type", "description": "Type of item being tested"},
                    {"source": "target_id", "name": "target_identifier", "description": "Unique target identifier"},
                    {"source": "station_id", "name": "station_location", "description": "Testing station ID"}
                ],
                "dataset": {
                    "name": "testing_telemetry",
                    "topic": "azure-iot-operations/data/testing-rigs",
                    "sampling_interval": 1000,
                    "queue_size": 1
                }
            }
        }
    
    def _find_azure_cli(self) -> Optional[str]:
        """Find Azure CLI executable path."""
        # Try common locations for Azure CLI
        possible_paths = [
            r"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",  # Most common location
            "az.cmd",  # If it's in PATH
            "az",  # If it's in PATH
            r"C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
            os.path.expanduser(r"~\AppData\Local\Programs\Microsoft\Azure CLI\Scripts\az.cmd"),
            r"C:\Program Files\Azure CLI\Scripts\az.cmd",
        ]
        
        for path in possible_paths:
            # Use shutil.which for PATH lookup
            if path in ["az", "az.cmd"]:
                found_path = shutil.which(path)
                if found_path:
                    return found_path
            # Check if file exists for absolute paths
            elif os.path.isfile(path):
                return path
        
        return None
    
    def _run_az_command(self, command: List[str]) -> Dict[str, Any]:
        """Execute Azure CLI command and return JSON result."""
        try:
            if not self.az_path:
                return {"error": "Azure CLI not found"}
            
            # Replace 'az' with the full path
            az_command = [self.az_path] + command[1:]
            
            result = subprocess.run(
                az_command,
                capture_output=True,
                text=True,
                check=True
            )
            
            if result.stdout.strip():
                return json.loads(result.stdout)
            return {"success": True}
            
        except FileNotFoundError:
            return {"error": "Azure CLI (az) not found in PATH. Please install Azure CLI."}
        except subprocess.CalledProcessError as e:
            print(f"❌ Command failed: {' '.join(az_command)}")
            print(f"Error: {e.stderr}")
            return {"error": e.stderr}
        except json.JSONDecodeError as e:
            print(f"❌ JSON decode error: {e}")
            print(f"Output: {result.stdout}")
            return {"error": f"JSON decode error: {e}"}
    
    def _check_az_cli(self) -> bool:
        """Check if Azure CLI is available."""
        if not self.az_path:
            return False
            
        try:
            result = subprocess.run(
                [self.az_path, "--version"],
                capture_output=True,
                text=True,
                check=True
            )
            return True
        except (FileNotFoundError, subprocess.CalledProcessError):
            return False
    
    def _check_and_create_device_endpoint(self) -> bool:
        """Check if device and endpoint exist, create them if they don't."""
        print("\n🔍 Checking device and endpoint requirements...")
        
        # Try to create device (will fail if it already exists, which is fine)
        print(f"📱 Creating device: {self.device_name}")
        create_device_cmd = [
            "az", "iot", "ops", "ns", "device", "create",
            "--name", self.device_name,
            "--instance", self.instance_name,
            "--resource-group", self.resource_group
        ]
        
        result = self._run_az_command(create_device_cmd)
        if "error" in result:
            if "already exists" in result["error"] or "Conflict" in result["error"]:
                print(f"✅ Device already exists: {self.device_name}")
            else:
                print(f"❌ Failed to create device: {result['error']}")
                return False
        else:
            print(f"✅ Created device: {self.device_name}")
        
        # Try to create custom endpoint (will fail if it already exists, which is fine)
        print(f"🔌 Creating custom endpoint: {self.endpoint_name}")
        create_endpoint_cmd = [
            "az", "iot", "ops", "ns", "device", "endpoint", "inbound", "add", "custom",
            "--name", self.endpoint_name,
            "--device", self.device_name,
            "--instance", self.instance_name,
            "--resource-group", self.resource_group,
            "--endpoint-type", "Microsoft.Custom",
            "--address", "mqtt://localhost:1883"  # Default MQTT address
        ]
        
        result = self._run_az_command(create_endpoint_cmd)
        if "error" in result:
            if "already exists" in result["error"] or "Conflict" in result["error"]:
                print(f"✅ Endpoint already exists: {self.endpoint_name}")
            else:
                print(f"❌ Failed to create endpoint: {result['error']}")
                return False
        else:
            print(f"✅ Created endpoint: {self.endpoint_name}")
        
        return True
    
    def create_custom_asset(self, asset_name: str, asset_config: Dict[str, Any]) -> bool:
        """Create a custom MQTT asset with datasets and data points."""
        print(f"\n🏭 Creating asset: {asset_name}")
        
        # Create the custom asset
        create_asset_cmd = [
            "az", "iot", "ops", "ns", "asset", "custom", "create",
            "--name", asset_name,
            "--instance", self.instance_name,
            "--resource-group", self.resource_group,
            "--device", self.device_name,
            "--endpoint", self.endpoint_name,
            "--description", asset_config["description"]
        ]
        
        result = self._run_az_command(create_asset_cmd)
        if "error" in result:
            if "already exists" in result["error"] or "Conflict" in result["error"]:
                print(f"  ✅ Asset already exists: {asset_name}")
            else:
                print(f"  ❌ Failed to create asset: {asset_name}")
                return False
        else:
            print(f"  ✅ Asset created: {asset_name}")
        
        # Create dataset (without destination first)
        dataset_config = asset_config["dataset"]
        create_dataset_cmd = [
            "az", "iot", "ops", "ns", "asset", "custom", "dataset", "add",
            "--asset", asset_name,
            "--name", dataset_config["name"],
            "--instance", self.instance_name,
            "--resource-group", self.resource_group,
            "--data-source", "mqtt"  # For MQTT-based assets
        ]
        
        result = self._run_az_command(create_dataset_cmd)
        if "error" in result:
            if "already exists" in result["error"] or "Conflict" in result["error"]:
                print(f"  ✅ Dataset already exists: {dataset_config['name']}")
            else:
                print(f"  ❌ Failed to create dataset: {dataset_config['name']}")
                print(f"❌ Failed to create asset: {asset_name}")
                return False
        else:
            print(f"  ✅ Created dataset: {dataset_config['name']}")
        
        # Update dataset with MQTT destination
        update_dataset_cmd = [
            "az", "iot", "ops", "ns", "asset", "custom", "dataset", "update",
            "--asset", asset_name,
            "--name", dataset_config["name"],
            "--instance", self.instance_name,
            "--resource-group", self.resource_group,
            "--destination", f"topic=\"{dataset_config['topic']}\" retain=Never qos=Qos1 ttl=3600"
        ]
        
        result = self._run_az_command(update_dataset_cmd)
        if "error" in result:
            print(f"  ❌ Failed to update dataset destination: {dataset_config['name']}")
            print(f"❌ Failed to create asset: {asset_name}")
            return False
        else:
            print(f"  ✅ Updated dataset destination: {dataset_config['name']}")
        
        # Add data points
        for data_point in asset_config["data_points"]:
            add_datapoint_cmd = [
                "az", "iot", "ops", "ns", "asset", "custom", "datapoint", "add",
                "--asset", asset_name,
                "--dataset", dataset_config["name"],
                "--name", data_point["name"],
                "--data-source", data_point["source"],
                "--instance", self.instance_name,
                "--resource-group", self.resource_group
            ]
            
            result = self._run_az_command(add_datapoint_cmd)
            if "error" in result:
                if "already exists" in result["error"] or "Conflict" in result["error"]:
                    print(f"  ✅ Data point already exists: {data_point['name']}")
                else:
                    print(f"❌ Failed to add data point: {data_point['name']}")
                    continue
            else:
                print(f"  ✅ Added data point: {data_point['name']} -> {data_point['source']}")
        
        print(f"✅ Successfully created asset: {asset_name}")
        return True
    
    def create_all_assets(self):
        """Create all spaceship factory assets."""
        print("🚀 Starting Spaceship Factory Asset Creation...")
        print(f"Resource Group: {self.resource_group}")
        print(f"IoT Operations Instance: {self.instance_name}")
        
        # Check and create device/endpoint first
        if not self._check_and_create_device_endpoint():
            print("❌ Failed to set up device and endpoint. Cannot continue.")
            return
        
        success_count = 0
        total_count = 0
        
        for asset_group, config in self.assets_config.items():
            asset_type = config["asset_type"]
            count = config["count"]
            
            for i in range(1, count + 1):
                total_count += 1
                # Fix asset name to comply with Azure pattern: ^[a-z0-9][a-z0-9-]*[a-z0-9]$
                asset_name = f"spaceship-factory-{asset_type.replace('_', '-')}-{i:02d}"
                
                if self.create_custom_asset(asset_name, config):
                    success_count += 1
                else:
                    print(f"❌ Failed to create asset: {asset_name}")
        
        print(f"\n📊 Asset Creation Summary:")
        print(f"  ✅ Successfully created: {success_count}/{total_count} assets")
        print(f"  ❌ Failed: {total_count - success_count} assets")
        
        if success_count == total_count:
            print("\n🎉 All assets created successfully!")
            self._print_next_steps()
        else:
            print(f"\n⚠️  Some assets failed to create. Check the errors above.")
    
    def _print_next_steps(self):
        """Print next steps for the user."""
        print("\n📋 Next Steps:")
        print("1. ✅ Device and endpoint created/verified")
        print("2. ✅ Assets and data points created")
        print("3. 🔄 Update your simulator to publish to AIO topics:")
        
        for asset_group, config in self.assets_config.items():
            topic = config["dataset"]["topic"]
            print(f"   - {asset_group}: {topic}")
        
        print("4. 🔍 Verify data flow in Azure IoT Operations portal")
        print("5. 📊 Set up data flows to route data to cloud services")
        print(f"\nCreated device: {self.device_name}")
        print(f"Created endpoint: {self.endpoint_name}")

    def generate_asset_summary(self) -> str:
        """Generate a summary of assets to be created."""
        summary = []
        total_assets = 0
        total_data_points = 0
        
        for asset_group, config in self.assets_config.items():
            count = config["count"]
            data_point_count = len(config["data_points"])
            
            total_assets += count
            total_data_points += count * data_point_count
            
            summary.append(f"  📱 {asset_group.replace('_', ' ').title()}: {count} assets × {data_point_count} data points = {count * data_point_count} total data points")
        
        result = "🏭 Spaceship Factory Asset Configuration:\n"
        result += "\n".join(summary)
        result += f"\n\n📊 Total: {total_assets} assets, {total_data_points} data points"
        
        return result


def main():
    """Main function to run asset creation."""
    if len(sys.argv) != 3:
        print("Usage: python bulk_asset_creation.py <resource_group> <iot_operations_instance>")
        print("Example: python bulk_asset_creation.py my-rg my-aio-instance")
        sys.exit(1)
    
    resource_group = sys.argv[1]
    instance_name = sys.argv[2]
    
    # Create asset manager
    manager = AzureIoTOpsAssetManager(resource_group, instance_name)
    
    # Check if Azure CLI is available
    if not manager.az_path:
        print("❌ Azure CLI not found!")
        print(f"\nSearched in common locations:")
        print("- System PATH")
        print("- C:\\Program Files (x86)\\Microsoft SDKs\\Azure\\CLI2\\wbin\\")
        print("- C:\\Program Files\\Microsoft SDKs\\Azure\\CLI2\\wbin\\")
        print("- %USERPROFILE%\\AppData\\Local\\Programs\\Microsoft\\Azure CLI\\Scripts\\")
        print("- C:\\Program Files\\Azure CLI\\Scripts\\")
        print("\nPlease ensure Azure CLI is properly installed and accessible.")
        print("You can test by running 'az --version' in a new terminal.")
        print("\nAlternatives:")
        print("1. Use generate_cli_commands.py to get manual commands")
        print("2. Create assets manually in Azure portal")
        sys.exit(1)
    
    print(f"✅ Found Azure CLI at: {manager.az_path}")
    
    if not manager._check_az_cli():
        print("❌ Azure CLI found but not working properly!")
        sys.exit(1)
    
    # Show summary first
    print(manager.generate_asset_summary())
    
    # Ask for confirmation
    response = input("\n❓ Do you want to create these assets? (y/N): ")
    if response.lower() != 'y':
        print("❌ Asset creation cancelled.")
        sys.exit(0)
    
    # Create all assets
    manager.create_all_assets()


if __name__ == "__main__":
    main()