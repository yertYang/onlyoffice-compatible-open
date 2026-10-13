# ONLYOFFICE 兼容打开

<img src="AppIcon.png" width="128" alt="兼容打开图标">

一个 macOS 本地辅助工具，用于处理部分 WPS Word 文档中嵌入的 Excel 双击后无反应的问题。选择或拖入 `.docx`，工具自动生成兼容副本，再使用已安装的 ONLYOFFICE 打开。

这是独立开发的辅助工具，非 ONLYOFFICE 官方产品。它处理特定的文件包装兼容问题，不能修复所有嵌入对象或修改 ONLYOFFICE 本身。

## 安装和下次使用

1. 解压 `ONLYOFFICE兼容打开-1.1-Apple芯片.zip`。
2. 将 `ONLYOFFICE兼容打开.app` 拖到“应用程序”。
3. 打开工具，点击“选择 Word 文件…”或拖入一个或多个 `.docx`。也可以把文件拖到应用图标上。

可把应用固定到程序坞，方便下次使用。应用运行不依赖 Python、Node.js 或 Codex，文档在本机处理。

需要修复时，结果保存在原文件旁的 `ONLYOFFICE兼容副本/<原文件名>-兼容版.docx`；已有同名结果时自动追加编号。原文件始终保留。普通文档、已经转换过的文档直接打开，无需再生成副本。

要求：Apple 芯片 Mac，macOS 12 或更新版本，另行安装 ONLYOFFICE Desktop Editors。安装包使用本地临时签名，未做 Apple 开发者签名或公证。

## 原理和支持范围

某些 WPS `.docx` 把普通 `.xlsx` 包装在 OLE 复合文件的 `package` 流内，并通过 `Excel.Sheet.12` 嵌入。工具提取原始 XLSX 字节，把对象关系改为 OOXML package 关系，并补充内容类型。关系使用相对路径，以兼容 ONLYOFFICE 的加载行为。

- 支持 `.docx` 内 `Type="Embed"`、`ProgID="Excel.Sheet.12"`，且包含完整普通 XLSX 的对象。
- XLSX 原始字节保留；正文、图片、样式等文档内容保持原样。原 OLE 数据也保留在兼容副本内。
- 不支持旧版 `.doc`、老式 `.xls`、含宏的 XLSX 包装、外部链接附件。未识别的对象会保留原样；部分跳过情形会提示原因。
- 加密、损坏、带数字签名的 DOCX 停止处理。单个 DOCX 上限 256 MB，单个读取成员或 OLE 数据上限 128 MB。
- 输出前检查 ZIP 完整性、写入内容和正文一致性。

已在 macOS / ONLYOFFICE 9.4.0 中用实际含 6 个 Excel 附件的 WPS 文件验证：转换后可双击打开嵌入表格；6 个 XLSX 的内容字节不变，原文档与兼容副本渲染一致。实际业务文件、文件名和附件数据不包含在仓库中。

## 从源码构建

安装 Apple Command Line Tools（`xcode-select --install`），然后在项目目录执行：

```sh
bash build.sh
```

生成 `dist/ONLYOFFICE兼容打开.app` 和 ZIP 安装包，默认目标是 `arm64-apple-macos12.0`。图标资源已预生成，无需额外安装依赖。可用 `ARCH=x86_64 bash build.sh` 生成 Intel 版本，但该版本尚未在 Intel Mac 上验证。

命令行转换（不启动窗口）：

```sh
dist/ONLYOFFICE兼容打开.app/Contents/MacOS/CompatibleOpen --repair /绝对路径/文件.docx
# 可选第三个参数指定输出文件夹
dist/ONLYOFFICE兼容打开.app/Contents/MacOS/CompatibleOpen --repair /绝对路径/文件.docx /绝对路径/结果目录
```

成功时输出 JSON，失败时返回非零退出码。合成样本回归检查需要 Python 3，仅开发测试时使用：

```sh
python3 smoke.py
```

## 上游问题线索

查阅 ONLYOFFICE GitHub 后，发现 [DesktopEditors #1646](https://github.com/ONLYOFFICE/DesktopEditors/issues/1646) 涉及 PowerPoint 中嵌入 Excel 的预览兼容；[官方回复](https://github.com/ONLYOFFICE/DesktopEditors/issues/1646#issuecomment-3018903164) 称该问题已在 9.0.0 修复。这与本项目的 WPS DOCX 双击无反应问题有关联，但不是同一个问题。未找到能够证明升级即可解决本次问题的官方修复记录。

## 目录

```text
CompatibleOpen.swift  原生 Swift / AppKit 应用与转换逻辑
AppIcon.*             SVG 源图标、PNG 预览和 ICNS 图标
build.sh              构建、临时签名、ZIP 打包
smoke.py              无业务数据的合成样本回归检查
```
