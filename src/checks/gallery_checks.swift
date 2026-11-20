import Foundation

func galleryChecks() -> [(String, Bool)] {
    let base = GalleryLook([
        "shape": "Wake",
        "palette": "Custom",
        "dither": "Bayer 4",
        "custom": ["#101010", "#444444", "#888888", "#CCCCCC", "#FFFFFF"],
        "seed": 46.2,
        "params": ["gravity": 0.4, "viscosity": 2]
    ])
    let palettes = base.variations(.palette), dithers = base.variations(.dither)
    func without(_ look: GalleryLook, _ keys: Set<String>) -> String {
        KYAML.emit(look.pattern.filter { !keys.contains($0.key) }, line: true)
    }
    let ids = Set(["a", "b", "c", "d"])
    var visited = Set<String>(), picks: [String] = []
    for _ in 0 ..< 12 {
        var cycle = SavedLookShuffle(visited: visited)
        if let id = cycle.next(in: ids, current: picks.last) { picks.append(id) }
        visited = cycle.visited
    }
    let completeRounds = picks.count == 12 && stride(from: 0, to: 12, by: 4).allSatisfy {
        Set(picks[$0 ..< $0 + 4]) == ids
    }
    var edited = SavedLookShuffle(visited: ["a", "deleted"])
    let fresh = edited.next(in: ["a", "new"], current: "a")
    let empty = edited.next(in: [], current: fresh)
    let only = edited.next(in: ["only"], current: "only")
    return [
        (
            "four distinct palette and dither previews include the original first",
            [palettes, dithers].allSatisfy { $0.count == 4 && Set($0.map(\.id)).count == 4 && $0.first?.id == base.id }
        ),
        (
            "palette variations preserve the original frame and simulation",
            palettes.allSatisfy { without($0, ["palette", "custom"]) == without(base, ["palette", "custom"]) }
        ),
        (
            "dither variations preserve embedded custom colours and all other settings",
            dithers.map(\.dither) == ["Bayer 4", "Bayer 8", "R2", "Smooth"] &&
                dithers.allSatisfy { without($0, ["dither"]) == without(base, ["dither"]) }
        ),
        ("saved shuffle completes every round across restored progress", completeRounds),
        (
            "saved shuffle avoids consecutive duplicates across rounds",
            zip(picks, picks.dropFirst()).allSatisfy { $0 != $1 }
        ),
        (
            "saved shuffle handles added, removed, empty and single looks",
            fresh == "new" && empty == nil && only == "only"
        )
    ]
}
