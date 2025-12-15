# Optional Tools Quick Reference

## Overview

The `optional_tools` section in `linux_aio_config.json` controls installation of helpful utilities for debugging, managing, and accessing your edge deployment.

```json
{
  "optional_tools": {
    "k9s": true,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": false
  }
}
```

**Available Tools:**
- **k9s**: Terminal UI for Kubernetes cluster management
- **mqtt-viewer**: Command-line MQTT message viewer
- **mqttui**: Interactive TUI for MQTT topic exploration
- **ssh**: Secure remote shell access to edge device

---

## k9s - Kubernetes Terminal UI

### Installation
Set `"k9s": true` in linux_aio_config.json and run `linux_installer.sh`

Or install manually:
```bash
# Linux AMD64
wget https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz
tar -xzf k9s_Linux_amd64.tar.gz
sudo mv k9s /usr/local/bin/
k9s version
```

### Quick Start
```bash
# Launch k9s
k9s

# Launch in a specific namespace
k9s -n azure-iot-operations
```

### Essential Shortcuts

#### Navigation
- `:pods` - View pods
- `:svc` - View services
- `:deploy` - View deployments
- `:ns` - View namespaces
- `:nodes` - View nodes
- `/` - Filter resources
- `Ctrl+A` - Show all resources

#### Actions
- `l` - View logs (tail -f)
- `d` - Describe resource
- `e` - Edit resource
- `y` - View YAML
- `Ctrl+D` - Delete resource
- `s` - Shell into container
- `p` - Previous resource
- `n` - Next resource

#### View Options
- `0` - Show all namespaces
- `1-9` - Show pods with specific number of containers
- `?` - Help menu
- `Ctrl+C` or `q` - Quit/back

### Common Tasks

#### Monitor AIO Pods
```bash
k9s -n azure-iot-operations
# Then press :pods
# Filter with / and type "aio"
```

#### View Pod Logs
```bash
k9s -n azure-iot-operations
# Navigate to pod with arrow keys
# Press 'l' for logs
# Press 's' to toggle auto-scroll
```

#### Debug Failed Pod
```bash
k9s
# Navigate to failing pod
# Press 'd' to describe (shows events)
# Press 'l' to view logs
# Press 'y' to view YAML config
```

#### Check Resource Usage
```bash
k9s
# Press :nodes
# See CPU/Memory usage per node
# Press :pods
# See resource usage per pod
```

### Configuration
k9s config location: `~/.config/k9s/config.yml`

```yaml
k9s:
  refreshRate: 2
  maxConnRetry: 5
  readOnly: false
  noExitOnCtrlC: false
  ui:
    enableMouse: true
    headless: false
    logoless: false
    crumbsless: false
  logger:
    tail: 100
    buffer: 5000
```

---

## mqtt-viewer - MQTT Message Viewer

### Installation
Set `"mqtt-viewer": true` in linux_aio_config.json and run `linux_installer.sh`

Or install manually:
```bash
# Via pip
pip3 install mqtt-viewer

# Verify installation
mqtt-viewer --help
```

### Quick Start

#### View All Factory Telemetry
```bash
mqtt-viewer -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883 -t 'factory/#'
```

#### View Specific Topic
```bash
mqtt-viewer -h localhost -p 1883 -t 'factory/assembly-line-1/telemetry'
```

#### With Authentication
```bash
mqtt-viewer -h broker -p 8883 -t 'topic' -u username -P password --tls
```

### Common Use Cases

#### Debug MQTT Connectivity
```bash
# Test if broker is accessible
mqtt-viewer -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883 -t '$SYS/#'
```

#### Monitor Telemetry from Simulator
```bash
# Watch messages from edgemqttsim
mqtt-viewer -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883 -t 'factory/+/telemetry' --pretty
```

#### Check Message Rate
```bash
# Count messages per second
mqtt-viewer -h localhost -p 1883 -t 'factory/#' --count
```

#### Save Messages to File
```bash
# Log messages for analysis
mqtt-viewer -h localhost -p 1883 -t 'factory/#' > telemetry_log.json
```

### Command Options

