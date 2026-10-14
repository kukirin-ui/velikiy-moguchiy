import Cocoa
import SwiftUI
import Combine

// MARK: - helpers

typealias J = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String? { self[k] as? String }
    func d(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func i(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
    func b(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? false }
    func o(_ k: String) -> J? { self[k] as? J }
}

let ruLocale = Locale(identifier: "ru_RU")
func num(_ v: Double?, _ digits: Int = 0) -> String {
    guard let v = v else { return "—" }
    let f = NumberFormatter()
    f.locale = ruLocale
    f.numberStyle = .decimal
    f.minimumFractionDigits = digits
    f.maximumFractionDigits = digits
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}
func num(_ v: Int?) -> String { num(v.map(Double.init), 0) }

func dur(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes) мин" }
    let h = minutes / 60, m = minutes % 60
    if h < 48 { return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин" }
    return "\(h / 24) д \(h % 24) ч"
}
func durSec(_ s: Int) -> String { s < 60 ? "\(s) с" : dur(s / 60) }
func ago(_ s: Int) -> String { s < 60 ? "\(s) с назад" : dur(s / 60) + " назад" }

// MARK: - данные

struct Line: Identifiable {
    let id = UUID()
    var label: String
    var text: String
    var color: Color? = nil
    var bar: Double? = nil
    var dot: String? = nil   // подзаголовок с точкой (сервер в секции RunPod)
}

struct Section: Identifiable {
    let id: String
    var name: String
    var dot: String
    var stateText: String
    var uptime: String?
    var summary: String
    var lines: [Line]
}

let errNames: [(String, String)] = [("bot", "бот"), ("throttle", "403/429"), ("unavailable", "недоступно"),
                                    ("ffmpeg", "ffmpeg"), ("noface", "нет лица"), ("other", "прочее")]

func errString(_ d: J?) -> String {
    guard let d = d else { return "нет" }
    let parts = errNames.compactMap { (k, n) -> String? in
        let c = d.i(k) ?? 0
        return c > 0 ? "\(n) \(num(c))" : nil
    }
    return parts.isEmpty ? "нет" : parts.joined(separator: " · ")
}

func commonLines(_ d: J, stuckColor: Bool = true) -> [Line] {
    var out: [Line] = []
    if let g = d.o("group") {
        var p = ["CPU \(num(g.d("cpu"), 0))%", "RAM \(num((g.d("rss_mb") ?? 0) / 1024, 1)) ГБ"]
        if let c = g.i("children") { p.append("процессов \(c + 1)") }
        out.append(Line(label: "Ресурсы", text: p.joined(separator: " · ")))
    }
    return out
}

func logLine(_ d: J) -> Line? {
    guard let l = d.o("last_log"), let t = l.s("text") else { return nil }
    let age = l.i("age_s") ?? 0
    let stuck = d.b("stuck")
    var txt = "\(l.s("time") ?? "") (\(ago(age))) \(t)"
    if stuck { txt += " — возможно завис" }
    return Line(label: "Лог", text: txt, color: stuck ? .yellow : nil)
}

func memLine(_ d: J) -> Line? {
    guard let m = d.o("mem_guard") else { return nil }
    var parts: [String] = []
    if let e = m.s("last_event") {
        let ev = e.replacingOccurrences(of: "[mem_guard] ", with: "")
        parts.append("\(ev)\(m.s("last_event_time").map { " (\($0))" } ?? "")")
    }
    parts.append("пауз за час \(m.i("pauses_1h") ?? 0)")
    return Line(label: "mem_guard", text: parts.joined(separator: " · "), color: m.b("paused_now") ? .yellow : nil)
}

func errorLines(_ d: J) -> [Line] {
    guard let e = d.o("errors") else { return [] }
    var out: [Line] = []
    out.append(Line(label: "Ошибки 10м", text: errString(e.o("recent"))))
    out.append(Line(label: "Всего", text: errString(e.o("total"))))
    if let l = e.o("last"), let t = l.s("text") {
        out.append(Line(label: "Последняя", text: "\(l.s("time") ?? "") \(t)"))
    }
    return out
}

func buildSections(_ root: J) -> [Section] {
    var res: [Section] = []

    if let d = root.o("multivsr") {
        var ls: [Line] = []
        if let s = d.s("stage") { ls.append(Line(label: "Этап", text: s)) }
        if let t = d.d("target_hours"), let h = d.d("hours") {
            var txt = "\(num(h, 1)) из \(num(t, 0)) ч"
            if let p = d.i("percent") { txt += " (\(p)%)" }
            if let e = d.i("eta_min") { txt += " · ещё ≈ \(dur(e))" }
            ls.append(Line(label: "Прогресс", text: txt, bar: min(1, h / max(t, 0.01))))
        }
        var sp = ["\(num(d.d("clips_per_min"), 1)) клипов/мин", "\(num(d.d("hours_per_hour"), 1)) ч/ч"]
        if let dl = d.d("download_mb_s") { sp.append("загрузка \(num(dl, 1)) МБ/с") }
        ls.append(Line(label: "Скорость", text: sp.joined(separator: " · ")))
        var q: [String] = []
        if let c = d.i("queue_crop") { q.append("скачано, не нарезано \(num(c))") }
        if let f = d.i("queue_features") { q.append("нарезано, без признаков \(num(f))") }
        if !q.isEmpty { ls.append(Line(label: "Очереди", text: q.joined(separator: " · "))) }
        var w: [String] = []
        if let n = d.i("workers") { w.append("загрузка \(n)") }
        if let n = d.i("crop_procs") { w.append("кроп \(n)") }
        if let c = d.s("worker_change") { w.append(c) }
        if !w.isEmpty { ls.append(Line(label: "Потоки", text: w.joined(separator: " · "))) }
        ls += errorLines(d)
        if let m = memLine(d) { ls.append(m) }
        ls += commonLines(d)
        if let l = logLine(d) { ls.append(l) }
        let summary = "\(num(d.i("clips"))) кл · \(num(d.d("hours"), 1)) ч · \(num(d.d("clips_per_min"), 0))/мин"
        res.append(Section(id: "multivsr", name: "MultiVSR", dot: d.s("dot") ?? "gray", stateText: d.s("state_text") ?? "",
                           uptime: d.i("uptime_s").map(durSec), summary: summary, lines: ls))
    }

    if let d = root.o("features") {
        var ls: [Line] = []
        if let s = d.s("stage") { ls.append(Line(label: "Этап", text: s)) }
        if let n = d.i("npy"), let c = d.i("clips"), c > 0 {
            var txt = "\(num(n)) из \(num(c)) клипов"
            if let p = d.i("percent") { txt += " (\(p)%)" }
            if let e = d.i("eta_min") { txt += " · ещё ≈ \(dur(e))" }
            ls.append(Line(label: "Прогресс", text: txt, bar: Double(n) / Double(c)))
        }
        var sp = ["\(num(d.d("clips_per_min"), 1)) клипов/мин"]
        if let s = d.d("clips_per_s_session") { sp.append("за сессию \(num(s, 1)) клип/с") }
        ls.append(Line(label: "Скорость", text: sp.joined(separator: " · ")))
        if let f = d.i("queue_features") { ls.append(Line(label: "Очереди", text: "без признаков \(num(f))")) }
        if let e = d.o("errors") {
            ls.append(Line(label: "Ошибки", text: "MPS OOM за 10 мин \(e.i("oom_10min") ?? 0) · файлов .err \(e.i("npy_err_files") ?? 0)"))
        }
        if let m = memLine(d) { ls.append(m) }
        ls += commonLines(d)
        if let l = logLine(d) { ls.append(l) }
        let summary = "\(num(d.i("npy"))) призн. · \(num(d.d("clips_per_min"), 0))/мин"
        res.append(Section(id: "features", name: "Признаки VTP", dot: d.s("dot") ?? "gray", stateText: d.s("state_text") ?? "",
                           uptime: d.i("uptime_s").map(durSec), summary: summary, lines: ls))
    }

    if let d = root.o("newdata") {
        var ls: [Line] = []
        if let s = d.s("stage") { ls.append(Line(label: "Этап", text: s)) }
        if let f = d.o("funnel") {
            let names: [(String, String)] = [("candidates", "кандидатов"), ("genre", "жанр"), ("face", "лицо крупное"),
                                             ("sync", "синхрон губ"), ("asr", "GigaAM"), ("accepted", "принято")]
            let parts = names.compactMap { (k, n) in f.i(k).map { "\(n) \(num($0))" } }
            var txt = parts.joined(separator: " → ")
            if let h = d.d("hours") { txt += " · \(num(h, 1)) ч" }
            ls.append(Line(label: "Воронка", text: txt))
        }
        if !d.b("entry_found") && d.s("state") == "stopped" {
            ls.append(Line(label: "Заметка", text: "в newdata/ ещё нет скрипта сборщика", color: .secondary))
        }
        ls += commonLines(d)
        if let l = logLine(d) { ls.append(l) }
        let accepted = d.o("funnel")?.i("accepted")
        res.append(Section(id: "newdata", name: "Новые видео", dot: d.s("dot") ?? "gray", stateText: d.s("state_text") ?? "",
                           uptime: d.i("uptime_s").map(durSec), summary: accepted.map { "принято \(num($0))" } ?? "", lines: ls))
    }

    if let d = root.o("app") {
        var ls: [Line] = []
        if let a = d.i("last_dictation_age_s") {
            ls.append(Line(label: "Диктовка", text: "последняя \(ago(a)) (\(d.s("last_dictation_time") ?? ""))"))
        }
        ls += commonLines(d)
        res.append(Section(id: "app", name: "Великий & Могучий", dot: d.s("dot") ?? "gray", stateText: d.s("state_text") ?? "",
                           uptime: d.i("uptime_s").map(durSec), summary: "", lines: ls))
    }

    if let d = root.o("runpod") {
        var ls: [Line] = []
        let pods = (d["pods"] as? [J]) ?? []
        for p in pods {
            var head = [p.s("gpu") ?? ""].filter { !$0.isEmpty }
            head.append(p.b("alive") ? "работает" : "нет данных > 10 мин")
            if let a = p.i("hb_age_s"), p.b("alive") { head.append("пульс \(ago(a))") }
            ls.append(Line(label: "", text: head.joined(separator: " · "), color: p.b("alive") ? nil : .yellow, dot: p.s("dot") ?? "gray"))
            ls[ls.count - 1].label = p.s("name") ?? ""
            if p.i("clips") != nil {
                ls.append(Line(label: "Клипы", text: "\(num(p.i("clips"))) на сервере · признаков \(num(p.i("features")))"))
                var sp = ["\(num(p.d("clips_per_min"), 1)) клипов/мин", "\(num(p.d("hours_per_hour"), 2)) ч/ч"]
                if let t = p.i("threads") { sp.append("потоков \(t)") }
                ls.append(Line(label: "Скорость", text: sp.joined(separator: " · ")))
                var gp = "GPU \(num(p.i("gpu_util")))%"
                if let m = p.d("gpu_mib") { gp += " · \(num(m / 1024, 1)) ГБ" }
                gp += " · диск своб \(num(p.d("disk_free_gb"), 0)) ГБ"
                var ln = Line(label: "Ресурсы", text: gp)
                let bad = (p.s("fetch") ?? "running") != "running" || (p.s("features_worker") ?? "running") != "running"
                if bad {
                    ln.text += " · сборщик \(p.s("fetch") ?? "—"), признаки \(p.s("features_worker") ?? "—")"
                    ln.color = .yellow
                }
                ls.append(ln)
            }
            if let b = p.o("backup") {
                ls.append(Line(label: "Бэкап", text: "\(ago(b.i("age_s") ?? 0)) (\(b.s("time") ?? "")) · влито \(num(b.i("merged")))"))
            } else {
                ls.append(Line(label: "Бэкап", text: "ещё не было", color: .secondary))
            }
            if let m = p.i("left_min") {
                ls.append(Line(label: "Срок", text: m > 0 ? "осталось \(dur(m))" : "срок вышел \(dur(-m)) назад", color: m < 30 ? .yellow : nil))
            }
            if let c = p.d("cost") {
                ls.append(Line(label: "Расход", text: "$\(num(c, 2)) · \(dur(Int((p.d("hours") ?? 0) * 60))) × $\(num(p.d("rate"), 2))/ч"))
            }
        }
        if pods.isEmpty { ls.append(Line(label: "Серверы", text: "серверов нет", color: .secondary)) }
        var summary = "задач \(d.i("jobs") ?? 0)"
        if let t = d.o("total") {
            ls.append(Line(label: "Итого", text: "$\(num(t.d("rate"), 2))/ч · потрачено $\(num(t.d("cost"), 2)) · \(num(t.d("clips_per_min"), 1)) клипов/мин · \(num(t.d("hours_per_hour"), 2)) ч/ч"))
            if let m = d.i("mirror") { ls.append(Line(label: "Зеркало", text: "\(num(m)) клипов в data/public_pod")) }
            summary = "\(pods.count) серв · $\(num(t.d("rate"), 2))/ч · $\(num(t.d("cost"), 2)) · \(num(t.d("clips_per_min"), 0))/мин"
        }
        if let j = d.i("jobs"), j > 0 { ls.append(Line(label: "Задачи", text: "rp.py: \(j)")) }
        res.append(Section(id: "runpod", name: "RunPod", dot: d.s("dot") ?? "gray", stateText: d.s("state_text") ?? "",
                           uptime: nil, summary: summary, lines: ls))
    }
    return res
}

func systemLines(_ root: J) -> [Line] {
    guard let s = root.o("system") else { return [] }
    var out: [Line] = []
    out.append(Line(label: "Память", text: "\(num(s.i("mem_free_pct")))% своб · сжато \(num(s.d("compressed_gb"), 1)) ГБ · своп \(num(s.d("swap_used_gb"), 1)) ГБ (\(num(s.d("swapout_mb_s"), 1)) МБ/с)"))
    var cpu = "\(num(s.i("cpu_pct")))%"
    if let g = s.i("gpu_pct") { cpu += " · GPU \(g)%" }
    out.append(Line(label: "CPU", text: cpu))
    out.append(Line(label: "Сеть", text: "↓ \(num(s.d("net_down_mb_s"), 1)) · ↑ \(num(s.d("net_up_mb_s"), 1)) МБ/с"))
    var disk = "\(num(s.d("disk_free_gb"), 0)) ГБ своб"
    if let g = s.d("data_growth_gb_h") { disk += " · data \(g >= 0 ? "+" : "")\(num(g, 1)) ГБ/ч" }
    out.append(Line(label: "Диск", text: disk))
    return out
}

func systemSummary(_ root: J) -> String {
    guard let s = root.o("system") else { return "" }
    return "своб \(num(s.i("mem_free_pct")))% · CPU \(num(s.i("cpu_pct")))% · ↓\(num(s.d("net_down_mb_s"), 0)) МБ/с · диск \(num(s.d("disk_free_gb"), 0)) ГБ"
}

// MARK: - модель

final class Model: ObservableObject {
    @Published var sections: [Section] = []
    @Published var sysLines: [Line] = []
    @Published var sysSummary = ""
    @Published var error: String? = nil
    @Published var updated: Date? = nil
    @Published var collapsed: Set<String>
    @Published var desiredHeight: CGFloat = 220
    @Published var contentH: CGFloat = 0
    @Published var sysH: CGFloat = 0
    let maxH: CGFloat = 600
    var scrollH: CGFloat { max(0, min(contentH, maxH - sysH)) }
    func recompute() {
        let h = 30 + scrollH + sysH + 2
        if abs(h - desiredHeight) > 0.5 { desiredHeight = h }
    }

    init() {
        collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? [])
    }
    func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        UserDefaults.standard.set(Array(collapsed), forKey: "collapsed")
    }
    func apply(_ root: J) {
        sections = buildSections(root)
        sysLines = systemLines(root)
        sysSummary = systemSummary(root)
        error = nil
        updated = Date()
    }
}

