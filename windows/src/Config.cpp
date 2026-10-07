#include "Config.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <algorithm>
#include <cmath>

QString tomlString(const QString &value) {
    const QByteArray json = QJsonDocument(QJsonArray{value}).toJson(QJsonDocument::Compact);
    return QString::fromUtf8(json.mid(1, json.size() - 2));
}
QString readText(const QString &path) { QFile f(path); return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.readAll()) : QString(); }
bool writeText(const QString &path, const QString &text, QString *error) {
    QSaveFile f(path);
    const QByteArray bytes = text.toUtf8();
    if (!QDir().mkpath(QFileInfo(path).absolutePath()) || !f.open(QIODevice::WriteOnly) || f.write(bytes) != bytes.size() || !f.commit()) {
        if (error) *error = QStringLiteral("Could not write %1: %2").arg(path, f.errorString());
        return false;
    }
    return true;
}
namespace {
QString withoutComment(const QString &text) {
    QChar quote; bool escape = false;
    for (int i = 0; i < text.size(); ++i) {
        const QChar c = text[i];
        if (!quote.isNull()) {
            if (escape) escape = false;
            else if (quote == QLatin1Char('"') && c == QLatin1Char('\\')) escape = true;
            else if (c == quote) quote = QChar();
        } else if (c == QLatin1Char('"') || c == QLatin1Char('\'')) quote = c;
        else if (c == QLatin1Char('#')) return text.left(i);
    }
    return text;
}
bool stringValue(const QString &raw, QString &value) {
    if (raw.size() >= 2 && raw.startsWith(QLatin1Char('\'')) && raw.endsWith(QLatin1Char('\''))) {
        value = raw.mid(1, raw.size() - 2); return !value.contains(QLatin1Char('\''));
    }
    if (!raw.startsWith(QLatin1Char('"'))) return false;
    const QJsonDocument doc = QJsonDocument::fromJson((QLatin1Char('[') + raw + QLatin1Char(']')).toUtf8());
    if (!doc.isArray() || doc.array().size() != 1 || !doc.array()[0].isString()) return false;
    value = doc.array()[0].toString(); return true;
}
bool valueOf(const QString &raw, QVariant &value) {
    QString s;
    if (stringValue(raw, s)) { value = s; return true; }
    if (raw.startsWith(QLatin1Char('[')) && raw.endsWith(QLatin1Char(']'))) {
        const QString body = raw.mid(1, raw.size() - 2);
        QStringList items; QChar quote; bool escape = false; int start = 0;
        for (int i = 0; i <= body.size(); ++i) {
            if (i == body.size() || (quote.isNull() && body[i] == QLatin1Char(','))) {
                const QString part = body.mid(start, i - start).trimmed();
                if (!part.isEmpty()) { if (!stringValue(part, s)) return false; items << s; }
                else if (i != body.size()) return false;
                start = i + 1;
            } else if (escape) escape = false;
            else if (quote == QLatin1Char('"') && body[i] == QLatin1Char('\\')) escape = true;
            else if (!quote.isNull() && body[i] == quote) quote = QChar();
            else if (quote.isNull() && (body[i] == QLatin1Char('"') || body[i] == QLatin1Char('\''))) quote = body[i];
        }
        if (!quote.isNull()) return false;
        value = items; return true;
    }
    static const QRegularExpression number(QStringLiteral("^[+-]?(?:[0-9]+(?:\\.[0-9]+)?)(?:[eE][+-]?[0-9]+)?$"));
    bool ok = false; const double n = raw.toDouble(&ok);
    if (ok && std::isfinite(n) && number.match(raw).hasMatch()) { value = n; return true; }
    return false;
}
bool valid(const ConfigKey &key, const QVariant &v) {
    if (key.type == ConfigType::Number) return v.metaType().id() == QMetaType::Double && v.toDouble() >= key.min && v.toDouble() <= key.max;
    if (v.metaType().id() != QMetaType::QString) return false;
    return key.type == ConfigType::Text || key.choices.contains(v.toString());
}
QString serialized(const QVariant &v) { return v.metaType().id() == QMetaType::QString ? tomlString(v.toString()) : QString::number(v.toDouble(), 'g', 12); }
}
TomlResult parseToml(const QString &text) {
    TomlResult result; QSet<QString> seen;
    const auto lines = text.split(QLatin1Char('\n'));
    for (int i = 0; i < lines.size(); ++i) {
        const QString line = withoutComment(lines[i]).trimmed();
        if (line.isEmpty()) continue;
        const int eq = line.indexOf(QLatin1Char('='));
        const QString key = eq < 0 ? QString() : line.left(eq).trimmed();
        static const QRegularExpression keyPattern(QStringLiteral("^[A-Za-z_][A-Za-z0-9_]*$"));
        QVariant value;
        if (!keyPattern.match(key).hasMatch() || !valueOf(line.mid(eq + 1).trimmed(), value) || seen.contains(key)) {
            result.errors << QStringLiteral("line %1: invalid or duplicate key/value: %2").arg(i + 1).arg(key);
            result.values.remove(key); seen.insert(key); continue;
        }
        seen.insert(key); result.values.insert(key, value);
    }
    return result;
}
const QList<ConfigKey> &configKeys() {
    static const QList<ConfigKey> keys{
        {"font_family", "Font family. Empty: bundled D2Coding; unknown: system monospaced font.", "글꼴 이름. 빈 값은 D2Coding, 없는 이름은 시스템 고정폭 글꼴.", ConfigType::Text},
        {"font_size", "Font size in pt. Ctrl +/- changes this line; Ctrl 0 resets it.", "글꼴 크기(pt). Ctrl +/-로 이 줄을 바꾸고 Ctrl 0으로 기본값 복원.", ConfigType::Number, 6, 72},
        {"line_height", "Multiple of the font's natural height. Borders stay joined.", "줄 높이 배수. 간격을 늘려도 테두리 선은 이어진다.", ConfigType::Number, 1, 3},
        {"theme", "Appearance: auto follows Windows app mode; dark or light overrides it.", "모양. auto는 Windows 앱 모드, dark/light는 지정한 모양.", ConfigType::Choice, 0, 0, {"auto", "dark", "light"}},
        {"contrast", "0 leaves colors unchanged. Positive blends toward white/black; negative toward background (80% at -100).", "대비. 0은 프로그램 색 그대로. +는 흰색/검정 쪽으로, -는 배경 쪽으로(-100에서 80%) 섞는다.", ConfigType::Number, -100, 100}};
    return keys;
}
QVariant styleValue(const Style &s, const QString &key) {
    if (key == "font_family") return s.family;
    if (key == "font_size") return s.size;
    if (key == "line_height") return s.lineHeight;
    if (key == "theme") return s.theme;
    return s.contrast;
}
void setStyleValue(Style &s, const QString &key, const QVariant &v) {
    if (key == "font_family") s.family = v.toString();
    else if (key == "font_size") s.size = v.toDouble();
    else if (key == "line_height") s.lineHeight = v.toDouble();
    else if (key == "theme") s.theme = v.toString();
    else if (key == "contrast") s.contrast = v.toDouble();
}
Style parseConfig(const QString &text, const Style &defaults, QStringList *errors) {
    const auto parsed = parseToml(text); QStringList problems = parsed.errors; Style style = defaults;
    for (auto it = parsed.values.cbegin(); it != parsed.values.cend(); ++it) {
        const auto &keys = configKeys();
        const auto key = std::find_if(keys.cbegin(), keys.cend(), [&](const auto &k) { return k.key == it.key(); });
        if (key == keys.cend()) problems << QStringLiteral("unknown key: %1").arg(it.key());
        else if (!valid(*key, it.value())) problems << QStringLiteral("invalid value for %1; using its default").arg(it.key());
        else setStyleValue(style, it.key(), it.value());
    }
    if (errors) *errors = problems;
    return style;
}
QString configTemplate(const Style &defaults, bool korean) {
    QString out = korean ? QStringLiteral("# TUIDock 설정. 저장하면 바로 반영. Ctrl+,도 같은 파일을 편집한다.\n\n")
                         : QStringLiteral("# TUIDock settings. Save to apply. Ctrl+, edits the same file.\n\n");
    for (const auto &key : configKeys()) {
        out += QStringLiteral("# %1\n").arg(korean ? key.ko : key.en);
        out += QStringLiteral("# Type: %1; default: %2").arg(key.type == ConfigType::Number ? "number" : "string", serialized(styleValue(defaults, key.key)));
        if (key.type == ConfigType::Number) out += QStringLiteral("; range: %1..%2").arg(key.min).arg(key.max);
        if (key.type == ConfigType::Choice) out += "; choices: " + key.choices.join(", ");
        out += "\n" + key.key + " = " + serialized(styleValue(defaults, key.key)) + "\n\n";
    }
    return out;
}
Config::Config(QString file, Style initial, QObject *parent) : QObject(parent), path(std::move(file)), defaults(std::move(initial)), current(defaults) {
    debounce.setSingleShot(true); debounce.setInterval(50);
    connect(&watcher, &QFileSystemWatcher::fileChanged, this, [this] { debounce.start(); });
    connect(&watcher, &QFileSystemWatcher::directoryChanged, this, [this] { debounce.start(); });
    connect(&debounce, &QTimer::timeout, this, &Config::reload);
    reload();
}
void Config::reload() {
    current = parseConfig(readText(path), defaults);
    const QString dir = QFileInfo(path).absolutePath();
    if (QFileInfo::exists(dir) && !watcher.directories().contains(dir)) watcher.addPath(dir);
    if (QFileInfo::exists(path) && !watcher.files().contains(path)) watcher.addPath(path);
    emit changed();
}
bool Config::ensure(QString *error) {
    if (QFileInfo::exists(path)) return true;
    const bool ok = writeText(path, configTemplate(defaults), error); reload(); return ok;
}
bool Config::set(const QString &key, const QVariant &value, QString *error) {
    const auto &keys = configKeys();
    const auto spec = std::find_if(keys.cbegin(), keys.cend(), [&](const auto &k) { return k.key == key; });
    if (spec == keys.cend() || !valid(*spec, value)) { if (error) *error = "Invalid setting: " + key; return false; }
    QStringList lines = (QFileInfo::exists(path) ? readText(path) : configTemplate(defaults)).split('\n');
    bool found = false;
    for (QString &line : lines) {
        const QString body = withoutComment(line);
        if (body.section('=', 0, 0).trimmed() != key || !body.contains('=')) continue;
        const QString comment = line.mid(body.size());
        if (!found) { line = key + " = " + serialized(value) + (comment.isEmpty() ? "" : " " + comment); found = true; }
        else line = "# " + line;
    }
    if (!found) lines << key + " = " + serialized(value);
    const bool ok = writeText(path, lines.join('\n'), error); if (ok) reload(); return ok;
}
