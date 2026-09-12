#!/bin/bash
set -e

rm -rf device/lava/LXX525 vendor/lava/LXX525

git clone https://github.com/eleve1n/android_device_lava_LXX525-lineage \
    --depth 1 -b lineage-22.1 \
    device/lava/LXX525

git clone https://github.com/eleve1n/android_vendor_lava_LXX525 \
    --depth 1 -b lineage-22.1 \
    vendor/lava/LXX525

source build/envsetup.sh
lunch lineage_LXX525-ap3a-userdebug
m bacon