# Zetaris Lightning Installer

An automated deployment tool for setting up the complete Zetaris Lightning data virtualization platform on Kubernetes.

## Overview

The Zetaris Lightning Installer is a comprehensive bash-based deployment script that automates the installation of the Zetaris Lightning platform and all its dependencies on a Kubernetes cluster. This installer handles the complete setup process, from infrastructure components to the Zetaris Lightning services, providing a one-command deployment solution.

## What is Zetaris Lightning?

Zetaris Lightning is a data virtualization platform that enables organizations to query and analyze data across multiple sources without the need to move or copy data. It provides a unified view of distributed data sources through a single interface.

## Architecture Components

The installer deploys the following components in sequence:

### Infrastructure & Dependencies
- **Helm** - Package manager for Kubernetes
- **Kubernetes Environment** - Namespaces, service accounts, and RBAC
- **PostgreSQL** - Primary database for metadata and audit logs
- **Certificate Manager** - SSL/TLS certificate management
- **Spark Operator** - Apache Spark workload management

### Core Zetaris Services
- **Lightning Server** - Core data virtualization engine
- **Lightning API** - RESTful API services
- **Lightning GUI** - Web-based user interface
- **Lightning Zeppelin** - Notebook interface for data analysis

### Data & Search Services
- **OpenSearch** - Search and analytics engine
- **Lightning Solr** - Search indexing service

### AI & Advanced Features
- **Private AI** - AI services with privacy controls
- **Digiavatar** - Digital avatar services

### Optional Components
- **Airflow** - Workflow orchestration (commented out by default)

## Prerequisites

- Kubernetes cluster (1.20+)
- `kubectl` configured and connected to your cluster
- `curl` for downloading Helm
- Sufficient cluster resources (CPU, memory, storage)
- Network connectivity to pull Docker images

## Installation

### 1. Configuration

Edit the configuration file to match your environment:

```bash
vim config/zetaris.conf
```

Key configuration parameters:
- `ZETARIS_TOKEN`: Your Zetaris license token
- `ENVIRONMENT`: Deployment environment (local/dev/prod)
- `STORAGE_CLASS`: Kubernetes storage class for persistent volumes
- `DNS_DOMAIN`: Base domain for your deployment
- `DB_PASSWORD`: PostgreSQL password

### 2. Generate Keys (if needed)

```bash
./scripts/generate-keys.sh
```

### 3. Run the Installer

```bash
./install-zetaris.sh
```

The installer will:
1. Validate prerequisites
2. Setup Helm repositories
3. Deploy all components in the correct order
4. Create initial user accounts
5. Provide deployment summary and access information

## Directory Structure

```
zetaris-installer/
├── install-zetaris.sh          # Main installation script
├── config/
│   └── zetaris.conf            # Configuration file
├── lib/                        # Function libraries
│   ├── logging-functions.sh    # Logging utilities
│   ├── k8s-functions.sh        # Kubernetes operations
│   ├── helm-functions.sh       # Helm operations
│   └── helm-*-functions.sh     # Component-specific functions
├── scripts/
│   └── generate-keys.sh        # Key generation utility
├── keys/                       # Generated keys and certificates
└── logs/                       # Installation logs
```

## Features

- **Automated Deployment**: One-command installation of the entire stack
- **Modular Architecture**: Component-specific functions for maintainability
- **Error Handling**: Comprehensive error checking and rollback capabilities
- **Logging**: Detailed logging for troubleshooting
- **Configuration-Driven**: Easily customizable through configuration files
- **Prerequisites Check**: Validates environment before deployment
- **Progress Tracking**: Real-time deployment progress updates

## Configuration Options

### Environment Types
- `local`: Single-node or development environment
- `dev`: Development cluster setup
- `prod`: Production-ready configuration

### Storage Classes
Configure persistent storage based on your cluster setup:
- `nfs-rwx`: NFS-based read-write-many storage
- `local-path`: Local node storage
- Custom storage classes as per your cluster

### DNS Configuration
- `DNS_PROTOCOL`: http or https
- `DNS_DOMAIN`: Base domain for services
- `BASE_DNS_NAME`: Specific domain for this deployment

## Post-Installation

After successful installation, the installer will provide:
- Service URLs and access information
- Initial user credentials
- Next steps for configuration
- Troubleshooting commands

## Troubleshooting

### View Logs
```bash
# Check installer logs
tail -f logs/install-$(date +%Y%m%d).log

# Check Kubernetes pod status
kubectl get pods -A

# Check specific component logs
kubectl logs -f deployment/lightning-server -n zetaris
```

### Common Issues
1. **Storage Class Issues**: Ensure your storage class supports the required access modes
2. **Resource Constraints**: Verify sufficient CPU/memory in your cluster
3. **Network Policies**: Check if network policies block inter-pod communication
4. **Image Pull Issues**: Verify access to required container registries

## Support

For support and additional documentation:
- Check the logs directory for detailed installation logs
- Review Kubernetes events: `kubectl get events -A`
- Verify component status: `kubectl get pods,svc,ingress -n zetaris`

## Security Notes

- The `keys/` directory contains sensitive certificates and is excluded from version control
- Default passwords should be changed in production environments
- Review and adjust RBAC policies as needed for your security requirements

## License

This installer is provided by Zetaris. Ensure you have appropriate licenses for all deployed components.