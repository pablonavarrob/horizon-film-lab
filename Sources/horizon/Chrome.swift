import AppKit
import SwiftUI

// Chunky panel chrome under a minilab teal header. Silver face, two-tone
// bevels, sunken white value fields, white stage.
//
// ONE TYPE SCALE, three sizes only. An earlier pass used eight different sizes
// between 8 and 19 px and that is what made it read as thrown together.
//
//   label  13   every button and label
//   value  17   the C/M/Y/D readouts
//   small  11   the handful of captions that genuinely are secondary
//
// Tahoma is the period-correct Windows UI face and ships on macOS, so it costs
// nothing and does more for "real software" than any amount of border work.

// Palette sampled from an 800x600 pixel-exact screenshot of a real SP-500
// running FE, not estimated by eye. Several of my earlier guesses were badly
// off: the header top was #66B1B4 where the real value is #5CD8D8, and the
// title text is black, not white.
enum FUI {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }

    // Re-sampled against the two COLOUR screenshots of this exact screen --
    // sp500 p033 (order entry) and p035 (Digital Image Export). Pixel
    // coordinates given so any of these can be re-checked.
    //
    // Four were already right and are left alone: tealBar #29A5A5 (p033 297,71),
    // green #12B58C (p033 738,516 and p035 738,516 agree), lit #FEFD9B
    // (p033 112,117, the selected sidebar card) and ring #64FF02 (p035 450,476,
    // where it outlines the ACTIVE TAB -- so it is the machine's own
    // "this one is selected" colour, used here for the same purpose).
    static let silver = hex(0xC0C0C0)      // panel face, p033 297,120
    static let hiLight = Color.white
    static let shadowGrey = hex(0x9F9F9F)
    static let outline = hex(0x414141)     // hard rule outside every bevel
    static let fieldWhite = Color.white    // editable field
    static let fieldRO = hex(0xCECECE)     // read-only field
    static let tealTop = hex(0x60DCDC)     // p033 400,4
    /// Was #007474, which is far darker than anything on the real screen: the
    /// header gradient bottoms out at #39B5B5 and the row under it is #118D8D.
    /// That one value was making the whole header read as murky.
    static let tealBot = hex(0x118D8D)     // p033 400,30
    static let tealRule = hex(0x005963)    // p033 400,43
    static let tealBar = hex(0x29A5A5)     // panel heading bars, confirmed
    static let green = hex(0x12B58C)       // START, confirmed
    static let greenLip = hex(0x3CFFE5)    // its 1px top highlight
    static let lit = hex(0xFEFD9B)         // selected card: pale yellow, confirmed
    static let ring = hex(0x64FF02)        // selection ring, confirmed
    static let statusBar = hex(0x595959)   // p033 400,516 -- was #606060
    static let ink = hex(0x121213)

    /// Surfaces that are NOT the panel face. The machine uses three greys where
    /// this UI used one, which is most of why it read flatter than the reference.
    static let panelWell = hex(0xB3B3B3)   // recessed column, p035 106,90
    static let iconFace = hex(0xD9D9D9)    // icon/command button, p033 297,157
    static let fkeyFace = hex(0xBFBFBF)    // F-key cell, p033 60,508
    static let fkeyNum = hex(0x7C7C7C)     // its row-number box, p033 10,505

    // The machine's own C/M/Y/D indicator-bar colours, measured from a
    // lossless capture of the judgement screen.
    static let barC = hex(0x01B5EF)
    static let barM = hex(0xE7007B)
    static let barY = hex(0xFFF700)
    static let barD = hex(0x000000)

    /// Label tints. Darkened where they have to stay legible on #C0C0C0 --
    /// #FFF700 yellow on silver is unreadable, so the word "Yellow" gets an
    /// olive that still reads as yellow-ish.
    static let inkCyan = hex(0x00789E)
    static let inkRed = hex(0xC01414)
    static let inkMagenta = hex(0xB00060)
    static let inkGreen = hex(0x0A7A28)
    static let inkYellow = hex(0x877A00)
    static let inkBlue = hex(0x1430C0)

    static func label(_ bold: Bool = false) -> Font {
        .custom("Tahoma", size: 13).weight(bold ? .bold : .regular)
    }
    static func value() -> Font { .custom("Tahoma", size: 17).weight(.bold) }
    /// A fourth size, added because the panel headings needed to be bigger and
    /// bolder than body text to actually separate the sections.
    static func heading() -> Font { .custom("Tahoma", size: 15).weight(.bold) }
    static func small(_ bold: Bool = false) -> Font {
        .custom("Tahoma", size: 11).weight(bold ? .bold : .regular)
    }

    /// The badge, loaded from the bundle. Nil when running the raw SPM binary
    /// rather than Horizon.app, so the header just falls back to text.
    static let badge: NSImage? = {
        guard let p = Bundle.main.path(forResource: "logo", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: p)
    }()
}

