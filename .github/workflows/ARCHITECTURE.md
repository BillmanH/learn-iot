# GitHub Actions Workflow Architecture

## Overall Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Developer Actions                            │
└───────────────┬─────────────────────────────────────────────────────┘
                │
                ├─── Create PR ──────────────────┐
                │                                 │
                ├─── Merge to main/dev ──────────┤
                │                                 │
                └─── Manual workflow trigger ────┤
                                                  │
                                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         GitHub Actions                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌──────────────────┐  ┌──────────────────┐                         │
│  │  Build & Test    │  │  Deploy App      │                         │
│  │  (on PR)         │  │  (on merge/     │                         │
│  │                  │  │   manual)        │                         │
│  │  1. Detect apps  │  │  1. Detect apps  │                         │
│  │  2. Build images │  │  2. Build images │                         │
│  │  3. Validate     │  │  3. Push images  │                         │
│  │  4. Report       │  │  4. Deploy K8s   │                         │
│  └──────────────────┘  │  5. Verify       │                         │
│                        └──────────────────┘                         │
│                                                                       │
│  ┌──────────────────┐                                                │
│  │  Cleanup         │                                                │
│  │  (manual only)   │                                                │
│  │                  │                                                │
│  │  1. Connect Arc  │                                                │
│  │  2. Delete K8s   │                                                │
│  │  3. Delete imgs  │                                                │
│  └──────────────────┘                                                │
└───────────────┬─────────────────────────────────────────────────────┘
                │
                ├─── Docker Hub / ACR ────────────┐
                │                                  │
                └─── Azure Arc K8s Cluster ───────┤
                                                   │
                                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         Deployment Target                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │              Azure Arc-enabled K8s Cluster                   │    │
│  │                                                              │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │    │
│  │  │ hello-flask  │  │   sputnik    │  │  your-app    │     │    │
│  │  │ pod(s)       │  │   pod(s)     │  │  pod(s)      │     │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘     │    │
│  │                                                              │    │
│  │  ┌──────────────────────────────────────────────────────┐  │    │
│  │  │              Services (NodePort)                      │  │    │
│  │  │  hello-flask-service:30080                           │  │    │
│  │  │  sputnik-service:30081                               │  │    │
│  │  └──────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

## Deployment Workflow Detailed Steps

```
┌──────────────┐
│ Code Change  │
└──────┬───────┘
       │
       ▼
┌──────────────────────────────┐
│ 1. Detect Changed Apps       │
│    • Parse git diff          │
│    • Find Dockerfile dirs    │
│    • Create matrix           │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ 2. Build Docker Image        │
│    • docker build            │
│    • Tag with commit SHA     │
│    • Use build cache         │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ 3. Push to Registry          │
│    • Login (Docker/ACR)      │
│    • Push versioned tag      │
│    • Update :latest tag      │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ 4. Azure Authentication      │
│    • Login with SP           │
│    • Set subscription        │
│    • Verify access           │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ 5. Connect to Arc Cluster    │
│    • Start proxy             │
│    • Wait for connection     │
│    • Verify kubectl access   │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ 6. Apply Deployment          │
│    • Replace placeholders    │
│    • kubectl apply           │
│    • Wait for rollout        │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ 7. Verify Deployment         │
│    • Check pod status        │
│    • Get service info        │
│    • Show logs               │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ 8. Report Status             │
│    • Create summary          │
│    • Comment on PR           │
│    • Send notifications      │
└──────────────────────────────┘
```

## Build & Test Workflow (PR)

```
Pull Request Created/Updated
       │
       ▼
┌──────────────────────────────┐
│ Detect Changed Applications  │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ Build Matrix                 │
│ [hello-flask, sputnik]       │
└──────┬───────────────────────┘
       │
       ├────────────────┬────────────────┐
       ▼                ▼                ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Build Image  │  │ Build Image  │  │ Build Image  │
│ hello-flask  │  │ sputnik      │  │ your-app     │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       ▼                 ▼                 ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Validate     │  │ Validate     │  │ Validate     │
│ Manifests    │  │ Manifests    │  │ Manifests    │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       └────────────────┬────────────────┘
                        │
                        ▼
                 ┌──────────────┐
                 │ Comment on PR│
                 │ with Results │
                 └──────────────┘
```

## Health Check Workflow (removed)

The periodic cluster health check workflow has been removed. Use manual checks or add your own scheduled monitoring if needed.

