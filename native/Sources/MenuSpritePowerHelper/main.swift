import Foundation
import IOKit
import IOKit.pwr_mgt
import PowerControl

private final class Endpoint: NSObject, PowerHelperProtocol {
    let controller: PowerController
    init(_ controller: PowerController) { self.controller = controller }
    func perform(_ data: Data, withReply reply: @escaping (Data)->Void) {
        DispatchQueue.main.async {
            let result: PowerSnapshot
            if data.count <= 4096, let request = try? JSONDecoder().decode(PowerRequest.self,from:data) { result = self.controller.handle(request) }
            else { var s = self.controller.snapshot(); s.error = "Invalid request"; result = s }
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
    }
}
private final class Server: NSObject, NSXPCListenerDelegate {
    let controller = PowerController()
    private let ownershipLock = NSLock()
    private var owner: NSXPCConnection?
    var hasOwner: Bool { ownershipLock.lock(); defer { ownershipLock.unlock() }; return owner != nil }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        ownershipLock.lock()
        guard connection.effectiveUserIdentifier != 0, owner == nil else { ownershipLock.unlock(); return false }
        owner = connection
        ownershipLock.unlock()
        connection.exportedInterface = NSXPCInterface(with:PowerHelperProtocol.self)
        connection.exportedObject = Endpoint(controller)
        connection.invalidationHandler = { [weak self] in DispatchQueue.main.async {
            guard let self else { return }
            do { try self.controller.restoreAll() } catch { self.controller.lastError = error.localizedDescription }
            self.controller.schedule(); self.ownershipLock.lock(); self.owner = nil; self.ownershipLock.unlock()
        }}
        connection.resume(); return true
    }
}
if CommandLine.arguments.contains("--probe") {
    let data = try JSONEncoder().encode(BatteryHardware().snapshot())
    print(String(decoding:data,as:UTF8.self)); exit(0)
}
guard geteuid() == 0 else { fputs("Run the installed launch daemon; --probe is read-only.\n",stderr); exit(1) }
if CommandLine.arguments.contains("--restore") {
    let controller = PowerController()
    do { try controller.restoreAll(); exit(0) } catch { fputs("Recovery failed: \(error.localizedDescription)\n",stderr); exit(1) }
}
private let server = Server()
let listener = NSXPCListener(machServiceName:PowerIdentity.service)
listener.setConnectionCodeSigningRequirement(PowerIdentity.appRequirement)
listener.delegate = server
var notifier: io_object_t = 0
var port: IONotificationPortRef?
var powerConnection: io_connect_t = 0
// IOKit/IOMessage.h: iokit_common_msg(0x280/0x270); C macros are not imported by Swift.
powerConnection = IORegisterForSystemPower(nil,&port,{ _, _, message, argument in
    if message == 0xe0000280 {
        do { try server.controller.restoreAll() } catch { server.controller.lastError = error.localizedDescription }
        server.controller.schedule()
    }
    if message == 0xe0000280 || message == 0xe0000270 {
        IOAllowPowerChange(powerConnection, Int(bitPattern:argument))
    }
},&notifier)
guard powerConnection != 0, port != nil else { fputs("System sleep notification registration failed; controls unavailable.\n",stderr); exit(1) }
if let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() { CFRunLoopAddSource(CFRunLoopGetMain(),source,.defaultMode) }
let idleTimer = Timer.scheduledTimer(withTimeInterval:120,repeats:true) { _ in
    if !server.hasOwner && !server.controller.active && !server.controller.needsRecovery { exit(0) }
}
idleTimer.tolerance = 15
listener.resume()
RunLoop.main.run()
