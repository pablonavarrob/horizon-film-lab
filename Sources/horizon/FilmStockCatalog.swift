import Foundation

/// The displayed film name and its box speed share one catalog so naming
/// conventions such as 50D, 400H, and Vision3 are never parsed as ISO values.
enum FilmStockCatalog {
    struct Stock {
        let name: String
        let boxISO: String

        init(_ name: String, _ boxISO: Int) {
            self.name = name
            self.boxISO = String(boxISO)
        }
    }

    struct Group {
        let title: String
        let stocks: [Stock]
    }

    static let groups: [Group] = [
        Group(title: "Colour negative", stocks: [
            Stock("Kodak Portra 160", 160), Stock("Kodak Portra 400", 400),
            Stock("Kodak Portra 800", 800), Stock("Kodak Gold 200", 200),
            Stock("Kodak UltraMax 400", 400), Stock("Kodak ColorPlus 200", 200),
            Stock("Kodak Ektar 100", 100), Stock("Fujifilm 200", 200),
            Stock("Fujifilm 400", 400), Stock("Fujicolor C200", 200),
            Stock("Fujicolor Pro 400H", 400), Stock("Harman Phoenix 200", 200),
            Stock("CineStill 50D", 50), Stock("CineStill 400D", 400),
            Stock("CineStill 800T", 800)
        ]),
        Group(title: "Black & white negative", stocks: [
            Stock("Ilford HP5 Plus 400", 400), Stock("Ilford FP4 Plus 125", 125),
            Stock("Ilford Delta 100", 100), Stock("Ilford Delta 400", 400),
            Stock("Ilford Delta 3200", 3200), Stock("Kodak Tri-X 400", 400),
            Stock("Kodak T-Max 100", 100), Stock("Kodak T-Max 400", 400),
            Stock("Kentmere 100", 100), Stock("Kentmere 400", 400),
            Stock("Fomapan 100", 100), Stock("Fomapan 200", 200), Stock("Fomapan 400", 400)
        ]),
        Group(title: "Motion-picture negative", stocks: [
            Stock("Kodak Vision3 50D", 50), Stock("Kodak Vision3 200T", 200),
            Stock("Kodak Vision3 250D", 250), Stock("Kodak Vision3 500T", 500)
        ])
    ]

    static func boxISO(for name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.lazy.flatMap(\.stocks).first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.boxISO
    }
}
