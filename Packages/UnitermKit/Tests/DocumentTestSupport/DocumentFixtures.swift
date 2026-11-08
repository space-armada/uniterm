import AppKit
import Foundation
import PDFKit
import TableTestSupport

/// Generates document files in code, so the repo holds no binary fixtures. The fixtures use
/// synthetic content only.
public enum DocumentFixtures {
  public static func makeFolder() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-doc-\(UUID().uuidString)", isDirectory: true)

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    return root
  }

  @discardableResult
  public static func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)

    return url
  }

  /// The path of the unsandboxed helper that SwiftPM builds beside the test bundle.
  public static func packageHelper() -> URL {
    let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
    let products = bundle?.bundleURL.deletingLastPathComponent()

    return (products ?? URL(fileURLWithPath: ".")).appendingPathComponent("DocumentDecoderHelper")
  }

  /// A file the debug helper reads as a request to misbehave: `crash`, `stop`, `spin`,
  /// `slow:<ms>`, or `balloon:<megabytes>`.
  public static func fault(_ kind: String) -> Data {
    Data("UNITERM-FAULT \(kind)\nrest of a file".utf8)
  }

  /// The pixels of a solid red image: `width` by `height`, premultiplied RGBA in sRGB.
  public static func redPixels(width: Int, height: Int) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)

    for index in stride(from: 0, to: bytes.count, by: 4) {
      bytes[index] = 255
      bytes[index + 3] = 255
    }

    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)!
  }

  /// An image with exactly `width` by `height` pixels, all red, whatever the screen's scale.
  public static func redImage(width: Int, height: Int) -> NSImage {
    NSImage(
      cgImage: redPixels(width: width, height: height),
      size: NSSize(width: width, height: height))
  }

  /// A paragraph of body text, and optionally a heading above it.
  public static func attributed(
    heading: String? = nil, body: String, headerLevel: Int = 1
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()

    if let heading {
      let style = NSMutableParagraphStyle()
      style.headerLevel = headerLevel

      result.append(
        NSAttributedString(
          string: heading + "\n",
          attributes: [
            .font: NSFont.boldSystemFont(ofSize: 24), .paragraphStyle: style,
          ]))
    }

    result.append(
      NSAttributedString(
        string: body, attributes: [.font: NSFont.systemFont(ofSize: 13)]))

    return result
  }

  public static func data(
    _ text: NSAttributedString, type: NSAttributedString.DocumentType
  ) throws -> Data {
    try text.data(
      from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
  }

  public static func rtf(body: String = "Hello, document.", heading: String? = nil) throws -> Data {
    try data(attributed(heading: heading, body: body), type: .rtf)
  }

  public static func docx(body: String = "Hello, document.", heading: String? = nil) throws -> Data
  {
    try data(attributed(heading: heading, body: body), type: .officeOpenXML)
  }

  public static func doc(body: String = "Hello, document.", heading: String? = nil) throws -> Data {
    try data(attributed(heading: heading, body: body), type: .docFormat)
  }

  /// An RTF document with a link.
  public static func rtfWithLink(_ link: String, text: String = "a link") throws -> Data {
    let string = NSMutableAttributedString(string: "See ")
    string.append(NSAttributedString(string: text, attributes: [.link: URL(string: link)!]))

    return try data(string, type: .rtf)
  }

  /// A `.docx` with a red picture between two runs of text, built by hand since the system writer
  /// does not keep pictures. The picture is a PNG in `word/media`.
  public static func docxWithImage(width: Int = 40, height: Int = 20) -> Data {
    let rep = NSBitmapImageRep(cgImage: redPixels(width: width, height: height))
    let png = rep.representation(using: .png, properties: [:]) ?? Data()
    let emu = width * 9525
    let tall = height * 9525

    let parts = [
      ZipPart(
        "[Content_Types].xml",
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """),
      ZipPart(
        "_rels/.rels",
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """),
      ZipPart(
        "word/_rels/document.xml.rels",
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
        </Relationships>
        """),
      ZipPart(
        "word/document.xml",
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body><w:p><w:r><w:t xml:space="preserve">Before </w:t></w:r><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(emu)" cy="\(tall)"/><wp:docPr id="1" name="Picture 1"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="image1.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(emu)" cy="\(tall)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r><w:r><w:t xml:space="preserve"> after.</w:t></w:r></w:p></w:body>
        </w:document>
        """),
      ZipPart("word/media/image1.png", bytes: Array(png)),
    ]

    return Data(ZipFixture.archive(parts))
  }

  /// An RTF document that holds `rows` by `columns` table cells.
  public static func rtfWithTable(rows: Int, columns: Int) -> Data {
    var text = "{\\rtf1\\ansi\n"

    for row in 0..<rows {
      text += "\\trowd"

      for column in 1...columns { text += "\\cellx\(column * 1000)" }

      for column in 0..<columns { text += "r\(row)c\(column)\\intbl\\cell " }

      text += "\\row\n"
    }

    text += "}"

    return Data(text.utf8)
  }

  /// A PDF with one page of text for each entry.
  public static func pdf(pages: [String] = ["Hello, PDF."]) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)

    guard let consumer = CGDataConsumer(data: data as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return Data() }

    for page in pages {
      context.beginPDFPage(nil)

      let text = NSAttributedString(
        string: page, attributes: [.font: NSFont.systemFont(ofSize: 24)])
      let line = CTLineCreateWithAttributedString(text)

      context.textPosition = CGPoint(x: 72, y: 700)
      CTLineDraw(line, context)
      context.endPDFPage()
    }

    context.closePDF()

    return data as Data
  }
}
