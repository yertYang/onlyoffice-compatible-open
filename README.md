# ONLYOFFICE 兼容打开 1.2

<img src="AppIcon.png" width="128" alt="兼容打开图标">

一个 macOS 本地辅助工具。选择或拖入 Word `.docx`，自动检查 WPS 嵌入 Excel 的兼容问题，并把 DOCX、XLSX、PPTX、ZIP、PDF 等附件提取到列表中，方便选择、打开和在 Finder 中查看。

这是独立开发的辅助工具，非 ONLYOFFICE 官方产品。Excel 使用已验证的兼容副本方案；其他附件通过本工具的附件列表打开，不能保证在 ONLYOFFICE 的 Word 正文中直接双击打开。

## 安装和下次使用

1. 解压 `ONLYOFFICE兼容打开-1.2-Apple芯片.zip`。
2. 将 `ONLYOFFICE兼容打开.app` 拖到“应用程序”，替换旧版本前先退出旧应用。
3. 打开工具，点击“选择 Word 文件…”或拖入一个或多个 `.docx`。也可以把文件拖到应用图标上。
4. 处理完成后，选择附件并点击“打开所选附件”，或双击附件行。“显示附件”可在 Finder 中找到文件。

“处理后打开 Word”默认开启，可取消并记住选择。DOCX、XLSX、PPTX 和旧版 Office 附件优先使用已安装的 ONLYOFFICE；PDF、图片、文本等使用系统关联应用；ZIP 交给系统关联的解压工具。RAR、7Z 需要安装能处理它们的应用。提取时不会自动打开附件。

可把应用固定到程序坞。应用运行不依赖 Python、Node.js 或 Codex，所有文档在本机处理。

要求：Apple 芯片 Mac，macOS 12 或更新版本，另行安装 ONLYOFFICE Desktop Editors。安装包使用本地临时签名，未做 Apple 开发者签名或公证。

## 结果位置

- 附件：原文件旁的 `ONLYOFFICE附件/<Word 文件名>/`。文件名尽量使用嵌入的原名称；对象没有原名称时使用内部对象名称。
- Excel 兼容副本：需要修复时生成 `ONLYOFFICE兼容副本/<原文件名>-兼容版.docx`。已有同名副本时追加编号；普通文档和已经修复的副本直接打开。
- 附件原始字节保留。重复提取会复用同名且内容相同的附件；同名但内容不同则追加编号，不覆盖已有文件。
- 原 Word 保留。对提取出的附件所做的编辑不会自动写回 Word；需要时请在 Word 中重新插入。

## 附件支持范围

| 附件或包装 | 行为 |
| --- | --- |
| OLE `Package` 流、`Ole10Native` 文件附件、`CONTENTS` 流，以及直接 OOXML package 关系 | 识别内容并提取 |
| 普通 DOCX、XLSX、PPTX | 在附件列表中打开 |
| ZIP（含空 ZIP）、RAR、7Z、PDF、PNG、JPEG、GIF、RTF | 提取后交给系统关联应用 |
| 带原文件扩展名的 UTF-8 TXT、CSV、JSON、XML、MD、LOG | 提取后交给系统关联应用 |
| 旧 Office OLE 对象中的 WordDocument、Workbook/Book、PowerPoint Document | 保存为 DOC、XLS、PPT；是否能打开取决于内容及关联应用 |
| DOCM、XLSM、PPTM、未知格式及可执行文件 | 仅保存，可在 Finder 中自行选择应用 |
| 外部链接、加密附件、损坏或尚未支持的包装 | 列出原因，不访问外部链接 |

扫描正文及页眉、页脚等 Word 部件内引用的 OLE 对象，同一个内部附件只提取一次。不处理只有预览图片、没有真实嵌入文件的数据。父文档必须是 `.docx`；旧版 `.doc` 请先另存为 `.docx`。单个对象提取失败时继续处理其他可识别附件。

