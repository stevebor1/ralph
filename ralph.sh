#!/usr/bin/env bash
# Cross-platform entry point — delegates to ralph.ps1 via PowerShell Core (pwsh).
# Install pwsh: https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell
exec pwsh -File "$(dirname "$0")/ralph.ps1" "$@"
