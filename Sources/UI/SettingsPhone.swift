import AppKit
import CoreImage

/// Settings › Phone: the relay, pairing a phone with a QR code, and the paired phones (docs/phone.md).
extension SettingsView {
    func phone() {
        let p = model.phone
        form.header("Relay", note: "Maxwell's iPhone app reaches this Mac through a relay. Everything is encrypted on the Mac and the phone; the relay can't read it.")
        relayRow(p)
        form.header("Pair a phone")
        pairRows(p)
        form.header("Paired phones")
        if p.phones.isEmpty {
            form.paragraph("No phones yet. Pair one above.")
        }
        for ph in p.phones {
            let remove = MXButton("Remove", small: true) { [weak self] in self?.onRemovePhone?(ph.id) }
            remove.tip = Tip("\(ph.name) stops reaching this Mac. Pair it again to undo.")
            let seen = ph.online ? "Online now" : ph.lastSeen.map { "Last seen \(Format.ago($0))" } ?? "Not connected since pairing"
            form.row(ph.name, [(remove, remove.intrinsicContentSize.width)], note: seen, icon: PresenceMark(online: ph.online))
        }
    }

    private func relayRow(_ p: PhoneStatus) {
        let host = p.relayURL.flatMap { URL(string: $0)?.host } ?? p.relayURL ?? ""
        switch p.relay {
        case .notSet:
            form.row("Not set up", [], note: "Add phone-relay = wss://… to ~/.config/maxwell/config. Until then your phone can't reach this Mac.")
        case .connecting:
            form.row("Connecting…", [], note: host)
        case .connected:
            form.row("Connected", [], note: host)
        case .cantReach(let why):
            form.row("Can't reach \(host)", [], note: "\(why.prefix(1).uppercased() + why.dropFirst()). Maxwell keeps trying.", warn: true)
        }
    }

    private func pairRows(_ p: PhoneStatus) {
        guard p.relay != .notSet else {
            return form.row("Set up the relay first", [], note: "Pairing needs the relay, so the phone can find this Mac.", enabled: false)
        }
        guard let link = p.pairLink, let expires = p.pairExpires else {
            let pair = MXButton("Pair a phone", primary: true, small: true) { [weak self] in self?.onPairPhone?() }
            return form.row("Show a pairing code", [(pair, pair.intrinsicContentSize.width)],
                            note: "Open the Maxwell app on your iPhone and scan it. A code works once, for 10 minutes.")
        }
        form.wide("Scan with the Maxwell app", note: "Works once, until \(Format.clock.string(from: expires)).", QRCodeView(text: link), height: 196)
        let copy = MXButton("Copy link", small: true) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
        copy.tip = Tip("For a phone that can't scan: open the link on it")
        let again = MXButton("New code", small: true) { [weak self] in self?.onPairPhone?() }
        form.row("", [(copy, copy.intrinsicContentSize.width), (again, again.intrinsicContentSize.width)],
                 note: "The link holds this code's key. Share it only with your own phone.")
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

/// A phone's row mark: a filled square while it is online, an outline when not.
final class PresenceMark: MXView {
    private let online: Bool
    init(online: Bool) { self.online = online; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let sq = NSRect(x: bounds.midX - 4, y: bounds.midY - 4, width: 8, height: 8)
        if online { t.safe.setFill(); sq.fill() } else { t.fg3.setStroke(); let b = NSBezierPath(rect: sq.insetBy(dx: 0.5, dy: 0.5)); b.lineWidth = 1; b.stroke() }
    }
}
