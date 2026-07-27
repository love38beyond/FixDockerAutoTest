#!/bin/bash
# Wrapper script for FixInitiator.py with Docker-friendly environment variable support.
# Run with: FIX_HOST=192.168.1.100 bash launcher.sh
export FIX_HOST="${FIX_HOST:-10.3.138.139}"
export FIX_PORT="${FIX_PORT:-61111}"
cd "$(dirname "$0")"
PYTHON=$(command -v python3.6 || command -v python36 || command -v python3 || command -v python)
$PYTHON FixInitiator.py "$@"
