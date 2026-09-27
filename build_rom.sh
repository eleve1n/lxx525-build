#!/bin/bash
set -e

cd /crave-devspaces/LOS

# 1. Initialize environment first
source build/envsetup.sh

# 2. Select target product
lunch lineage_LXX525-ap3a-userdebug

# 3. Clean targets using mka (which supports env setup)
mka installclean

# 4. Start compilation
mka bacon