带数字签名的 DOCX 可只读提取附件，但禁止兼容改写，以免使签名失效。加密或损坏的父文档停止处理。单个 DOCX 上限 256 MB，单个读取成员或 OLE 流上限 128 MB；最多 256 个附件，附件累计上限 512 MB。

## Excel 兼容修复原理

某些 WPS `.docx` 把普通 `.xlsx` 包装在 OLE 复合文件的 `package` 流内，并通过 `Type="Embed"`、`ProgID="Excel.Sheet.12"` 嵌入。本工具提取完整普通 XLSX 字节，将对象关系改为 OOXML package 关系并补充内容类型。关系使用相对路径，以兼容 ONLYOFFICE 的加载行为。

正文、图片、样式等内容以及原 OLE 数据保留。含宏的表格、老式 XLS、其他包装和外部链接不适用这一修复，仍可按上面的范围提取。输出前检查 ZIP 完整性、写入内容和正文一致性。

原有 Excel 方案已在 macOS / ONLYOFFICE 9.4.0 中用实际含 6 个 Excel 附件的 WPS 文件验证：转换后可双击打开嵌入表格；6 个 XLSX 的字节不变，原文档与兼容副本渲染一致。1.2 的混合附件、FAT/MiniFAT、中文名称、重名复用、损坏对象隔离、数字签名和路径限制使用合成样本回归验证。实际业务文件、文件名和附件数据不包含在仓库中。

## 从源码构建

安装 Apple Command Line Tools（`xcode-select --install`），然后在项目目录执行：

```sh
bash build.sh
```

生成 `dist/ONLYOFFICE兼容打开.app` 和 ZIP 安装包，默认目标是 `arm64-apple-macos12.0`。图标资源已预生成，无需额外安装依赖。可用 `ARCH=x86_64 bash build.sh` 生成 Intel 版本，但该版本尚未在 Intel Mac 上验证。

命令行处理（不启动窗口）：

```sh
APP="dist/ONLYOFFICE兼容打开.app/Contents/MacOS/CompatibleOpen"
"$APP" --list /绝对路径/文件.docx          # 只列出，不导出附件
"$APP" --extract /绝对路径/文件.docx       # 只提取附件
"$APP" --repair /绝对路径/文件.docx        # 仅执行原 Excel 兼容修复
"$APP" --process /绝对路径/文件.docx       # 提取附件并修复 Excel
"$APP" --process /绝对路径/文件.docx /绝对路径/结果目录
```

可选第三个参数指定输出目录。`--process` 在该目录下分别使用 `附件/` 和 `兼容副本/`；其他操作直接使用该目录。无须修复时 `output` 指向原 Word。

成功时输出 JSON；文档级错误返回非零退出码。单个附件失败或 `--process` 的兼容修复无法完成，会在 JSON 的 `warnings` 及附件 `note` 中列出原因；其他附件仍可成功导出。`--list` 的附件 `output` 为 null。

合成样本回归检查需要 Python 3，仅开发测试时使用：

```sh
python3 smoke.py
```

## 上游问题线索

[DesktopEditors #1646](https://github.com/ONLYOFFICE/DesktopEditors/issues/1646) 涉及 PowerPoint 中嵌入 Excel 的预览兼容；[官方回复](https://github.com/ONLYOFFICE/DesktopEditors/issues/1646#issuecomment-3018903164) 称该问题已在 9.0.0 修复。这与本项目的 WPS DOCX 双击无反应问题有关联，但不是同一个问题。未找到能够证明升级即可解决本次问题的官方修复记录。

## 目录

```text
CompatibleOpen.swift  原生 Swift / AppKit 应用、附件识别和兼容修复逻辑
AppIcon.*             SVG 源图标、PNG 预览和 ICNS 图标
build.sh              构建、临时签名、ZIP 打包
smoke.py              无业务数据的合成样本回归检查
安装与使用说明.txt    安装包附带的说明
```
