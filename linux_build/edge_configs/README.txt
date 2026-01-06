Azure IoT Operations - Backup Information
==========================================

Backup created: Tue Jan  6 07:09:24 PM UTC 2026
Hostname: home-nuc-1
User: billmanh

Files in this backup:
  - cluster_info.json (cluster connection information)
  - linux_aio_config.json (installation configuration)
  - linux_installer*.log (installation logs)

To restore these files on another system:
1. Copy files to the linux_build directory
2. Run: ./external_configurator.sh --cluster-info cluster_info.json

For more information, see:
  linux_build/docs/backup_restore_guide.md
