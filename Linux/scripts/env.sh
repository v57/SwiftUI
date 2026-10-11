# Environment for the Linux (GTK) test VM. Source it: `. Linux/scripts/env.sh`.
# The VM is an Ubuntu desktop (arm64) UTM bundle using Apple Virtualization, created by
# Linux/scripts/create-vm; SwiftUI is synced into ~/SwiftUI there and built with Swift 6.3.3.
export SWIFTUI_VM_DIR="${SWIFTUI_VM_DIR:-$HOME/Downloads/VMs}"
export SWIFTUI_VM_NAME="${SWIFTUI_VM_NAME:-Ubuntu}"
export SWIFTUI_VM_BUNDLE="$SWIFTUI_VM_DIR/$SWIFTUI_VM_NAME.utm"
export SWIFTUI_VM_USER="${SWIFTUI_VM_USER:-v57}"
export SWIFTUI_VM_SWIFT="${SWIFTUI_VM_SWIFT:-/opt/swift/usr/bin}"
SWIFTUI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SWIFTUI_ROOT
export SWIFTUI_VZRUN="$SWIFTUI_ROOT/.build-linux/vzrun"
