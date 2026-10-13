import Cocoa
import UniformTypeIdentifiers

enum RepairError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
let fm = FileManager.default
let relationshipNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
func fail(_ s: String) -> RepairError { .message(s) }

func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, limit: Int = 128 * 1024 * 1024) throws -> Data {
    let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
    p.currentDirectoryURL = cwd
    let output = Pipe(); p.standardOutput = output
    let errorURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    fm.createFile(atPath: errorURL.path, contents: nil)
    let errorFile = try FileHandle(forWritingTo: errorURL); p.standardError = errorFile
    defer { try? errorFile.close(); try? fm.removeItem(at: errorURL) }
    try p.run()
    var data = Data()
    while true {
        let block = output.fileHandleForReading.availableData
        if block.isEmpty { break }
        if data.count + block.count > limit { p.terminate(); p.waitUntilExit(); throw fail("文件内容超过处理上限，原文件未改动。") }
        data.append(block)
    }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        throw fail("文件处理失败（\(URL(fileURLWithPath: executable).lastPathComponent)）：\(stderr.prefix(700))")
    }
    return data
}
func entries(_ url: URL) throws -> [String] {
    let d = try run("/usr/bin/unzip", ["-Z1", url.path], limit: 8 * 1024 * 1024)
    guard let s = String(data: d, encoding: .utf8) else { throw fail("无法识别文档内部文件名。") }
    let names = s.split(separator: "\n").map(String.init)
    guard Set(names).count == names.count else { throw fail("文档含重复内部文件名，已停止处理。") }
    return names
}
func member(_ archive: URL, _ path: String) throws -> Data {
    guard !path.contains("\\"), !path.contains("\n") else { throw fail("不支持的内部文件名。") }
    var pattern = path
    for ch in ["[", "]", "*", "?"] { pattern = pattern.replacingOccurrences(of:ch,with:"\\"+ch) }
    return try run("/usr/bin/unzip", ["-p", archive.path, pattern])
}
func xml(_ d: Data) throws -> XMLDocument {
    // The document does not need external entities or DTDs.
    if let s = String(data: d, encoding: .utf8), s.contains("<!DOCTYPE") || s.contains("<!ENTITY") { throw fail("文档 XML 包含不支持的外部定义。") }
    return try XMLDocument(data: d, options: [])
}
func elements(_ doc: XMLDocument, _ name: String) throws -> [XMLElement] {
    try doc.nodes(forXPath: "//*[local-name()='\(name)']").compactMap { $0 as? XMLElement }
}
func escaped(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}
func attr(_ e: XMLElement, _ name: String) -> String { e.attribute(forName: name)?.stringValue ?? "" }
func patchRelationship(_ source: String, id: String, target: String) throws -> String {
    let regex = try NSRegularExpression(pattern: "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?Relationship\\b[^>]*>")
    let ns = source as NSString
    var result = source; var count = 0
    for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).reversed() {
        let old = ns.substring(with: match.range)
        let idRE = try NSRegularExpression(pattern: "\\bId\\s*=\\s*([\"'])" + NSRegularExpression.escapedPattern(for: escaped(id)) + "\\1")
        guard idRE.firstMatch(in: old, range: NSRange(location: 0, length: (old as NSString).length)) != nil else { continue }
        var new = old
        for (key, value) in [("Target", target), ("Type", relationshipNS + "/package")] {
            let re = try NSRegularExpression(pattern: "\\b" + key + "\\s*=\\s*([\"'])[^\"']*\\1")
            let range = NSRange(location: 0, length: (new as NSString).length)
            guard let m = re.firstMatch(in: new, range: range) else { throw fail("嵌入对象关系不完整。") }
            new = (new as NSString).replacingCharacters(in: m.range, with: key + "=\"" + escaped(value) + "\"")
        }
        result = (result as NSString).replacingCharacters(in: match.range, with: new); count += 1
    }
    guard count == 1 else { throw fail("无法唯一定位嵌入对象关系。") }
    return result
}

