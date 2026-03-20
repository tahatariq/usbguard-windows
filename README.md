# USB-Block

A comprehensive USB device management and security solution featuring both standalone and enterprise (BigFix) deployment options.

## Overview

USB-Block provides powerful USB device control and monitoring capabilities to enhance system security and prevent unauthorized data transfer. With two deployment approaches, it can be adapted to individual users or enterprise environments.

**Language Composition:**
- PowerShell (53.7%)
- HTML (45.7%)
- Batch (0.6%)

## Project Structure

```
usb-block/
├── USBGuard-Standalone/      # Standalone deployment
│   ├── USBGuard.ps1          # Core PowerShell script
│   ├── USBGuard_Advanced.ps1 # Advanced configuration module
│   ├── USBGuard.hta          # Interactive GUI application
│   ├── Launch_USBGuard.bat   # Batch launcher
│   └── README.md             # Standalone documentation
│
└── USBGuard-BigFix/          # Enterprise/BigFix deployment
    └── [Enterprise-specific files]
```

## Features

### USBGuard Standalone
A complete USB device management solution that includes:
- **Interactive GUI** - User-friendly HTA interface for easy management
- **PowerShell Core** - Robust scripting engine for device control
- **Advanced Settings** - Fine-grained configuration options
- **Easy Deployment** - Simple batch-based launcher

### USBGuard BigFix
Enterprise-grade deployment designed for:
- Large-scale IT environments
- Centralized device management
- Policy-based USB control
- Integration with BigFix infrastructure

## Getting Started

### Standalone Deployment

1. Navigate to the `USBGuard-Standalone` directory
2. Run `Launch_USBGuard.bat` to start the application
3. Refer to `USBGuard-Standalone/README.md` for detailed usage instructions

### Enterprise Deployment

1. For BigFix integration, see the `USBGuard-BigFix` directory
2. Follow enterprise deployment procedures for your environment

## Key Components

| Component | Type | Purpose |
|-----------|------|---------|
| USBGuard.ps1 | PowerShell | Main script for USB device control and monitoring |
| USBGuard_Advanced.ps1 | PowerShell | Advanced configuration and settings management |
| USBGuard.hta | HTML/VBScript | Interactive graphical user interface |
| Launch_USBGuard.bat | Batch | Simple launcher script |

## Requirements

- Windows operating system
- PowerShell (version compatible with scripts)
- Administrator privileges for USB device management
- For HTA: Windows with HTA support enabled

## Usage

### Basic Usage
```powershell
.\USBGuard.ps1
```

### With Advanced Options
```powershell
.\USBGuard_Advanced.ps1
```

### GUI Interface
```batch
Launch_USBGuard.bat
```

## Configuration

Refer to the documentation within each deployment folder:
- **Standalone:** `USBGuard-Standalone/README.md`
- **Enterprise:** Consult your BigFix administrator

## Security Considerations

- Always run with appropriate administrator privileges
- Review USB policies before deployment
- Test in non-production environments first
- Keep scripts
