import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentInteractionControllerDelegate {
  private var downloadChannel: FlutterMethodChannel?
  private var documentController: UIDocumentInteractionController?
  private let redirectDelegate = PdfSessionDelegate()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    WebFileUpload.install()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.nxp.eauto/downloads",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    downloadChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "Couldn't save the PDF", details: nil))
        return
      }
      switch call.method {
      case "downloadUrl":
        self.downloadUrl(call, result: result)
      case "saveBytes":
        self.saveBytes(call, result: result)
      case "openFile":
        self.openFile(call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    topViewController() ?? UIViewController()
  }

  private func downloadUrl(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let url = args["url"] as? String else {
      result(FlutterError(code: "bad_args", message: "Invalid download link", details: nil))
      return
    }
    let filename = args["filename"] as? String
    let userAgent = args["userAgent"] as? String
    let referrer = args["referrer"] as? String
    Task {
      do {
        let saved = try await PdfFileStore.download(
          urlString: url,
          filenameHint: filename,
          userAgent: userAgent,
          referrer: referrer,
          redirectDelegate: redirectDelegate
        )
        DispatchQueue.main.async { result(saved) }
      } catch let error as PdfDownloadError {
        DispatchQueue.main.async {
          result(FlutterError(code: error.flutterCode, message: error.localizedDescription, details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "download_failed",
            message: "Couldn't download the PDF. Check your connection and try again.",
            details: nil
          ))
        }
      }
    }
  }

  private func saveBytes(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "Couldn't save the PDF", details: nil))
      return
    }
    let data: Data
    if let typed = args["bytes"] as? FlutterStandardTypedData {
      data = typed.data
    } else if let raw = args["bytes"] as? Data {
      data = raw
    } else {
      result(FlutterError(code: "bad_args", message: "The PDF was empty", details: nil))
      return
    }
    let filename = args["filename"] as? String
    Task {
      do {
        let saved = try PdfFileStore.save(data: data, filenameHint: filename)
        DispatchQueue.main.async { result(saved) }
      } catch let error as PdfDownloadError {
        DispatchQueue.main.async {
          result(FlutterError(code: error.flutterCode, message: error.localizedDescription, details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "download_failed", message: "Couldn't save the PDF", details: nil))
        }
      }
    }
  }

  private func openFile(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String else {
      result(FlutterError(code: "bad_args", message: "Couldn't open the PDF", details: nil))
      return
    }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      result(FlutterError(code: "open_failed", message: "Couldn't open the PDF", details: nil))
      return
    }
    let controller = UIDocumentInteractionController(url: url)
    controller.delegate = self
    controller.name = url.lastPathComponent
    controller.uti = "com.adobe.pdf"
    documentController = controller
    if controller.presentPreview(animated: true) {
      result(true)
    } else {
      result(FlutterError(code: "no_app", message: "No app found to open PDFs", details: nil))
    }
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}

private enum PdfDownloadError: LocalizedError {
  case notPdf
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .notPdf:
      return "This file is not a PDF"
    case .failed(let message):
      return message
    }
  }

  var flutterCode: String {
    switch self {
    case .notPdf:
      return "not_pdf"
    case .failed:
      return "download_failed"
    }
  }
}

private final class PdfSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    Task {
      var next = request
      if let agent = task.originalRequest?.value(forHTTPHeaderField: "User-Agent") {
        next.setValue(agent, forHTTPHeaderField: "User-Agent")
      }
      if let referer = task.originalRequest?.value(forHTTPHeaderField: "Referer") {
        next.setValue(referer, forHTTPHeaderField: "Referer")
      }
      if let url = next.url {
        let header = await PdfFileStore.cookieHeader(for: url)
        next.setValue(header.isEmpty ? nil : header, forHTTPHeaderField: "Cookie")
      }
      completionHandler(next)
    }
  }
}

private enum PdfFileStore {
  private static let maxBytes = 80 * 1024 * 1024
  private static let defaultUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  static func download(
    urlString: String,
    filenameHint: String?,
    userAgent: String?,
    referrer: String?,
    redirectDelegate: PdfSessionDelegate
  ) async throws -> [String: String] {
    guard let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      throw PdfDownloadError.failed("Invalid download link")
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 120
    request.setValue("application/pdf,application/octet-stream,*/*", forHTTPHeaderField: "Accept")
    let agent = userAgent?.isEmpty == false ? userAgent! : defaultUserAgent
    request.setValue(agent, forHTTPHeaderField: "User-Agent")
    if let referrer, referrer.hasPrefix("http"), referrer != urlString {
      request.setValue(referrer, forHTTPHeaderField: "Referer")
    }
    let cookies = await cookieHeader(for: url)
    if !cookies.isEmpty {
      request.setValue(cookies, forHTTPHeaderField: "Cookie")
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 180
    let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw PdfDownloadError.failed("Couldn't download the PDF")
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw PdfDownloadError.failed("Please sign in and try again")
    }
    guard (200...299).contains(http.statusCode) else {
      throw PdfDownloadError.failed("Couldn't download the PDF (\(http.statusCode))")
    }
    if data.count > maxBytes {
      throw PdfDownloadError.failed("The PDF is too large to save")
    }
    let mime = http.value(forHTTPHeaderField: "Content-Type") ?? ""
    let disposition = http.value(forHTTPHeaderField: "Content-Disposition")
    let filename = sanitize(filenameFromContentDisposition(disposition) ?? filenameHint ?? filename(from: url))
    guard looksLikePdf(data, mime: mime) else {
      throw PdfDownloadError.notPdf
    }
    return try write(data, filename: filename)
  }

