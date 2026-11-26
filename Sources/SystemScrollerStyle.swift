import AppKit
import CoreFoundation
import IOKit.hid

@MainActor
final class SystemScrollerStyle: NSObject {
    private let manager = IOHIDManagerCreate(nil, 0)
    private(set) var isLegacy = false
    var onChange: (() -> Void)?

    #if DEBUG
    var styleDescription: String { isLegacy ? "legacy" : "overlay" }
    #endif

    override init() {
        super.init()
        let matching = [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer].map { usage in
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: usage]
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let devicesChanged: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }

            let observer = Unmanaged<SystemScrollerStyle>.fromOpaque(context).takeUnretainedValue()
            // IOHIDManager removes the device after invoking the callback.
            DispatchQueue.main.async { [weak observer] in observer?.refresh() }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, devicesChanged, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, devicesChanged, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(settingsChanged), name: Notification.Name("AppleShowScrollBarsSettingChanged"), object: nil, suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        refresh()
    }

    isolated deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    @objc private nonisolated func settingsChanged(_: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        var preference = CFPreferencesCopyValue("AppleShowScrollBars" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        #if DEBUG
        preference = UserDefaults.standard.string(forKey: "snapshotScrollBars") ?? preference
        #endif
        let legacy: Bool
        if preference == "Always" {
            legacy = true
        } else if preference == "WhenScrolling" {
            legacy = false
        } else {
            let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
            legacy = devices.contains { device in
                let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? NSNumber
                guard builtIn?.boolValue != true else { return false }

                let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "").lowercased()
                guard !product.contains("trackpad"), !product.contains("magic mouse") else { return false }

                let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
                return ![kIOHIDTransportSPIValue, kIOHIDTransportI2CValue, kIOHIDTransportFIFOValue, kIOHIDTransportVirtualValue].contains(transport)
            }
        }
        guard legacy != isLegacy else { return }

        isLegacy = legacy
        onChange?()
    }
}