struct CompoundFile {
    let b: [UInt8]
    init(_ data: Data) { b = Array(data) }
    func uint(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, offset + width <= b.count else { throw fail("OLE 数据不完整。") }
        return (0..<width).reduce(UInt64(0)) { $0 | UInt64(b[offset+$1]) << ($1*8) }
    }
    func package() throws -> Data? {
        guard b.count >= 512, Array(b.prefix(8)) == [0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1] else { return nil }
        guard try uint(28, 2) == 0xfffe else { throw fail("不支持的 OLE 字节序。") }
        let power = Int(try uint(30, 2)), miniPower = Int(try uint(32, 2))
        guard [9,12].contains(power), miniPower == 6 else { throw fail("不支持的 OLE 扇区格式。") }
        let size = 1 << power, sectorCount = b.count / size - 1
        func sector(_ sid: UInt64) throws -> [UInt8] {
            guard sid < UInt64(sectorCount) else { throw fail("OLE 扇区引用越界。") }
            let start = (Int(sid)+1)*size; return Array(b[start..<start+size])
        }
        func words(_ bytes: [UInt8]) -> [UInt64] {
            stride(from:0,to:bytes.count,by:4).map { o in (0..<4).reduce(UInt64(0)) { $0 | UInt64(bytes[o+$1]) << ($1*8) } }
        }
        var fats = (0..<109).map { try! uint(76+$0*4,4) }.filter { $0 < 0xfffffffa }
        var dif = try uint(68,4), visited = Set<UInt64>()
        let difCount = try uint(72,4)
        guard difCount <= UInt64(sectorCount) else { throw fail("OLE 索引无效。") }
        for _ in 0..<Int(difCount) {
            guard visited.insert(dif).inserted else { throw fail("OLE 索引循环。") }
            let w = words(try sector(dif)); fats += w.dropLast().filter { $0 < 0xfffffffa }; dif = w.last!
        }
        let fatCount = Int(try uint(44,4))
        guard fats.count >= fatCount, fatCount <= sectorCount else { throw fail("OLE FAT 不完整。") }
        var fat: [UInt64] = []
        for sid in fats.prefix(fatCount) { fat += words(try sector(sid)) }
        func chain(_ start: UInt64, table: [UInt64], fetch: (UInt64) throws -> [UInt8]) throws -> [UInt8] {
            var id = start, seen = Set<UInt64>(), result: [UInt8] = []
            while id != 0xfffffffe {
                guard id < UInt64(table.count), seen.insert(id).inserted else { throw fail("OLE 数据链损坏。") }
                result += try fetch(id)
                guard result.count <= 128*1024*1024 else { throw fail("OLE 对象过大。") }
                id = table[Int(id)]
            }
            return result
        }
        let directory = try chain(uint(48,4), table:fat, fetch:sector)
        var root: (UInt64,Int)?, pkg: (UInt64,Int)?
        for offset in stride(from:0,to:directory.count,by:128) {
            let entry = CompoundFile(Data(directory[offset..<offset+128]))
            let n = Int(try entry.uint(64,2)); guard n <= 64, n % 2 == 0 else { throw fail("OLE 目录损坏。") }
            let name = String(data:Data(entry.b.prefix(max(0,n-2))),encoding:.utf16LittleEndian) ?? ""
            let start = try entry.uint(116,4), length = try entry.uint(120,power == 9 ? 4 : 8)
            guard length <= 128*1024*1024 else { throw fail("OLE 对象过大。") }
            if entry.b[66] == 5 { root = (start,Int(length)) }
            if entry.b[66] == 2 && name.lowercased() == "package" { pkg = (start,Int(length)) }
        }
        guard let pkg else { return nil }
        let bytes: [UInt8]
        if pkg.1 >= Int(try uint(56,4)) {
            bytes = try chain(pkg.0,table:fat,fetch:sector)
        } else {
            guard let root else { throw fail("OLE 小型流缺失。") }
            let miniStream = Array(try chain(root.0,table:fat,fetch:sector).prefix(root.1))
            let miniFat = words(try chain(uint(60,4),table:fat,fetch:sector))
            bytes = try chain(pkg.0,table:miniFat) { sid in
                let start = Int(sid)*64
                guard start >= 0, start+64 <= miniStream.count else { throw fail("OLE 小型流越界。") }
                return Array(miniStream[start..<start+64])
            }
        }
        guard bytes.count >= pkg.1 else { throw fail("Excel 附件不完整。") }
        return Data(bytes.prefix(pkg.1))
    }
}

