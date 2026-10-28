import Foundation
import Metal
import simd

struct PipeVertex {
    var pos: SIMD4<Float>
    var norm: SIMD4<Float>
}

struct PipeInstance {
    var c0: SIMD4<Float>
    var c1: SIMD4<Float>
    var c2: SIMD4<Float>
    var c3: SIMD4<Float>
}

struct PipeUniforms {
    var view: simd_float4x4
    var proj: simd_float4x4
    var params: SIMD4<Float>
}

struct PipeRNG {
    var state: UInt64

    init(seed: Float, cycle: Int) {
        let s = UInt64(seed.bitPattern) &* 0x9E37_79B9_7F4A_7C15
        let c = UInt64(bitPattern: Int64(cycle)) &+ 0xBF58_476D_1CE4_E5B9
        state = s ^ (c &* 0x94D0_49BB_1331_11EB) ^ 0xD6E8_FEB8_6659_FD93
        _ = raw()
    }

    mutating func raw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(raw() % UInt64(bound)) }
    mutating func range(_ lo: Int, _ hi: Int) -> Int { lo + next(hi - lo + 1) }
}

// Unit primitives matching Win98 SCRSAVE/PIPES/OBJECTS.CXX + GLAUX teapot.c
struct PipeMeshes {
    let buffer: MTLBuffer
    let cyl: Range<Int>, sph: Range<Int>, elb: Range<Int>, tea: Range<Int>

    init?(_ dev: MTLDevice) {
        var v: [PipeVertex] = []
        v.reserveCapacity(16_384)
        let c0 = v.count
        Self.appendCylinder(&v, slices: 24)
        let c1 = v.count
        Self.appendSphere(&v, slices: 24, stacks: 14)
        let c2 = v.count
        Self.appendElbow(&v, slices: 24, stacks: 12)
        let c3 = v.count
        UtahTeapot.append(to: &v, grid: 7, addTri: Self.addTri)
        let c4 = v.count
        guard let buf = dev.makeBuffer(bytes: v, length: v.count * MemoryLayout<PipeVertex>.stride) else { return nil }
        buffer = buf
        cyl = c0 ..< c1
        sph = c1 ..< c2
        elb = c2 ..< c3
        tea = c3 ..< c4
    }

    static func addTri(_ out: inout [PipeVertex], _ a: PipeVertex, _ b: PipeVertex, _ c: PipeVertex) {
        let ab = SIMD3(b.pos.x - a.pos.x, b.pos.y - a.pos.y, b.pos.z - a.pos.z)
        let ac = SIMD3(c.pos.x - a.pos.x, c.pos.y - a.pos.y, c.pos.z - a.pos.z)
        let avg = SIMD3(a.norm.x + b.norm.x + c.norm.x, a.norm.y + b.norm.y + c.norm.y, a.norm.z + b.norm.z + c.norm.z)
        out.append(a)
        if simd_dot(simd_cross(ab, ac), avg) >= 0 {
            out.append(b)
            out.append(c)
        } else {
            out.append(c)
            out.append(b)
        }
    }

    private static func appendCylinder(_ out: inout [PipeVertex], slices: Int) {
        for i in 0 ..< slices {
            let a0 = Float(i) * (2 * .pi / Float(slices)), a1 = Float(i + 1) * (2 * .pi / Float(slices))
            let n0 = SIMD4<Float>(cos(a0), sin(a0), 0, 0), n1 = SIMD4<Float>(cos(a1), sin(a1), 0, 0)
            let p00 = PipeVertex(pos: SIMD4(n0.x, n0.y, 0, 1), norm: n0)
            let p10 = PipeVertex(pos: SIMD4(n1.x, n1.y, 0, 1), norm: n1)
            let p01 = PipeVertex(pos: SIMD4(n0.x, n0.y, 1, 1), norm: n0)
            let p11 = PipeVertex(pos: SIMD4(n1.x, n1.y, 1, 1), norm: n1)
            addTri(&out, p00, p10, p11)
            addTri(&out, p00, p11, p01)
        }
    }

