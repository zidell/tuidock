#pragma once
#include <QFileSystemWatcher>
#include <QMap>
#include <QObject>
#include <QTimer>
#include <QVariant>

struct TomlResult { QMap<QString, QVariant> values; QStringList errors; };
QString tomlString(const QString &value);
TomlResult parseToml(const QString &text);
bool writeText(const QString &path, const QString &text, QString *error = nullptr);
QString readText(const QString &path);

struct Style {
    QString family, theme = QStringLiteral("auto");
    double size = 13, lineHeight = 1.3, contrast = 0;
    bool operator==(const Style &) const = default;
};
enum class ConfigType { Text, Number, Choice };
struct ConfigKey {
    QString key, en, ko;
    ConfigType type;
    double min = 0, max = 0;
    QStringList choices;
};
const QList<ConfigKey> &configKeys();
QVariant styleValue(const Style &s, const QString &key);
void setStyleValue(Style &s, const QString &key, const QVariant &value);
Style parseConfig(const QString &text, const Style &defaults, QStringList *errors = nullptr);
QString configTemplate(const Style &defaults, bool korean = false);

// 파일+부모 폴더를 감시해 이름을 바꾸며 저장한 파일에도 다시 붙는다.
class Config : public QObject {
    Q_OBJECT
public:
    Config(QString path, Style defaults, QObject *parent = nullptr);
    const QString path;
    const Style defaults;
    Style current;
    bool ensure(QString *error = nullptr);
    bool set(const QString &key, const QVariant &value, QString *error = nullptr);
    void reload();
signals:
    void changed();
private:
    QFileSystemWatcher watcher;
    QTimer debounce;
};
