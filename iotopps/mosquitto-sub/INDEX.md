# Mosquitto Subscriber - Complete Package

## 📦 What's Included

This folder contains everything needed to deploy and use a MQTT message subscriber for Azure IoT Operations.

```
mosquitto-sub/
├── deployment.yaml       # Kubernetes deployment manifest
├── Dockerfile.reference  # Reference (not built - uses official image)
├── README.md            # Full documentation
├── QUICKSTART.md        # Quick start guide
└── TROUBLESHOOTING.md   # Detailed troubleshooting
```

## 🚀 Quick Start (3 Steps)

### 1. Deploy
Push to GitHub (automatic deployment):
```bash
git add iotopps/mosquitto-sub/
git commit -m "Add MQTT subscriber"
git push origin dev
```

### 2. View Messages
```bash
kubectl logs -n default -l app=mosquitto-sub -f
```

### 3. See Results
```
sputnik/beep {"timestamp": "2024-10-28T10:15:30Z", "beep_number": 1, "message": "beep!"}
sputnik/beep {"timestamp": "2024-10-28T10:15:35Z", "beep_number": 2, "message": "beep!"}
```

## 📚 Documentation

### Start Here
- **[QUICKSTART.md](QUICKSTART.md)** - Get running in 5 minutes

### Full Documentation
- **[README.md](README.md)** - Complete guide with all features and configuration options

### Help & Troubleshooting
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - Solve common issues

## 🎯 Purpose

**Monitor MQTT messages** published to the Azure IoT Operations broker.

Perfect for:
- ✅ Verifying publishers like Sputnik are working
- ✅ Debugging message flow
- ✅ Testing new MQTT topics
- ✅ Learning how MQTT works

## ⚙️ How It Works

```
1. Mosquitto-sub connects to AIO MQTT Broker
2. Authenticates using ServiceAccountToken (K8S-SAT)
3. Subscribes to configured topic (default: sputnik/beep)
4. Displays incoming messages in pod logs
```

## 🔧 Key Features

- **No custom code needed** - Uses official eclipse-mosquitto image
- **Same auth as Sputnik** - ServiceAccountToken (K8S-SAT)
- **Auto-deployed via GitHub Actions** - Just push to dev branch
- **Topic wildcards supported** - Subscribe to multiple topics
- **Real-time message display** - See messages as they arrive

## 📋 Configuration

Edit `deployment.yaml` to change settings:

```yaml
env:
# Change this to subscribe to different topics
- name: MQTT_TOPIC
  value: "sputnik/beep"  # Your topic here
  
# Wildcards supported:
# "sputnik/#"           - All sputnik topics
# "devices/+/telemetry" - All device telemetry
# "#"                   - Everything (careful!)
```

## 🔐 Security

- **Authentication**: Kubernetes ServiceAccountToken (same as Sputnik)
- **Encryption**: TLS 1.2+ for all connections
- **Authorization**: Controlled by Azure IoT Operations BrokerAuthorization policies
- **Token Auto-Renewal**: Kubernetes handles token refresh every 24 hours

## 🎓 Learning Path

1. **Deploy and view Sputnik messages** (Start here)
2. Read [QUICKSTART.md](QUICKSTART.md) for basic usage
3. Try changing the subscribed topic
4. Read [README.md](README.md) for advanced features
5. If issues arise, check [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## 🆚 Mosquitto-Sub vs Sputnik

| Feature | Sputnik | Mosquitto-Sub |
|---------|---------|---------------|
| **Role** | Publisher (sends) | Subscriber (receives) |
| **Language** | Python | Shell/mosquitto_sub |
| **Custom Code** | Yes | No |
| **Docker Build** | Required | Not needed |
| **Logs Show** | Sent messages | Received messages |
| **Purpose** | IoT device simulator | Message monitoring |

## 🔗 Related

- **[Sputnik](../sputnik/README.md)** - The publisher sending messages
- **[Hello Flask](../hello-flask/README.md)** - Example web service
- **[GitHub Actions Workflow](../../.github/workflows/deploy-iot-edge.yaml)** - Deployment automation

## ❓ FAQ

### Q: Do I need to build a Docker image?
**A:** No! Uses the official `eclipse-mosquitto:2.0` image.

### Q: Can I subscribe to multiple topics?
**A:** Yes! Use wildcards like `sputnik/#` or deploy multiple instances with different topics.

### Q: How do I see the messages?
**A:** Run: `kubectl logs -n default -l app=mosquitto-sub -f`

### Q: Can I run this outside the cluster?
**A:** Not with ServiceAccountToken. For external access, you'd need X.509 certificates or expose the broker via NodePort/LoadBalancer.

### Q: How do I change the topic?
**A:** Edit `MQTT_TOPIC` in `deployment.yaml` and redeploy.

## 🎉 Success Criteria

You'll know it's working when:
- ✅ Pod shows status `Running`
- ✅ Logs show "Connected successfully"
- ✅ Messages from Sputnik appear in logs
- ✅ New messages appear every 5 seconds

## 📞 Next Steps

1. **Deploy it**: Follow [QUICKSTART.md](QUICKSTART.md)
2. **View messages**: `kubectl logs -n default -l app=mosquitto-sub -f`
3. **Explore**: Try different topics, read the full README
4. **Build**: Create your own MQTT publishers and subscribers!

---

**Ready to start?** → Open [QUICKSTART.md](QUICKSTART.md)