```
Usage: mqtt-viewer [OPTIONS]

Options:
  -h, --host TEXT        MQTT broker host
  -p, --port INTEGER     MQTT broker port (default: 1883)
  -t, --topic TEXT       MQTT topic to subscribe to (supports wildcards)
  -u, --username TEXT    MQTT username
  -P, --password TEXT    MQTT password
  --tls                  Enable TLS/SSL
  --pretty               Pretty-print JSON messages
  --count                Show message count
  --verbose              Verbose output
  --help                 Show this message and exit
```

### Alternative: mosquitto_sub

If mqtt-viewer is not available, use mosquitto_sub from within the AIO cluster:

```bash
# From outside cluster
kubectl exec -it -n azure-iot-operations deploy/aio-broker-frontend -- \
  mosquitto_sub -h localhost -p 18883 -t 'factory/#' -v

# Pretty print with jq
kubectl exec -it -n azure-iot-operations deploy/aio-broker-frontend -- \
  mosquitto_sub -h localhost -p 18883 -t 'factory/telemetry' | jq .
```

---

## mqttui - Interactive MQTT Terminal UI

### Installation
Set `"mqttui": true` in linux_aio_config.json and run `linux_installer.sh`

Or install manually:
```bash
# Linux AMD64
wget https://github.com/EdJoPaTo/mqttui/releases/latest/download/mqttui-x86_64-unknown-linux-gnu.tar.gz
tar -xzf mqttui-x86_64-unknown-linux-gnu.tar.gz
sudo mv mqttui /usr/local/bin/
mqttui --version
```

### Quick Start

#### Launch with AIO Broker
```bash
mqttui -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883
```

#### With Authentication
```bash
mqttui -h broker -p 8883 -u username -P password
```

#### With TLS (insecure for self-signed certs)
```bash
mqttui -h broker -p 8883 --insecure
```

### Interface Overview

```
┌─────────────────────────────────────────────────────────────┐
│ Topics Tree (Left)         │ Messages (Right)               │
│                            │                                 │
│ ▼ factory/                 │ Topic: factory/telemetry       │
│   ▼ assembly-line-1/       │ Time: 12:34:56                 │
│     • telemetry            │ {                               │
│     • status               │   "temperature": 72.5,          │
│   ▼ cnc-machine/           │   "pressure": 101.3             │
│     • telemetry            │ }                               │
│   • alerts                 │                                 │
│                            │ [Previous messages...]          │
└─────────────────────────────────────────────────────────────┘
Status: Connected | Subscriptions: 3 | Messages: 42
```

### Essential Shortcuts

#### Navigation
- `↑/↓` or `j/k` - Move up/down in topics
- `←/→` or `h/l` - Collapse/expand topic branches
- `Tab` - Switch between topics and messages panes
- `g` - Go to top
- `G` - Go to bottom

#### Actions
- `s` - Subscribe to selected topic
- `u` - Unsubscribe from selected topic
- `Space` - Toggle topic expansion
- `p` - Publish message to topic
- `d` - Delete/clear messages for topic
- `/` - Search messages
- `?` - Show help
- `q` - Quit

#### View Options
- `c` - Toggle compact mode
- `w` - Toggle wrap mode for messages
- `r` - Refresh/reconnect
- `Ctrl+L` - Clear screen and redraw

### Common Tasks

#### Discover All Topics
```bash
# Launch mqttui and let it build the topic tree
mqttui -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883

# Wait for messages to arrive
# Topic tree automatically populates on left side
# Navigate with arrow keys
# Press 's' on any topic to subscribe
```

#### Subscribe to Multiple Topics
```bash
# Launch mqttui
mqttui -h localhost -p 1883

# In the UI:
# 1. Navigate to 'factory/telemetry' and press 's'
# 2. Navigate to 'factory/status' and press 's'
# 3. Navigate to 'factory/alerts' and press 's'
# Messages from all topics appear in right pane
```

#### View Message History
```bash
# Launch mqttui
mqttui -h localhost -p 1883

# Subscribe to topics
# Switch to messages pane with Tab
# Scroll through history with ↑/↓
# Search with '/' key
```

#### Publish Test Messages
```bash
# Launch mqttui
mqttui -h localhost -p 1883

# Navigate to target topic
# Press 'p' to publish
# Enter message payload
# Press Enter to send
```

#### Export/Save Messages
```bash
# Redirect stdout to capture messages
mqttui -h localhost -p 1883 | tee mqtt_messages.log

# Or use mqtt-viewer for logging
mqtt-viewer -h localhost -p 1883 -t 'factory/#' > factory.log
```

