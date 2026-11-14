import CoreML
import Darwin
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
    if let registrar = registrar(forPlugin: "ReefSightCoreMlBench") {
      coreMlBench.register(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private let coreMlBench = CoreMlBench()

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

/// Issue #11: the Core ML speed test for the CoralscapesV2 SegFormer, driven by
/// `lib/services/coreml_benchmark.dart` on `reefsight/coreml_bench`. Dev-only.
/// Kept in this file because adding a Swift file needs `project.pbxproj` edits,
/// and there's no local Xcode (sub-plan 13). Every model call runs on one serial
/// queue, which also guards `models`; replies go back on the main thread.
private final class CoreMlBench {
  private let queue = DispatchQueue(label: "reefsight.coreml_bench", qos: .userInitiated)
  private var models: [Int: MLModel] = [:]
  private var nextHandle = 1

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "reefsight/coreml_bench", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
      switch call.method {
      case "footprint":
        result(CoreMlBench.footprint().map { NSNumber(value: $0) })
      case "deviceModel":
        result(CoreMlBench.machine())
      case "compile":
        self.queue.async { reply(self.run("compile_failed") { try self.compile(args) }) }
      case "computePlan":
        self.computePlan(args, reply)
      case "load":
        self.queue.async { reply(self.run("load_failed") { try self.load(args) }) }
      case "predict":
        self.queue.async { reply(self.run("predict_failed") { try self.predict(args) }) }
      case "unload":
        self.queue.async {
          if let handle = args["handle"] as? Int { self.models.removeValue(forKey: handle) }
          reply(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private struct BenchError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private func run(_ code: String, _ body: () throws -> Any?) -> Any? {
    do {
      return try body()
    } catch {
      return FlutterError(code: code, message: error.localizedDescription, details: nil)
    }
  }

  private static func millis(since start: CFAbsoluteTime) -> Double {
    (CFAbsoluteTimeGetCurrent() - start) * 1000
  }

  private static func units(_ raw: Any?) throws -> MLComputeUnits {
    switch raw as? String {
    case "all": return .all
    case "cpuAndGpu":
      if #available(iOS 14.0, *) { return .cpuAndGPU }
      throw BenchError(message: "CPU + GPU needs iOS 14")
    case "cpuOnly": return .cpuOnly
    case "cpuAndNeuralEngine":
      if #available(iOS 16.0, *) { return .cpuAndNeuralEngine }
      throw BenchError(message: "CPU + Neural Engine needs iOS 16")
    default:
      throw BenchError(message: "Unknown compute units: \(String(describing: raw))")
    }
  }

  private static func path(_ args: [String: Any], _ key: String) throws -> URL {
    guard let p = args[key] as? String else { throw BenchError(message: "Missing \(key)") }
    return URL(fileURLWithPath: p)
  }

  /// The app's `phys_footprint`: what jetsam counts against the memory limit.
  static func footprint() -> Int? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : nil
  }

  /// `utsname.machine`, e.g. "iPhone14,7" (iPhone 14).
  static func machine() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
  }

  /// Runs [body] while a background timer samples `phys_footprint` every
  /// 20 ms, and returns the highest value seen: the transient peak inside a
  /// Core ML call, which a reading before and after would miss.
  private static func withPeakFootprint<T>(_ body: () throws -> T) rethrows -> (T, Int?) {
    let sampler = DispatchQueue(label: "reefsight.coreml_bench.footprint")
    let lock = NSLock()
    var peak = CoreMlBench.footprint() ?? 0
    let timer = DispatchSource.makeTimerSource(queue: sampler)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
    timer.setEventHandler {
      if let now = CoreMlBench.footprint() {
        lock.lock()
        if now > peak { peak = now }
        lock.unlock()
      }
    }
    timer.resume()
    defer { timer.cancel() }
    let value = try body()
    timer.cancel()
    sampler.sync {}
    lock.lock()
    if let now = CoreMlBench.footprint(), now > peak { peak = now }
    let result = peak
    lock.unlock()
    return (value, result > 0 ? result : nil)
  }

  private func compile(_ args: [String: Any]) throws -> Any? {
    let source = try CoreMlBench.path(args, "mlpackagePath")
    let dest = try CoreMlBench.path(args, "destPath")
    let start = CFAbsoluteTimeGetCurrent()
    let compiled = try MLModel.compileModel(at: source)
    let ms = CoreMlBench.millis(since: start)
    let fm = FileManager.default
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: compiled, to: dest)
    return ["compiledPath": dest.path, "compileMs": ms]
  }

  private func load(_ args: [String: Any]) throws -> Any? {
    let url = try CoreMlBench.path(args, "compiledPath")
    let config = MLModelConfiguration()
    config.computeUnits = try CoreMlBench.units(args["computeUnits"])
    let ((model, ms), peak) = try CoreMlBench.withPeakFootprint { () throws -> (MLModel, Double) in
      let start = CFAbsoluteTimeGetCurrent()
      let m = try MLModel(contentsOf: url, configuration: config)
      return (m, CoreMlBench.millis(since: start))
    }
    let handle = nextHandle
    nextHandle += 1
    models[handle] = model
    var reply: [String: Any] = ["handle": handle, "loadMs": ms]
    if let peak = peak { reply["peakFootprintBytes"] = peak }
    return reply
  }

  /// Times `prediction(from:)` alone: the PNG is decoded into the model's input
  /// before the clock starts, and the maps are written after it stops.
  private func predict(_ args: [String: Any]) throws -> Any? {
    guard let handle = args["handle"] as? Int, let model = models[handle] else {
      throw BenchError(message: "No loaded model for this handle")
    }
    let inputs = model.modelDescription.inputDescriptionsByName
    guard let input = inputs.first(where: { $0.value.type == .image }),
          let constraint = input.value.imageConstraint else {
      throw BenchError(message: "The model has no image input")
    }
    let image = try MLFeatureValue(
      imageAt: try CoreMlBench.path(args, "inputPath"), constraint: constraint, options: nil)
    let provider = try MLDictionaryFeatureProvider(dictionary: [input.key: image])

    let ((output, ms), peak) = try CoreMlBench.withPeakFootprint { () throws -> (MLFeatureProvider, Double) in
      let start = CFAbsoluteTimeGetCurrent()
      let o = try model.prediction(from: provider)
      return (o, CoreMlBench.millis(since: start))
    }

    guard let outName = model.modelDescription.outputDescriptionsByName
            .first(where: { $0.value.type == .multiArray })?.key,
          let logits = output.featureValue(for: outName)?.multiArrayValue,
          logits.shape.count == 4, logits.shape[1].intValue > 0 else {
      throw BenchError(message: "Expected a 1 x C x H x W logits output with C > 0")
    }
    let shape = logits.shape.map { $0.intValue }
    var reply: [String: Any] = ["ms": ms, "mapWidth": shape[3], "mapHeight": shape[2]]
    if let argmax = args["argmaxPath"] as? String, let conf = args["confidencePath"] as? String {
      // Notebook 29 exports float32 logits; reading anything else element by
      // element would take minutes, so refuse it instead.
      guard logits.dataType == .float32 else {
        throw BenchError(message: "Logits are not float32; re-export with notebook 29")
      }
      let (cls, prob, nonFinite) = CoreMlBench.argmax(logits)
      try Data(cls).write(to: URL(fileURLWithPath: argmax))
      try Data(prob).write(to: URL(fileURLWithPath: conf))
      reply["nonFinitePixels"] = nonFinite
    }
    if let bytes = CoreMlBench.footprint() { reply["footprintBytes"] = bytes }
    if let peak = peak { reply["peakFootprintBytes"] = peak }
    return reply
  }

  /// Per pixel: the top class (uint8) and its softmax probability (uint8,
  /// x255), plus how many pixels had NaN or infinite logits (FP16 overflow on
  /// the Neural Engine or GPU). Those get class 0 and probability 0 instead of
  /// trapping on `Int(NaN)`.
  private static func argmax(_ logits: MLMultiArray) -> ([UInt8], [UInt8], Int) {
    let shape = logits.shape.map { $0.intValue }
    let strides = logits.strides.map { $0.intValue }
    let c = shape[1], h = shape[2], w = shape[3]
    var cls = [UInt8](repeating: 0, count: h * w)
    var prob = [UInt8](repeating: 0, count: h * w)
    var nonFinite = 0
    let f32 = logits.dataPointer.assumingMemoryBound(to: Float.self)
    var values = [Float](repeating: 0, count: c)
    for y in 0..<h {
      for x in 0..<w {
        var best = 0
        var finite = true
        for k in 0..<c {
          values[k] = f32[k * strides[1] + y * strides[2] + x * strides[3]]
          if !values[k].isFinite { finite = false }
          if values[k] > values[best] { best = k }
        }
        var sum: Float = 0
        if finite {
          for k in 0..<c { sum += expf(values[k] - values[best]) }
        }
        if !finite || !sum.isFinite || sum <= 0 {
          nonFinite += 1
          continue
        }
        cls[y * w + x] = UInt8(clamping: best)
        prob[y * w + x] = UInt8(clamping: Int((255 / sum).rounded()))
      }
    }
    return (cls, prob, nonFinite)
  }

  /// How many of the program's ops Core ML prefers to run on each device
  /// (`MLComputePlan`, iOS 17.4+): the on-phone stand-in for Xcode's report.
  private func computePlan(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
    guard #available(iOS 17.4, *) else {
      reply(["available": false])
      return
    }
    let url: URL
    let config = MLModelConfiguration()
    do {
      url = try CoreMlBench.path(args, "compiledPath")
      config.computeUnits = try CoreMlBench.units(args["computeUnits"])
    } catch {
      reply(FlutterError(code: "plan_failed", message: error.localizedDescription, details: nil))
      return
    }
    Task {
      do {
        let plan = try await MLComputePlan.load(contentsOf: url, configuration: config)
        var counts = ["neuralEngine": 0, "gpu": 0, "cpu": 0, "other": 0]
        if case let .program(program) = plan.modelStructure {
          for function in program.functions.values {
            CoreMlBench.count(function.block, plan, &counts)
          }
        }
        var out: [String: Any] = counts
        out["available"] = true
        reply(out)
      } catch {
        reply(FlutterError(code: "plan_failed", message: error.localizedDescription, details: nil))
      }
    }
  }

  @available(iOS 17.4, *)
  private static func count(
    _ block: MLModelStructure.Program.Block, _ plan: MLComputePlan, _ counts: inout [String: Int]
  ) {
    for op in block.operations {
      if let usage = plan.deviceUsage(for: op) {
        switch usage.preferred {
        case .neuralEngine: counts["neuralEngine", default: 0] += 1
        case .gpu: counts["gpu", default: 0] += 1
        case .cpu: counts["cpu", default: 0] += 1
        @unknown default: counts["other", default: 0] += 1
        }
      } else {
        counts["other", default: 0] += 1
      }
      for inner in op.blocks { count(inner, plan, &counts) }
    }
  }
}
