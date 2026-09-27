#!/bin/bash
set -e

# Move to the workspace root
cd /crave-devspaces/LOS

# Set up environment and target
source build/envsetup.sh
lunch lineage_LXX525-ap3a-userdebug

# Start compilation
mka bacon
