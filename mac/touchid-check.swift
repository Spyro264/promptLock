import Foundation
import LocalAuthentication

let reason = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "authorize this action"
let context = LAContext()
var error: NSError?
guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
    fputs("Touch ID unavailable: \(error?.localizedDescription ?? "unknown")\n", stderr)
    exit(1)
}
let sema = DispatchSemaphore(value: 0)
var ok = false
context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, err in
    ok = success
    if !success { fputs("Authentication failed\n", stderr) }
    sema.signal()
}
sema.wait()
exit(ok ? 0 : 1)
