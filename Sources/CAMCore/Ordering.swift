import Foundation

/// Reordering a job so the machine needs as few bit changes as possible, without breaking the orders that matter.
///
/// Fixed rules (within each step of a two-sided job: dowel holes, side A, side B, which keep their order):
/// - an operation that follows another (rest machining, a finishing cutout) stays after it;
/// - facing keeps its place relative to everything else;
/// - 3D finishing (parallel, waterline) comes after the roughing and pockets that clear its area, or a ball nose would
///   plunge into uncut material;
/// - cutouts that cut the part free stay after everything else on their side.
/// Within those, operations with the tool in the spindle go first; when the tool must change, the earliest operation
/// (in the current order) that may run next decides the new tool. Otherwise the current order is kept.
extension JobTemplates {
    /// Bit changes the job needs: consecutive enabled operations with different tools.
    public static func toolChanges(_ ops: [Operation]) -> Int {
        let tools = ops.filter(\.enabled).map(\.tool.id)
        return zip(tools, tools.dropFirst()).filter { $0 != $1 }.count
    }

    /// True for a cutout that cuts the part free (not one that stops above the stock bottom or at a depth limit).
    static func cutsFree(_ op: Operation) -> Bool {
        op.kind == .cutout && !(op.stockToLeaveZ > 0) && op.maxDepth == nil
    }

    /// Clears bulk material that a 3D finish relies on being gone.
    static func clearsForFinishing(_ op: Operation) -> Bool {
        (op.kind == .roughing || op.kind == .pocket || op.kind == .facing) && op.restFromOp == nil && op.restFrom == nil
    }

    static func isFinish(_ op: Operation) -> Bool { op.kind == .parallelFinish || op.kind == .waterlineFinish }

    /// `ops` reordered for the fewest bit changes under the rules above. Stable: nothing moves without a reason.
    public static func orderedForFewestToolChanges(_ ops: [Operation]) -> [Operation] {
        var out: [Operation] = []
        var current: UUID? = nil
        for stage in FlipStage.allCases {
            let group = ops.filter { $0.flipStage == stage }
            let n = group.count
            guard n > 0 else { continue }
            // must[j]: indices (in `group`) that have to run before j.
            var must = [Set<Int>](repeating: [], count: n)
            for j in 0..<n {
                let b = group[j]
                for i in 0..<n where i != j {
                    let a = group[i]
                    var before = false
                    if b.restFromOp == a.id && i < j { before = true }
                    if b.restFromOp == nil, let t = b.restFrom, a.tool.id == t.id, i < j { before = true }
                    if (a.kind == .facing || b.kind == .facing) && i < j { before = true }
                    if isFinish(b) && clearsForFinishing(a) { before = true }
                    // A slot cut from what's left must see the clearing above it done first.
                    if b.kind == .slot && b.cutsLeftoverOnly && clearsForFinishing(a) && i < j { before = true }
                    if cutsFree(b) && (!cutsFree(a) || i < j) { before = true }
                    if before { must[j].insert(i) }
                }
            }
            var done = [Bool](repeating: false, count: n)
            for _ in 0..<n {
                let ready = (0..<n).filter { j in !done[j] && must[j].allSatisfy { done[$0] } }
                // Conflicting rules (an odd hand-made order) leave nothing ready: keep the current order from there.
                let pick = ready.first { group[$0].enabled && group[$0].tool.id == current }
                    ?? ready.first { !group[$0].enabled }
                    ?? ready.first
                    ?? (0..<n).first { !done[$0] }!
                done[pick] = true
                out.append(group[pick])
                if group[pick].enabled { current = group[pick].tool.id }
            }
        }
        return out
    }
}
