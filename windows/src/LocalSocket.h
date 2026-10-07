#pragma once
#include <QObject>
#include <QHash>
#include <QQueue>
class QSocketNotifier;
class LocalSocket : public QObject {
    Q_OBJECT
public:
    explicit LocalSocket(QObject *parent = nullptr);
    ~LocalSocket() override;
    bool listen(const QString &path, QString *error);
    static bool send(const QString &path, const QByteArray &message);
signals:
    void message(const QByteArray &message);
private:
    void acceptConnections();
    void receive(quintptr fd);
    void closeClient(quintptr fd);
    quintptr server = ~quintptr(0);
    QString filename;
    QSocketNotifier *notifier = nullptr;
    struct Client { QByteArray bytes; QSocketNotifier *notifier; quintptr fd; bool done = false; };
    QHash<quintptr, Client> clients;
    QQueue<quintptr> order;
    quintptr sequence = 0;
    bool destroying = false;
};
