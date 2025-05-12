import Cocoa
import WebKit

class SVGToPNGConverter: NSObject, WKNavigationDelegate {
    let svgURL: URL
    let outputURL: URL
    let size: CGSize
    
    init(svgURL: URL, outputURL: URL, size: CGSize) {
        self.svgURL = svgURL
        self.outputURL = outputURL
        self.size = size
        super.init()
    }
    
    func convert() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        webView.navigationDelegate = self
        
        let htmlString = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body {
                    margin: 0;
                    padding: 0;
                    background-color: transparent;
                }
                svg {
                    width: \(size.width)px;
                    height: \(size.height)px;
                }
            </style>
        </head>
        <body>
            <img src="file://\(svgURL.path)" width="\(size.width)" height="\(size.height)">
        </body>
        </html>
        """
        
        webView.loadHTMLString(htmlString, baseURL: nil)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let config = NSMutableData()
            let context = CGContext(data: nil, width: Int(self.size.width), height: Int(self.size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            
            let bounds = CGRect(origin: .zero, size: self.size)
            webView.layer?.render(in: context)
            
            if let image = context.makeImage() {
                let bitmap = NSBitmapImageRep(cgImage: image)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: self.outputURL)
                    print("Saved PNG to \(self.outputURL.path)")
                    exit(0)
                }
            }
            
            print("Failed to convert SVG to PNG")
            exit(1)
        }
    }
}

// Main
if CommandLine.arguments.count < 3 {
    print("Usage: SVGToPNG <svg_path> <output_path> [width] [height]")
    exit(1)
}

let svgPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let width = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 1024 : 1024
let height = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? 1024 : 1024

let svgURL = URL(fileURLWithPath: svgPath)
let outputURL = URL(fileURLWithPath: outputPath)
let size = CGSize(width: width, height: height)

let converter = SVGToPNGConverter(svgURL: svgURL, outputURL: outputURL, size: size)
converter.convert()

// Keep the app running
RunLoop.main.run()