/// Classic two-tone bevel. `up` = raised control, `down` = recessed field.
struct Bevel: ViewModifier {
    var up = true
    var width: CGFloat = 2
    func body(content: Content) -> some View {
        content.overlay(GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: 0, y: g.size.height))
                p.addLine(to: .zero)
                p.addLine(to: CGPoint(x: g.size.width, y: 0))
            }.stroke(up ? FUI.hiLight : FUI.shadowGrey, lineWidth: width)
            Path { p in
                p.move(to: CGPoint(x: g.size.width, y: 0))
                p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                p.addLine(to: CGPoint(x: 0, y: g.size.height))
            }.stroke(up ? FUI.shadowGrey : FUI.hiLight, lineWidth: width)
        })
    }
}

extension View {
    func bevel(up: Bool = true, width: CGFloat = 2) -> some View {
        modifier(Bevel(up: up, width: width))
    }
}

/// Big chunky button. `lit` draws it pressed-in with an amber face, which is
/// how every toggle in this UI shows its state.
struct Chunky: ButtonStyle {
    var height: CGFloat = 38
    var minWidth: CGFloat? = nil
    var lit = false
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed || lit
        return configuration.label
            .font(FUI.label(true))
            .foregroundStyle(FUI.ink)
            .frame(minWidth: minWidth, maxWidth: minWidth == nil ? .infinity : nil)
            .frame(height: height)
            // #D9D9D9, one step LIGHTER than the panel it sits on. Buttons used
            // to be the same #C0C0C0 as the panel face, so a row of them read as
            // one grey slab with lines on it. The reference separates them
            // (panel 297,120 = #C0C0C0; button 297,157 = #D9D9D9) and that one
            // step is most of what makes its controls look like controls.
            .background(lit ? FUI.lit : (tint ?? FUI.iconFace))
            .bevel(up: !down)
            // The machine's signature: a hard 1px outline OUTSIDE the bevel.
            .overlay(Rectangle().strokeBorder(FUI.outline, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Sunken white readout.
struct Field: View {
    let text: String
    var width: CGFloat = 56
    var height: CGFloat = 32
    /// Read-only readouts are #CECECE, editable ones white — the machine's
    /// distinguishes them and it's how you know what you can change.
    var readOnly = false

    var body: some View {
        Text(text)
            .font(FUI.value())
            .foregroundStyle(FUI.ink)
            .frame(width: width, height: height)
            .background(readOnly ? FUI.fieldRO : FUI.fieldWhite)
            .bevel(up: false)
            .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.55), lineWidth: 1))
    }
}

