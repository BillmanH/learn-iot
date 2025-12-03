"""
Azure CLI Command Generator for Spaceship Factory Assets
Generates Azure CLI commands that you can copy and paste to create assets manually.
"""

import json
from typing import Dict, List, Any


class AzureCLICommandGenerator:
    """Generates Azure CLI commands for bulk asset creation."""
    
    def __init__(self, resource_group: str, instance_name: str):
        self.resource_group = resource_group
        self.instance_name = instance_name
        self.assets_config = self._load_asset_definitions()
    
    def _load_asset_definitions(self) -> Dict[str, Any]:
        """Define asset configurations based on message structure."""
        return {
            "cnc_machines": {
                "asset_type": "cnc_machine",
                "count": 5,
                "description": "CNC Machine for precision part manufacturing",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier"},
                    {"source": "status", "name": "machine_status"},
                    {"source": "cycle_time", "name": "operation_cycle_time"},
                    {"source": "quality", "name": "part_quality"},
                    {"source": "part_type", "name": "manufactured_part_type"},
                    {"source": "part_id", "name": "part_identifier"},
                    {"source": "station_id", "name": "station_location"}
                ],
                "dataset": {
                    "name": "cnc_telemetry",
                    "topic": "azure-iot-operations/data/cnc-machines"
                }
            },
            "3d_printers": {
                "asset_type": "printer_3d",
                "count": 8,
                "description": "3D Printer for additive manufacturing",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier"},
                    {"source": "status", "name": "machine_status"},
                    {"source": "progress", "name": "print_progress"},
                    {"source": "quality", "name": "part_quality"},
                    {"source": "part_type", "name": "printed_part_type"},
                    {"source": "part_id", "name": "part_identifier"},
                    {"source": "station_id", "name": "station_location"}
                ],
                "dataset": {
                    "name": "3dprinter_telemetry",
                    "topic": "azure-iot-operations/data/3d-printers"
                }
            },
            "welding_stations": {
                "asset_type": "welding",
                "count": 4,
                "description": "Welding Station for assembly operations",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier"},
                    {"source": "status", "name": "machine_status"},
                    {"source": "last_cycle_time", "name": "weld_cycle_time"},
                    {"source": "quality", "name": "weld_quality"},
                    {"source": "assembly_type", "name": "assembly_type"},
                    {"source": "assembly_id", "name": "assembly_identifier"},
                    {"source": "station_id", "name": "station_location"}
                ],
                "dataset": {
                    "name": "welding_telemetry",
                    "topic": "azure-iot-operations/data/welding-stations"
                }
            },
            "painting_booths": {
                "asset_type": "painting",
                "count": 3,
                "description": "Painting Booth for surface finishing",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier"},
                    {"source": "status", "name": "machine_status"},
                    {"source": "cycle_time", "name": "paint_cycle_time"},
                    {"source": "quality", "name": "paint_quality"},
                    {"source": "color", "name": "paint_color"},
                    {"source": "part_id", "name": "part_identifier"},
                    {"source": "station_id", "name": "station_location"}
                ],
                "dataset": {
                    "name": "painting_telemetry",
                    "topic": "azure-iot-operations/data/painting-booths"
                }
            },
            "testing_rigs": {
                "asset_type": "testing",
                "count": 2,
                "description": "Testing Rig for quality assurance",
                "data_points": [
                    {"source": "machine_id", "name": "machine_identifier"},
                    {"source": "status", "name": "machine_status"},
                    {"source": "test_result", "name": "test_result"},
                    {"source": "issues_found", "name": "defect_count"},
                    {"source": "target_type", "name": "test_target_type"},
                    {"source": "target_id", "name": "target_identifier"},
                    {"source": "station_id", "name": "station_location"}
                ],
                "dataset": {
                    "name": "testing_telemetry",
                    "topic": "azure-iot-operations/data/testing-rigs"
                }
            }
        }
    
    def generate_commands(self) -> str:
        """Generate all Azure CLI commands."""
        commands = []
        commands.append("# Spaceship Factory Asset Creation Commands")
        commands.append("# Copy and paste these commands into your terminal")
        commands.append("# Make sure you're logged in: az login")
        commands.append("")
        
        # Add device and endpoint creation commands
        device_name = "spaceship-factory-device"
        endpoint_name = "spaceship-factory-endpoint"
        
        commands.append("# Step 1: Create Device and Endpoint")
        commands.append("")
        
        device_cmd = f"""az iot ops ns device create \\
  --name {device_name} \\
  --instance {self.instance_name} \\
  --resource-group {self.resource_group}"""
        commands.append(device_cmd)
        commands.append("")
        
        endpoint_cmd = f"""az iot ops ns device endpoint inbound add custom \\
  --name {endpoint_name} \\
  --device {device_name} \\
  --instance {self.instance_name} \\
  --resource-group {self.resource_group} \\
  --endpoint-type Microsoft.Custom \\
  --address mqtt://localhost:1883"""
        commands.append(endpoint_cmd)
        commands.append("")
        commands.append("# Step 2: Create Assets")
        commands.append("")
        
        for asset_group, config in self.assets_config.items():
            asset_type = config["asset_type"]
            count = config["count"]
            
            commands.append(f"# Creating {asset_group.replace('_', ' ').title()}")
            commands.append("")
            
            for i in range(1, count + 1):
                # Fix asset name to comply with Azure pattern: ^[a-z0-9][a-z0-9-]*[a-z0-9]$
                asset_name = f"spaceship-factory-{asset_type.replace('_', '-')}-{i:02d}"
                dataset_name = config["dataset"]["name"]
                topic = config["dataset"]["topic"]
                description = config["description"]
                
                # Create custom asset
                create_cmd = f"""az iot ops ns asset custom create \\
  --name {asset_name} \\
  --instance {self.instance_name} \\
  --resource-group {self.resource_group} \\
  --device {device_name} \\
  --endpoint {endpoint_name} \\
  --description "{description} #{i:02d}\""""
                commands.append(create_cmd)
                commands.append("")
                
                # Create dataset
                dataset_cmd = f"""az iot ops ns asset custom dataset add \\
  --asset {asset_name} \\
  --name {dataset_name} \\
  --instance {self.instance_name} \\
  --resource-group {self.resource_group} \\
  --data-source mqtt \\
  --destination topic="{topic}" retain=Never qos=Qos1 ttl=3600"""
                commands.append(dataset_cmd)
                commands.append("")
                
                # Add data points
                for data_point in config["data_points"]:
                    datapoint_cmd = f"""az iot ops ns asset custom datapoint add \\
  --asset {asset_name} \\
  --dataset {dataset_name} \\
  --name {data_point["name"]} \\
  --data-source {data_point["source"]} \\
  --instance {self.instance_name} \\
  --resource-group {self.resource_group}"""
                    commands.append(datapoint_cmd)
                    commands.append("")
                
                commands.append("# ----------------------------------------")
                commands.append("")
        
        return "\n".join(commands)
    
    def save_commands_to_file(self, filename: str = "azure_cli_commands.sh"):
        """Save commands to a file."""
        commands = self.generate_commands()
        
        with open(filename, 'w', encoding='utf-8') as f:
            f.write(commands)
        
        print(f"✅ Commands saved to: {filename}")
        print(f"📋 You can now run: bash {filename}")
        print("   Or copy/paste individual commands from the file")
    
    def generate_summary(self) -> str:
        """Generate a summary of what will be created."""
        summary = []
        total_assets = 0
        total_data_points = 0
        
        for asset_group, config in self.assets_config.items():
            count = config["count"]
            data_point_count = len(config["data_points"])
            
            total_assets += count
            total_data_points += count * data_point_count
            
            summary.append(f"  📱 {asset_group.replace('_', ' ').title()}: {count} assets × {data_point_count} data points")
        
        result = "🏭 Spaceship Factory Asset Configuration:\n"
        result += "\n".join(summary)
        result += f"\n\n📊 Total: {total_assets} assets, {total_data_points} data points"
        
        return result


def main():
    """Generate Azure CLI commands."""
    import sys
    
    if len(sys.argv) != 3:
        print("Usage: python generate_cli_commands.py <resource_group> <iot_operations_instance>")
        print("Example: python generate_cli_commands.py IoT-Operations-Work-Edge-bel-aio bel-aio-work-cluster-aio")
        sys.exit(1)
    
    resource_group = sys.argv[1]
    instance_name = sys.argv[2]
    
    generator = AzureCLICommandGenerator(resource_group, instance_name)
    
    print(generator.generate_summary())
    print()
    
    # Save to file
    generator.save_commands_to_file("spaceship_factory_commands.sh")
    
    print("\n🔧 Next Steps:")
    print("1. Install Azure CLI if you haven't already")
    print("2. Run: az login")
    print("3. Run the generated commands from spaceship_factory_commands.sh")
    print("4. Or copy/paste commands individually into your terminal")


if __name__ == "__main__":
    main()