    private static func appendSphere(_ out: inout [PipeVertex], slices: Int, stacks: Int) {
        func vert(_ st: Int, _ sl: Int) -> PipeVertex {
            let ph = Float(st) * (.pi / Float(stacks)), th = Float(sl) * (2 * .pi / Float(slices))
            let n = SIMD3<Float>(sin(ph) * cos(th), sin(ph) * sin(th), cos(ph))
            return PipeVertex(pos: SIMD4(n, 1), norm: SIMD4(n, 0))
        }
        for j in 0 ..< stacks {
            for i in 0 ..< slices {
                let p00 = vert(j, i), p10 = vert(j, i + 1), p01 = vert(j + 1, i), p11 = vert(j + 1, i + 1)
                if j > 0 { addTri(&out, p00, p10, p11) }
                if j + 1 < stacks { addTri(&out, p00, p11, p01) }
            }
        }
    }

    private static func appendElbow(_ out: inout [PipeVertex], slices: Int, stacks: Int) {
        func vert(_ st: Int, _ sl: Int) -> PipeVertex {
            let th = Float(st) * (0.5 * .pi / Float(stacks)), ph = Float(sl) * (2 * .pi / Float(slices))
            let ct = cos(th), stn = sin(th), cp = cos(ph), sp = sin(ph)
            return PipeVertex(
                pos: SIMD4((1 + cp) * ct, (1 + cp) * stn, sp, 1),
                norm: SIMD4(cp * ct, cp * stn, sp, 0)
            )
        }
        for j in 0 ..< stacks {
            for i in 0 ..< slices {
                let p00 = vert(j, i), p10 = vert(j, i + 1), p01 = vert(j + 1, i), p11 = vert(j + 1, i + 1)
                addTri(&out, p00, p10, p11)
                addTri(&out, p00, p11, p01)
            }
        }
    }
}

let kPipeDirs: [SIMD3<Float>] = [
    SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)
]
private let kPipeSteps: [SIMD3<Int>] = [
    SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)
]
let kCylU: [SIMD3<Float>] = [
    SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)
]
let kCylV: [SIMD3<Float>] = [
    SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)
]

enum PipePrimKind {
    case cyl(dir: Int, long: Bool)
    case cap
    case ball
    case elb(dIn: Int, dOut: Int)
    case tea(yaw: Float)
}

struct PipePrim {
    let kind: PipePrimKind
    let pos: SIMD3<Float>
    let mat: UInt8
    let tick: Float
}

// Win98 SCRSAVE/PIPES/STATE.CXX + NPIPE.CXX + NODE.CXX 3D grid state machine
struct PipeScene {
    let key: [Int]
    let prims: [PipePrim]
    let totalTicks: Int
    let collisions: Int

    private struct Cursor {
        var pos: SIMD3<Int>, lastDir: Int, weightStraight: Int, mat: UInt8
        var isLead: Bool, furthest = false, stuck = false
    }

    private struct Sim {
        let nx: Int, ny: Int, nz: Int, jointMode: Int, chase: Bool
        var taken: [Bool]
        var collisions = 0, spawned = 0, usedNodes = 0
        var prims: [PipePrim] = []
        var rng: PipeRNG

        func valid(_ p: SIMD3<Int>) -> Bool {
            p.x >= 0 && p.x < nx && p.y >= 0 && p.y < ny && p.z >= 0 && p.z < nz
        }

        func isEmpty(_ p: SIMD3<Int>) -> Bool { valid(p) && !taken[(p.z * ny + p.y) * nx + p.x] }

        mutating func claim(_ p: SIMD3<Int>) {
            let idx = (p.z * ny + p.y) * nx + p.x
            if taken[idx] { collisions += 1 }
            taken[idx] = true
        }

        func world(_ p: SIMD3<Int>) -> SIMD3<Float> {
            SIMD3(
                (Float(p.x) - Float(nx - 1) * 0.5) * 7.0,
                (Float(p.y) - Float(ny - 1) * 0.5) * 7.0,
                (Float(p.z) - Float(nz - 1) * 0.5) * 7.0
            )
        }