### Advanced Features

#### Topic Wildcards
mqttui automatically subscribes to `#` (all topics) for discovery, then allows you to selectively subscribe to specific patterns.

#### Message Filtering
Press `/` in messages pane to search/filter messages by content.

#### Connection Status
Bottom status bar shows:
- Connection state (Connected/Disconnected)
- Active subscriptions count
- Total messages received

#### Color Coding
- **Green**: Successfully received messages
- **Yellow**: System/status messages
- **Red**: Error messages or connection issues
- **Blue**: Highlighted/selected items

### Configuration
mqttui config location: `~/.config/mqttui/config.toml`

```toml
[broker]
default_host = "aio-broker.azure-iot-operations.svc.cluster.local"
default_port = 18883

[ui]
compact_mode = false
auto_scroll = true
wrap_messages = true

[subscriptions]
auto_subscribe = ["factory/#", "devices/#"]
```

### Use Cases

#### 1. Topic Discovery
**Problem**: Don't know what topics exist  
**Solution**: Launch mqttui, watch topic tree build automatically

#### 2. Multi-Topic Monitoring
**Problem**: Need to watch multiple topics simultaneously  
**Solution**: Subscribe to multiple topics, all messages in one view

#### 3. Interactive Debugging
**Problem**: Need to explore MQTT structure interactively  
**Solution**: Use mqttui's visual tree and message inspection

#### 4. Message Pattern Analysis
**Problem**: Looking for specific message patterns  
**Solution**: Use search (`/`) to filter messages

---

## ssh - Secure Remote Shell Access

### Installation
Set `"ssh": true` in linux_aio_config.json and run `linux_installer.sh`

The installer will:
1. Install openssh-server
2. Generate 4096-bit RSA key pair
3. Configure key-based authentication only
4. Disable password authentication
5. Configure firewall rules
6. Start and enable SSH service
7. Display connection information

### Post-Install Output

After installation completes, you'll see:

```
========================================
SSH Configuration Complete
========================================
SSH Server: RUNNING
Host IP: 192.168.1.100
SSH Port: 22

Private Key Location: /home/adminuser/.ssh/id_rsa_edge_device
Public Key: Added to authorized_keys

To connect from another machine:
1. Copy private key to your machine
2. Run: ssh -i /path/to/id_rsa_edge_device adminuser@192.168.1.100

Security Notes:
- Password authentication is DISABLED
- Only key-based authentication is allowed
- Keep private key secure and never commit to git
========================================
```

### Connecting from Remote Machine

#### Step 1: Copy Private Key
```bash
# From edge device, copy the private key
scp adminuser@192.168.1.100:/home/adminuser/.ssh/id_rsa_edge_device ~/edge_key

# Or use USB drive, secure file transfer, etc.
```

#### Step 2: Set Key Permissions
```bash
chmod 600 ~/edge_key
```

#### Step 3: Connect
```bash
ssh -i ~/edge_key adminuser@192.168.1.100
```

#### Step 4: Add to SSH Config (Optional)
```bash
# Add to ~/.ssh/config
cat >> ~/.ssh/config << EOF
Host edge-device
    HostName 192.168.1.100
    User adminuser
    IdentityFile ~/edge_key
    StrictHostKeyChecking accept-new
EOF

# Now connect with:
ssh edge-device
```

### Common Tasks

#### Check SSH Service Status
```bash
# On edge device
systemctl status sshd

# Check if SSH port is listening
sudo netstat -tlnp | grep :22
```

#### View SSH Logs
```bash
# Real-time log monitoring
sudo journalctl -u sshd -f

# Recent connection attempts
sudo journalctl -u sshd -n 50
```

#### Manage Authorized Keys
```bash
# View authorized keys
cat ~/.ssh/authorized_keys

# Add additional keys
echo "ssh-rsa AAAAB3... user@machine" >> ~/.ssh/authorized_keys

# Remove a key
nano ~/.ssh/authorized_keys  # Delete the line
```

#### Test Connection Without Key
```bash
# This should FAIL (password auth disabled)
ssh adminuser@192.168.1.100
# Expected: Permission denied (publickey)
```

