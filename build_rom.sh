#!/bin/bash
set -e

# Navigate to workspace root
cd /crave-devspaces/LOS

# Clean build output artifacts (without deleting source trees)
make installclean

# Initialize environment
source build/envsetup.sh

# Select target
lunch lineage_LXX525-ap3a-userdebug

# Execute build
mka bacon