struct RepairResult {
    let source: URL, output: URL
    let count: Int
    let warnings: [String]
}
func repair(_ input: URL, outputFolder: URL? = nil) throws -> RepairResult {
    let source = input.standardizedFileURL
    guard source.pathExtension.lowercased() == "docx" else { throw fail("仅支持 .docx；旧版 .doc 请先在 WPS 中另存为 .docx。") }
    let size = try source.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
    guard size.isRegularFile == true, (size.fileSize ?? 0) <= 256*1024*1024 else { throw fail("请选择不超过 256 MB 的 Word 文档。") }
    let temp = fm.temporaryDirectory.appendingPathComponent("CompatibleOpen-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:temp,withIntermediateDirectories:true); defer { try? fm.removeItem(at:temp) }
    let names = try entries(source), nameSet = Set(names)
    guard nameSet.contains("word/document.xml"), nameSet.contains("[Content_Types].xml") else { throw fail("不是有效的 .docx，或文档已加密。") }
    guard !names.contains(where:{$0.hasPrefix("_xmlsignatures/")}) else { throw fail("文档带有数字签名，转换会使签名失效，已保留原文件并停止。") }
    _ = try run("/usr/bin/unzip",["-tqq",source.path])
    var changes: [String:Data] = [:], replacements: [String:String] = [:], warnings: [String] = []
    var count = 0
    for part in names.filter({ $0.hasPrefix("word/") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }).sorted() {
        let partData = try member(source,part)
        guard let partText = String(data:partData,encoding:.utf8), partText.contains("OLEObject") else { continue }
        let doc = try xml(partData)
        let objects = try elements(doc,"OLEObject").filter { attr($0,"Type") == "Embed" && attr($0,"ProgID") == "Excel.Sheet.12" }
        if objects.isEmpty { continue }
        let partURL = URL(fileURLWithPath:"/"+part)
        let folder = partURL.deletingLastPathComponent()
        let relPath = String(folder.path.dropFirst()) + "/_rels/" + partURL.lastPathComponent + ".rels"
        guard nameSet.contains(relPath) else { throw fail("Excel 对象的关联文件缺失。") }
        let relData = try changes[relPath] ?? member(source,relPath)
        let relationships = try elements(xml(relData),"Relationship")
        guard var relText = String(data:relData,encoding:.utf8) else { throw fail("不支持的 XML 编码。") }
        for obj in objects {
            let id = obj.attribute(forLocalName:"id",uri:relationshipNS)?.stringValue ?? attr(obj,"r:id")
            guard let rel = relationships.first(where:{attr($0,"Id")==id}), attr(rel,"TargetMode") != "External" else { warnings.append("一个 Excel 对象缺少本地附件，已原样保留。"); continue }
            let target = attr(rel,"Target")
            guard !target.isEmpty, !target.contains(":"), !target.contains("\\"), !target.contains("%") else { warnings.append("一个对象使用特殊路径，已原样保留。"); continue }
            let full = String((target.hasPrefix("/") ? URL(fileURLWithPath:target) : folder.appendingPathComponent(target)).standardizedFileURL.path.dropFirst())
            guard full.hasPrefix("word/embeddings/"), nameSet.contains(full) else { warnings.append("一个附件路径异常，已原样保留。"); continue }
            if full.lowercased().hasSuffix(".xlsx") { continue }
            guard full.lowercased().hasSuffix(".bin") else { continue }
            var newFull: String
            if let cached = replacements[full] { newFull = cached }
            else {
                guard let package = try CompoundFile(member(source,full)).package() else { warnings.append("一个 OLE 对象不含可识别的 Excel 包，已原样保留。"); continue }
                let probe = temp.appendingPathComponent("probe.xlsx"); try package.write(to:probe)
                let bookNames = try entries(probe)
                guard bookNames.contains("xl/workbook.xml"), bookNames.contains("[Content_Types].xml"), !bookNames.contains(where:{$0.lowercased().contains("vbaproject")}) else { warnings.append("一个对象不是普通 .xlsx，已原样保留。"); continue }
                let ct = try member(probe,"[Content_Types].xml")
                guard String(data:ct,encoding:.utf8)?.contains("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml") == true else { warnings.append("一个对象不是普通 .xlsx，已原样保留。"); continue }
                _ = try run("/usr/bin/unzip",["-tqq",probe.path])
                let stem = String(full.dropLast(4)); newFull = stem+"_compat.xlsx"; var suffix = 2
                while nameSet.contains(newFull) || changes[newFull] != nil { newFull = stem+"_compat_\(suffix).xlsx"; suffix += 1 }
                replacements[full] = newFull; changes[newFull] = package
            }
            // Use relative targets: ONLYOFFICE does not consistently load absolute OLE package targets.
            let parentParts = folder.path.split(separator:"/").map(String.init)
            let newParts = newFull.split(separator:"/").map(String.init)
            var common = 0
            while common < min(parentParts.count,newParts.count) && parentParts[common] == newParts[common] { common += 1 }
            let relative = String(repeating:"../",count:parentParts.count-common) + newParts.dropFirst(common).joined(separator:"/")
            relText = try patchRelationship(relText,id:id,target:relative)
            count += 1
        }
        if relText != String(data:relData,encoding:.utf8) { changes[relPath] = Data(relText.utf8) }
    }
    if count == 0 { return RepairResult(source:source,output:source,count:0,warnings:warnings) }
    let contentData = try member(source,"[Content_Types].xml")
    var content = String(data:contentData,encoding:.utf8) ?? ""
    let close = try NSRegularExpression(pattern:"</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?Types\\s*>")
    guard let match = close.firstMatch(in:content,range:NSRange(location:0,length:(content as NSString).length)) else { throw fail("文档内容类型定义不完整。") }
    let root = try xml(contentData).rootElement()!
    let prefix = root.name?.contains(":") == true ? String(root.name!.split(separator:":")[0])+":" : ""
    let additions = replacements.values.sorted().map { "<\(prefix)Override PartName=\"/\(escaped($0))\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\"/>" }.joined()
    content = (content as NSString).replacingCharacters(in:NSRange(location:match.range.location,length:0),with:additions)
    changes["[Content_Types].xml"] = Data(content.utf8)
    let staging = temp.appendingPathComponent("parts",isDirectory:true); try fm.createDirectory(at:staging,withIntermediateDirectories:true)
    for (name,data) in changes {
        if name.hasSuffix(".xml") || name.hasSuffix(".rels") { _ = try xml(data) }
        let url = staging.appendingPathComponent(name); try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:url)
    }
    let archive = temp.appendingPathComponent("repaired.docx"); try fm.copyItem(at:source,to:archive)
    _ = try run("/usr/bin/zip",["-q",archive.path] + changes.keys.sorted(),cwd:staging)
    _ = try run("/usr/bin/unzip",["-tqq",archive.path])
    for (name,data) in changes { guard try member(archive,name) == data else { throw fail("修复后验证失败，未输出副本。") } }
    guard try member(archive,"word/document.xml") == member(source,"word/document.xml") else { throw fail("正文校验失败，未输出副本。") }
    let destination = outputFolder ?? source.deletingLastPathComponent().appendingPathComponent("ONLYOFFICE兼容副本",isDirectory:true)
    try fm.createDirectory(at:destination,withIntermediateDirectories:true)
    let base = source.deletingPathExtension().lastPathComponent + "-兼容版"
    var output = destination.appendingPathComponent(base+".docx"); var suffix = 2
    while fm.fileExists(atPath:output.path) { output=destination.appendingPathComponent(base+" (\(suffix)).docx"); suffix += 1 }
    try fm.copyItem(at:archive,to:output)
    return RepairResult(source:source,output:output,count:count,warnings:warnings)
}

