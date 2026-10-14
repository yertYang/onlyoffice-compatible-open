#!/usr/bin/env python3
"""Regression checks with synthetic OOXML/CFB files; no private fixtures."""
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent
EXE = ROOT / 'dist/ONLYOFFICE兼容打开.app/Contents/MacOS/CompatibleOpen'
FREE, END, FAT = 0xffffffff, 0xfffffffe, 0xfffffffd
REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'


def zipped(parts):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_STORED) as archive:
        for name, data in parts.items():
            # Stable timestamps make independently generated expected bytes identical.
            archive.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), data)
    return out.getvalue()


def workbook(padding=0):
    return zipped({
        '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
        '_rels/.rels': f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{REL}/officeDocument" Target="xl/workbook.xml"/></Relationships>',
        'xl/workbook.xml': f'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="{REL}"><sheets><sheet name="Synthetic" sheetId="1" r:id="rId1"/></sheets></workbook>',
        'xl/_rels/workbook.xml.rels': f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{REL}/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
        'xl/worksheets/sheet1.xml': '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1"><v>42</v></c><c r="B1"><f>A1*2</f><v>84</v></c></row></sheetData></worksheet>',
        'docProps/core.xml': '<core><!--' + 'p' * padding + '--></core>',
    })


def directory_entry(name, kind, start, length, child=FREE):
    entry = bytearray(128)
    encoded = (name + '\0').encode('utf-16-le')
    entry[:len(encoded)] = encoded
    struct.pack_into('<HBBIII', entry, 64, len(encoded), kind, 1, FREE, FREE, child)
    struct.pack_into('<IQ', entry, 116, start, length)
    return bytes(entry)


def compound(package, stream_name='package'):
    """Minimal CFB v3 fixture using FAT or MiniFAT according to stream size."""
    small = len(package) < 4096
    if small:
        mini_count = (len(package) + 63) // 64
        stream = package.ljust(mini_count * 64, b'\0')
        data_count = (len(stream) + 511) // 512
        root = directory_entry('Root Entry', 5, 3, len(stream), 1)
        pkg = directory_entry(stream_name, 2, 0, len(package))
        mini_fat = list(range(1, mini_count)) + [END]
        mini_fat += [FREE] * (128 - len(mini_fat))
        data_sectors = [struct.pack('<128I', *mini_fat)]
        first = 3
    else:
        stream = package
        data_count = (len(stream) + 511) // 512
        root = directory_entry('Root Entry', 5, END, 0, 1)
        pkg = directory_entry(stream_name, 2, 2, len(package))
        data_sectors = []
        first = 2
    padded = stream.ljust(data_count * 512, b'\0')
    data_sectors += [padded[i:i+512] for i in range(0, len(padded), 512)]
    fat = [FAT, END] + ([END] if small else [])
    fat += list(range(first + 1, first + data_count)) + [END]
    fat += [FREE] * (128 - len(fat))
    header = bytearray(512)
    header[:8] = bytes.fromhex('d0cf11e0a1b11ae1')
    struct.pack_into('<HHHHH', header, 24, 0x3e, 3, 0xfffe, 9, 6)
    struct.pack_into('<IIIIIIIII', header, 40, 0, 1, 1, 0, 4096, 2 if small else END, 1 if small else 0, END, 0)
    struct.pack_into('<109I', header, 76, 0, *([FREE] * 108))
    directory = (root + pkg).ljust(512, b'\0')
    return bytes(header) + struct.pack('<128I', *fat) + directory + b''.join(data_sectors)


def document(packages):
    objects = ''.join(f'<w:p><w:r><w:object><o:OLEObject Type="Embed" ProgID="Excel.Sheet.12" r:id="rId{i}"/></w:object></w:r></w:p>' for i in range(1, len(packages) + 1))
    parts = {
        '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="bin" ContentType="application/vnd.openxmlformats-officedocument.oleObject"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
        'word/document.xml': f'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:r="{REL}"><w:body><w:p><w:r><w:t>Keep this text</w:t></w:r></w:p>{objects}</w:body></w:document>',
        'word/_rels/document.xml.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + ''.join(f'<Relationship Id="rId{i}" Type="{REL}/oleObject" Target="embeddings/object{i}.bin"/>' for i in range(1, len(packages) + 1)) + '</Relationships>',
        'word/styles.xml': '<styles xmlns="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>',
        'word/media/preserved.dat': b'unchanged synthetic image bytes',
    }
    for i, package in enumerate(packages, 1):
        parts[f'word/embeddings/object{i}.bin'] = compound(package, 'package' if i % 2 else 'Package')
    return parts


def native_stream(name, data, encoding='utf-8'):
    # OLENativeStream fields, independently packed from the Swift parser.
    label = name.encode(encoding) + b'\0'
    body = struct.pack('<H', 2) + label + b'C:\\source\\file\0'
    body += struct.pack('<II', 0, 3) + b'C:\\temp\\file\0'
    body += struct.pack('<I', len(data)) + data
    return struct.pack('<I', len(body)) + body


