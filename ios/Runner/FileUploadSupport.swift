import ObjectiveC
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import WebKit

private var webFileUploadDelegateKey: UInt8 = 0

enum WebFileUpload {
  private static var installed = false

  static func install() {
    if installed { return }
    let original = class_getInstanceMethod(
      WKWebView.self,
      #selector(setter: WKWebView.uiDelegate)
    )
    let swizzled = class_getInstanceMethod(
      WKWebView.self,
      #selector(WKWebView.webFileUpload_setUIDelegate(_:))
    )
    if let original, let swizzled {
      method_exchangeImplementations(original, swizzled)
      installed = true
    }
  }
}

extension WKWebView {
  @objc func webFileUpload_setUIDelegate(_ delegate: WKUIDelegate?) {
    guard let delegate, !(delegate is WebFileUploadDelegate) else {
      if delegate == nil {
        objc_setAssociatedObject(
          self,
          &webFileUploadDelegateKey,
          nil,
          .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
      }
      webFileUpload_setUIDelegate(delegate)
      return
    }
    let wrapper = WebFileUploadDelegate(forwarding: delegate)
    objc_setAssociatedObject(
      self,
      &webFileUploadDelegateKey,
      wrapper,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    webFileUpload_setUIDelegate(wrapper)
  }
}

/// Forwards WebKit UI callbacks and presents the same upload choices as Safari.
final class WebFileUploadDelegate: NSObject, WKUIDelegate {
  let forwarding: WKUIDelegate

  init(forwarding: WKUIDelegate) {
    self.forwarding = forwarding
  }

  override func responds(to aSelector: Selector!) -> Bool {
    if #available(iOS 18.4, *) {
      if aSelector == #selector(webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)) {
        return true
      }
    }
    return super.responds(to: aSelector) || forwarding.responds(to: aSelector)
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    if forwarding.responds(to: aSelector) {
      return forwarding
    }
    return super.forwardingTarget(for: aSelector)
  }

  @available(iOS 18.4, *)
  func webView(
    _ webView: WKWebView,
    runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping ([URL]?) -> Void
  ) {
    WebFileUploadPresenter.shared.present(
      allowsMultiple: parameters.allowsMultipleSelection,
      completion: completionHandler
    )
  }
}

final class WebFileUploadPresenter: NSObject,
  PHPickerViewControllerDelegate,
  UIImagePickerControllerDelegate,
  UINavigationControllerDelegate,
  UIDocumentPickerDelegate
{
  static let shared = WebFileUploadPresenter()

  private var completion: (([URL]?) -> Void)?
  private var allowsMultiple = false

  @available(iOS 18.4, *)
  func present(allowsMultiple: Bool, completion: @escaping ([URL]?) -> Void) {
    DispatchQueue.main.async {
      guard self.completion == nil else {
        completion(nil)
        return
      }
      guard let presenter = Self.topViewController() else {
        completion(nil)
        return
      }
      self.completion = completion
      self.allowsMultiple = allowsMultiple

      let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
      sheet.addAction(UIAlertAction(title: "Photo Library", style: .default) { [weak self] _ in
        self?.presentAfterSheet { self?.presentPhotoLibrary() }
      })
      if UIImagePickerController.isSourceTypeAvailable(.camera) {
        sheet.addAction(UIAlertAction(title: "Take Photo or Video", style: .default) { [weak self] _ in
          self?.presentAfterSheet { self?.presentCamera() }
        })
      }
      sheet.addAction(UIAlertAction(title: "Choose File", style: .default) { [weak self] _ in
        self?.presentAfterSheet { self?.presentDocuments() }
      })
      sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
        self?.finish(nil)
      })
      if let popover = sheet.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(
          x: presenter.view.bounds.midX,
          y: presenter.view.bounds.maxY - 1,
          width: 1,
          height: 1
        )
        popover.permittedArrowDirections = []
      }
      presenter.present(sheet, animated: true)
    }
  }

  private func presentAfterSheet(_ show: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: show)
  }

  private func presentPhotoLibrary() {
    guard let presenter = Self.topViewController() else {
      finish(nil)
      return
    }
    var configuration = PHPickerConfiguration()
    configuration.filter = .any(of: [.images, .videos])
    configuration.selectionLimit = allowsMultiple ? 0 : 1
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  private func presentCamera() {
    guard let presenter = Self.topViewController() else {
      finish(nil)
      return
    }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  private func presentDocuments() {
    guard let presenter = Self.topViewController() else {
      finish(nil)
      return
    }
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.image, .movie, .audio, .pdf, .data],
      asCopy: true
    )
    picker.allowsMultipleSelection = allowsMultiple
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    if results.isEmpty {
      finish(nil)
      return
    }
    Task {
      var urls: [URL] = []
      for result in results {
        if let url = await Self.copy(result.itemProvider) {
          urls.append(url)
        }
      }
      await MainActor.run {
        self.finish(urls.isEmpty ? nil : urls)
      }
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    finish(nil)
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    if let media = info[.mediaURL] as? URL, let copied = Self.copyFile(media) {
      finish([copied])
      return
    }
    if let image = info[.originalImage] as? UIImage,
       let data = image.jpegData(compressionQuality: 0.92) {
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).jpg")
      do {
        try data.write(to: destination, options: .atomic)
        finish([destination])
      } catch {
        finish(nil)
      }
      return
    }
    finish(nil)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let copied = urls.compactMap { url -> URL? in
      let accessing = url.startAccessingSecurityScopedResource()
      defer {
        if accessing { url.stopAccessingSecurityScopedResource() }
      }
      return Self.copyFile(url)
    }
    finish(copied.isEmpty ? nil : copied)
  }

  private func finish(_ urls: [URL]?) {
    let callback = completion
    completion = nil
    callback?(urls)
  }

  private static func copy(_ provider: NSItemProvider) async -> URL? {
    for identifier in provider.registeredTypeIdentifiers {
      if let url = await loadFile(provider, identifier) {
        return url
      }
    }
    return nil
  }

  private static func loadFile(_ provider: NSItemProvider, _ identifier: String) async -> URL? {
    await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
        guard let url, let copied = copyFile(url) else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: copied)
      }
    }
  }

  private static func copyFile(_ url: URL) -> URL? {
    let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).\(ext)")
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: url, to: destination)
      return destination
    } catch {
      return nil
    }
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}
