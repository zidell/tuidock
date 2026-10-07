#include "LocalSocket.h"
#include <QFile>
#include <QSocketNotifier>
#include <QTimer>
#include <winsock2.h>
#include <afunix.h>

namespace {
struct Winsock { bool ok; Winsock() { WSADATA data; ok = WSAStartup(MAKEWORD(2, 2), &data) == 0; } ~Winsock() { if (ok) WSACleanup(); } };
bool address(const QString &path, sockaddr_un &addr) {
    const QByteArray bytes = path.toUtf8(); if (bytes.size() >= sizeof(addr.sun_path)) return false;
    addr = {}; addr.sun_family = AF_UNIX; memcpy(addr.sun_path, bytes.constData(), bytes.size()); return true;
}
Winsock &winsock() { static Winsock instance; return instance; }
}
LocalSocket::LocalSocket(QObject *parent) : QObject(parent) {}
LocalSocket::~LocalSocket() {
    destroying = true;
    for (auto fd : clients.keys()) closeClient(fd);
    delete notifier;
    if (server != INVALID_SOCKET) closesocket(server);
    if (!filename.isEmpty()) QFile::remove(filename);
}
bool LocalSocket::listen(const QString &path, QString *error) {
    sockaddr_un addr;
    if (!winsock().ok || !address(path, addr)) { if (error) *error = "Socket path is too long or Winsock is unavailable."; return false; }
    server = socket(AF_UNIX, SOCK_STREAM, 0);
    // 앱 뮤텍스를 가진 첫 실행기만 지난 소켓 파일을 지운다.
    QFile::remove(path);
    if (server == INVALID_SOCKET || bind(server, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) || ::listen(server, 8)) {
        if (error) *error = QString("Could not listen on local socket (%1)").arg(WSAGetLastError());
        if (server != INVALID_SOCKET) closesocket(server); server = INVALID_SOCKET; return false;
    }
    filename = path; u_long nonblocking = 1; ioctlsocket(server, FIONBIO, &nonblocking);
    notifier = new QSocketNotifier(server, QSocketNotifier::Read, this);
    connect(notifier, &QSocketNotifier::activated, this, [this] { acceptConnections(); }); return true;
}
void LocalSocket::acceptConnections() {
    for (;;) {
        SOCKET fd = accept(server, nullptr, nullptr); if (fd == INVALID_SOCKET) return;
        if (clients.size() >= 16) { closesocket(fd); continue; }
        u_long nonblocking = 1; ioctlsocket(fd, FIONBIO, &nonblocking);
        auto *n = new QSocketNotifier(fd, QSocketNotifier::Read, this);
        const quintptr id = ++sequence; order.enqueue(id);
        clients.insert(id, {{}, n, fd}); connect(n, &QSocketNotifier::activated, this, [this, id] { receive(id); });
        // fd가 재사용되어도 이전 연결의 타이머가 새 연결을 닫지 않는다.
        QTimer::singleShot(1000, n, [this, id] { if (clients.contains(id) && !clients[id].done) { clients[id].bytes.clear(); closeClient(id); } });
    }
}
void LocalSocket::closeClient(quintptr fd) {
    if (!clients.contains(fd) || clients[fd].done) return;
    auto &client = clients[fd]; client.done = true; client.notifier->setEnabled(false); client.notifier->deleteLater(); closesocket(client.fd);
    // 전송 순서를 보존한다. 읽기 알림 순서에 따라 hello/bye가 뒤집히지 않는다.
    while (!order.isEmpty() && clients[order.head()].done) {
        const auto complete = clients.take(order.dequeue());
        if (!destroying && !complete.bytes.isEmpty()) emit message(complete.bytes);
    }
}
void LocalSocket::receive(quintptr fd) {
    if (!clients.contains(fd) || clients[fd].done) return;
    char bytes[257];
    for (;;) {
        const int count = recv(clients[fd].fd, bytes, sizeof(bytes), 0);
        if (count == SOCKET_ERROR) { if (WSAGetLastError() != WSAEWOULDBLOCK) { clients[fd].bytes.clear(); closeClient(fd); } return; }
        if (count == 0) { closeClient(fd); return; }
        clients[fd].bytes.append(bytes, count); if (clients[fd].bytes.size() > 256) { clients[fd].bytes.clear(); closeClient(fd); return; }
    }
}
bool LocalSocket::send(const QString &path, const QByteArray &message) {
    sockaddr_un addr; if (!winsock().ok || !address(path, addr) || message.size() > 256) return false;
    SOCKET fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd == INVALID_SOCKET) return false;
    DWORD timeout = 500; setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<char *>(&timeout), sizeof(timeout));
    bool ok = ::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0;
    int offset = 0;
    while (ok && offset < message.size()) { int n = ::send(fd, message.constData() + offset, int(message.size()) - offset, 0); if (n <= 0) ok = false; else offset += n; }
    shutdown(fd, SD_SEND); closesocket(fd); return ok;
}