def embedded_word():
    return zipped({
        '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
        '_rels/.rels': f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{REL}/officeDocument" Target="word/document.xml"/></Relationships>',
        'word/document.xml': '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>嵌入的示例 Word</w:t></w:r></w:p></w:body></w:document>',
    })


def embedded_presentation():
    return zipped({
        '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/></Types>',
        'ppt/presentation.xml': '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>',
    })


def attachment_document(items):
    parts = document([])
    objects, rels = [], []
    for i, item in enumerate(items, 1):
        target = item.get('target', f'embeddings/attachment{i}.bin')
        mode = ' TargetMode="External"' if item.get('external') else ''
        kind = 'Link' if item.get('external') else 'Embed'
        objects.append(f'<w:p><w:r><w:object><o:OLEObject Type="{kind}" ProgID="{item.get("prog", "Package")}" r:id="rId{i}"/></w:object></w:r></w:p>')
        rels.append(f'<Relationship Id="rId{i}" Type="{REL}/{item.get("rel", "oleObject")}" Target="{target}"{mode}/>')
        if not item.get('external'):
            parts['word/' + target] = item['data']
    parts['word/document.xml'] = f'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:r="{REL}"><w:body><w:p><w:r><w:t>原正文保留</w:t></w:r></w:p>{"".join(objects)}</w:body></w:document>'
    parts['word/_rels/document.xml.rels'] = f'<Relationships xmlns="{REL}">{"".join(rels)}</Relationships>'
    return parts


class CompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='compatible-open-test-')
        self.base = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, source):
        return self.action('--repair', source)

    def action(self, action, source):
        return subprocess.run([str(EXE), action, str(source), str(self.base / 'results')], capture_output=True, text=True, timeout=30)

    def result(self, action, source):
        proc = self.action(action, source)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def test_conversion_preserves_content_and_is_idempotent(self):
        packages = [workbook(), workbook(6000)]
        self.assertLess(len(packages[0]), 4096)
        self.assertGreater(len(packages[1]), 4096)
        parts = document(packages)
        # Exercise name collisions without overwriting an existing embedded member.
        parts['word/embeddings/object1_compat.xlsx'] = b'preserve existing member'
        source = self.base / '合成样本.docx'
        source.write_bytes(zipped(parts))
        digest = hashlib.sha256(source.read_bytes()).digest()
        proc = self.invoke(source)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result['converted'], 2)
        output = Path(result['output'])
        self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), digest)
        with zipfile.ZipFile(output) as archive:
            self.assertIsNone(archive.testzip())
            for name, data in parts.items():
                if name not in ('[Content_Types].xml', 'word/_rels/document.xml.rels'):
                    self.assertEqual(archive.read(name), data.encode() if isinstance(data, str) else data)
            relationships = ET.fromstring(archive.read('word/_rels/document.xml.rels'))
            for relationship, package in zip(relationships, packages):
                target = relationship.attrib['Target']
                self.assertFalse(target.startswith('/'), 'ONLYOFFICE requires relative embedded package targets')
                self.assertEqual(relationship.attrib['Type'], REL + '/package')
                self.assertEqual(archive.read('word/' + target), package)
            self.assertIn('object1_compat_2.xlsx', relationships[0].attrib['Target'])
        again = self.invoke(output)
        self.assertEqual(again.returncode, 0, again.stderr)
        repeated = json.loads(again.stdout)
        self.assertEqual(repeated['converted'], 0)
        self.assertEqual(repeated['output'], str(output))

    def test_signed_and_broken_documents_are_rejected(self):
        parts = document([workbook()])
        parts['_xmlsignatures/sig1.xml'] = '<Signature/>'
        source = self.base / 'signed.docx'
        source.write_bytes(zipped(parts))
        self.assertNotEqual(self.invoke(source).returncode, 0)
        source = self.base / 'broken.docx'
        source.write_bytes(b'not a ZIP archive')
        self.assertNotEqual(self.invoke(source).returncode, 0)
        self.assertFalse((self.base / 'results').exists())

    def test_mixed_attachments_list_extract_and_process(self):
        word, book, ppt = embedded_word(), workbook(6000), embedded_presentation()
        archive = zipped({'说明.txt': 'ZIP 中的内容', 'nested/value.json': '{"value":42}'})
        pdf = b'%PDF-1.4\n% synthetic attachment\n%%EOF\n'
        items = [
            {'data': compound(word, 'Package'), 'prog': 'Word.Document.12'},
            {'data': compound(book), 'prog': 'Excel.Sheet.12'},
            {'data': compound(native_stream('资料.zip', archive), '\x01OlE10NaTiVe')},
            {'data': ppt, 'prog': 'PowerPoint.Show.12', 'target': 'embeddings/slides.pptx', 'rel': 'package'},
            {'data': compound(pdf, 'CONTENTS'), 'prog': 'AcroExch.Document.DC'},
            {'target': 'https://example.invalid/linked.docx', 'external': True},
        ]
        source = self.base / '混合附件.docx'
        original = zipped(attachment_document(items)); source.write_bytes(original)
        listed = self.result('--list', source)
        self.assertEqual(len(listed['attachments']), 6)
        self.assertFalse((self.base / 'results').exists(), '--list must not export files')
        self.assertTrue(all(x['output'] is None for x in listed['attachments']))
        result = self.result('--process', source)
        rows = result['attachments']
        self.assertEqual([x['type'] for x in rows[:5]], ['docx', 'xlsx', 'zip', 'pptx', 'pdf'])
        for row, data in zip(rows, [word, book, archive, ppt, pdf]):
            self.assertTrue(row['canOpen'])
            self.assertEqual(Path(row['output']).read_bytes(), data)
        self.assertEqual(rows[2]['name'], '资料.zip')
        self.assertIsNone(rows[-1]['output'])
        self.assertFalse(rows[-1]['canOpen'])
        self.assertEqual(result['converted'], 1)
        self.assertEqual(source.read_bytes(), original)
        with zipfile.ZipFile(result['output']) as repaired:
            self.assertEqual(repaired.read('word/document.xml'), attachment_document(items)['word/document.xml'].encode())

    def test_native_names_collisions_reuse_and_no_traversal(self):
        data_a, data_b = zipped({'a.txt': 'one'}), zipped({'a.txt': 'two'})
        names = ['..\\..\\资料.zip', '/tmp/资料.zip', '资料.zip']
        items = [{'data': compound(native_stream(name, data), '\x01Ole10Native')} for name, data in zip(names, [data_a, data_b, data_a])]
        source = self.base / 'names.docx'; source.write_bytes(zipped(attachment_document(items)))
        first = self.result('--extract', source)['attachments']
        self.assertEqual(Path(first[0]['output']).name, '资料.zip')
        self.assertEqual(Path(first[1]['output']).name, '资料 (2).zip')
        self.assertEqual(first[0]['output'], first[2]['output'])
        self.assertTrue(all(Path(row['output']).parent == self.base / 'results' for row in first))
        second = self.result('--extract', source)['attachments']
        self.assertEqual([r['output'] for r in first], [r['output'] for r in second])
        self.assertEqual(len(list((self.base / 'results').iterdir())), 2)

    def test_empty_zip_gbk_name_and_corrupt_object_are_isolated(self):
        empty = zipped({})
        good = native_stream('中文资料.zip', empty, 'gb18030')
        bad = native_stream('损坏.zip', empty)[:-10]
        text = '文本附件内容'.encode()
        items = [
            {'data': compound(good, '\x01Ole10Native')},
            {'data': compound(bad, '\x01Ole10Native')},
            {'data': compound(native_stream('说明.txt', text), '\x01Ole10Native')},
        ]
        source = self.base / 'edge.docx'; source.write_bytes(zipped(attachment_document(items)))
        result = self.result('--extract', source)
        rows = result['attachments']
        self.assertEqual(rows[0]['name'], '中文资料.zip')
        self.assertEqual(Path(rows[0]['output']).read_bytes(), empty)
        self.assertIsNone(rows[1]['output'])
        self.assertEqual(Path(rows[2]['output']).read_bytes(), text)
        self.assertEqual(len(result['warnings']), 1)

    def test_signature_readonly_export_and_dangerous_container_paths(self):
        parts = attachment_document([{'data': compound(embedded_word(), 'package'), 'prog': 'Word.Document.12'}])
        parts['_xmlsignatures/sig1.xml'] = '<Signature/>'
        source = self.base / 'signed.docx'; original = zipped(parts); source.write_bytes(original)
        exported = self.result('--extract', source)
        self.assertEqual(Path(exported['attachments'][0]['output']).read_bytes(), embedded_word())
        self.assertEqual(source.read_bytes(), original)
        self.assertNotEqual(self.action('--repair', source).returncode, 0)
        parts['word/../../../escaped.xml'] = '<x/>'
        source = self.base / 'traversal.docx'; source.write_bytes(zipped(parts))
        self.assertNotEqual(self.action('--extract', source).returncode, 0)
        self.assertNotEqual(self.action('--repair', source).returncode, 0)

    def test_active_and_unknown_files_are_saved_without_open_permission(self):
        executable = b'MZ' + b'\0' * 80
        word = embedded_word()
        items = [
            {'data': compound(native_stream('program.exe', executable), '\x01Ole10Native')},
            {'data': compound(native_stream('misleading.exe', word), '\x01Ole10Native')},
            {'data': compound(native_stream('a.' + 'b' * 250 + '.zip', zipped({})), '\x01Ole10Native')},
        ]
        source = self.base / ('a.' + 'b' * 220 + '.docx'); source.write_bytes(zipped(attachment_document(items)))
        result = self.result('--extract', source)['attachments']
        self.assertFalse(result[0]['canOpen'])
        self.assertEqual(Path(result[0]['output']).read_bytes(), executable)
        self.assertEqual(result[1]['type'], 'docx')
        self.assertTrue(result[1]['canOpen'])
        self.assertLessEqual(len(result[2]['name'].encode()), 210)


if __name__ == '__main__':
    if not EXE.exists():
        raise SystemExit('Run bash build.sh first.')
    unittest.main(verbosity=2)