// MARK: - вид

func dotColor(_ s: String) -> Color {
    switch s {
    case "green": return Color(red: 0.2, green: 0.8, blue: 0.35)
    case "yellow": return Color(red: 1.0, green: 0.8, blue: 0.1)
    case "red": return Color(red: 1.0, green: 0.27, blue: 0.23)
    default: return Color.gray
    }
}

struct BarView: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(Color(red: 0.2, green: 0.8, blue: 0.35)).frame(width: max(2, g.size.width * CGFloat(value)))
            }
        }.frame(height: 4)
    }
}

struct LineView: View {
    let l: Line
    var body: some View {
        if let dot = l.dot {
            HStack(spacing: 6) {
                Circle().fill(dotColor(dot)).frame(width: 7, height: 7)
                Text(l.label).font(.system(size: 11, weight: .semibold))
                Text(l.text).font(.system(size: 11)).foregroundColor(l.color ?? .secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 3)
        } else { plain }
    }
    var plain: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(l.label).foregroundColor(.secondary).frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let b = l.bar { BarView(value: b) }
                Text(l.text).foregroundColor(l.color ?? .primary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11).monospacedDigit())
    }
}

struct SectionView: View {
    @ObservedObject var model: Model
    let sec: Section
    var body: some View {
        let open = !model.collapsed.contains(sec.id)
        VStack(alignment: .leading, spacing: 3) {
            Button(action: { model.toggle(sec.id) }) {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary).frame(width: 8)
                    Circle().fill(dotColor(sec.dot)).frame(width: 9, height: 9)
                    Text(sec.name).font(.system(size: 12, weight: .semibold))
                    Text(sec.stateText + (sec.uptime.map { " · \($0)" } ?? "")).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    if !open { Text(sec.summary).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary).lineLimit(1) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sec.name)
            if open {
                ForEach(sec.lines) { LineView(l: $0) }.padding(.leading, 23)
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: Model

    var body: some View {
        let scrollH = model.scrollH
        let sysOpen = !model.collapsed.contains("system")
        VStack(spacing: 0) {
            HStack {
                Text("Конвейеры").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if let e = model.error { Text(e).font(.system(size: 10)).foregroundColor(.yellow) }
                else if let u = model.updated {
                    Text(u, style: .time).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(model.sections) { SectionView(model: model, sec: $0) }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in model.contentH = h; model.recompute() }
            }
            .frame(height: scrollH > 0 ? scrollH : nil)
            Divider().padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 3) {
                Button(action: { model.toggle("system") }) {
                    HStack(spacing: 6) {
                        Image(systemName: sysOpen ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary).frame(width: 8)
                        Text("Система").font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 4)
                        if !sysOpen { Text(model.sysSummary).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary).lineLimit(1) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Система")
                if sysOpen { ForEach(model.sysLines) { LineView(l: $0) }.padding(.leading, 14) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in model.sysH = h; model.recompute() }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - окно

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = Model()
    var panel: StatusPanel!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var bag = Set<AnyCancellable>()
    var running = false
    var overrideOrigin: NSPoint? = nil
    var testNormalLevel = false
    let queue = DispatchQueue(label: "pipeline-status.refresh", qos: .utility)
    let minW: CGFloat = 340

    var scriptPath: String {
        if let p = Bundle.main.path(forResource: "status", ofType: "py") { return p }
        // Not bundled (swiftc main.swift in this folder): status.py next to the source.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("status.py").path
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--origin"), i + 1 < args.count {
            let p = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if p.count == 2 { overrideOrigin = NSPoint(x: p[0], y: p[1]) }
        }
        UserDefaults.standard.register(defaults: ["alwaysOnTop": true])
        testNormalLevel = args.contains("--normal-level")
        buildPanel()
        buildStatusItem()
        model.$desiredHeight.removeDuplicates().sink { [weak self] h in self?.resizeToContent(h) }.store(in: &bag)
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.snapshot(path) }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        let a = NSMenuItem(title: "Обновить", action: #selector(refreshNow), keyEquivalent: ""); a.target = self; m.addItem(a)
        let t = NSMenuItem(title: "Поверх всех окон", action: #selector(toggleTop), keyEquivalent: ""); t.target = self
        t.state = alwaysOnTop ? .on : .off
        m.addItem(t)
        let v = NSMenuItem(title: panel.isVisible ? "Скрыть окно" : "Показать окно", action: #selector(toggleVisible), keyEquivalent: ""); v.target = self
        m.addItem(v)
        m.addItem(.separator())
        let q = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: ""); q.target = self; m.addItem(q)
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = makeMenu()
        menu.removeAllItems()
        for it in fresh.items { fresh.removeItem(it); menu.addItem(it) }
    }

    var alwaysOnTop: Bool { UserDefaults.standard.bool(forKey: "alwaysOnTop") }

    func buildPanel() {
        let w = CGFloat(UserDefaults.standard.double(forKey: "width")).clamped(minW, 900, fallback: 420)
        let rect = NSRect(x: 0, y: 0, width: w, height: 220)
        panel = StatusPanel(contentRect: rect, styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = (alwaysOnTop && !testNormalLevel) ? .floating : .normal
        panel.minSize = NSSize(width: minW, height: 120)
        panel.maxSize = NSSize(width: 900, height: 2000)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.title = "Конвейер"

        let fx = NSVisualEffectView(frame: rect)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.autoresizingMask = [.width, .height]
        let host = ClickHostingView(rootView: RootView(model: model))
        host.frame = fx.bounds
        host.autoresizingMask = [.width, .height]
        host.menu = makeMenu()
        fx.addSubview(host)
        fx.menu = host.menu
        panel.contentView = fx

        placePanel()
        panel.orderFrontRegardless()
    }

    func placePanel() {
        var f = panel.frame
        if let o = overrideOrigin {
            // o = левый верхний угол в глобальных координатах Quartz (y вниз от верха главного экрана)
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - o.y
            f.origin = NSPoint(x: o.x, y: top - f.height)
        } else if let sx = UserDefaults.standard.object(forKey: "topLeftX") as? Double,
                  let sy = UserDefaults.standard.object(forKey: "topLeftY") as? Double,
                  NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: sx + 20, y: sy - 20)) }) {
            f.origin = NSPoint(x: sx, y: sy - f.height)
        } else if let s = NSScreen.main {
            let v = s.visibleFrame
            f.origin = NSPoint(x: v.maxX - f.width - 12, y: v.maxY - f.height - 12)
        }
        panel.setFrame(f, display: true)
    }

    func resizeToContent(_ target: CGFloat) {
        guard let panel = panel else { return }
        let h = max(120, target)
        var f = panel.frame
        if abs(f.height - h) < 0.5 { return }
        let top = f.maxY
        f.size.height = h
        f.origin.y = top - h
        panel.setFrame(f, display: true, animate: false)
    }

    /// Отладка: отрисовать содержимое окна в PNG средствами самого приложения (без захвата экрана).
    func snapshot(_ path: String) {
        guard let v = panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func savePosition() {
        guard overrideOrigin == nil, let panel = panel else { return }
        UserDefaults.standard.set(Double(panel.frame.minX), forKey: "topLeftX")
        UserDefaults.standard.set(Double(panel.frame.maxY), forKey: "topLeftY")
        UserDefaults.standard.set(Double(panel.frame.width), forKey: "width")
    }
    func windowDidMove(_ n: Notification) { savePosition() }
    func windowDidResize(_ n: Notification) { savePosition() }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // высота определяется содержимым; пользователь меняет ширину
        return NSSize(width: frameSize.width, height: max(120, model.desiredHeight))
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: "Конвейер")
            b.toolTip = "Конвейер: статус"
        }
        statusItem.menu = makeMenu()
    }

    @objc func refreshNow() { refresh() }
    @objc func toggleTop() {
        UserDefaults.standard.set(!alwaysOnTop, forKey: "alwaysOnTop")
        panel.level = alwaysOnTop ? .floating : .normal
    }
    @objc func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
    @objc func quit() { NSApp.terminate(nil) }

    func refresh() {
        if running { return }
        running = true
        let path = scriptPath
        queue.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [path]
            p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var parsed: J? = nil
            var err: String? = nil
            do {
                try p.run()
                let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: kill)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                kill.cancel()
                parsed = (try? JSONSerialization.jsonObject(with: data)) as? J
                if parsed == nil { err = "нет данных от status.py" }
            } catch {
                err = "не запустился status.py"
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = false
                if let r = parsed { self.model.apply(r) } else { self.model.error = err }
            }
        }
    }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat, fallback: CGFloat) -> CGFloat {
        if self == 0 || self.isNaN { return fallback }
        return Swift.min(Swift.max(self, lo), hi)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
