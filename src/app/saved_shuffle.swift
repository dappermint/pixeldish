import Foundation

struct SavedLookShuffle {
    var visited: Set<String>

    mutating func next(in ids: Set<String>, current: String?) -> String? {
        visited.formIntersection(ids)
        if visited == ids { visited.removeAll() }
        let remaining = ids.subtracting(visited)
        let other = remaining.filter { $0 != current }
        guard let next = other.randomElement() ?? remaining.randomElement() else { return nil }
        visited.insert(next)
        return next
    }
}

extension AppDelegate {
    func shuffleIfDue() {
        if Pref.d.bool(forKey: "autoShuffle"), Date().timeIntervalSince(lastShuffle) >= 3_600 { shuffle() }
    }

    func shuffleSavedLook() {
        let saved = savedLooks()
        let ids = Set(saved.compactMap { $0["id"] as? String })
        let current = Pref.d.bool(forKey: "isPhoto") ? nil : currentPattern()["id"] as? String
        let key = "savedShuffleVisited"
        var cycle = SavedLookShuffle(visited: Set(Pref.d.stringArray(forKey: key) ?? []))
        let id = cycle.next(in: ids, current: current)
        Pref.d.set(cycle.visited.sorted(), forKey: key)
        guard let id, id != current, let look = Config.resolve(id, saved) else { return }
        selectLook(look)
    }
}
