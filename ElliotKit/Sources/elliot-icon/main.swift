import Foundation

let usage = """
    elliot-icon — renders Elliot's mark

      elliot-icon iconset <dir>                    the ten PNGs iconutil wants
      elliot-icon png <path> --pixels <n>          one square PNG
      elliot-icon png <path> --pixels <n> --check  re-render and compare, don't write
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    switch arguments.first {
    case "iconset":
        guard arguments.count == 2 else { fail(usage) }
        try IconRenderer.writeIconSet(to: URL(filePath: arguments[1]))

    case "png":
        guard arguments.count >= 4, arguments[2] == "--pixels", let side = Int(arguments[3]), side > 0
        else { fail(usage) }
        let url = URL(filePath: arguments[1])
        if arguments.count == 5, arguments[4] == "--check" {
            try IconRenderer.check(url, pixels: side)
        } else if arguments.count == 4 {
            try IconRenderer.write(IconRenderer.image(pixels: side), to: url)
        } else {
            fail(usage)
        }

    default:
        fail(usage)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    // 1, not 2: the arguments were fine, the work failed. `--check` leans on
    // this to mean "the committed file no longer matches its source".
    exit(1)
}
