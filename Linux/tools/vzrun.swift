// Headless runner for a UTM Apple-backend Linux bundle (the same virtual hardware UTM sets up),
// for installing and running the GTK test VM without UTM's UI. Built by Linux/scripts/vm.
//   vzrun init <bundle>                 create Data/efi_vars.fd, print a machine identifier (base64)
//   vzrun run <bundle> [--iso <path>]   boot headless; serial console -> <bundle>/../<name>-console.log
//                                       (input: the <name>-console.in FIFO); SIGTERM = ACPI power off
// Never run it while UTM runs the same VM.
import Foundation
import Virtualization

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let args = CommandLine.arguments
guard args.count >= 3 else { die("usage: vzrun init|run <bundle.utm> [--iso path]") }
let bundle = URL(fileURLWithPath: args[2])
let data = bundle.appendingPathComponent("Data")
let efiURL = data.appendingPathComponent("efi_vars.fd")

if args[1] == "init" {
    _ = try VZEFIVariableStore(creatingVariableStoreAt: efiURL, options: [.allowOverwrite])
    print(VZGenericMachineIdentifier().dataRepresentation.base64EncodedString())
    exit(0)
}

let plist = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: bundle.appendingPathComponent("config.plist")), format: nil) as! [String: Any]
let system = plist["System"] as! [String: Any]
let platformDict = system["GenericPlatform"] as! [String: Any]
let drives = plist["Drive"] as! [[String: Any]]
let networks = plist["Network"] as! [[String: Any]]

let config = VZVirtualMachineConfiguration()
config.cpuCount = system["CPUCount"] as! Int
config.memorySize = UInt64(system["MemorySize"] as! Int) * 1024 * 1024
let platform = VZGenericPlatformConfiguration()
platform.machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: platformDict["machineIdentifier"] as! Data)!
config.platform = platform
let loader = VZEFIBootLoader()
loader.variableStore = VZEFIVariableStore(url: efiURL)
config.bootLoader = loader

var storage: [VZStorageDeviceConfiguration] = []
for d in drives {
    guard let name = d["ImageName"] as? String else { continue }
    let att = try VZDiskImageStorageDeviceAttachment(
        url: data.appendingPathComponent(name), readOnly: d["ReadOnly"] as? Bool ?? false,
        cachingMode: .cached, synchronizationMode: .full)
    storage.append(VZVirtioBlockDeviceConfiguration(attachment: att))
}
if let i = args.firstIndex(of: "--iso"), i + 1 < args.count {
    let att = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: args[i + 1]), readOnly: true)
    storage.append(VZUSBMassStorageDeviceConfiguration(attachment: att))
}
config.storageDevices = storage

config.networkDevices = networks.map { n in
    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    net.macAddress = VZMACAddress(string: n["MacAddress"] as! String)!
    return net
}
let gpu = VZVirtioGraphicsDeviceConfiguration()
gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1080)]
config.graphicsDevices = [gpu]
config.keyboards = [VZUSBKeyboardConfiguration()]
config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

let logURL = bundle.deletingLastPathComponent().appendingPathComponent(
    bundle.deletingPathExtension().lastPathComponent + "-console.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
/// Console input: a FIFO next to the log (`printf 'cmd\n' > <name>-console.in`).
func consoleInput() -> FileHandle {
    let path = logURL.deletingLastPathComponent().appendingPathComponent(
        bundle.deletingPathExtension().lastPathComponent + "-console.in").path
    unlink(path)
    mkfifo(path, 0o600)
    return FileHandle(fileDescriptor: open(path, O_RDWR), closeOnDealloc: true)
}
let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
serial.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: consoleInput(),
    fileHandleForWriting: try FileHandle(forWritingTo: logURL))
config.serialPorts = [serial]

try config.validate()

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) { print("guest stopped"); exit(0) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { die("stopped with error: \(error)") }
}
let delegate = Delegate()
let vm = VZVirtualMachine(configuration: config)
vm.delegate = delegate

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var stopSources: [DispatchSourceSignal] = []
var shutdownRequested = false
for sig in [SIGTERM, SIGINT] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        // First signal: ACPI power button. Second: hard stop.
        if !shutdownRequested, vm.canRequestStop, (try? vm.requestStop()) != nil {
            shutdownRequested = true; print("requested guest shutdown")
        } else {
            vm.stop { _ in exit(0) }
        }
    }
    src.resume()
    stopSources.append(src)
}

vm.start { result in
    if case .failure(let e) = result { die("start failed: \(e)") }
    print("started; console -> \(logURL.path)")
}
dispatchMain()
