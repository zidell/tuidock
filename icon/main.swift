// 아이콘 도구: tuidock make가 부른다. 빌드: swiftc -o icon icon/IconRender.swift icon/main.swift
// 사용: icon 출력.png 글자(이모지나 앱 이름) [#배경색]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("사용: icon 출력.png 글자 [#배경색]\n".data(using: .utf8)!)
    exit(2)
}
let data = IconRender.png(text: args[2], color: args.count > 3 ? args[3] : IconRender.defaultColor)
try data.write(to: URL(fileURLWithPath: args[1]))
