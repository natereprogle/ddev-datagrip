#!/usr/bin/env bash
# shellcheck shell=bash
#
# datagrip-lib/versions/unsupported.sh
# Sourced when the DataGrip version predates all supported versions.

echo "❌ DataGrip ${DATAGRIP_VERSION} is below the minimum supported version (2025.2.5)."
echo "   Please upgrade DataGrip to 2025.2.5 or newer."
echo ""
echo "   If you have multiple DataGrip versions installed and the wrong one was detected,"
echo "   pin the version you want to use:"
echo "     ddev datagrip config set datagrip-version <version>"
return 1
