#pragma once
#include "Maker.h"
#include <QMainWindow>
#include <QPointer>
class TermView;
class LocalSocket;
class Settings;
class Launcher : public QMainWindow {
    Q_OBJECT
public:
    Launcher(Paths paths, AppSpec app, QWidget *parent = nullptr);
    ~Launcher() override;
    // 0: 첫 실행, 1: 이미 실행 중인 창으로 전달, -1: 실패.
    int start(QString *error);
protected:
    void closeEvent(QCloseEvent *event) override;
private:
    void saveState();
    void focusApp();
    void font(int delta);
    void style(const Style &value);
    void receive(const QByteArray &message);
    Paths paths; AppSpec app;
    QString socketDir;
    void *mutex = nullptr;
    TermView *term = nullptr;
    Config *config = nullptr;
    LocalSocket *socket = nullptr;
    QPointer<Settings> settings;
    bool connected = false, intentional = false, closing = false, force = false;
};
