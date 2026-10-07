// 실제 ConPTY 왕복 시험용 프로그램. 사용자 파일과 설정은 건드리지 않는다.
#include <QCoreApplication>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <windows.h>

static void output(const QByteArray &bytes) {
    DWORD n = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), bytes.constData(), DWORD(bytes.size()), &n, nullptr);
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), ENABLE_VIRTUAL_TERMINAL_INPUT);
    SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    const QStringList args = app.arguments().mid(1);
    const QString mode = args.value(0);
    if (mode == QStringLiteral("args")) {
        QJsonObject result{{QStringLiteral("args"), QJsonArray::fromStringList(args.mid(1))},
                           {QStringLiteral("cwd"), QDir::currentPath()},
                           {QStringLiteral("term"), qEnvironmentVariable("TERM")},
                           {QStringLiteral("color"), qEnvironmentVariable("COLORTERM")},
                           {QStringLiteral("program"), qEnvironmentVariable("TERM_PROGRAM")}};
        output(QJsonDocument(result).toJson(QJsonDocument::Compact) + "\r\nFINAL-MARKER\r\n");
        return 0;
    }
    if (mode == QStringLiteral("exit")) { output("FINAL-MARKER\r\n"); return args.value(1).toInt(); }
    if (mode == QStringLiteral("crash")) { RaiseException(0xE0000001, EXCEPTION_NONCONTINUABLE, 0, nullptr); return 1; }
    if (mode == QStringLiteral("flood")) {
        for (;;) output(QByteArray(16384, 'x'));
    }
    if (mode == QStringLiteral("descendant")) {
        std::wstring command = L"cmd.exe /c ping -n 30 127.0.0.1 >nul";
        STARTUPINFOW si{}; si.cb = sizeof si;
        PROCESS_INFORMATION pi{};
        if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) return 3;
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        output("FINAL-MARKER\r\n");
        return 0;
    }
    if (mode == QStringLiteral("probe")) output("\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b[?2031h\x1b[?996n\x1b[?1000h\x1b[?1006h\r\nREADY\r\n");
    else output("\x1b[?1049h\x1b[2J\x1b[HREADY\r\n");
    char buf[1024]; DWORD n = 0; QByteArray history;
    for (;;) {
        if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), buf, sizeof buf, &n, nullptr) || n == 0) return 0;
        const QByteArray input(buf, int(n));
        // 콘솔 입력은 같은 쓰기도 여러 ReadFile로 나뉜다. 실제 바이트 스트림을 누적해 검사한다.
        history += input; history = history.right(1024);
        output("HEX:" + history.toHex() + "\r\n");
        if (input.contains('q')) return 0;
    }
}