        mutating func takeStart(prev: Cursor?) -> SIMD3<Int>? {
            var empty: [SIMD3<Int>] = []
            empty.reserveCapacity(taken.count)
            for z in 0 ..< nz {
                for y in 0 ..< ny {
                    for x in 0 ..< nx where !taken[(z * ny + y) * nx + x] {
                        empty.append(SIMD3(x, y, z))
                    }
                }
            }
            guard !empty.isEmpty else { return nil }
            let pick: SIMD3<Int>
            if let prev, prev.furthest {
                let c = prev.pos
                let ref = SIMD3(c.x >= nx / 2 ? 0 : nx - 1, c.y >= ny / 2 ? 0 : ny - 1, c.z >= nz / 2 ? 0 : nz - 1)
                pick = empty.min {
                    abs($0.x - ref.x) + abs($0.y - ref.y) + abs($0.z - ref.z) <
                        abs($1.x - ref.x) + abs($1.y - ref.y) + abs($1.z - ref.z)
                } ?? empty[0]
            } else {
                pick = empty[rng.next(empty.count)]
            }
            claim(pick)
            return pick
        }

        mutating func chooseDir(pos: SIMD3<Int>, lastDir: Int, weight: Int, lead: SIMD3<Int>?, start: Bool) -> Int? {
            if let lead {
                var pref: [Int] = []
                if lead.x != pos.x { pref.append(lead.x > pos.x ? 0 : 1) }
                if lead.y != pos.y { pref.append(lead.y > pos.y ? 2 : 3) }
                if lead.z != pos.z { pref.append(lead.z > pos.z ? 4 : 5) }
                let open = pref.filter { $0 != (lastDir ^ 1) && isEmpty(pos &+ kPipeSteps[$0]) }
                if !open.isEmpty { return open[rng.next(open.count)] }
            }
            let straightOK = isEmpty(pos &+ kPipeSteps[lastDir])
            if straightOK, weight == 100 { return lastDir }
            let w = straightOK ? weight : 0
            let turns = (0 ..< 6)
                .filter { $0 != lastDir && (start || $0 != (lastDir ^ 1)) && isEmpty(pos &+ kPipeSteps[$0]) }
            let total = w + turns.count
            guard total > 0 else { return nil }
            let pick = rng.next(total)
            return pick < w ? lastDir : turns[pick - w]
        }

        mutating func spawn(tick: Int, lead: Bool, prev: Cursor?, avoiding mats: [UInt8]) -> Cursor? {
            guard let pos = takeStart(prev: prev) else { return nil }
            let weight = rng.next(20) == 0 ? rng.range(25, 100) : rng.range(1, 4)
            let free = (0 ..< 12).map(UInt8.init).filter { !mats.contains($0) }
            let mat = free.isEmpty ? UInt8(rng.next(12)) : free[rng.next(free.count)]
            let initDir = rng.next(6)
            guard let dir = chooseDir(pos: pos, lastDir: initDir, weight: weight, lead: nil, start: true) else {
                prims.append(PipePrim(
                    kind: .tea(yaw: Float(rng.next(4)) * (.pi * 0.5)),
                    pos: world(pos),
                    mat: mat,
                    tick: Float(tick)
                ))
                return Cursor(
                    pos: pos,
                    lastDir: initDir,
                    weightStraight: weight,
                    mat: mat,
                    isLead: lead,
                    furthest: prev?.furthest ?? false,
                    stuck: true
                )
            }
            let nxt = pos &+ kPipeSteps[dir], wp = world(pos)
            claim(nxt)
            prims.append(PipePrim(kind: .cap, pos: wp, mat: mat, tick: Float(tick)))
            prims.append(PipePrim(kind: .cyl(dir: dir, long: false), pos: wp, mat: mat, tick: Float(tick)))
            return Cursor(
                pos: nxt,
                lastDir: dir,
                weightStraight: weight,
                mat: mat,
                isLead: lead,
                furthest: prev?.furthest ?? false
            )
        }