#### Copy Files via SCP
```bash
# Copy file to edge device
scp -i ~/edge_key local_file.txt adminuser@192.168.1.100:/tmp/

# Copy from edge device
scp -i ~/edge_key adminuser@192.168.1.100:/tmp/remote_file.txt ./

# Copy directory recursively
scp -i ~/edge_key -r local_dir adminuser@192.168.1.100:/tmp/
```

#### Run Remote Commands
```bash
# Execute single command
ssh -i ~/edge_key adminuser@192.168.1.100 'kubectl get pods -A'

# Run multiple commands
ssh -i ~/edge_key adminuser@192.168.1.100 'cd /tmp && ls -la && df -h'

# Interactive commands
ssh -i ~/edge_key adminuser@192.168.1.100 -t 'sudo systemctl restart k3s'
```

### Security Features

#### Key-Based Authentication Only
- Password login completely disabled
- Protects against brute-force attacks
- Requires physical access to private key

#### Strong Encryption
- 4096-bit RSA keys (industry standard)
- Secure key exchange protocols
- Forward secrecy

#### Firewall Integration
- UFW automatically configured
- Only port 22 exposed
- Rate limiting available

#### Connection Logging
- All connections logged via systemd journal
- Failed authentication attempts tracked
- Audit trail for compliance

### Configuration

SSH config location: `/etc/ssh/sshd_config`

Key settings applied by installer:
```bash
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
X11Forwarding no
MaxAuthTries 3
```

### Use Cases

#### 1. Remote Troubleshooting
**Problem**: Need to debug edge device from office  
**Solution**: SSH in and run kubectl/diagnostic commands

#### 2. Log Collection
**Problem**: Need to retrieve logs for analysis  
**Solution**: Use scp to copy log files to development machine

#### 3. Remote Updates
**Problem**: Need to update edge configuration  
**Solution**: SSH in, edit files, restart services

#### 4. Multi-Site Management
**Problem**: Managing multiple edge devices  
**Solution**: SSH with inventory scripts or Ansible

---

## Troubleshooting

### k9s Won't Start

#### KUBECONFIG not set
```bash
export KUBECONFIG=~/.kube/config
k9s
```

#### Permission denied
```bash
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 600 ~/.kube/config
```

#### Cluster not accessible
```bash
# Test kubectl first
kubectl get nodes

# If kubectl works but k9s doesn't
rm -rf ~/.config/k9s
k9s
```

### mqtt-viewer Connection Failed

#### Broker not accessible
```bash
# Check if broker is running
kubectl get svc -n azure-iot-operations aio-broker

# Test with kubectl port-forward
kubectl port-forward -n azure-iot-operations svc/aio-broker 1883:18883
mqtt-viewer -h localhost -p 1883 -t 'factory/#'
```

#### Authentication required
```bash
# Check AIO broker authentication settings
kubectl get secret -n azure-iot-operations

# Use appropriate credentials or token
```

#### Module not installed
```bash
# Install via pip
pip3 install mqtt-viewer

# Or use system package manager
sudo apt install mosquitto-clients
mosquitto_sub -h localhost -p 1883 -t 'factory/#'
```

### mqttui Issues

#### Binary not found
```bash
# Download latest release
wget https://github.com/EdJoPaTo/mqttui/releases/latest/download/mqttui-x86_64-unknown-linux-gnu.tar.gz
tar -xzf mqttui-x86_64-unknown-linux-gnu.tar.gz
sudo mv mqttui /usr/local/bin/
mqttui --version
```

#### Connection refused
```bash
# Test broker accessibility first
kubectl get svc -n azure-iot-operations aio-broker

# Check if broker is listening on port 18883
kubectl port-forward -n azure-iot-operations svc/aio-broker 18883:18883

# Then try mqttui
mqttui -h localhost -p 18883
```

#### TLS certificate errors
```bash
# For self-signed certificates, use --insecure
mqttui -h broker -p 8883 --insecure

# For proper TLS with CA cert
mqttui -h broker -p 8883 --cafile /path/to/ca.crt
```

#### No topics appearing
```bash
# Wait 10-15 seconds for messages to arrive
# mqttui builds topic tree based on received messages
# If still empty, check if messages are being published:

mqtt-viewer -h same-broker -p same-port -t '#'
```

#### UI garbled or not displaying correctly
```bash
# Clear terminal
clear

# Check terminal size
echo $COLUMNS x $LINES  # Should be at least 80x24

# Try different terminal
export TERM=xterm-256color
mqttui -h broker -p 18883
```

