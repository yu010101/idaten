// footprint-cli — あるアプリに属する全プロセスの physical footprint を時系列で測る。
//
// なぜ RSS でないか: RSS は圧縮メモリとスワップを含まない。「常駐7.1MB」と報告したものが
// 実際は319MBだった前例がある。ri_phys_footprint は圧縮・スワップ分を含む(Activity Monitor の「メモリ」と同じ量)。
//
// 「属する」の決め方(ここを誤ると隣のものを測る):
//   1. 親子関係(ppid)で root の子孫 — Chromium の Helper はこれで拾える
//   2. responsible pid が集合内 — WebKit の WebContent/Networking は launchd の子(ppid=1)なので親子では拾えない
//   端末から直接バイナリを起動すると responsible pid が端末アプリになる。計測対象は `open -n -a` で起動すること。
//
// 使い方:
//   footprint-cli --pid <root pid> [--interval 1] [--duration 60] [--csv out.csv] [--by-proc]
//   footprint-cli --pid <root pid> --once            1回だけ測って内訳を出す(自己検査用)

import Foundation
import Darwin

@_silgen_name("responsibility_get_pid_responsible_for_pid")
func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

struct ProcSample {
    let pid: pid_t
    let name: String
    let footprint: UInt64      // bytes
    let cpuNanos: UInt64       // user+system, ナノ秒に換算済み
}

// Apple Silicon では ri_user_time / ri_system_time は mach absolute time 単位。ナノ秒へは timebase で換算する
let timebase: mach_timebase_info_data_t = {
    var t = mach_timebase_info_data_t()
    mach_timebase_info(&t)
    return t
}()
func toNanos(_ machTime: UInt64) -> UInt64 {
    return machTime * UInt64(timebase.numer) / UInt64(timebase.denom)
}

func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var buf = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    guard got > 0 else { return [] }
    return Array(buf.prefix(Int(got))).filter { $0 > 0 }
}

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard r == size else { return nil }
    return pid_t(info.pbi_ppid)
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let r = proc_pidpath(pid, &buf, UInt32(buf.count))
    if r > 0 { return (String(cString: buf) as NSString).lastPathComponent }
    var nbuf = [CChar](repeating: 0, count: 256)
    proc_name(pid, &nbuf, UInt32(nbuf.count))
    return String(cString: nbuf)
}

func sample(_ pid: pid_t) -> ProcSample? {
    var ri = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard r == 0 else { return nil }   // 終了済み・権限なしは数えない(数えたふりをしない)
    return ProcSample(pid: pid, name: procName(pid), footprint: ri.ri_phys_footprint,
                      cpuNanos: toNanos(ri.ri_user_time) + toNanos(ri.ri_system_time))
}

/// root から、親子関係と responsible pid の両方で閉包をとる
func family(of root: pid_t) -> [pid_t] {
    let pids = allPids()
    var parent: [pid_t: pid_t] = [:]
    var responsible: [pid_t: pid_t] = [:]
    for p in pids {
        if let pp = parentPid(p) { parent[p] = pp }
        let rp = responsibility_get_pid_responsible_for_pid(p)
        if rp > 0 { responsible[p] = rp }
    }
    var members: Set<pid_t> = [root]
    var grew = true
    while grew {
        grew = false
        for p in pids where !members.contains(p) {
            if let pp = parent[p], members.contains(pp) { members.insert(p); grew = true; continue }
            if let rp = responsible[p], rp != p, members.contains(rp) { members.insert(p); grew = true }
        }
    }
    return members.sorted()
}

// 1,048,576 で割るので単位は MiB。MB(10^6)ではない
func mb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1_048_576.0) }

func percentile(_ xs: [UInt64], _ q: Double) -> UInt64 {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let idx = min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))
    return s[idx]
}

// ---- 引数 ----
var rootPid: pid_t = 0
var interval = 1.0
var duration = 60.0
var csvPath: String? = nil
var byProc = false
var once = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--pid": rootPid = pid_t(it.next() ?? "") ?? 0
    case "--interval": interval = Double(it.next() ?? "") ?? 1.0
    case "--duration": duration = Double(it.next() ?? "") ?? 60.0
    case "--csv": csvPath = it.next()
    case "--by-proc": byProc = true
    case "--once": once = true
    default:
        FileHandle.standardError.write("unknown arg: \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}
guard rootPid > 0, kill(rootPid, 0) == 0 || errno == EPERM else {
    FileHandle.standardError.write("usage: footprint-cli --pid <root pid> [--interval s] [--duration s] [--csv path] [--by-proc] [--once]\n".data(using: .utf8)!)
    exit(2)
}

if once {
    let samples = family(of: rootPid).compactMap(sample)
    for s in samples.sorted(by: { $0.footprint > $1.footprint }) {
        print("\(s.pid)\t\(mb(s.footprint)) MiB\t\(s.name)")
    }
    let total = samples.reduce(UInt64(0)) { $0 + $1.footprint }
    print("TOTAL\t\(mb(total)) MiB\tprocs=\(samples.count)")
    exit(0)
}

var csv = "t_sec,nprocs,footprint_bytes,cpu_nanos\n"
var totals: [UInt64] = []
var firstCpu: UInt64? = nil
var lastCpu: UInt64 = 0
let start = Date()
while Date().timeIntervalSince(start) < duration {
    let samples = family(of: rootPid).compactMap(sample)
    if samples.isEmpty { break }   // root が消えた
    let total = samples.reduce(UInt64(0)) { $0 + $1.footprint }
    let cpu = samples.reduce(UInt64(0)) { $0 + $1.cpuNanos }
    if firstCpu == nil { firstCpu = cpu }
    lastCpu = cpu
    totals.append(total)
    let t = Date().timeIntervalSince(start)
    csv += String(format: "%.1f,%d,%llu,%llu\n", t, samples.count, total, cpu)
    if byProc {
        for s in samples.sorted(by: { $0.footprint > $1.footprint }).prefix(5) {
            FileHandle.standardError.write("  \(s.pid) \(mb(s.footprint))MB \(s.name)\n".data(using: .utf8)!)
        }
    }
    Thread.sleep(forTimeInterval: interval)
}
if let p = csvPath { try? csv.write(toFile: p, atomically: true, encoding: .utf8) }
// CPU は「測定区間内の増分」。プロセスの出入りがあるので目安であり、厳密な積算ではない
let cpuDelta = lastCpu >= (firstCpu ?? 0) ? lastCpu - (firstCpu ?? 0) : 0
print("samples=\(totals.count) median_mb=\(mb(percentile(totals, 0.5))) p95_mb=\(mb(percentile(totals, 0.95))) peak_mb=\(mb(totals.max() ?? 0)) cpu_delta_sec=\(String(format: "%.2f", Double(cpuDelta) / 1e9))")
