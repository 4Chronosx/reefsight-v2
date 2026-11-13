import Flutter
import ImageIO
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
      case "photoMetadata":
        // Issue #5: an imported photo's header (HEIC and anything else
        // Dart can't parse), read by `NativePhotoMetadataReader` in
        // lib/services/photo_metadata.dart. ImageIO reads properties only,
        // never decoding the image. Size is as stored; Dart applies the
        // orientation.
        guard let args = call.arguments as? [String: Any], let path = args["path"] as? String,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
          result(nil)
          return
        }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var reply: [String: Any] = [:]
        reply["width"] = props[kCGImagePropertyPixelWidth]
        reply["height"] = props[kCGImagePropertyPixelHeight]
        reply["orientation"] = props[kCGImagePropertyOrientation]
        reply["make"] = tiff[kCGImagePropertyTIFFMake]
        reply["model"] = tiff[kCGImagePropertyTIFFModel]
        reply["dateTimeOriginal"] = exif[kCGImagePropertyExifDateTimeOriginal]
        reply["offsetTimeOriginal"] = exif[kCGImagePropertyExifOffsetTimeOriginal]
        reply["focalLength35mm"] = exif[kCGImagePropertyExifFocalLenIn35mmFilm]
        result(reply)
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
