import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let thermalStreamHandler = ThermalStreamHandler()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "ReefSightDeviceChecks") {
      registerDeviceChecks(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Sub-plan 13 (pre-dive checks): free storage and the thermal state, read
  /// by `lib/services/device_info.dart`'s `PlatformDeviceInfo`. Kept minimal:
  /// there's no local macOS, so this only compiles on Codemagic.
  private func registerDeviceChecks(messenger: FlutterBinaryMessenger) {
    let device = FlutterMethodChannel(name: "reefsight/device", binaryMessenger: messenger)
    device.setMethodCallHandler { call, result in
      switch call.method {
      case "freeBytes":
        do {
          let values = try URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
          if let bytes = values.volumeAvailableCapacityForImportantUsage {
            result(NSNumber(value: bytes))
          } else {
            result(nil)
          }
        } catch {
          result(FlutterError(code: "unavailable", message: error.localizedDescription, details: nil))
        }
      case "thermalState":
        result(ProcessInfo.processInfo.thermalState.rawValue)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let thermal = FlutterEventChannel(name: "reefsight/thermal", binaryMessenger: messenger)
    thermal.setStreamHandler(thermalStreamHandler)
  }
}

/// Sends `ProcessInfo.thermalState.rawValue` on listen and on every
/// `thermalStateDidChangeNotification`.
private final class ThermalStreamHandler: NSObject, FlutterStreamHandler {
  private var observer: NSObjectProtocol?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    // A second listen without a cancel must not leave the first observer
    // sending to a stale sink.
    _ = onCancel(withArguments: nil)
    observer = NotificationCenter.default.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      events(ProcessInfo.processInfo.thermalState.rawValue)
    }
    events(ProcessInfo.processInfo.thermalState.rawValue)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let observer = observer {
      NotificationCenter.default.removeObserver(observer)
    }
    observer = nil
    return nil
  }
}
