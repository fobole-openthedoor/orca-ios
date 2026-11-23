import OrcaCore
import UIKit

/// Host ⋯ › Edit host (app/h/[hostId]/edit.tsx): the name this phone gives the desktop and its address, the
/// desktop's Orca version, and Remove host.
final class EditHostViewController: SettingsPageViewController {
  private let session: HostSession
  private let nameCell = HostFieldCell()
  private let addressCell = HostFieldCell()
  private var saveError: String?
  private var saving = false
  private var save: UIBarButtonItem!

  init(session: HostSession) {
    self.session = session
    super.init()
    hidesBottomBarWhenPushed = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "host.edit.title", defaultValue: "Edit host")
    save = UIBarButtonItem(
      image: Lucide.check.image(size: 20, strokeWidth: 2.2), primaryAction: UIAction { [weak self] _ in self?.saveHost() })
    save.accessibilityLabel = String(localized: "host.edit.saveHost", defaultValue: "Save host")
    navigationItem.rightBarButtonItem = save
    tableView.keyboardDismissMode = .interactive

    // The field edits the phone's own name; empty means "use the desktop's name", which the placeholder shows.
    nameCell.configure(
      label: String(localized: "host.edit.name", defaultValue: "Name"), text: session.host.personalName ?? "",
      placeholder: session.status?.machineName ?? String(localized: "host.edit.hostNamePlaceholder", defaultValue: "Host name"))
    nameCell.field.autocapitalizationType = .words
    nameCell.field.autocorrectionType = .no
    nameCell.field.returnKeyType = .next
    nameCell.field.addAction(UIAction { [weak self] _ in self?.addressCell.field.becomeFirstResponder() }, for: .editingDidEndOnExit)

