// Gifiles의 PtyWin.cpp를 바탕으로 종료 코드·스레드 수명·인자 전달을 보완했다(GPLv3).
#include "Pty.h"
#include <QDir>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <windows.h>

namespace {
void closeHandle(HANDLE &h) {
    if (h && h != INVALID_HANDLE_VALUE) CloseHandle(h);
    h = nullptr;
}
}

struct Pty::Impl {
    HPCON console = nullptr;
    HANDLE input = nullptr, output = nullptr;
    PROCESS_INFORMATION pi = {};
    std::thread reader, writer, waiter;
    std::atomic<bool> running{false}, stopping{false};
    std::mutex consoleMutex, inputMutex;
    std::condition_variable inputReady;
    QByteArray pendingInput;
    QString error;

    void closeConsole() {
        std::lock_guard lock(consoleMutex);
        if (console) {
            ClosePseudoConsole(console);
            console = nullptr;
        }
    }
    void cleanup() {
        stopping = true;
        running = false;
        inputReady.notify_all();
        // 출력 스레드는 EOF까지 계속 읽는다. ClosePseudoConsole의 마지막 프레임도 비워야 한다.
        closeConsole();
        if (writer.joinable()) {
            CancelSynchronousIo(writer.native_handle());
            writer.join();
        }
        if (waiter.joinable()) waiter.join();
        if (reader.joinable()) reader.join();
        closeHandle(input);
        closeHandle(output);
        closeHandle(pi.hProcess);
        closeHandle(pi.hThread);
    }
    ~Impl() { cleanup(); }
};

Pty::Pty(QObject *parent) : QObject(parent), d(std::make_unique<Impl>()) {}
Pty::~Pty() = default;

// Windows CRT 규칙: 따옴표 앞 역슬래시는 두 배 + 하나, 닫는 따옴표 앞은 두 배.
QString Pty::quoteArg(const QString &arg) {
    if (!arg.isEmpty() && !arg.contains(QRegularExpression(QStringLiteral("[\\s\"]")))) return arg;
    QString out = QStringLiteral("\"");
    int slashes = 0;
    for (QChar c : arg) {
        if (c == QLatin1Char('\\')) { ++slashes; continue; }
        if (c == QLatin1Char('"')) out += QString(slashes * 2 + 1, QLatin1Char('\\'));
        else out += QString(slashes, QLatin1Char('\\'));
        out += c;
        slashes = 0;
    }
    return out + QString(slashes * 2, QLatin1Char('\\')) + QLatin1Char('"');
}

