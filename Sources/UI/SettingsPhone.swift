import AppKit
import CoreImage

/// Settings › Phone: the relay, pairing a phone with a QR code, and the paired phones (docs/phone.md).
extension SettingsView {
    func phone() {
        let p = model.phone
        form.header("Relay", note: "Maxwell's iPhone app reaches this Mac through a relay. Messages are end-to-end encrypted; the relay can't read them.")
        relayRow(p)
        form.header("Pair a phone")
        pairRows(p)
        form.header("Paired phones")
        if p.phones.isEmpty { form.paragraph("No phones yet.") }
        for ph in p.phones {
            let remove = MXButton("Remove", small: true) { [weak self] in self?.confirmRemove(ph) }
            let seen = ph.online ? "Online" : ph.lastSeen.map { "Offline · last seen \(Format.ago($0))" } ?? "Offline · not connected since pairing"
            form.row(ph.name, [(remove, remove.intrinsicContentSize.width)], note: seen, icon: StatusSquare(ph.online ? .on : .off))
        }
    }

    private func relayRow(_ p: PhoneStatus) {
        let address = p.relayURL.flatMap { URL(string: $0) }.map { u in (u.host ?? "") + (u.port.map { ":\($0)" } ?? "") } ?? p.relayURL ?? ""
        switch p.relay {
        case .off:
            let open = MXButton("Open config", small: true) { [weak self] in self?.onRunAction?("open-config") }
            form.row("Off", [(open, open.intrinsicContentSize.width)],
                     note: "Your config turns the phone off with its phone-relay line. Remove that line to turn it on.", icon: StatusSquare(.off))
        case .idle:
            form.row("Not connected", [], note: "Maxwell connects only while a phone is paired or a code is showing.", icon: StatusSquare(.off))
        case .connecting:
            form.row("Connecting…", [], note: address, icon: StatusSquare(.off))
        case .connected:
            form.row("Connected", [], note: address, icon: StatusSquare(.on))
        case .cantReach(let why):
            form.row("Can't reach \(address)", [], note: "\(why.prefix(1).uppercased() + why.dropFirst()). Maxwell keeps trying.", icon: StatusSquare(.warn), warn: true)
        }
    }

    private func pairRows(_ p: PhoneStatus) {
        guard p.relay != .off else {
            return form.row("", [], note: "Pairing works once the phone is on.", enabled: false)
        }
        guard let link = p.pairLink, let expires = p.pairExpires else {
            let show = MXButton("Show code", primary: true, small: true) { [weak self] in self?.onPairPhone?() }
            return form.row("", [(show, show.intrinsicContentSize.width)],
                            note: "Scan the code with Maxwell on your iPhone. Each code works once, for 10 minutes.")
        }
        form.wide("Scan with Maxwell on your iPhone", note: "Works once, until \(Format.clock.string(from: expires)).", QRCodeView(text: link), height: 160)
        let copy = MXButton("Copy link", small: true) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
        copy.tip = Tip("For a phone that can't scan: open the link on it")
        let again = MXButton("New code", small: true) { [weak self] in self?.onPairPhone?() }
        let done = MXButton("Done", small: true) { [weak self] in self?.onCancelPairing?() }
        done.tip = Tip("Hides the code; it stops working")
        form.row("", [(copy, copy.intrinsicContentSize.width), (again, again.intrinsicContentSize.width), (done, done.intrinsicContentSize.width)],
                 note: "Anyone with this link can pair. Send it only to yourself.")
    }

    private func confirmRemove(_ ph: PhoneStatus.Phone) {
        guard let w = window else { onRemovePhone?(ph.id); return }
        let a = NSAlert()
        a.messageText = "Remove \(ph.name)?"
        a.informativeText = "It can't reach this Mac until you pair it again."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        a.beginSheetModal(for: w) { [weak self] r in if r == .alertFirstButtonReturn { self?.onRemovePhone?(ph.id) } }
    }
}

/// A QR code, black on white with its quiet zone, sharp at any size.
final class QRCodeView: MXView {
    private let image: CGImage?

    init(text: String) {
        let f = CIFilter(name: "CIQRCodeGenerator")
        f?.setValue(Data(text.utf8), forKey: "inputMessage")
        f?.setValue("M", forKey: "inputCorrectionLevel")
        image = f?.outputImage.flatMap { CIContext().createCGImage($0, from: $0.extent) }
        super.init(frame: .zero)
        setAccessibilityLabel("Pairing code")
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.height, bounds.width)
        let box = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor.white.setFill()
        box.fill()
        let modules = CGFloat(image.width)
        let scale = floor((side - 16) / modules)
        let size = modules * scale
        let code = NSRect(x: (side - size) / 2, y: (side - size) / 2, width: size, height: size)
        ctx.interpolationQuality = .none
        ctx.saveGState()
        // Flipped view: draw the image upright.
        ctx.translateBy(x: 0, y: code.maxY + code.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: code)
        ctx.restoreGState()
    }
}

/// A row's status: green when on, grey when off, the Needs you colour when something is wrong.
final class StatusSquare: MXView {
    enum Kind { case on, off, warn }
    private let kind: Kind
    init(_ kind: Kind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let sq = NSRect(x: bounds.midX - 4, y: bounds.midY - 4, width: 8, height: 8)
        switch kind {
        case .on: t.safe.setFill(); sq.fill()
        case .warn: t.on.setFill(); sq.fill()
        case .off: t.fg3.setFill(); sq.fill()
        }
    }
}