  static func save(data: Data, filenameHint: String?) throws -> [String: String] {
    if data.isEmpty {
      throw PdfDownloadError.failed("The PDF was empty")
    }
    if data.count > maxBytes {
      throw PdfDownloadError.failed("The PDF is too large to save")
    }
    guard looksLikePdf(data, mime: "application/pdf") else {
      throw PdfDownloadError.notPdf
    }
    return try write(data, filename: sanitize(filenameHint ?? "document.pdf"))
  }

  static func cookieHeader(for url: URL) async -> String {
    let cookies = await allCookies()
    guard let host = url.host?.lowercased() else { return "" }
    let path = url.path.isEmpty ? "/" : url.path
    let secure = url.scheme?.lowercased() == "https"
    return cookies.compactMap { cookie -> String? in
      if cookie.isSecure && !secure { return nil }
      var domain = cookie.domain.lowercased()
      if domain.hasPrefix(".") { domain.removeFirst() }
      let hostMatches = host == domain || host.hasSuffix(".\(domain)")
      let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
      guard hostMatches, path.hasPrefix(cookiePath) else { return nil }
      return "\(cookie.name)=\(cookie.value)"
    }.joined(separator: "; ")
  }

  private static func allCookies() async -> [HTTPCookie] {
    await withCheckedContinuation { continuation in
      WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
        continuation.resume(returning: cookies)
      }
    }
  }

  private static func write(_ data: Data, filename: String) throws -> [String: String] {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let destination = uniqueFileURL(directory: directory, filename: filename)
    do {
      try data.write(to: destination, options: .atomic)
    } catch {
      throw PdfDownloadError.failed("Couldn't save the PDF")
    }
    return [
      "path": destination.path,
      "filename": destination.lastPathComponent,
      "location": "the Files app",
    ]
  }

  private static func uniqueFileURL(directory: URL, filename: String) -> URL {
    var candidate = directory.appendingPathComponent(filename)
    let base = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension
    var index = 1
    while FileManager.default.fileExists(atPath: candidate.path) && index < 100 {
      let next = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
      candidate = directory.appendingPathComponent(next)
      index += 1
    }
    return candidate
  }

  private static func looksLikePdf(_ data: Data, mime: String) -> Bool {
    if data.isEmpty { return false }
    let sample = data.prefix(1024)
    let text = String(data: sample, encoding: .isoLatin1) ?? ""
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.hasPrefix("<!") || lower.hasPrefix("<html") || lower.hasPrefix("<?xml") || trimmed.hasPrefix("{") {
      return false
    }
    if text.contains("%PDF") { return true }
    return mime.lowercased().contains("pdf")
  }

  private static func filenameFromContentDisposition(_ header: String?) -> String? {
    guard let header, !header.isEmpty else { return nil }
    var star: String?
    var plain: String?
    for part in header.split(separator: ";") {
      let item = part.trimmingCharacters(in: .whitespaces)
      guard let separator = item.firstIndex(of: "=") else { continue }
      let key = item[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = item[item.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      if key == "filename*" {
        star = String(value)
      } else if key == "filename" {
        plain = String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      }
    }
    if var star {
      if let marker = star.range(of: "''") {
        star = String(star[marker.upperBound...])
      }
      star = star.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      let decoded = star.removingPercentEncoding ?? star
      return decoded.isEmpty ? nil : decoded
    }
    if let plain, !plain.isEmpty { return plain }
    return nil
  }

  private static func filename(from url: URL) -> String {
    let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    if last.isEmpty || last == "/" { return "document.pdf" }
    return last.components(separatedBy: ";").first ?? last
  }

  private static func sanitize(_ raw: String) -> String {
    var name = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "document"
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
    name = name.components(separatedBy: illegal).joined(separator: "_")
    if name.count > 120 { name = String(name.prefix(120)) }
    if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
    if name == ".pdf" || name.isEmpty { name = "document.pdf" }
    return name
  }
}
