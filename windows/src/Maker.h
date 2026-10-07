#pragma once
#include "Config.h"
#include <QImage>
#include <QSet>
#include <optional>

struct Paths {
    QString root, shortcuts, installed;
    static Paths system();
    QString app(const QString &id) const;
    static bool validId(const QString &id);
    static QString idFor(const QString &name);
    static QString socketDir(const QString &id);
};
struct AppSpec {
    QString id, name, command, terminal = "builtin", emoji, image, color = "#4778d5";
    QStringList args;
    Style defaults;
};
struct MakeOptions {
    AppSpec spec;
    QSet<QString> supplied;
    bool shortcut = true;
};
QString resolveProgram(const QString &input);
QString shortcutName(const QString &name);
bool loadApp(const Paths &paths, const QString &id, AppSpec &app, QString *error);
QImage renderIcon(const AppSpec &app, int size = 256);
QImage fitWindowsIcon(const QImage &image, int size = 1024);
QByteArray iconData(const QImage &image);
bool makeApp(const Paths &paths, const MakeOptions &options, AppSpec &result, QString *error, QString *warning = nullptr);
bool removeApp(const Paths &paths, const QString &nameOrId, QString *error);
bool installApp(const Paths &paths, const QString &source, QString *error);
bool setWindowIdentity(void *hwnd, const Paths &paths, const AppSpec &app, QString *error = nullptr);
QString quoteWindows(const QString &argument);