class DropView: NSView {
    var dropped: (([URL])->Void)?
    override init(frame:NSRect) { super.init(frame:frame); registerForDraggedTypes([.fileURL]); wantsLayer=true; layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor; layer?.cornerRadius=12 }
    required init?(coder:NSCoder) { fatalError() }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation { .copy }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }; dropped?(urls); return true
    }
}
class AppDelegate: NSObject, NSApplicationDelegate {
    var window:NSWindow!, status:NSTextField!, detail:NSTextField!, choose:NSButton!, reveal:NSButton!, progress:NSProgressIndicator!
    var lastOutputs:[URL]=[], pending:[URL]=[], busy=false
    func applicationDidFinishLaunching(_ notification:Notification) {
        if let url = Bundle.main.url(forResource:"AppIcon",withExtension:"icns"), let icon = NSImage(contentsOf:url) { NSApp.applicationIconImage = icon }
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:440),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="ONLYOFFICE 兼容打开"; window.center(); window.isReleasedWhenClosed=false
        let drop=DropView(frame:NSRect(x:20,y:20,width:600,height:400)); window.contentView?.addSubview(drop)
        drop.dropped = { [weak self] urls in self?.process(urls) }
        func label(_ text:String,_ frame:NSRect,_ size:CGFloat,_ weight:NSFont.Weight = .regular)->NSTextField {
            let l=NSTextField(wrappingLabelWithString:text); l.frame=frame; l.font = .systemFont(ofSize:size,weight:weight); drop.addSubview(l); return l
        }
        _=label("把 Word 拖到这里",NSRect(x:28,y:325,width:544,height:36),25,.semibold)
        _=label("自动处理 WPS 嵌入 Excel 的兼容问题",NSRect(x:28,y:292,width:544,height:24),15)
        _=label("支持 .docx，可一次选择多个文件。原文件保留，兼容副本存放在原文件旁的“ONLYOFFICE兼容副本”文件夹。",NSRect(x:28,y:231,width:544,height:52),13)
        choose=NSButton(title:"选择 Word 文件…",target:self,action:#selector(selectFiles)); choose.bezelStyle = .rounded; choose.frame=NSRect(x:24,y:178,width:180,height:34); drop.addSubview(choose)
        reveal=NSButton(title:"显示处理结果",target:self,action:#selector(showOutputs)); reveal.bezelStyle = .rounded; reveal.frame=NSRect(x:212,y:178,width:160,height:34); reveal.isEnabled=false; drop.addSubview(reveal)
        progress=NSProgressIndicator(frame:NSRect(x:558,y:184,width:20,height:20)); progress.style = .spinning; progress.isDisplayedWhenStopped=false; drop.addSubview(progress)
        status=label("准备就绪",NSRect(x:28,y:138,width:544,height:25),15,.medium)
        detail=label("处理完成后会使用 ONLYOFFICE 打开。普通文档直接打开。所有处理均在本机进行。",NSRect(x:28,y:24,width:544,height:105),13)
        detail.textColor = .secondaryLabelColor
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if !pending.isEmpty { let items=pending; pending=[]; process(items) }
    }
    @objc func selectFiles() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[UTType(filenameExtension:"docx")!]; panel.allowsMultipleSelection=true; panel.canChooseDirectories=false
        panel.beginSheetModal(for:window) { response in if response == .OK { self.process(panel.urls) } }
    }
    @objc func showOutputs() { NSWorkspace.shared.activateFileViewerSelecting(lastOutputs) }
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        let urls=filenames.map { URL(fileURLWithPath:$0) }
        if window == nil { pending += urls } else { process(urls) }
        sender.reply(toOpenOrPrint:.success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { !busy }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { busy ? .terminateCancel : .terminateNow }
    func process(_ urls:[URL]) {
        guard !busy else { return }
        busy=true; choose.isEnabled=false; reveal.isEnabled=false; progress.startAnimation(nil); status.stringValue="正在检查 \(urls.count) 个文件…"; detail.stringValue="正在验证附件并生成兼容副本，请稍候。"
        let unique=Array(Set(urls)).sorted {$0.path < $1.path}
        DispatchQueue.global(qos:.userInitiated).async {
            var results:[RepairResult]=[], errors:[String]=[]
            for url in unique { do { results.append(try repair(url)) } catch { errors.append(url.lastPathComponent+"："+error.localizedDescription) } }
            DispatchQueue.main.async {
                self.busy=false; self.choose.isEnabled=true; self.progress.stopAnimation(nil)
                self.lastOutputs=results.map(\.output); self.reveal.isEnabled = !results.isEmpty
                let n=results.reduce(0){$0+$1.count}
                self.status.stringValue="已处理 \(results.count) 个文件，转换 \(n) 个 Excel 附件" + (errors.isEmpty ? "" : "；\(errors.count) 个失败")
                var messages=results.flatMap(\.warnings)+errors
                if results.contains(where:{$0.count>0}) { messages.insert("兼容副本已保存在原文件旁，原文件未改动。",at:0) }
                if n==0 && errors.isEmpty { messages.insert("未发现需要转换的 Excel 包装，直接打开原文件。",at:0) }
                self.detail.stringValue=messages.joined(separator:"\n")
                if !results.isEmpty {
                    if let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"asc.onlyoffice.ONLYOFFICE") {
                        let config=NSWorkspace.OpenConfiguration(); config.activates=true
                        NSWorkspace.shared.open(results.map(\.output),withApplicationAt:app,configuration:config) { _,error in
                            if let error { DispatchQueue.main.async { self.detail.stringValue += "\nONLYOFFICE 未能打开："+error.localizedDescription } }
                        }
                    } else { self.detail.stringValue += "\n未找到 ONLYOFFICE，请点击“显示处理结果”后自行打开。" }
                }
                if !errors.isEmpty || results.contains(where:{!$0.warnings.isEmpty}) {
                    let alert=NSAlert(); alert.messageText="部分内容需要注意"; alert.informativeText=messages.joined(separator:"\n"); alert.addButton(withTitle:"知道了"); alert.beginSheetModal(for:self.window)
                }
            }
        }
    }
}
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--repair" {
    do {
        let folder=CommandLine.arguments.count >= 4 ? URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true) : nil
        let result=try repair(URL(fileURLWithPath:CommandLine.arguments[2]),outputFolder:folder)
        let obj:[String:Any] = ["source":result.source.path,"output":result.output.path,"converted":result.count,"warnings":result.warnings]
        print(String(data:try JSONSerialization.data(withJSONObject:obj,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!); exit(0)
    } catch { fputs(error.localizedDescription+"\n",stderr); exit(1) }
}
let app=NSApplication.shared
let delegate=AppDelegate(); app.delegate=delegate; app.setActivationPolicy(.regular); app.run()