### SSH Issues

#### Cannot connect to edge device
```bash
# Check SSH service on edge device
ssh adminuser@edge-device 'systemctl status sshd'

# Check network connectivity
ping 192.168.1.100

# Check firewall
ssh adminuser@edge-device 'sudo ufw status'
```

#### Permission denied (publickey)
```bash
# Verify key permissions
ls -la ~/edge_key
# Should show: -rw------- (600)

chmod 600 ~/edge_key

# Verify key is correct
ssh-keygen -lf ~/edge_key
```

#### Host key verification failed
```bash
# Remove old host key
ssh-keygen -R 192.168.1.100

# Or use StrictHostKeyChecking=accept-new
ssh -o StrictHostKeyChecking=accept-new -i ~/edge_key adminuser@192.168.1.100
```

#### Connection timeout
```bash
# Check if SSH port is open
nc -zv 192.168.1.100 22

# Check if device is on same network
ip route get 192.168.1.100

# Try with verbose output
ssh -vvv -i ~/edge_key adminuser@192.168.1.100
```

#### Key was regenerated
```bash
# If edge device was rebuilt, you'll see host key mismatch
# Remove old key and accept new one
ssh-keygen -R 192.168.1.100
ssh -o StrictHostKeyChecking=accept-new -i ~/edge_key adminuser@192.168.1.100
```

---

## When to Use Each Tool

### k9s
- ✅ Daily development and debugging
- ✅ Learning Kubernetes concepts
- ✅ Real-time monitoring during testing
- ✅ Quick resource inspection
- ✅ Pod log viewing
- ❌ Production environments (use monitoring systems)
- ❌ CI/CD pipelines (use kubectl)
- ❌ Automated scripts

### mqtt-viewer
- ✅ Debugging MQTT connectivity issues
- ✅ Validating telemetry data format
- ✅ Testing message flows
- ✅ Development and integration testing
- ✅ Message rate analysis
- ✅ Simple logging to file
- ❌ Production monitoring (use proper telemetry systems)
- ❌ Long-term message storage
- ❌ High-volume message analysis
- ❌ Interactive topic exploration (use mqttui)

### mqttui
- ✅ Interactive MQTT topic discovery
- ✅ Multi-topic monitoring in one view
- ✅ Real-time message inspection
- ✅ Learning MQTT topic structure
- ✅ Ad-hoc testing and experimentation
- ✅ Message pattern searching
- ❌ Automated testing (use mqtt-viewer)
- ❌ Message logging to file (use mqtt-viewer)
- ❌ Production monitoring (use proper telemetry systems)
- ❌ CI/CD pipelines

### ssh
- ✅ Remote troubleshooting and debugging
- ✅ Multi-site edge device management
- ✅ Remote log collection
- ✅ Configuration updates
- ✅ Emergency access
- ✅ Development and testing environments
- ❌ Air-gapped or isolated networks
- ❌ Strict zero-trust environments
- ❌ When physical-only access is mandated
- ❌ High-security production without remote access policy
- ❌ Production environments (use monitoring systems)
- ❌ CI/CD pipelines (use kubectl)
- ❌ Automated scripts

### mqtt-viewer
- ✅ Debugging MQTT connectivity issues
- ✅ Validating telemetry data format
- ✅ Testing message flows
- ✅ Development and integration testing
- ✅ Message rate analysis
- ✅ Simple logging to file
- ❌ Production monitoring (use proper telemetry systems)
- ❌ Long-term message storage
- ❌ High-volume message analysis
- ❌ Interactive topic exploration (use mqttui)

### mqttui
- ✅ Interactive MQTT topic discovery
- ✅ Multi-topic monitoring in one view
- ✅ Real-time message inspection
- ✅ Learning MQTT topic structure
- ✅ Ad-hoc testing and experimentation
- ✅ Message pattern searching
- ❌ Automated testing (use mqtt-viewer)
- ❌ Message logging to file (use mqtt-viewer)
- ❌ Production monitoring (use proper telemetry systems)
- ❌ CI/CD pipelines

---

## Comparison with Alternatives

