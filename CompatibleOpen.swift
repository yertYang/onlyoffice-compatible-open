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
    let output = Pipe(); p.standardOutput = output; p.standardInput = FileHandle.nullDevice
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
func entries(_ url: URL, strictUTF8: Bool = true) throws -> [String] {
    let d = try run("/usr/bin/unzip", ["-Z1", url.path], limit: 8 * 1024 * 1024)
    // macOS zipinfo can emit legacy or partially converted names in ordinary ZIPs.
    // Only ASCII OOXML part names are needed when identifying an attachment.
    guard let s = String(data: d, encoding: .utf8) ?? (strictUTF8 ? nil : String(decoding:d,as:UTF8.self)) else { throw fail("无法识别文档内部文件名。") }
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
    guard let s = String(data:d,encoding:.utf8) else { throw fail("暂不支持此文档的 XML 编码。") }
    if s.contains("<!DOCTYPE") || s.contains("<!ENTITY") { throw fail("文档 XML 包含不支持的外部定义。") }
    return try XMLDocument(data: d, options: [.nodeLoadExternalEntitiesNever])
}
func validateDocumentMembers(_ names: [String]) throws {
    guard names.allSatisfy({ name in
        !name.hasPrefix("/") && !name.contains("\\") && !name.contains("\u{0}") &&
        !name.split(separator:"/",omittingEmptySubsequences:false).contains(where:{ $0 == ".." || $0 == "." })
    }) else { throw fail("文档内部路径异常，已停止处理。") }
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
    func package() throws -> Data? { try streams(["package"])["package"] }
    func streams(_ wanted: Set<String>) throws -> [String:Data] {
        guard b.count >= 512, Array(b.prefix(8)) == [0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1] else { return [:] }
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
        var root: (UInt64,Int)?, stored: [(String,UInt64,Int)] = []
        for offset in stride(from:0,to:directory.count,by:128) {
            let entry = CompoundFile(Data(directory[offset..<offset+128]))
            guard [2,5].contains(entry.b[66]) else { continue }
            let n = Int(try entry.uint(64,2)); guard n <= 64, n % 2 == 0 else { throw fail("OLE 目录损坏。") }
            let name = String(data:Data(entry.b.prefix(max(0,n-2))),encoding:.utf16LittleEndian) ?? ""
            let start = try entry.uint(116,4), length = try entry.uint(120,power == 9 ? 4 : 8)
            guard length <= 128*1024*1024 else { throw fail("OLE 对象过大。") }
            if entry.b[66] == 5 { root = (start,Int(length)) }
            if entry.b[66] == 2 && wanted.contains(name.lowercased()) { stored.append((name.lowercased(),start,Int(length))) }
        }
        var output: [String:Data] = [:], miniStream: [UInt8]?, miniFat: [UInt64]?
        for (name,start,length) in stored {
            guard output[name] == nil else { throw fail("OLE 附件包含重名数据流。") }
            if length == 0 { output[name] = Data(); continue }
            let bytes: [UInt8]
            if length >= Int(try uint(56,4)) {
                bytes = try chain(start,table:fat,fetch:sector)
            } else {
            guard let root else { throw fail("OLE 小型流缺失。") }
            if miniStream == nil {
                let rootBytes = try chain(root.0,table:fat,fetch:sector)
                guard rootBytes.count >= root.1 else { throw fail("OLE 小型流不完整。") }
                miniStream = Array(rootBytes.prefix(root.1))
                miniFat = words(try chain(uint(60,4),table:fat,fetch:sector))
            }
            bytes = try chain(start,table:miniFat!) { sid in
                let start = Int(sid)*64
                guard start >= 0, start+64 <= miniStream!.count else { throw fail("OLE 小型流越界。") }
                return Array(miniStream![start..<start+64])
            }
            }
            guard bytes.count >= length else { throw fail("附件数据不完整。") }
            output[name] = Data(bytes.prefix(length))
        }
        return output
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
    try validateDocumentMembers(names)
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

struct PayloadType {
    let ext: String, title: String
    let canOpen: Bool
}
struct Attachment {
    let document: URL, member: String, name: String, type: PayloadType, size: Int
    let output: URL?, note: String
    var json: [String:Any] {
        ["document":document.path,"member":member,"name":name,"type":type.ext,
         "bytes":size,"output":output?.path as Any? ?? NSNull(),"canOpen":type.canOpen,"note":note]
    }
}
struct AttachmentScan {
    let source: URL, attachments: [Attachment], warnings: [String]
}
let oleMagic: [UInt8] = [0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1]
let officeExtensions: Set<String> = ["docx","xlsx","pptx","doc","xls","ppt"]

func safeName(_ hint: String, fallback: String, ext: String? = nil) -> String {
    var name = hint.replacingOccurrences(of:"\\",with:"/").split(separator:"/").last.map(String.init) ?? ""
    name = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/:".unicodeScalars.contains($0) }.map(String.init).joined()
    name = name.trimmingCharacters(in:CharacterSet(charactersIn:" ."))
    if name.isEmpty { name = fallback }
    if let ext, !ext.isEmpty {
        let stem = (name as NSString).deletingPathExtension
        name = (stem.isEmpty ? fallback : stem) + "." + ext
    }
    // Leave room for collision suffixes on macOS filesystems (255 UTF-8 bytes).
    let suffix = ext.map { "."+$0 } ?? ""
    var stem = ext == nil ? name : (name as NSString).deletingPathExtension
    while (stem+suffix).utf8.count > 210 && !stem.isEmpty { stem.removeLast() }
    name = (stem.isEmpty ? fallback : stem)+suffix
    return name
}

func nativePayload(_ data: Data) throws -> (String,Data) {
    // MS-OLEDS OLENativeStream; all declared sizes are checked before slicing.
    let b = Array(data); let raw = CompoundFile(data)
    guard b.count >= 6 else { throw fail("附件包装不完整。") }
    let declared = Int(try raw.uint(0,4))
    guard declared <= b.count-4 else { throw fail("附件包装长度无效。") }
    let end = declared == 0 ? b.count : declared+4
    var cursor = 6
    func string() throws -> String {
        let begin = cursor
        while cursor < end && b[cursor] != 0 {
            cursor += 1
            guard cursor-begin <= 32768 else { throw fail("附件文件名过长。") }
        }
        guard cursor < end else { throw fail("附件文件名不完整。") }
        let bytes = Data(b[begin..<cursor]); cursor += 1
        let chinese = String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data:bytes,encoding:.utf8) ?? String(data:bytes,encoding:chinese) ?? String(data:bytes,encoding:.windowsCP1252) ?? ""
    }
    let label = try string(), original = try string()
    guard cursor+8 <= end else { throw fail("附件包装不完整。") }; cursor += 8
    let temporary = try string()
    guard cursor+4 <= end else { throw fail("此对象仅包含文件链接，未包含附件数据。") }
    let length = Int(try raw.uint(cursor,4)); cursor += 4
    guard length <= 128*1024*1024, length <= end-cursor else { throw fail("附件数据不完整或超过处理上限。") }
    let hint = !label.isEmpty ? label : (!original.isEmpty ? original : temporary)
    return (hint,Data(b[cursor..<cursor+length]))
}

func payloadType(_ data: Data, hint: String, temp: URL) throws -> PayloadType {
    let b = Array(data.prefix(16))
    func starts(_ bytes:[UInt8])->Bool { b.starts(with:bytes) }
    if starts([0x50,0x4b,0x03,0x04]) || starts([0x50,0x4b,0x05,0x06]) || starts([0x50,0x4b,0x07,0x08]) {
        if starts([0x50,0x4b,0x05,0x06]), data.count >= 22, data[4..<20].allSatisfy({$0 == 0}),
           data.count == 22+Int(data[20])+Int(data[21])*256 { return PayloadType(ext:"zip",title:"ZIP 压缩包",canOpen:true) }
        let probe = temp.appendingPathComponent("identify.zip"); try data.write(to:probe)
        let names = Set(try entries(probe,strictUTF8:false))
        if names.contains("[Content_Types].xml") {
            let content = try xml(member(probe,"[Content_Types].xml"))
            let types = try elements(content,"Override").map { attr($0,"ContentType") }
            for (part,ext,mime) in [
                ("word/document.xml","docx","application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
                ("xl/workbook.xml","xlsx","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
                ("ppt/presentation.xml","pptx","application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml")
            ] where names.contains(part) && types.contains(mime) {
                return PayloadType(ext:ext,title:ext.uppercased(),canOpen:true)
            }
            for (part,ext,mime) in [
                ("word/document.xml","docm","application/vnd.ms-word.document.macroEnabled.main+xml"),
                ("xl/workbook.xml","xlsm","application/vnd.ms-excel.sheet.macroEnabled.main+xml"),
                ("ppt/presentation.xml","pptm","application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml")
            ] where names.contains(part) && types.contains(mime) {
                return PayloadType(ext:ext,title:ext.uppercased()+"（仅保存）",canOpen:false)
            }
        }
        return PayloadType(ext:"zip",title:"ZIP 压缩包",canOpen:true)
    }
    if starts(Array("%PDF-".utf8)) { return PayloadType(ext:"pdf",title:"PDF",canOpen:true) }
    if starts([0x52,0x61,0x72,0x21,0x1a,0x07]) { return PayloadType(ext:"rar",title:"RAR 压缩包",canOpen:true) }
    if starts([0x37,0x7a,0xbc,0xaf,0x27,0x1c]) { return PayloadType(ext:"7z",title:"7Z 压缩包",canOpen:true) }
    if starts([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) { return PayloadType(ext:"png",title:"PNG 图片",canOpen:true) }
    if starts([0xff,0xd8,0xff]) { return PayloadType(ext:"jpg",title:"JPEG 图片",canOpen:true) }
    if starts(Array("GIF8".utf8)) { return PayloadType(ext:"gif",title:"GIF 图片",canOpen:true) }
    if starts(Array("{\\rtf".utf8)) { return PayloadType(ext:"rtf",title:"RTF",canOpen:true) }
    let ext = (hint as NSString).pathExtension.lowercased()
    if ["txt","csv","json","xml","md","log"].contains(ext),
       let text = String(data:data,encoding:.utf8), !text.unicodeScalars.contains(where:{ $0.value == 0 || ($0.value < 32 && ![9,10,13].contains($0.value)) }) {
        return PayloadType(ext:ext,title:ext.uppercased(),canOpen:true)
    }
    let safeExt = !ext.isEmpty && ext.count <= 12 && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } ? ext : "bin"
    return PayloadType(ext:safeExt,title:safeExt.uppercased()+"（仅保存）",canOpen:false)
}

func unwrapAttachment(_ data: Data, hint: String, temp: URL) throws -> (String,Data,PayloadType) {
    if Array(data.prefix(8)) == oleMagic {
        let streams = try CompoundFile(data).streams(["package","\u{1}ole10native","contents","worddocument","workbook","book","powerpoint document","encryptedpackage"])
        if let package = streams["package"] {
            return (hint,package,try payloadType(package,hint:hint,temp:temp))
        }
        if let native = streams["\u{1}ole10native"] {
            let (name,payload) = try nativePayload(native)
            return (name,payload,try payloadType(payload,hint:name,temp:temp))
        }
        if let contents = streams["contents"] {
            return (hint,contents,try payloadType(contents,hint:hint,temp:temp))
        }
        for (stream,ext) in [("worddocument","doc"),("workbook","xls"),("book","xls"),("powerpoint document","ppt")] where streams[stream] != nil {
            return (hint,data,PayloadType(ext:ext,title:ext.uppercased(),canOpen:true))
        }
        throw fail(streams["encryptedpackage"] == nil ? "暂不支持此嵌入对象的包装格式。" : "此附件已加密，无法提取内容。")
    }
    return (hint,data,try payloadType(data,hint:hint,temp:temp))
}

func saveAttachment(_ data: Data, named name: String, folder: URL, temp: URL) throws -> URL {
    try fm.createDirectory(at:folder,withIntermediateDirectories:true)
    var output = folder.appendingPathComponent(name), suffix = 2
    while fm.fileExists(atPath:output.path) {
        let values = try output.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        if values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == data.count,
           try Data(contentsOf:output) == data { return output }
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        output = folder.appendingPathComponent(stem+" (\(suffix))"+(ext.isEmpty ? "" : "."+ext)); suffix += 1
    }
    let staged = temp.appendingPathComponent("attachment-"+UUID().uuidString)
    try data.write(to:staged); defer { try? fm.removeItem(at:staged) }
    try fm.copyItem(at:staged,to:output) // Fails rather than overwriting in a race.
    return output
}

func scanAttachments(_ input: URL, extract: Bool, outputFolder: URL? = nil) throws -> AttachmentScan {
    let source = input.standardizedFileURL
    guard source.pathExtension.lowercased() == "docx" else { throw fail("请选择 .docx 格式的 Word 文档。") }
    let values = try source.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? 0) <= 256*1024*1024 else { throw fail("请选择不超过 256 MB 的 Word 文档。") }
    let names = try entries(source), nameSet = Set(names)
    try validateDocumentMembers(names)
    guard nameSet.contains("word/document.xml"), nameSet.contains("[Content_Types].xml") else { throw fail("不是有效的 DOCX，或文档已加密。") }
    _ = try run("/usr/bin/unzip",["-tqq",source.path])
    _ = try xml(member(source,"word/document.xml")); _ = try xml(member(source,"[Content_Types].xml"))
    let temp = fm.temporaryDirectory.appendingPathComponent("CompatibleAttachments-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:temp,withIntermediateDirectories:true); defer { try? fm.removeItem(at:temp) }
    let folder = outputFolder ?? source.deletingLastPathComponent().appendingPathComponent("ONLYOFFICE附件",isDirectory:true)
        .appendingPathComponent(safeName(source.deletingPathExtension().lastPathComponent,fallback:"文档"),isDirectory:true)
    var attachments: [Attachment] = [], warnings: [String] = [], seen = Set<String>(), total = 0
    let parts = names.filter { $0.hasPrefix("word/") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }.sorted { a,b in
        if a == "word/document.xml" { return b != a }; if b == "word/document.xml" { return false }; return a < b
    }
    for part in parts {
        let bytes = try member(source,part)
        guard String(data:bytes,encoding:.utf8)?.contains("OLEObject") == true else { continue }
        let objects = try elements(xml(bytes),"OLEObject")
        let parent = URL(fileURLWithPath:"/"+part).deletingLastPathComponent()
        let relPath = String(parent.path.dropFirst())+"/_rels/"+URL(fileURLWithPath:part).lastPathComponent+".rels"
        let relationships = nameSet.contains(relPath) ? try elements(xml(member(source,relPath)),"Relationship") : []
        for obj in objects {
            guard attachments.count < 256 else { throw fail("文档附件超过 256 个，请分批处理。") }
            let id = obj.attribute(forLocalName:"id",uri:relationshipNS)?.stringValue ?? attr(obj,"r:id")
            var full = part+"#"+id, name = "附件-\(attachments.count+1)"
            do {
                guard attr(obj,"Type") == "Embed", let rel = relationships.first(where:{attr($0,"Id")==id}), attr(rel,"TargetMode") != "External" else {
                    throw fail("此对象是外部链接或未包含本地附件。")
                }
                let target = attr(rel,"Target")
                guard !target.isEmpty, !target.contains(":"), !target.contains("\\"), !target.contains("%") else { throw fail("附件路径无法识别。") }
                full = String((target.hasPrefix("/") ? URL(fileURLWithPath:target) : parent.appendingPathComponent(target)).standardizedFileURL.path.dropFirst())
                guard full.hasPrefix("word/embeddings/"), nameSet.contains(full) else { throw fail("文档内缺少附件数据。") }
                guard seen.insert(full).inserted else { continue }
                let raw = try member(source,full)
                let hint = URL(fileURLWithPath:full).lastPathComponent
                let (label,payload,type) = try unwrapAttachment(raw,hint:hint,temp:temp)
                name = safeName(label,fallback:name,ext:type.ext)
                guard payload.count <= 512*1024*1024-total else { throw fail("提取的附件总大小超过 512 MB。") }; total += payload.count
                let output = extract ? try saveAttachment(payload,named:name,folder:folder,temp:temp) : nil
                let note = extract ? (type.canOpen ? "已提取，可打开" : "已保存，请在 Finder 中选择应用") : (type.canOpen ? "可提取" : "可提取，仅保存")
                attachments.append(Attachment(document:source,member:full,name:name,type:type,size:payload.count,output:output,note:note))
            } catch {
                let message = error.localizedDescription
                warnings.append(name+"："+message)
                attachments.append(Attachment(document:source,member:full,name:name,type:PayloadType(ext:"",title:"未提取",canOpen:false),size:0,output:nil,note:message))
            }
        }
    }
    return AttachmentScan(source:source,attachments:attachments,warnings:warnings)
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
class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window:NSWindow!, status:NSTextField!, detail:NSTextField!, choose:NSButton!, progress:NSProgressIndicator!
    var table:NSTableView!, openButton:NSButton!, showButton:NSButton!, wordButton:NSButton!, resultButton:NSButton!, autoOpen:NSButton!
    var lastOutputs:[URL]=[], pending:[URL]=[], attachments:[Attachment]=[], busy=false
    func applicationDidFinishLaunching(_ notification:Notification) {
        let icon = Bundle.main.url(forResource:"AppIcon",withExtension:"icns").flatMap { NSImage(contentsOf:$0) }
        if let icon { NSApp.applicationIconImage = icon }
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="ONLYOFFICE 兼容打开 1.2"; window.center(); window.minSize=NSSize(width:820,height:600); window.isReleasedWhenClosed=false
        let content=window.contentView!
        let drop=DropView(frame:NSRect(x:20,y:520,width:860,height:160)); drop.autoresizingMask=[.width,.minYMargin]; content.addSubview(drop)
        drop.dropped = { [weak self] urls in self?.process(urls) }
        func label(_ text:String,_ frame:NSRect,_ size:CGFloat,_ parent:NSView,_ weight:NSFont.Weight = .regular)->NSTextField {
            let l=NSTextField(wrappingLabelWithString:text); l.frame=frame; l.font = .systemFont(ofSize:size,weight:weight); l.autoresizingMask=[.width,.minYMargin]; parent.addSubview(l); return l
        }
        let image=NSImageView(frame:NSRect(x:24,y:86,width:60,height:60)); image.image=icon; image.autoresizingMask=[.minYMargin]; drop.addSubview(image)
        _=label("Word 兼容打开 · 附件管理",NSRect(x:100,y:113,width:720,height:36),25,drop,.semibold)
        _=label("把 Word 拖到这里：自动检查 Excel，并提取 DOCX、ZIP 等附件",NSRect(x:100,y:77,width:720,height:28),14,drop)
        choose=NSButton(title:"选择 Word 文件…",target:self,action:#selector(selectFiles)); choose.bezelStyle = .rounded; choose.frame=NSRect(x:24,y:23,width:174,height:34); drop.addSubview(choose)
        autoOpen=NSButton(checkboxWithTitle:"处理后打开 Word",target:self,action:#selector(saveAutoOpen)); autoOpen.frame=NSRect(x:216,y:27,width:210,height:26)
        autoOpen.state = UserDefaults.standard.object(forKey:"openWordAfterProcessing") == nil || UserDefaults.standard.bool(forKey:"openWordAfterProcessing") ? .on : .off
        drop.addSubview(autoOpen)
        progress=NSProgressIndicator(frame:NSRect(x:814,y:29,width:22,height:22)); progress.style = .spinning; progress.isDisplayedWhenStopped=false; progress.autoresizingMask=[.minXMargin]; drop.addSubview(progress)
        status=label("准备就绪",NSRect(x:20,y:478,width:860,height:28),15,content,.medium)
        detail=label("支持一次选择多个 .docx。处理后在下方选择附件，再点击“打开所选附件”；ZIP 由系统解压。",NSRect(x:20,y:426,width:860,height:48),13,content); detail.textColor = .secondaryLabelColor
        table=NSTableView(); table.rowHeight=34; table.usesAlternatingRowBackgroundColors=true; table.allowsMultipleSelection=true; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (id,title,width) in [("name","附件",260.0),("type","类型 / 大小",135.0),("document","所在 Word",205.0),("note","处理结果",240.0)] {
            let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id)); column.title=title; column.width=width; column.minWidth=85; table.addTableColumn(column)
        }
        table.dataSource=self; table.delegate=self; table.target=self; table.doubleAction=#selector(openAttachment)
        let scroll=NSScrollView(frame:NSRect(x:20,y:112,width:860,height:304)); scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=true; scroll.borderType = .bezelBorder; scroll.documentView=table; scroll.autoresizingMask=[.width,.height]; content.addSubview(scroll)
        func button(_ title:String,_ x:CGFloat,_ width:CGFloat,_ action:Selector)->NSButton {
            let b=NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; b.frame=NSRect(x:x,y:62,width:width,height:34); content.addSubview(b); return b
        }
        openButton=button("打开所选附件",20,172,#selector(openAttachment))
        showButton=button("显示附件",200,130,#selector(showAttachments))
        wordButton=button("打开 Word",348,140,#selector(openWord))
        resultButton=button("显示兼容副本",496,164,#selector(showOutputs))
        _=label("原文档保留 · 附件存放在原文件旁的“ONLYOFFICE附件”文件夹 · 所有处理均在本机完成",NSRect(x:20,y:16,width:860,height:32),12,content)
        updateButtons(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if !pending.isEmpty { let items=pending; pending=[]; process(items) }
    }
    @objc func saveAutoOpen() { UserDefaults.standard.set(autoOpen.state == .on,forKey:"openWordAfterProcessing") }
    @objc func selectFiles() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[UTType(filenameExtension:"docx")!]; panel.allowsMultipleSelection=true; panel.canChooseDirectories=false
        panel.beginSheetModal(for:window) { response in if response == .OK { self.process(panel.urls) } }
    }
    func numberOfRows(in tableView:NSTableView)->Int { attachments.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard row < attachments.count, let id=tableColumn?.identifier else { return nil }
        let item=attachments[row]
        let value:String
        switch id.rawValue {
        case "name": value=item.name
        case "type": value=item.type.title+(item.output == nil ? "" : " · "+ByteCountFormatter.string(fromByteCount:Int64(item.size),countStyle:.file))
        case "document": value=item.document.lastPathComponent
        default: value=item.note
        }
        let cell=NSTableCellView(frame:NSRect(x:0,y:0,width:tableColumn?.width ?? 120,height:34)); cell.identifier=id
        let field=NSTextField(labelWithString:value); field.font = .systemFont(ofSize:12); field.lineBreakMode = .byTruncatingTail
        field.frame=NSRect(x:6,y:8,width:(tableColumn?.width ?? 120)-12,height:19); field.autoresizingMask=[.width]; cell.addSubview(field); cell.textField=field
        cell.toolTip=value+(item.output.map { "\n"+$0.path } ?? "")
        return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification) { updateButtons() }
    func selectedAttachments()->[Attachment] { table.selectedRowIndexes.compactMap { $0 < attachments.count ? attachments[$0] : nil } }
    func updateButtons() {
        choose?.isEnabled = !busy; autoOpen?.isEnabled = !busy
        openButton?.isEnabled = !busy && selectedAttachments().contains { $0.output != nil && $0.type.canOpen }
        showButton?.isEnabled = !busy && attachments.contains { $0.output != nil }
        wordButton?.isEnabled = !busy && !lastOutputs.isEmpty; resultButton?.isEnabled = !busy && !lastOutputs.isEmpty
    }
    func openDocuments(_ urls:[URL]) {
        guard !urls.isEmpty else { return }
        if let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"asc.onlyoffice.ONLYOFFICE") {
            let config=NSWorkspace.OpenConfiguration(); config.activates=true
            NSWorkspace.shared.open(urls,withApplicationAt:app,configuration:config) { _,error in
                if let error { DispatchQueue.main.async { self.detail.stringValue="无法打开："+error.localizedDescription+"。文件已保存，可点击显示结果后自行打开。" } }
            }
        } else { for url in urls { if !NSWorkspace.shared.open(url) { detail.stringValue="未找到可打开该文件的应用，文件已保存。" } } }
    }
    @objc func openWord() { openDocuments(lastOutputs) }
    @objc func showOutputs() { NSWorkspace.shared.activateFileViewerSelecting(lastOutputs) }
    @objc func showAttachments() {
        let selected=selectedAttachments().compactMap(\.output)
        let urls=selected.isEmpty ? Array(Set(attachments.compactMap { $0.output?.deletingLastPathComponent() })) : selected
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    @objc func openAttachment() {
        let selected=selectedAttachments().filter { $0.output != nil && $0.type.canOpen }
        openDocuments(selected.filter { officeExtensions.contains($0.type.ext) }.compactMap(\.output))
        for item in selected where !officeExtensions.contains(item.type.ext) {
            if let url=item.output, !NSWorkspace.shared.open(url) { detail.stringValue="没有能打开“\(item.name)”的应用。附件已保存，可点击“显示附件”选择应用。" }
        }
    }
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        let urls=filenames.map { URL(fileURLWithPath:$0) }
        if window == nil { pending += urls } else if busy { pending += urls; detail.stringValue="新文件已加入队列，将在当前处理结束后继续。" } else { process(urls) }
        sender.reply(toOpenOrPrint:.success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { !busy }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { busy ? .terminateCancel : .terminateNow }
    func process(_ urls:[URL]) {
        guard !busy else { pending += urls; return }
        busy=true; updateButtons(); progress.startAnimation(nil); status.stringValue="正在检查 \(urls.count) 个 Word 文档…"; detail.stringValue="正在提取附件并检查 Excel 兼容性，请稍候。"
        let unique=Array(Set(urls)).sorted {$0.path < $1.path}
        DispatchQueue.global(qos:.userInitiated).async {
            var results:[RepairResult]=[], found:[Attachment]=[], errors:[String]=[], warnings:[String]=[]
            for url in unique {
                do {
                    let scan=try scanAttachments(url,extract:true); found += scan.attachments; warnings += scan.warnings
                    do { results.append(try repair(url)) }
                    catch { warnings.append(url.lastPathComponent+"："+error.localizedDescription); results.append(RepairResult(source:url,output:url,count:0,warnings:[])) }
                } catch { errors.append(url.lastPathComponent+"："+error.localizedDescription) }
            }
            DispatchQueue.main.async {
                self.busy=false; self.progress.stopAnimation(nil); self.lastOutputs=results.map(\.output); self.attachments=found; self.table.reloadData(); self.updateButtons()
                let fixed=results.reduce(0){$0+$1.count}, saved=found.filter {$0.output != nil}.count, failed=found.count-saved
                self.status.stringValue="已处理 \(results.count) 个 Word · 修复 \(fixed) 个 Excel · 提取 \(saved) 个附件"+(failed == 0 ? "" : " · \(failed) 个未提取")+(errors.isEmpty ? "" : " · \(errors.count) 个文档失败")
                let messages=errors+warnings+results.flatMap(\.warnings)
                self.detail.stringValue=messages.isEmpty ? (found.isEmpty ? "未发现嵌入附件。原文档保留，可点击“打开 Word”继续使用。" : "选择附件后点击“打开所选附件”或双击该行。ZIP 使用系统解压；其他格式使用对应应用。") : messages.prefix(3).joined(separator:"\n")
                self.detail.toolTip=messages.joined(separator:"\n")
                if self.autoOpen.state == .on { self.openDocuments(self.lastOutputs) }
                if !self.pending.isEmpty { let next=self.pending; self.pending=[]; self.process(next) }
            }
        }
    }
}
if CommandLine.arguments.count >= 3, ["--repair","--extract","--list","--process"].contains(CommandLine.arguments[1]) {
    do {
        let action=CommandLine.arguments[1], source=URL(fileURLWithPath:CommandLine.arguments[2])
        let folder=CommandLine.arguments.count >= 4 ? URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true) : nil
        var obj:[String:Any]
        if action == "--repair" {
            let result=try repair(source,outputFolder:folder)
            obj=["source":result.source.path,"output":result.output.path,"converted":result.count,"warnings":result.warnings]
        } else {
            let scan=try scanAttachments(source,extract:action != "--list",outputFolder:action == "--process" ? folder?.appendingPathComponent("附件",isDirectory:true) : folder)
            obj=["source":scan.source.path,"attachments":scan.attachments.map(\.json),"warnings":scan.warnings]
            if action == "--process" {
                do {
                    let result=try repair(source,outputFolder:folder?.appendingPathComponent("兼容副本",isDirectory:true))
                    obj["output"]=result.output.path; obj["converted"]=result.count; obj["warnings"]=scan.warnings+result.warnings
                } catch { obj["output"]=source.path; obj["converted"]=0; obj["warnings"]=scan.warnings+[error.localizedDescription] }
            }
        }
        print(String(data:try JSONSerialization.data(withJSONObject:obj,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!); exit(0)
    } catch { fputs(error.localizedDescription+"\n",stderr); exit(1) }
}
let app=NSApplication.shared
let delegate=AppDelegate(); app.delegate=delegate; app.setActivationPolicy(.regular); app.run()
