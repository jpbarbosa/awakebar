import Foundation
import IOKit.pwr_mgt   // IOPMAssertion*, to hold the Mac awake

// MARK: - Power assertion

// A single IOKit power assertion that AwakeBar holds itself. `set(true)`
// creates it (idempotent), `set(false)` releases it; `held` reflects the
// current state. PreventUserIdleSystemSleep mirrors `caffeinate -i`: the Mac
// stays awake but the display may still sleep.
@MainActor
final class PowerAssertion {
    private let name: String
    private var id: IOPMAssertionID = 0
    private(set) var held = false

    init(_ name: String) { self.name = name }

    func set(_ active: Bool) {
        if active, !held {
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name as CFString,
                &newID)
            if result == kIOReturnSuccess {
                id = newID
                held = true
            } else {
                NSLog("AwakeBar: power assertion '%@' failed (0x%08x)", name, result)
            }
        } else if !active, held {
            IOPMAssertionRelease(id)
            id = 0
            held = false
        }
    }
}
