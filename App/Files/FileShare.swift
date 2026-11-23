import OrcaCore
import UIKit

/// Shares a workspace file (files/share): copies it off the desktop in `files.readChunk` pieces into a temporary
/// folder, then hands it to the share sheet. `fallbackText` is shared as the file when the host is too old to read
/// files in chunks but the preview already holds the text.
@MainActor
enum FileShare {
  static func share(
    session: HostSession, worktreeId: String, path: String, fallbackText: String? = nil,
    from presenter: UIViewController, source: UIBarButtonItem?
  ) {
    let name = (path as NSString).lastPathComponent
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "share-\(UUID().uuidString)", isDirectory: true)
    let destination = folder.appendingPathComponent(name.isEmpty ? "file" : name)

    let progress = UIAlertController(
      title: String(localized: "files.fileShare.preparing", defaultValue: "Preparing file..."), message: nil,
      preferredStyle: .alert)
    let api = session.api
    let task = Task {
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
          try await api.downloadFile(worktreeId: worktreeId, path: path, to: destination) { read, total in
            let text = String(
              format: String(localized: "files.fileMediaPreview.downloading", defaultValue: "Downloading %1$@ of %2$@"),
              byteText(read), byteText(total))
            Task { @MainActor in progress.message = text }
          }
        } catch let error as RPCError where isMethodUnavailable(error) {
          guard let fallbackText else { throw ShareFailure.hostOutdated }
          try Data(fallbackText.utf8).write(to: destination)
        }
        try Task.checkCancellation()
        progress.dismiss(animated: true) {
          let sheet = UIActivityViewController(activityItems: [destination], applicationActivities: nil)
          sheet.popoverPresentationController?.barButtonItem = source
          if source == nil {
            sheet.popoverPresentationController?.sourceView = presenter.view
            sheet.popoverPresentationController?.sourceRect = CGRect(
              x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
          }
          sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
          presenter.present(sheet, animated: true)
        }
      } catch is CancellationError {
        try? FileManager.default.removeItem(at: folder)
      } catch {
        try? FileManager.default.removeItem(at: folder)
        let message: String
        switch error {
        case ShareFailure.hostOutdated:
          message = String(
            localized: "files.fileShare.hostOutdated",
            defaultValue: "Update Orca where this workspace runs to share files on mobile")
        case FileDownloadError.tooLarge:
          message = String(
            localized: "files.filePreviewResponse.fileTooLarge", defaultValue: "File too large for mobile preview")
        default:
          message = (error as? RPCError)?.message ?? error.localizedDescription
        }
        progress.dismiss(animated: true) {
          let alert = UIAlertController(
            title: String(localized: "files.fileShare.failed", defaultValue: "Unable to share this file"),
            message: message, preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
          presenter.present(alert, animated: true)
        }
      }
    }
    progress.addAction(
      UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel) { _ in
        task.cancel()
      })
    presenter.present(progress, animated: true)
  }

  private enum ShareFailure: Error { case hostOutdated }

  /// mobile-method-unavailable.ts: the host doesn't let phones call this method.
  nonisolated static func isMethodUnavailable(_ error: RPCError) -> Bool {
    error.code == "forbidden" || error.code == "method_not_found"
      || error.message.contains("not available to mobile clients")
  }

  /// formatPreviewByteLength in mobile-file-preview-response.ts.
  nonisolated static func byteText(_ bytes: Int) -> String {
    if bytes < 1024 {
      return String(format: String(localized: "files.filePreviewResponse.bytes", defaultValue: "%1$@ B"), "\(bytes)")
    }
    if bytes < 1024 * 1024 {
      return String(
        format: String(localized: "files.filePreviewResponse.kilobytes", defaultValue: "%1$@ KB"),
        "\(Int((Double(bytes) / 1024).rounded()))")
    }
    return String(
      format: String(localized: "files.filePreviewResponse.megabytes", defaultValue: "%1$@ MB"),
      String(format: "%.1f", Double(bytes) / (1024 * 1024)))
  }
}
