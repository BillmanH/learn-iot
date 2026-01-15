running the linux_installer.sh
(Reading database ... 160887 files and directories currently installed.)
Preparing to unpack .../snapd_2.73+ubuntu24.04_amd64.deb ...
Unpacking snapd (2.73+ubuntu24.04) over (2.72+ubuntu24.04) ...
Preparing to unpack .../azcmagent_1.60.03293.809_amd64.deb ...
Prerm called with: upgrade
Getting status via systemd
     Active: active (running) since Sun 2026-01-04 05:27:55 UTC; 1 week 4 days ago
EXT service is running
STOPPING EXT
Getting status via systemd
EXT service is not running.
Unconfiguring extd (systemd) service ...
Removed "/etc/systemd/system/himdsd.service.wants/extd.service".
Removed "/etc/systemd/system/multi-user.target.wants/extd.service".
Getting status via systemd
     Active: active (running) since Sun 2026-01-04 05:27:53 UTC; 1 week 4 days ago
Arc GC service is running
STOPPING Arc GC
Getting status via systemd
Arc GC service is not running.
Unconfiguring gcad (systemd) service ...
Removed "/etc/systemd/system/multi-user.target.wants/gcad.service".
Getting status via systemd
GC service is not running.
gcd Azure policy service is not running - cleaning up Configuration folder.
Removed "/etc/systemd/system/multi-user.target.wants/arcproxyd.service".
{"level":"fatal","msg":"sshproxy: error copying information from the connection: read tcp 10.14.4.86:56383-\u003e172.212.233.20:443: wsarecv: An existing connection was forcibly closed by the remote host.","proxyVersion":"1.3.026973"}
         
Then, trying to log back in:
C:\Users\wharding\repos>az ssh arc --subscription "fbaf508b-cb61-4383-9cda-a42bfa0c7bc9" --resource-group "ACX-AIO-CAT" --name "bel-aio" --local-user "azureuser"
{"level":"error","msg":"error connecting to wss://azgn-eastus-public-2p-cusdm-vazr0002.servicebus.windows.net/$hc/microsoft.hybridcompute/machines/d8beca7354361cd4f3dfc529f3b9e9d8de6cafd8d0b3e450d46f6601507d02f0/1768509251540313600/v2%3Fsb-hc-action=connect\u0026sb-hc-id=7b17ae72-fddb-4c9b-a8f9-94c2654aa0fe. 404 There are no listeners connected for the endpoint. TrackingId:7b17ae72-fddb-4c9b-a8f9-94c2654aa0fe_G14, SystemTracker:sb://azgn-eastus-public-2p-cusdm-vazr0002.servicebus.windows.net/microsoft.hybridcompute/machines/d8beca7354361cd4f3dfc529f3b9e9d8de6cafd8d0b3e450d46f6601507d02f0/1768509251540313600/v2, Timestamp:2026-01-15T20:34:13. websocket: bad handshake ","proxyVersion":"1.3.026973"}
{"level":"fatal","msg":"sshproxy: error connecting to the address: 404 There are no listeners connected for the endpoint. TrackingId:7b17ae72-fddb-4c9b-a8f9-94c2654aa0fe_G14, SystemTracker:sb://azgn-eastus-public-2p-cusdm-vazr0002.servicebus.windows.net/microsoft.hybridcompute/machines/d8beca7354361cd4f3dfc529f3b9e9d8de6cafd8d0b3e450d46f6601507d02f0/1768509251540313600/v2, Timestamp:2026-01-15T20:34:13. websocket: bad handshake","proxyVersion":"1.3.026973"}