## Data Flow

```
┌──────────────┐
│ GitHub Repo  │
└──────┬───────┘
       │ (1) Code
       ▼
┌──────────────────┐
│ GitHub Actions   │
│ Runner           │
└──────┬───────────┘
       │ (2) Build
       ▼
┌──────────────────┐      (3) Push
│ Docker Image     │◄──────────────┐
└──────┬───────────┘               │
       │                            │
       │ (4) Pull              ┌────────────┐
       ▼                       │ Registry   │
┌──────────────────┐          │ (Hub/ACR)  │
│ Arc Proxy        │          └────────────┘
│ (Port 47xxx)     │
└──────┬───────────┘
       │ (5) kubectl commands
       ▼
┌──────────────────┐
│ Arc-enabled K8s  │
│ Cluster          │
└──────┬───────────┘
       │ (6) Deploy
       ▼
┌──────────────────┐
│ Running Pods     │
│ & Services       │
└──────────────────┘
```

## Security Boundaries

```
┌─────────────────────────────────────────────────────┐
│              GitHub (Secure Zone)                    │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │         Encrypted Secrets                   │    │
│  │  • AZURE_CREDENTIALS                        │    │
│  │  • DOCKER_PASSWORD                          │    │
│  │  • ACR_PASSWORD                             │    │
│  └────────────────────────────────────────────┘    │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │         Repository Variables                │    │
│  │  • AZURE_RESOURCE_GROUP                     │    │
│  │  • AZURE_CLUSTER_NAME                       │    │
│  │  • REGISTRY_NAME                            │    │
│  └────────────────────────────────────────────┘    │
│                                                      │
└──────────────────┬───────────────────────────────────┘
                   │
                   │ (Encrypted Connection)
                   │
┌──────────────────▼───────────────────────────────────┐
│              Azure (Secure Zone)                     │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │     Service Principal (RBAC)                │    │
│  │  • Contributor on Resource Group            │    │
│  │  • Arc Cluster User                         │    │
│  │  • ACR Push (if using ACR)                  │    │
│  └────────────────────────────────────────────┘    │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │     Arc-enabled K8s Cluster                 │    │
│  │  • No direct internet access                │    │
│  │  • Connected via Arc agents                 │    │
│  │  • Proxy for kubectl access                 │    │
│  └────────────────────────────────────────────┘    │
│                                                      │
└──────────────────────────────────────────────────────┘
```

## File Structure

```
.github/workflows/
│
├── deploy-iot-edge.yaml          # Main deployment workflow
├── build-test.yaml                # PR validation workflow
<!-- cleanup-deployment.yaml (removed) -->
<!-- cluster-health-check.yaml (removed) -->
│
├── QUICKSTART.md                  # 15-min setup guide
├── GITHUB_SECRETS_SETUP.md       # Secrets configuration
├── README.md                      # Complete documentation
├── WORKFLOWS_SUMMARY.md          # This summary
└── ARCHITECTURE.md               # This architecture diagram
```

## Integration Points

```
┌────────────────────────────────────────────────────┐
│                  External Services                  │
└────────────────────────────────────────────────────┘
           │              │              │
           │              │              │
    ┌──────▼─────┐ ┌─────▼──────┐ ┌────▼──────┐
    │ Docker Hub │ │ Azure ACR  │ │  Azure    │
    │            │ │            │ │  Arc      │
    └──────┬─────┘ └─────┬──────┘ └────┬──────┘
           │              │              │
           └──────────────┴──────────────┘
                          │
                          ▼
           ┌──────────────────────────┐
           │   GitHub Actions         │
           │   Workflows              │
           └──────────────────────────┘
                          │
                          ▼
           ┌──────────────────────────┐
           │   Notifications          │
           │   • PR Comments          │
           │   • Step Summaries       │
           │   • Failure Alerts       │
           └──────────────────────────┘
```

## Workflow Trigger Matrix

| Workflow | Push | PR | Manual | Scheduled |
|----------|------|----|----|-----------|
| `deploy-iot-edge.yaml` | ✅ main/dev | ❌ | ✅ | ❌ |
| `build-test.yaml` | ❌ | ✅ | ✅ | ❌ |
| `cleanup-deployment.yaml` | ❌ | ❌ | ❌ | ❌ |
| `cluster-health-check.yaml` | ❌ | ❌ | ❌ | ❌ |
