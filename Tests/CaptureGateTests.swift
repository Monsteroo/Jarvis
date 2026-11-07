import Foundation

@main
struct CaptureGateTests {
    static func main() {
        var gate = CaptureGate()
        assert(!gate.recording, "Launch must never record")
        assert(!gate.press(enabled: false, authorized: true, ready: true))
        assert(!gate.recording, "Authorization alone must not enable capture")
        _ = gate.release()
        assert(!gate.press(enabled: true, authorized: false, ready: true))
        assert(!gate.recording, "A denied or pending permission must not record")
        // Permission resolving while held must not replay the press.
        assert(!gate.press(enabled: true, authorized: true, ready: true))
        assert(!gate.release())
        assert(!gate.recording)
        assert(gate.press(enabled: true, authorized: true, ready: true))
        assert(!gate.press(enabled: true, authorized: true, ready: true), "Key repeats must not restart")
        assert(gate.release(), "Release requests one stop")
        assert(!gate.release(), "Duplicate release must not transcribe again")
        assert(!gate.press(enabled: true, authorized: true, ready: false), "Loading/inference must not record")
        _ = gate.release()
        assert(gate.press(enabled: true, authorized: true, ready: true))
        gate.cancel()
        assert(!gate.recording, "Esc/sleep/timeout must stop capture")
        assert(!gate.press(enabled: true, authorized: true, ready: true), "Cancel while held must require release")
        assert(!gate.release(), "Cancelled audio must not be transcribed")
        assert(gate.press(enabled: true, authorized: true, ready: true), "Fresh press after cancellation works")
        print("CaptureGateTests: 19 lifecycle assertions passed")
    }
}
