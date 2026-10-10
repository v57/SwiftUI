# Environment for the Linux (GTK) test VM. Source it: `. Linux/scripts/env.sh`.
# The VM is an Ubuntu desktop (arm64) UTM bundle using Apple Virtualization, created by
# Linux/scripts/create-vm; SwiftUI2 is synced into ~/SwiftUI2 there and built with Swift 6.3.3.
export SWIFTUI2_VM_DIR="${SWIFTUI2_VM_DIR:-$HOME/Downloads/VMs}"
export SWIFTUI2_VM_NAME="${SWIFTUI2_VM_NAME:-Ubuntu}"
export SWIFTUI2_VM_BUNDLE="$SWIFTUI2_VM_DIR/$SWIFTUI2_VM_NAME.utm"
export SWIFTUI2_VM_USER="${SWIFTUI2_VM_USER:-v57}"
export SWIFTUI2_VM_SWIFT="${SWIFTUI2_VM_SWIFT:-/opt/swift/usr/bin}"
SWIFTUI2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SWIFTUI2_ROOT
export SWIFTUI2_VZRUN="$SWIFTUI2_ROOT/.build-linux/vzrun"
