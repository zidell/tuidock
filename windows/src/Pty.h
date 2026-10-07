#pragma once
#include <QObject>
#include <QStringList>
#include <memory>

// 프로그램을 셸 없이 ConPTY에 직접 연결한다.
class Pty : public QObject {
    Q_OBJECT
public:
    explicit Pty(QObject *parent = nullptr);
    ~Pty() override;
    bool start(const QString &program, const QStringList &args, const QString &cwd,
               int cols, int rows, const QStringList &extraEnv = {});
    bool isRunning() const;
    void write(const QByteArray &data);
    void resize(int cols, int rows);
    QString errorString() const;
    static QString quoteArg(const QString &arg);
signals:
    void dataReceived(const QByteArray &data);
    void finished(quint32 exitCode);
private:
    struct Impl;
    std::unique_ptr<Impl> d;
};