    addressCell.configure(
      label: String(localized: "host.edit.address", defaultValue: "Address"), text: HostEndpoint.display(session.host.endpoint),
      placeholder: "192.168.1.10:6768")
    addressCell.field.autocapitalizationType = .none
    addressCell.field.autocorrectionType = .no
    addressCell.field.keyboardType = .URL
    addressCell.field.returnKeyType = .done
    addressCell.field.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        if self.canSave { self.saveHost() }
      }, for: .editingDidEndOnExit)

    for cell in [nameCell, addressCell] {
      cell.field.addAction(
        UIAction { [weak self] _ in
          self?.saveError = nil
          self?.rebuild()
        }, for: .editingChanged)
    }
    rebuild()
  }

  override func updateProperties() {
    super.updateProperties()
    // The version arrives with the desktop's status.
    _ = session.status
    rebuild()
  }

  private var endpointEdit: HostEndpoint.Edit {
    HostEndpoint.resolveEdit(stored: session.host.endpoint, input: addressCell.field.text ?? "")
  }

  private var trimmedName: String { (nameCell.field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

  private var canSave: Bool {
    let nameChanged = trimmedName != (session.host.personalName ?? "")
    switch endpointEdit {
    case .invalid: return false
    case .changed: return !saving
    case .unchanged: return nameChanged && !saving
    }
  }

  private func rebuild() {
    guard isViewLoaded else { return }
    save.isEnabled = canSave
    let address = (addressCell.field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var note: (String, UIColor)?
    if let saveError {
      note = (saveError, Palette.statusRed)
    } else if case .invalid(let error) = endpointEdit, !address.isEmpty {
      note = (Self.message(for: error), Palette.statusRed)
    } else if case .changed(let endpoint) = endpointEdit, endpoint.lowercased() != address.lowercased() {
      // Only when it adds something to what was typed, such as the kept port or the scheme.
      note = (String(format: String(localized: "host.edit.connectionPreview", defaultValue: "Connects to %1$@"), endpoint), Palette.textSecondary)
    }
    var sections = [Section(footerView: note.map { Self.noteView($0.0, color: $0.1) }, rows: [.custom(nameCell), .custom(addressCell)])]
    if let version = session.status?.appVersion {
      sections.append(Section(rows: [.value(title: String(localized: "host.edit.orcaVersion", defaultValue: "Orca version"), value: version)]))
    }
    sections.append(
      Section(rows: [
        .button(
          title: String(localized: "host.edit.removeHost", defaultValue: "Remove host"), destructive: true, enabled: !saving,
          action: { [weak self] in self?.confirmRemove() })
      ]))
    self.sections = sections
  }

  private func saveHost() {
    guard canSave else { return }
    var host = session.host
    host.personalName = trimmedName.isEmpty ? nil : trimmedName
    if case .changed(let endpoint) = endpointEdit { host.endpoint = endpoint }
    saving = true
    saveError = nil
    rebuild()
    Task {
      do {
        try await AppModel.shared.update(host)
        navigationController?.popViewController(animated: true)
      } catch {
        saving = false
        saveError = error.localizedDescription.isEmpty
          ? String(localized: "host.edit.saveFailed", defaultValue: "Failed to save host.") : error.localizedDescription
        rebuild()
      }
    }
  }

  private func confirmRemove() {
    let alert = UIAlertController(
      title: String(localized: "home.screen.removeHostTitle", defaultValue: "Remove Host"),
      message: String(
        format: String(localized: "home.screen.removeHostMessage", defaultValue: "Remove \"%1$@\"? You can re-pair later."), session.name),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "common.remove", defaultValue: "Remove"), style: .destructive) { [weak self] _ in
        self?.remove()
      })
    present(alert, animated: true)
  }

  private func remove() {
    let id = session.host.id
    Task {
      do {
        try await AppModel.shared.remove(id)
        // The desktop's pages go with it: back to the list of desktops.
        navigationController?.popToRootViewController(animated: true)
      } catch {
        showAlert(
          title: String(localized: "home.screen.removeHostFailed", defaultValue: "Could not remove host"),
          message: String(localized: "home.screen.tryAgain", defaultValue: "Please try again."))
      }
    }
  }

  private static func message(for error: HostEndpoint.EditError) -> String {
    switch error {
    case .addressRequired: String(localized: "connection.hostEndpoint.addressRequired", defaultValue: "Enter a host address.")
    case .invalidPort: String(localized: "connection.hostEndpoint.invalidPort", defaultValue: "Port must be 1–65535.")
    case .invalidScheme: String(localized: "connection.hostEndpoint.invalidScheme", defaultValue: "Use ws:// or wss:// (or host:port).")
    case .invalidAddress: String(localized: "connection.hostEndpoint.invalidAddress", defaultValue: "Not a valid address.")
    case .pathOrQueryNotAllowed:
      String(localized: "connection.hostEndpoint.pathOrQueryNotAllowed", defaultValue: "Host must not include a path or query.")
    case .invalidHostname: String(localized: "connection.hostEndpoint.invalidHostname", defaultValue: "Not a valid hostname.")
    case .hostnameRequired: String(localized: "connection.hostEndpoint.hostnameRequired", defaultValue: "Missing hostname.")
    }
  }
}

extension SettingsPageViewController {
  /// A section's note in place of or under its rows (SettingsNote), red for an error.
  static func noteView(_ text: String, color: UIColor) -> UIView {
    let container = UIView()
    let label = TextLabel(text, size: 13, color: color, lines: 0)
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      // Lined up with the rows' text: the inset group's margin plus the row's own.
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Spacing.lg * 2),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Spacing.lg * 2),
      label.topAnchor.constraint(equalTo: container.topAnchor, constant: Spacing.sm),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Spacing.sm),
    ])
    return container
  }
}

/// An editable row (HostFieldRow): the label where a row's title sits, the text after it.
private final class HostFieldCell: UITableViewCell {
  private let label = TextLabel(size: 17)
  let field = UITextField()

  init() {
    super.init(style: .default, reuseIdentifier: nil)
    backgroundColor = Palette.bgRaised
    selectionStyle = .none
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
    field.font = .systemFont(ofSize: 17)
    field.textColor = Palette.textPrimary
    field.tintColor = Palette.accentBlue
    field.clearButtonMode = .whileEditing
    let row = UIStackView(arrangedSubviews: [label, field])
    row.spacing = Spacing.md
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: contentView.topAnchor),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(label text: String, text value: String, placeholder: String) {
    label.text = text
    field.text = value
    field.accessibilityLabel = text
    field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: Palette.textMuted])
  }
}
