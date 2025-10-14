<!--
Version change: Initial → 1.0.0
Modified principles: All principles established
Added sections: Development Environment, Deployment Architecture, Script Standards
Removed sections: None (initial constitution)
-->

# IoT Hub Learning Project Constitution

## Core Principles

### I. Cross-Platform Development Model
Development occurs on Windows machines using PowerShell and Windows tooling, while target deployment runs on Linux edge devices using Kubernetes (K3s) and containerized applications. All development scripts must support this Windows-to-Linux deployment model with proper cross-platform file handling via Git attributes.

### II. Script Duality Standard
Every deployment operation must provide both Windows PowerShell scripts (`.ps1`) for development machine execution and Linux shell scripts (`.sh`) for edge device execution. PowerShell scripts handle remote deployment workflows, while shell scripts enable local edge deployment. Both must achieve equivalent functionality through their respective platforms.

### III. Container-First Architecture
All applications must be containerized using Docker with clear separation between development (local testing) and production (edge deployment) environments. Applications must support multiple runtime modes: direct Python execution for development, Docker containers for testing, and Kubernetes deployments for production edge scenarios.

### IV. Configuration Externalization
All environment-specific configuration (Azure subscriptions, cluster details, registry credentials) must be externalized to `linux_build/linux_aio_config.json` and never committed to version control. Scripts must gracefully handle missing configuration with clear error messages.

### V. Focus and Task Discipline
Address only the specific problem or request presented by the user. Avoid tangential improvements, refactoring, or "while I'm here" changes unless explicitly requested. Complete the stated task fully before suggesting additional improvements. Scope creep dilutes effort and creates confusion.

### VI. ASCII-Only Code Standard
All code files must use only conventional ASCII characters (7-bit ASCII character set). Never use emojis, Unicode symbols, or special characters in source code, scripts, comments, or string literals. Use descriptive text prefixes like `[INFO]`, `[ERROR]`, `[SUCCESS]` instead of icons or emojis. This ensures consistent parsing across different platforms, terminals, and encoding environments, preventing character encoding issues that can break scripts or cause parse errors.

### VII. Documentation-Driven Development
Every component must include comprehensive documentation with platform-specific examples. README files must clearly distinguish between Windows development workflows and Linux deployment procedures, providing both PowerShell and shell script examples where applicable.

### Windows Development Machine Requirements
- PowerShell 5.1+ for deployment scripts
- Docker Desktop for container development
- Azure CLI for cloud resource management
- Git with proper line ending configuration via `.gitattributes`
- VS Code or compatible editor with cross-platform awareness

### Edge Device Target Environment
- Linux-based operating system (Ubuntu, RHEL, etc.)
- Kubernetes (K3s) cluster with Azure IoT Operations
- Container runtime (Docker or containerd)
- SSH access for remote deployment from Windows machines
- Arc-enabled cluster connectivity to Azure

## Deployment Architecture

### Remote Deployment Model (Primary)
Windows development machines deploy to remote Linux edge devices via:
1. PowerShell scripts build and push containers to registries
2. Azure CLI connects to Arc-enabled clusters
3. kubectl applies Kubernetes manifests to remote clusters
4. Deployment verification through remote cluster access

### Local Deployment Model (Secondary)
Direct deployment on Linux edge devices via:
1. Shell scripts clone repositories locally on edge devices
2. Local Docker builds and Kubernetes deployments
3. Direct kubectl access to local K3s clusters
4. Local development and testing workflows

## Script Standards

### PowerShell Script Requirements (`.ps1`)
- Support parameter-based configuration with defaults
- Include comprehensive help documentation with examples
- Implement colored output for user feedback
- Handle errors gracefully with actionable error messages
- Support both interactive and automated execution modes

### Shell Script Requirements (`.sh`)
- Use POSIX-compliant shell syntax for maximum compatibility
- Include proper shebang lines (`#!/bin/bash`)
- Implement equivalent functionality to PowerShell counterparts
- Handle missing dependencies with clear installation guidance
- Support both manual and scripted execution

### Cross-Platform File Standards
- Use `.gitattributes` for consistent line endings (CRLF for Windows files, LF for Unix files)
- Include `.editorconfig` for consistent coding styles
- Maintain separate `.bat` files for Windows command prompt compatibility
- Ensure shell scripts have appropriate execute permissions when checked out on Unix systems

## Quality Gates

### Before Any Commit
- All PowerShell scripts must execute successfully on Windows
- All shell scripts must be syntax-validated for POSIX compliance
- Documentation must include both Windows and Linux examples
- Configuration files must be properly externalized

### Before Any Deployment
- Container images must build successfully on development machines
- Kubernetes manifests must validate against cluster schemas
- Health checks must pass in both local and remote deployment scenarios
- All secrets and credentials must be properly externalized

## Governance

This constitution supersedes all other development practices and deployment procedures. All code reviews must verify compliance with cross-platform standards and deployment model requirements. Changes to deployment architecture or script standards require constitutional amendment through documented proposal and approval process.

**Version**: 1.2.0 | **Ratified**: 2025-10-14 | **Last Amended**: 2025-10-14