/// The committing action. Square left corners, semicircular right cap — the
/// real START is a "D" pointing right, not a capsule — plus the 1px #3CFFE5
/// highlight along its top edge.
struct StartButton: ButtonStyle {
    var height: CGFloat = 34
    var minWidth: CGFloat = 140
    func makeBody(configuration: Configuration) -> some View {
        let shape = UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: 3, bottomLeading: 3,
            bottomTrailing: height / 2, topTrailing: height / 2))
        return configuration.label
            .font(FUI.label(true))
            .foregroundStyle(FUI.ink)
            .frame(minWidth: minWidth).frame(height: height)
            .padding(.horizontal, 16)
            .background(shape.fill(configuration.isPressed
                ? FUI.green.opacity(0.75) : FUI.green))
            .overlay(shape.strokeBorder(FUI.outline.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .top) {
                FUI.greenLip.frame(height: 1).padding(.horizontal, 4)
            }
            .contentShape(shape)
    }
}

/// Sunken chip in the status strip.
struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(FUI.small()).foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 8).frame(height: 22)
            .background(FUI.hex(0x4A4A4A))
            .overlay(Rectangle().strokeBorder(FUI.hex(0x292929), lineWidth: 1))
            .overlay(Rectangle().strokeBorder(FUI.hex(0x6E6E6E), lineWidth: 1).padding(1))
    }
}

/// Teal heading bar, the way every minilab panel is titled: flat #29A5A5, thin
/// rules top and bottom.
///
/// The label is CENTRED, which was measured rather than chosen. The machine does
/// both: on the order-entry screen the heading ink starts 0-3 px from the left
/// edge of the bar, but on the Digital Image Export screen -- the screen this app
/// IS -- all three headings sit with 29/35, 29/33 and 50/55 px of slack either
/// side. Centred is what that screen does, so it is what this does.
struct PanelHeading: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(FUI.heading()).foregroundStyle(FUI.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(FUI.tealBar)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(FUI.hex(0x1C6F6F)), alignment: .top)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(FUI.hex(0x3BCDCD)), alignment: .bottom)
    }
}

/// The F-key strip: two rows of three, each cell a sunken #BFBFBF plate with the
/// key name in a darker inset box, and the row number in a #7C7C7C tab on the
/// left. Bottom-left of every single reference screen, and its absence was the
/// most conspicuous difference.
struct FKeyStrip: View {
    /// Six (key, caption, action). A nil action greys the cell, exactly as the
    /// machine shows an unbound key -- it still draws the F-number.
    let keys: [(String, String, (() -> Void)?)]
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                ForEach(["1", "2"], id: \.self) { n in
                    Text(n).font(FUI.small()).foregroundStyle(.white)
                        .frame(width: 13, height: 15).background(FUI.fkeyNum)
                        .overlay(Rectangle().strokeBorder(FUI.hex(0x3B3B3B), lineWidth: 1))
                }
            }
            VStack(spacing: 1) {
                ForEach(0..<2, id: \.self) { r in
                    HStack(spacing: 1) {
                        ForEach(0..<3, id: \.self) { c in
                            cell(keys[r * 3 + c])
                        }
                    }
                }
            }
        }
        .padding(2)
        .background(FUI.silver)
        .bevel(up: false, width: 1)
    }

    private func cell(_ k: (String, String, (() -> Void)?)) -> some View {
        Button { k.2?() } label: {
            HStack(spacing: 4) {
                Text(k.0).font(FUI.small()).foregroundStyle(FUI.ink.opacity(0.75))
                    .frame(width: 17, height: 13)
                    .background(FUI.hex(0xADADAD))
                Text(k.1).font(FUI.small())
                    .foregroundStyle(FUI.ink.opacity(k.2 == nil ? 0.3 : 1))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 1)
            .frame(width: 112, height: 15)
            .background(FUI.fkeyFace)
            .overlay(Rectangle().strokeBorder(FUI.hex(0x8C8C8C), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(k.2 == nil)
    }
}

/// The round teal glyph buttons in the top-right corner of every screen.
struct RoundIcon: View {
    let glyph: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(glyph).font(FUI.small(true))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(Circle().fill(FUI.hex(0x2FA9A9)))
                .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1))
                .overlay(Circle().strokeBorder(FUI.hex(0x044E4E).opacity(0.8), lineWidth: 1)
                    .padding(-1))
        }
        .buttonStyle(.plain)
    }
}
