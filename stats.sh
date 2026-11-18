#!/usr/bin/env bash
# Compatibility entry point for existing manual calls.
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/backup.sh" space "$@"
