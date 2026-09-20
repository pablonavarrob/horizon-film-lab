import SwiftUI

// The boot splash: the panel a minilab fills its main menu with while it comes
// up. Same furniture -- wordmark top-left, DIGITAL MINILAB over the logotype,
// the controller plaque, and a Date/Time readout bottom-right in the machine's
// own two-line format -- with our own marks.
//
// Shown once per launch, over the idle window. Auto-dismisses; click to skip.
//
// TO REMOVE: delete this file and the `.splash()` line in ContentView.

struct Splash: View {
    @Binding var shown: Bool
    /// Ticks the clock. The real machine's readout counts seconds, and a frozen
    /// clock on a splash screen looks like a screenshot rather than a boot.
    @State private var now = Date()

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM dd, yyyy"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        ZStack {
            Backdrop()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Wordmark()
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 2) {
                        Text("DIGITAL MINILAB")
                            .font(.custom("Tahoma", size: 17).weight(.bold))
                            .tracking(3.2)
                            .foregroundStyle(.white.opacity(0.95))
                        Text("Horizon")
                            .font(.custom("Tahoma", size: 74).weight(.heavy))
                            .italic()
                            .tracking(-1.5)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
                        // The dark plaque under the logotype.
                        Text("Digital Imaging Controller II")
                            .font(.custom("Tahoma", size: 19).weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 13)
                                .fill(FUI.hex(0x0C3B44).opacity(0.88)))
                            .overlay(RoundedRectangle(cornerRadius: 13)
                                .strokeBorder(.white.opacity(0.28), lineWidth: 1))
                            .padding(.top, 4)
                    }
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    // Sunken readout, the machine's exact two-line label format.
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Date:\(Self.dayFmt.string(from: now))")
                        Text("Time:\(Self.timeFmt.string(from: now))")
                    }
                    .font(FUI.label())
                    .foregroundStyle(FUI.ink)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(FUI.hex(0xB9B9B9))
                    .bevel(up: false, width: 1)
                    .overlay(Rectangle().strokeBorder(FUI.outline.opacity(0.5), lineWidth: 1))
                }
            }
            .padding(22)
        }
        .overlay(Rectangle().strokeBorder(FUI.tealRule, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .task {
            // Two jobs, deliberately not one timer: the clock ticks every second
            // while the splash is up, and a separate sleep dismisses it.
            try? await Task.sleep(for: .milliseconds(2900))
            dismiss()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                now = Date()
            }
        }
        .transition(.opacity)
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.45)) { shown = false }
    }
}

/// The technical-looking teal field behind the logotype: graticule, faint
/// columns, a diagonal light streak and the row of little outlined boxes along
/// the bottom. All of those are in the reference; none of it is an image file, so
/// there is nothing extra to bundle.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [FUI.hex(0x0A6E76), FUI.hex(0x1FA0A2), FUI.hex(0x0B5C68)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                // Graticule: a globe's worth of latitude and longitude.
                Path { p in
                    for i in 1..<7 {
                        let ry = h * 0.46 * Double(i) / 7
                        p.addEllipse(in: CGRect(x: w * 0.5 - w * 0.42, y: h * 0.5 - ry,
                                                width: w * 0.84, height: ry * 2))
                    }
                    for i in 0..<9 {
                        let rx = w * 0.42 * Double(i) / 8
                        p.addEllipse(in: CGRect(x: w * 0.5 - rx, y: h * 0.04,
                                                width: rx * 2, height: h * 0.92))
                    }
                }
                .stroke(.white.opacity(0.07), lineWidth: 1)
                // Faint vertical columns.
                Path { p in
                    for f in [0.06, 0.17, 0.30, 0.52, 0.68, 0.81, 0.93] {
                        p.addRect(CGRect(x: w * f, y: 0, width: w * 0.035, height: h))
                    }
                }
                .fill(.white.opacity(0.045))
                // The diagonal streak across the logotype.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.44, y: h))
                    p.addLine(to: CGPoint(x: w * 0.86, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.97, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.55, y: h))
                }
                .fill(.white.opacity(0.10))
                .blur(radius: 9)
                // The row of small outlined boxes along the lower edge.
                Path { p in
                    for i in 0..<11 {
                        p.addRect(CGRect(x: w * 0.04 + Double(i) * 26, y: h * 0.845,
                                         width: 19, height: 13))
                    }
                }
                .stroke(.white.opacity(0.16), lineWidth: 1)
            }
        }
    }
}

/// Corner wordmark: the mark, then HORIZON in tight bold caps.
///
/// Drawn rather than loaded, because at the 26 px this corner allows the badge
/// renders as mush -- and it would repeat the logotype that is already the
/// centre of the screen. Three bars for the three narrowband channels.
private struct Wordmark: View {
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                .frame(width: 22, height: 17)
                .overlay(
                    HStack(spacing: 1.5) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule().fill(.white.opacity(0.9)).frame(width: 2.5, height: 7)
                        }
                    }
                )
            Text("HORIZON")
                .font(.custom("Tahoma", size: 23).weight(.bold)).tracking(0.5)
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }
}


extension View {
    /// Lay the splash over the window while `shown`.
    func splash(_ shown: Binding<Bool>) -> some View {
        overlay {
            if shown.wrappedValue { Splash(shown: shown).transition(.opacity) }
        }
    }
}