bool Pty::start(const QString &program, const QStringList &args, const QString &cwd,
                int cols, int rows, const QStringList &extraEnv) {
    if (d->pi.hProcess || d->console || d->stopping) {
        d->error = QStringLiteral("A Pty instance can only be started once");
        return false;
    }
    HANDLE inRead = nullptr, outWrite = nullptr;
    LPPROC_THREAD_ATTRIBUTE_LIST attrs = nullptr;
    bool attrsInitialized = false;
    auto releaseSetup = [&] {
        closeHandle(inRead);
        closeHandle(outWrite);
        if (attrsInitialized) DeleteProcThreadAttributeList(attrs);
        if (attrs) HeapFree(GetProcessHeap(), 0, attrs);
    };
    auto fail = [&](const QString &operation, unsigned long code) {
        d->error = QStringLiteral("%1 failed (0x%2)").arg(operation).arg(code, 8, 16, QLatin1Char('0'));
        d->stopping = true;
        releaseSetup();
        d->cleanup();
        return false;
    };
    if (!CreatePipe(&inRead, &d->input, nullptr, 0) || !CreatePipe(&d->output, &outWrite, nullptr, 0))
        return fail(QStringLiteral("CreatePipe"), GetLastError());
    HRESULT hr = CreatePseudoConsole(COORD{SHORT(cols), SHORT(rows)}, inRead, outWrite, 0, &d->console);
    if (FAILED(hr)) return fail(QStringLiteral("CreatePseudoConsole"), hr);

    // 시작 실패 때도 콘솔을 닫는 동안 출력 채널을 비운다.
    d->reader = std::thread([this] {
        char buf[16384];
        DWORD n = 0;
        while (ReadFile(d->output, buf, sizeof buf, &n, nullptr) && n > 0) {
            QByteArray chunk(buf, int(n));
            if (!d->stopping)
                QMetaObject::invokeMethod(this, [this, chunk] { emit dataReceived(chunk); }, Qt::QueuedConnection);
        }
        if (!d->stopping) {
            // 마지막 출력과 종료 알림을 같은 스레드에서 순서대로 큐잉한다.
            WaitForSingleObject(d->pi.hProcess, INFINITE);
            DWORD code = 0;
            GetExitCodeProcess(d->pi.hProcess, &code);
            d->running = false;
            QMetaObject::invokeMethod(this, [this, code] { emit finished(code); }, Qt::QueuedConnection);
        }
    });
    SIZE_T size = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
    attrs = static_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(HeapAlloc(GetProcessHeap(), 0, size));
    if (!attrs) return fail(QStringLiteral("HeapAlloc"), ERROR_NOT_ENOUGH_MEMORY);
    if (!InitializeProcThreadAttributeList(attrs, 1, 0, &size))
        return fail(QStringLiteral("InitializeProcThreadAttributeList"), GetLastError());
    attrsInitialized = true;
    if (!UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, d->console, sizeof(HPCON), nullptr, nullptr))
        return fail(QStringLiteral("UpdateProcThreadAttribute"), GetLastError());

    STARTUPINFOEXW si = {};
    si.StartupInfo.cb = sizeof si;
    si.lpAttributeList = attrs;
    // 리다이렉트된 부모의 stdin을 물려받아 바로 EOF로 종료하지 않게 한다(Gifiles와 같은 조건).
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    QString command = quoteArg(program);
    for (const QString &arg : args) command += QLatin1Char(' ') + quoteArg(arg);
    std::wstring cmd = command.toStdWString();
    const std::wstring executable = QDir::toNativeSeparators(program).toStdWString();
    const std::wstring directory = QDir::toNativeSeparators(cwd).toStdWString();
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    for (const QString &kv : extraEnv) {
        const int eq = kv.indexOf(QLatin1Char('='));
        if (eq > 0) env.insert(kv.left(eq), kv.mid(eq + 1));
    }
    QStringList vars = env.toStringList();
    vars.sort(Qt::CaseInsensitive);
    std::wstring block;
    for (const QString &kv : vars) block += kv.toStdWString() + L'\0';
    block += L'\0';
    if (!CreateProcessW(executable.c_str(), cmd.data(), nullptr, nullptr, FALSE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, block.data(),
                        directory.empty() ? nullptr : directory.c_str(), &si.StartupInfo, &d->pi))
        return fail(QStringLiteral("CreateProcessW"), GetLastError());
    releaseSetup();
    d->running = true;
    d->writer = std::thread([this] {
        for (;;) {
            QByteArray bytes;
            {
                std::unique_lock lock(d->inputMutex);
                d->inputReady.wait(lock, [this] { return d->stopping || !d->pendingInput.isEmpty(); });
                if (d->stopping) return;
                bytes.swap(d->pendingInput);
            }
            DWORD written = 0;
            qsizetype offset = 0;
            while (!d->stopping && offset < bytes.size() &&
                   WriteFile(d->input, bytes.constData() + offset, DWORD(qMin<qsizetype>(4096, bytes.size() - offset)), &written, nullptr) && written)
                offset += written;
        }
    });
    d->waiter = std::thread([this] {
        WaitForSingleObject(d->pi.hProcess, INFINITE);
        d->closeConsole();
    });
    return true;
}

bool Pty::isRunning() const { return d->running; }
QString Pty::errorString() const { return d->error; }
void Pty::write(const QByteArray &data) {
    if (!d->running || d->stopping || data.isEmpty()) return;
    {
        std::lock_guard lock(d->inputMutex);
        d->pendingInput += data;
    }
    d->inputReady.notify_one();
}
void Pty::resize(int cols, int rows) {
    std::lock_guard lock(d->consoleMutex);
    if (d->console) ResizePseudoConsole(d->console, COORD{SHORT(cols), SHORT(rows)});
}
