import Foundation
import Darwin

/// 自分(Idaten)と、自分が抱えている WebKit・Chromium のプロセスを合算して、いま使っているメモリを測る。
/// 中身は tools/footprint/ の footprint-cli と同じ考え方:
///   - RSS でなく `ri_phys_footprint`(圧縮・スワップ込み。Activity Monitor の「メモリ」と同じ会計)
///   - 子プロセス(Chromium の Helper)は親子関係で、WebKit の WebContent/GPU/Networking は
///     launchd の子(ppid=1)なので responsible pid で拾う
///
/// 測れなかったプロセスは黙って落とさず数える。合計だけ見て「全部拾えた」と思い込まないため。
enum Footprint {
    struct Result {
        var bytes: UInt64
        var processes: Int
        /// 測れなかったプロセス数(権限・終了直後など)。0 でなければ表示に「一部未取得」と出す
        var missed: Int
        var mib: Double { Double(bytes) / 1_048_576 }
    }

    static func measure(roots: [pid_t]) -> Result {
        var family = Set<pid_t>()
        let all = allPids()
        var parents: [pid_t: pid_t] = [:]
        for p in all { if let pp = parentPid(p) { parents[p] = pp } }

        func isDescendant(_ pid: pid_t) -> Bool {
            var cur = pid
            for _ in 0..<32 {                       // 循環・深すぎる系図で止まらないように上限を置く
                guard let parent = parents[cur], parent > 1 else { return false }
                if roots.contains(parent) { return true }
                cur = parent
            }
            return false
        }

        for pid in all {
            if roots.contains(pid) || isDescendant(pid) || roots.contains(responsiblePid(pid)) {
                family.insert(pid)
            }
        }

        var total: UInt64 = 0
        var missed = 0
        for pid in family {
            if let bytes = footprintBytes(pid) { total += bytes } else { missed += 1 }
        }
        return Result(bytes: total, processes: family.count, missed: missed)
    }

    // MARK: - 下回り

    private static func allPids() -> [pid_t] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size)
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, count)
        guard size > 0 else { return [] }
        return pids.filter { $0 > 0 }
    }

    private static func parentPid(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func footprintBytes(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        return usage.ri_phys_footprint
    }
}

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

private func responsiblePid(_ pid: pid_t) -> pid_t {
    let r = responsibility_get_pid_responsible_for_pid(pid)
    return r > 0 ? r : -1
}