        mutating func respawn(_ threads: inout [Cursor], tick: Int) {
            var next: [Cursor] = []
            var promote = false
            for cur in threads {
                if !cur.stuck {
                    next.append(cur)
                    continue
                }
                let active = next.map(\.mat) + threads.filter { !$0.stuck }.map(\.mat)
                if spawned < (usedNodes < 260 ? 14 : 9), let rep = spawn(
                    tick: tick,
                    lead: cur.isLead,
                    prev: cur,
                    avoiding: active
                ) {
                    spawned += 1
                    usedNodes += rep.stuck ? 1 : 2
                    next.append(rep)
                } else if chase, cur.isLead {
                    promote = true
                }
            }
            if promote, !next.isEmpty {
                let i = rng.next(next.count)
                next[i].isLead = true
                next[i].furthest = true
            }
            threads = next
        }

        mutating func step(_ cur: inout Cursor, tick: Int, lead: SIMD3<Int>?) {
            let wp = world(cur.pos), tf = Float(tick)
            guard let dir = chooseDir(
                pos: cur.pos,
                lastDir: cur.lastDir,
                weight: cur.weightStraight,
                lead: lead,
                start: false
            )
            else {
                prims.append(PipePrim(kind: .cap, pos: wp, mat: cur.mat, tick: tf))
                cur.stuck = true
                return
            }
            claim(cur.pos &+ kPipeSteps[dir])
            usedNodes += 1
            if dir == cur.lastDir {
                prims.append(PipePrim(kind: .cyl(dir: dir, long: true), pos: wp, mat: cur.mat, tick: tf))
            } else {
                let joint: PipePrimKind = if jointMode == 0 {
                    .elb(dIn: cur.lastDir, dOut: dir)
                } else if jointMode == 2 {
                    .ball
                } else if rng.next(350) == 153 {
                    .tea(yaw: Float(rng.next(4)) * (.pi * 0.5))
                } else {
                    rng.next(3) == 0 ? .ball : .elb(dIn: cur.lastDir, dOut: dir)
                }
                prims.append(PipePrim(kind: joint, pos: wp, mat: cur.mat, tick: tf))
                prims.append(PipePrim(kind: .cyl(dir: dir, long: false), pos: wp, mat: cur.mat, tick: tf))
            }
            cur.pos &+= kPipeSteps[dir]
            cur.lastDir = dir
        }
    }

    static func simulate(seed: Float, cycle: Int, aspect: Float, jointMode: Int) -> PipeScene {
        let ar = max(aspect, 0.5)
        let nx = ar >= 1 ? max(11, min(23, Int((11.0 * ar).rounded()))) : 11
        let ny = ar >= 1 ? 11 : max(11, min(23, Int((11.0 / ar).rounded())))
        let nz = 15
        var rng = PipeRNG(seed: seed, cycle: cycle)
        let nThreads = rng.range(2, 4), chase = rng.next(5) == 0
        var sim = Sim(
            nx: nx, ny: ny, nz: nz, jointMode: jointMode, chase: chase,
            taken: [Bool](repeating: false, count: nx * ny * nz), rng: rng
        )
        sim.prims.reserveCapacity(1_024)
        var threads: [Cursor] = []
        for i in 0 ..< nThreads {
            if var c = sim.spawn(tick: 0, lead: chase && i == 0, prev: nil, avoiding: threads.map(\.mat)) {
                if c.isLead { c.furthest = true }
                threads.append(c)
                sim.spawned += 1
                sim.usedNodes += c.stuck ? 1 : 2
            }
        }
        var tick = 1
        while !threads.isEmpty, tick < 2_500 {
            sim.respawn(&threads, tick: tick)
            let leadPos = chase ? threads.first(where: \.isLead)?.pos : nil
            for idx in threads.indices where !threads[idx].stuck {
                sim.step(&threads[idx], tick: tick, lead: threads[idx].isLead ? nil : leadPos)
            }
            tick += 1
        }
        return PipeScene(
            key: [Int(seed.bitPattern), cycle, nx, ny, nz, jointMode],
            prims: sim.prims, totalTicks: max(tick, 1), collisions: sim.collisions
        )
    }
}
