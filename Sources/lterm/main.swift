import Foundation
import LtermCore

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--version" {
    print("lterm \(Lterm.version)")
} else {
    print("lterm \(Lterm.version): control tool for lterm-mac")
}
