#include "Launcher.h"
#include "LocalSocket.h"
#include "Settings.h"
#include "TermView.h"
#include <QApplication>
#include <QCloseEvent>
#include <QDir>
#include <QFileInfo>
#include <QMessageBox>
#include <QScreen>
#include <QSettings>
#include <QThread>
#include <QTimer>
#include <QWindow>
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <dwmapi.h>

Launcher::Launcher(Paths paths, AppSpec app, QWidget *parent) : QMainWindow(parent), paths(std::move(paths)), app(std::move(app)) {}
Launcher::~Launcher() { delete term; if (socket) delete socket; if (mutex) CloseHandle(HANDLE(mutex)); }
int Launcher::start(QString *error) {
    mutex = CreateMutexW(nullptr, FALSE, ("Local\\tuidock." + app.id).toStdWString().c_str());
    if (!mutex) { if (error) *error = "Could not create app mutex."; return -1; }
    const bool existing = GetLastError() == ERROR_ALREADY_EXISTS;
    socketDir = Paths::socketDir(app.id);
    if (existing) {
        // 새 인스턴스가 받은 전경 권한을 기존 인스턴스로 넘긴다.
        for (int i = 0; i < 30; ++i) {
            bool ok; DWORD pid = readText(socketDir + "/launcher.pid").trimmed().toUInt(&ok); if (ok) AllowSetForegroundWindow(pid);
            if (LocalSocket::send(socketDir + "/launcher.sock", "focus")) return 1;
            QThread::msleep(50);
        }
        if (error) *error = "The app is already running but did not respond."; return -1;
    }
    SetCurrentProcessExplicitAppUserModelID(("tuidock." + app.id).toStdWString().c_str());
    QDir().mkpath(socketDir); socket = new LocalSocket(this);
    if (!socket->listen(socketDir + "/launcher.sock", error) || !writeText(socketDir + "/launcher.pid", QString::number(GetCurrentProcessId()), error)) return -1;
    connect(socket,&LocalSocket::message,this,&Launcher::receive);
    config = new Config(paths.app(app.id) + "/config.toml", app.defaults, this); if (!config->ensure(error)) return -1;
    setWindowTitle(app.name); setWindowIcon(QIcon(paths.app(app.id) + "/icon.ico"));
    term = new TermView(this); setCentralWidget(term); term->applyStyle(config->current);
    QSettings state(paths.app(app.id) + "/state.ini",QSettings::IniFormat);
    QSize cells = state.value("cells").toSize(); QRect available = screen()->availableGeometry();
    if (cells.width() >= 10 && cells.width() <= 1000 && cells.height() >= 2 && cells.height() <= 1000) resize(term->sizeForCells(cells));
    else resize(available.width()*9/10,available.height()*9/10);
    QPoint pos = state.value("pos",available.center()-QPoint(width()/2,height()/2)).toPoint();
    bool visible = false; for (auto *s : QGuiApplication::screens()) if (s->availableGeometry().intersects(QRect(pos,QSize(width(),40)))) { available=s->availableGeometry(); visible=true; break; }
    if (!visible) pos = available.center()-QPoint(width()/2,height()/2);
    resize(qMin(width(),available.width()),qMin(height(),available.height()));
    move(qBound(available.left(),pos.x(),available.right()-width()+1),qBound(available.top(),pos.y(),available.bottom()-qMin(height(),available.height())+1));
    auto native = reinterpret_cast<void *>(winId());
    if (QGuiApplication::platformName()=="windows" && !setWindowIdentity(native,paths,app,error)) return -1;
    connect(config,&Config::changed,this,[this] { style(config->current); });
    connect(term,&TermView::fontRequested,this,&Launcher::font);
    connect(term,&TermView::settingsRequested,this,[this] {
        if (!settings) { settings = new Settings(config,this); connect(settings,&Settings::preview,this,&Launcher::style); }
        settings->show(); settings->raise(); settings->activateWindow();
    });
    connect(term,&TermView::closeRequested,this,[this] { saveState(); force = true; close(); });
    connect(term,&TermView::programFinished,this,[this](quint32) { connected=false; if (intentional) { force=true; close(); } });
    connect(windowHandle(),&QWindow::screenChanged,this,[this](QScreen *) { QSize cells=term->cells(); QTimer::singleShot(0,this,[this,cells] { resize(term->sizeForCells(cells)); }); });
    show(); term->setFocus(); style(config->current);
    QTimer::singleShot(0,term,[this] { term->start(app.command,app.args,QFileInfo(app.command).absolutePath(),socketDir); }); return 0;
}
void Launcher::saveState() {
    if (!term) return; QSettings state(paths.app(app.id)+"/state.ini",QSettings::IniFormat);
    state.setValue("cells",term->cells()); state.setValue("pos",pos()); state.setValue("font",config->current.size); state.sync();
}
void Launcher::style(const Style &value) {
    if (!term) return; QSize cells=term->cells(); term->applyStyle(value); resize(term->sizeForCells(cells));
    BOOL dark=term->isDark(); DwmSetWindowAttribute(HWND(winId()),20,&dark,sizeof(dark));
}
void Launcher::font(int delta) { if (config && term) config->set("font_size", delta ? qBound(6.,config->current.size+delta,72.) : config->defaults.size); }
void Launcher::focusApp() {
    showNormal(); raise(); activateWindow(); SetForegroundWindow(HWND(winId()));
}
void Launcher::receive(const QByteArray &msg) {
    if (msg.startsWith("hello ")) { bool ok; uint pid=msg.mid(6).toUInt(&ok); if (ok && pid) connected=true; }
    else if (msg == "focus") focusApp();
    else if (msg == "hide") showMinimized();
    else if (msg == "reload") {
        AppSpec updated; if (loadApp(paths,app.id,updated,nullptr)) {
            app=updated; setWindowTitle(app.name); setWindowIcon(QPixmap::fromImage(renderIcon(app)));
            if (QGuiApplication::platformName()=="windows") setWindowIdentity(reinterpret_cast<void *>(winId()),paths,app,nullptr);
        }
    }
    else if (msg == "font +1") font(1);
    else if (msg == "font -1") font(-1);
    else if (msg == "bye") { intentional=true; saveState(); LocalSocket::send(socketDir+"/app.sock","ok"); }
}
void Launcher::closeEvent(QCloseEvent *event) {
    if (!force && connected && term && term->isRunning() && !closing) {
        closing=true; event->ignore();
        if (!LocalSocket::send(socketDir+"/app.sock","key cmd+q")) { force=true; close(); return; }
        // 앱이 종료 요청에 응답하지 않아도 창을 영구히 닫을 수 없는 상태는 만들지 않는다.
        QTimer::singleShot(5000,this,[this] { if (closing && isVisible()) { force=true; close(); } }); return;
    }
    intentional=true; saveState(); event->accept();
}
