import Carbon
import Foundation
import SmsCodeCore

enum GlobalHotKeyAction: Equatable {
    case smartFallback
    case phoneAccount(UUID)
    case emailAccount(UUID)
}

struct GlobalHotKeyRegistration: Equatable {
    let shortcut: KeyboardShortcutDescriptor
    let action: GlobalHotKeyAction
}

final class GlobalHotKeyMonitor {
    private struct RegisteredHotKey {
        let ref: EventHotKeyRef
        let action: GlobalHotKeyAction
    }

    private var hotKeys: [UInt32: RegisteredHotKey] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var actionHandler: ((GlobalHotKeyAction) -> Void)?
    private let signature = fourCharCode("SCV2")

    @discardableResult
    func start(
        registrations: [GlobalHotKeyRegistration],
        handler: @escaping (GlobalHotKeyAction) -> Void
    ) -> [GlobalHotKeyRegistration] {
        stop()
        actionHandler = handler
        installEventHandlerIfNeeded()

        var failedRegistrations: [GlobalHotKeyRegistration] = []
        for (index, registration) in registrations.enumerated() {
            let hotKeyID = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                registration.shortcut.keyCode,
                registration.shortcut.modifierFlags,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            guard status == noErr, let hotKeyRef else {
                failedRegistrations.append(registration)
                continue
            }
            hotKeys[hotKeyID.id] = RegisteredHotKey(ref: hotKeyRef, action: registration.action)
        }
        return failedRegistrations
    }

    func stop() {
        for registered in hotKeys.values {
            UnregisterEventHotKey(registered.ref)
        }
        hotKeys.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        stop()
    }

    static func canRegister(_ shortcut: KeyboardShortcutDescriptor) -> Bool {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("SCTE"), id: 1)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        return status == noErr
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                let monitor = Unmanaged<GlobalHotKeyMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var incomingHotKeyID = EventHotKeyID()
                let error = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &incomingHotKeyID
                )

                guard error == noErr,
                      incomingHotKeyID.signature == monitor.signature,
                      let registered = monitor.hotKeys[incomingHotKeyID.id] else {
                    return noErr
                }

                DispatchQueue.main.async {
                    monitor.actionHandler?(registered.action)
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.utf16.prefix(4) {
        result = (result << 8) + OSType(scalar)
    }
    return result
}