### k9s vs kubectl
| Feature | k9s | kubectl |
|---------|-----|---------|
| UI | Interactive TUI | Command-line |
| Learning curve | Easy | Moderate |
| Speed | Fast navigation | Command per action |
| Automation | No | Yes |
| Best for | Interactive use | Scripts, CI/CD |

### mqtt-viewer vs mosquitto_sub
| Feature | mqtt-viewer | mosquitto_sub |
|---------|-------------|---------------|
| Installation | Python package | System package |
| JSON formatting | Built-in | Requires jq |
| Color output | Yes | No |
| UI | Better | Basic |
| Availability | May not be installed | Usually available |

### MQTT Tool Comparison
| Feature | mqttui | mqtt-viewer | mosquitto_sub |
|---------|--------|-------------|---------------|
| UI Type | Interactive TUI | Command-line | Command-line |
| Topic Discovery | Visual tree | Manual | Manual |
| Multi-topic | Single view | Multiple commands | Multiple commands |
| Message Search | Built-in (`/`) | External (grep) | External (grep) |
| Message History | Scrollable | All output | All output |
| Publish | Interactive | N/A | mosquitto_pub |
| Best For | Exploration | Logging/Testing | Scripts/Containers |
| Learning Curve | Low | Very low | Low |
| Installation | GitHub binary | pip install | apt install |

---

## Best Practices

### Development Environment
```json
{
  "optional_tools": {
    "k9s": true,
    "mqtt-viewer": true,
    "mqttui": true,
    "ssh": true
  }
}
```
**Why**: All tools accelerate development and debugging. SSH enables remote work.

### Production Environment
```json
{
  "optional_tools": {
    "k9s": false,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": false
  }
}
```
**Why**: Minimize attack surface, use centralized monitoring instead

### Production with Remote Management
```json
{
  "optional_tools": {
    "k9s": false,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": true
  }
}
```
**Why**: SSH for remote access, but no dev tools to minimize footprint

### CI/CD Pipeline
```json
{
  "optional_tools": {
    "k9s": false,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": false
  }
}
```
**Why**: Not needed for automated deployments, saves installation time

### Production with Operator Access
```json
{
  "optional_tools": {
    "k9s": true,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": true
  }
}
```
**Why**: k9s for interactive debugging, SSH for remote access, no MQTT tools in production

---

## Related Documentation

- [Modules Configuration Guide](./modules_configuration_guide.md) - Complete module system documentation
- [Separation of Concerns](./separation_of_concerns.md) - Overall architecture
- [Quick Reference](./separation_quick_reference.md) - Quick lookup guide

---

## Quick Command Reference Card

### k9s
```bash
k9s                              # Launch k9s
k9s -n azure-iot-operations     # Launch in specific namespace
:pods                            # View pods
:svc                             # View services
l                                # View logs
d                                # Describe resource
?                                # Help
q                                # Quit
```

### mqtt-viewer
```bash
# AIO broker (anonymous)
mqtt-viewer -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883 -t 'factory/#'

# With authentication
mqtt-viewer -h broker -p 8883 -t 'topic' -u user -P pass --tls

# Pretty print JSON
mqtt-viewer -h localhost -p 1883 -t 'factory/#' --pretty

# Count messages
mqtt-viewer -h localhost -p 1883 -t 'factory/#' --count
```

### mqttui
```bash
# AIO broker
mqttui -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883

# With authentication
mqttui -h broker -p 8883 -u user -P pass

# Inside TUI:
s                                # Subscribe to selected topic
u                                # Unsubscribe
p                                # Publish message
/                                # Search messages
?                                # Help
q                                # Quit
```

### ssh
```bash
# Connect with key
ssh -i ~/edge_key adminuser@192.168.1.100

# Copy file to edge
scp -i ~/edge_key file.txt adminuser@192.168.1.100:/tmp/

# Copy from edge
scp -i ~/edge_key adminuser@192.168.1.100:/tmp/file.txt ./

# Run remote command
ssh -i ~/edge_key adminuser@192.168.1.100 'kubectl get pods -A'

# Add to SSH config (~/.ssh/config)
Host edge-device
    HostName 192.168.1.100
    User adminuser
    IdentityFile ~/edge_key
```

### mosquitto_sub (alternative)
```bash
# From within cluster
kubectl exec -it -n azure-iot-operations deploy/aio-broker-frontend -- \
  mosquitto_sub -h localhost -p 18883 -t 'factory/#' -v
```
