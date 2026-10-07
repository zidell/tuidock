#include "Maker.h"
#include "LocalSocket.h"
#include <QBuffer>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDataStream>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QPainter>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <windows.h>
#include <shlobj.h>
#include <shellapi.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shobjidl.h>

Paths Paths::system() {
    const QString roaming = qEnvironmentVariable("APPDATA"), local = qEnvironmentVariable("LOCALAPPDATA");
    return {roaming + "/tuidock", roaming + "/Microsoft/Windows/Start Menu/Programs/TUIDock", local + "/Programs/TUIDock"};
}
bool Paths::validId(const QString &id) { return QRegularExpression("^[a-z0-9][a-z0-9._-]{0,79}$").match(id).hasMatch() && id != "." && id != ".."; }
QString Paths::app(const QString &id) const { return validId(id) ? QDir(root).filePath(id) : QString(); }
QString Paths::idFor(const QString &name) {
    QString slug = name.toLower(); slug.replace(QRegularExpression("[^a-z0-9]+"), "-");
    slug = slug.left(40); while (slug.endsWith('-')) slug.chop(1);
    if (slug.isEmpty() || slug.startsWith('-')) slug = "app";
    return slug + "-" + QString::fromLatin1(QCryptographicHash::hash(name.toUtf8(), QCryptographicHash::Sha256).toHex().left(12));
}
QString Paths::socketDir(const QString &id) {
    QString dir = QDir::temp().filePath("tuidock-" + id);
    if ((dir + "/launcher.sock").toUtf8().size() >= 108) {
        quint64 hash = 14695981039346656037ULL;
        for (unsigned char byte : id.toUtf8()) { hash ^= byte; hash *= 1099511628211ULL; }
        dir = QDir::temp().filePath("tuidock-" + QString::number(hash, 16));
    }
    return dir;
}
QString resolveProgram(const QString &input) {
    if (QFileInfo(input).isFile()) return QFileInfo(input).canonicalFilePath();
    const std::wstring name = input.toStdWString();
    wchar_t path[32768];
    DWORD n = SearchPathW(nullptr, name.c_str(), L".exe", DWORD(std::size(path)), path, nullptr);
    return n && n < std::size(path) ? QString::fromWCharArray(path) : QString();
}
QString shortcutName(const QString &name) {
    QString n = name; n.replace(QRegularExpression("[<>:\"/\\\\|?*\\x00-\\x1f]"), "_");
    n = n.left(100).trimmed(); while (n.endsWith('.') || n.endsWith(' ')) n.chop(1);
    if (n.isEmpty()) n = "App";
    if (QRegularExpression("^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|$)", QRegularExpression::CaseInsensitiveOption).match(n).hasMatch()) n.prepend('_');
    return n + ".lnk";
}
QString quoteWindows(const QString &argument) {
    QString out = "\""; int slashes = 0;
    for (QChar c : argument) {
        if (c == '\\') { ++slashes; continue; }
        out += QString(slashes * (c == '"' ? 2 : 1) + (c == '"' ? 1 : 0), '\\'); slashes = 0; out += c;
    }
    return out + QString(slashes * 2, '\\') + '"';
}
bool loadApp(const Paths &paths, const QString &id, AppSpec &app, QString *error) {
    auto fail = [&](const QString &s) { if (error) *error = s; return false; };
    if (!Paths::validId(id)) return fail("Invalid app id.");
    QFile file(paths.app(id) + "/app.toml");
    if (!file.open(QIODevice::ReadOnly)) return fail("App not found: " + id);
    const auto parsed = parseToml(QString::fromUtf8(file.readAll()));
    if (!parsed.errors.isEmpty()) return fail(parsed.errors.join('\n'));
    const auto &v = parsed.values;
    for (const QString &key : {QString("name"), QString("command"), QString("terminal")})
        if (v.value(key).metaType().id() != QMetaType::QString) return fail("Invalid app field: " + key);
    app = {}; app.id = id; app.name = v["name"].toString(); app.command = v["command"].toString(); app.terminal = v["terminal"].toString();
    if (app.name.isEmpty() || app.command.isEmpty() || app.terminal != "builtin") return fail("Invalid app definition. Windows supports the built-in terminal.");
    if (v.contains("args") && v["args"].metaType().id() != QMetaType::QStringList) return fail("args must be a string array.");
    app.args = v.value("args").toStringList(); app.emoji = v.value("emoji").toString(); app.image = v.value("image").toString();
    app.color = v.value("color", "#4778d5").toString();
    QString settings;
    for (const auto &key : configKeys()) if (v.contains(key.key)) settings += key.key + " = " + (v[key.key].metaType().id() == QMetaType::QString ? tomlString(v[key.key].toString()) : QString::number(v[key.key].toDouble())) + '\n';
    QStringList problems; app.defaults = parseConfig(settings, {}, &problems);
    if (!problems.isEmpty()) return fail(problems.join('\n'));
    return true;
}
QImage fitWindowsIcon(const QImage &image, int size) {
    // Windows는 아이콘 캔버스 전체를 사용한다. 글꼴 여백과 macOS 판 밖 그림자를 제거한다.
    if (image.isNull()) return {};
    QRect bounds;
    for (int y = 0; y < image.height(); ++y)
        for (int x = 0; x < image.width(); ++x)
            if (qAlpha(image.pixel(x, y)) >= 128) bounds |= QRect(x, y, 1, 1);
    if (bounds.isEmpty()) return image.scaled(size, size, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    const QImage cropped = image.copy(bounds);
    QSize fit = cropped.size(); fit.scale(size, size, Qt::KeepAspectRatio);
    QImage result(size, size, QImage::Format_ARGB32_Premultiplied); result.fill(Qt::transparent);
    QPainter p(&result); p.setRenderHint(QPainter::SmoothPixmapTransform);
    p.drawImage(QRect(QPoint((size-fit.width())/2, (size-fit.height())/2), fit), cropped);
    return result;
}
QImage renderIcon(const AppSpec &app, int size) {
    if (!app.image.isEmpty()) {
        QImage original(app.image);
        if (!original.isNull()) {
            QImage result(size, size, QImage::Format_ARGB32_Premultiplied); result.fill(Qt::transparent);
            QPainter p(&result); p.setRenderHint(QPainter::SmoothPixmapTransform);
            QSize fit = original.size(); fit.scale(size, size, Qt::KeepAspectRatio);
            p.drawImage(QRect(QPoint((size - fit.width()) / 2, (size - fit.height()) / 2), fit), original); return result;
        }
    }
    if (!app.emoji.isEmpty()) {
        QImage glyph(size * 2, size * 2, QImage::Format_ARGB32_Premultiplied); glyph.fill(Qt::transparent);
        QPainter p(&glyph); p.setRenderHint(QPainter::TextAntialiasing);
        QFont font("Segoe UI Emoji"); font.setPixelSize(size); p.setFont(font); p.setPen(Qt::white);
        p.drawText(glyph.rect(), Qt::AlignCenter, app.emoji); p.end();
        return fitWindowsIcon(glyph, size);
    }
    QImage result(size, size, QImage::Format_ARGB32_Premultiplied); result.fill(Qt::transparent);
    QPainter p(&result); p.setRenderHint(QPainter::Antialiasing); p.setRenderHint(QPainter::TextAntialiasing);
    if (app.emoji.isEmpty()) {
        const double edge = size * .098;
        p.setPen(Qt::NoPen); p.setBrush(QColor(app.color)); p.drawRoundedRect(QRectF(edge, edge, size - 2 * edge, size - 2 * edge), size * .18, size * .18);
    }
    QFont font(app.emoji.isEmpty() ? "Segoe UI" : "Segoe UI Emoji"); font.setPixelSize(qRound(size * (app.emoji.isEmpty() ? .57 : .73)));
    if (app.emoji.isEmpty()) font.setWeight(QFont::DemiBold);
    p.setFont(font); p.setPen(Qt::white);
    p.drawText(QRectF(size * .08, size * .08, size * .84, size * .84), Qt::AlignCenter, app.emoji.isEmpty() ? app.name.left(1).toUpper() : app.emoji);
    return result;
}
QByteArray iconData(const QImage &image) {
    const QList<int> sizes{16, 24, 32, 48, 64, 256}; QList<QByteArray> pngs;
    for (int size : sizes) { QByteArray png; QBuffer b(&png); b.open(QIODevice::WriteOnly); image.scaled(size, size, Qt::IgnoreAspectRatio, Qt::SmoothTransformation).save(&b, "PNG"); pngs << png; }
    QByteArray out; QDataStream s(&out, QIODevice::WriteOnly); s.setByteOrder(QDataStream::LittleEndian);
    s << quint16(0) << quint16(1) << quint16(sizes.size()); quint32 offset = 6 + 16 * quint32(sizes.size());
    for (int i = 0; i < sizes.size(); ++i) { s << quint8(sizes[i] == 256 ? 0 : sizes[i]) << quint8(sizes[i] == 256 ? 0 : sizes[i]) << quint8(0) << quint8(0) << quint16(1) << quint16(32) << quint32(pngs[i].size()) << offset; offset += quint32(pngs[i].size()); }
    for (const auto &png : pngs) out += png;
    return out;
}
namespace {
struct Com {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~Com() { if (SUCCEEDED(hr)) CoUninitialize(); }
};
HRESULT property(IPropertyStore *store, const PROPERTYKEY &key, const QString &text) {
    PROPVARIANT value; const auto str = text.toStdWString(); HRESULT hr = InitPropVariantFromString(str.c_str(), &value);
    if (SUCCEEDED(hr)) { hr = store->SetValue(key, value); PropVariantClear(&value); } return hr;
}
bool saveLink(const QString &path, const QString &target, const QString &arguments, const QString &icon, const QString &id, QString *error) {
    Com com; IShellLinkW *link = nullptr; IPropertyStore *store = nullptr; IPersistFile *file = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link));
    if (SUCCEEDED(hr)) hr = link->SetPath(target.toStdWString().c_str());
    if (SUCCEEDED(hr)) hr = link->SetArguments(arguments.toStdWString().c_str());
    if (SUCCEEDED(hr)) hr = link->SetWorkingDirectory(QFileInfo(target).absolutePath().toStdWString().c_str());
    if (SUCCEEDED(hr)) hr = link->SetIconLocation(icon.toStdWString().c_str(), 0);
    if (SUCCEEDED(hr)) hr = link->QueryInterface(IID_PPV_ARGS(&store));
    if (SUCCEEDED(hr)) hr = property(store, PKEY_AppUserModel_ID, "tuidock." + id);
    if (SUCCEEDED(hr)) hr = store->Commit();
    if (SUCCEEDED(hr)) hr = link->QueryInterface(IID_PPV_ARGS(&file));
    QDir().mkpath(QFileInfo(path).absolutePath()); const QString temp = path + ".tmp";
    if (SUCCEEDED(hr)) hr = file->Save(temp.toStdWString().c_str(), TRUE);
    if (SUCCEEDED(hr) && !MoveFileExW(temp.toStdWString().c_str(), path.toStdWString().c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) hr = HRESULT_FROM_WIN32(GetLastError());
    if (file) file->Release(); if (store) store->Release(); if (link) link->Release();
    if (FAILED(hr)) { QFile::remove(temp); if (error) *error = QString("Could not create shortcut (0x%1)").arg(quint32(hr), 8, 16, QLatin1Char('0')); return false; }
    SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, path.toStdWString().c_str(), nullptr); return true;
}
}
bool makeApp(const Paths &paths, const MakeOptions &options, AppSpec &result, QString *error, QString *warning) {
    AppSpec app = options.spec;
    if (app.name.isEmpty()) { app.name = QFileInfo(app.command).completeBaseName(); if (!app.name.isEmpty()) app.name[0] = app.name[0].toUpper(); }
    if (app.id.isEmpty()) {
        for (const auto &id : QDir(paths.root).entryList(QDir::Dirs | QDir::NoDotAndDotDot)) { AppSpec existing; if (loadApp(paths,id,existing,nullptr) && existing.name.compare(app.name,Qt::CaseInsensitive)==0) { app.id=id; break; } }
        if (app.id.isEmpty()) app.id = Paths::idFor(app.name);
    }
    if (!Paths::validId(app.id) || app.name.isEmpty() || app.name.size() > 200) { if (error) *error = "Invalid app name or id."; return false; }
    AppSpec old;
    if (QFileInfo::exists(paths.app(app.id) + "/app.toml")) {
        if (!loadApp(paths, app.id, old, error)) return false;
        if (!options.supplied.contains("emoji") && !options.supplied.contains("icon")) { app.emoji = old.emoji; app.image = old.image; }
        if (!options.supplied.contains("color")) app.color = old.color;
        if (!options.supplied.contains("terminal")) app.terminal = old.terminal;
        for (const auto &key : configKeys()) if (!options.supplied.contains(key.key)) setStyleValue(app.defaults, key.key, styleValue(old.defaults, key.key));
    }
    app.command = resolveProgram(app.command);
    if (app.command.isEmpty()) { if (error) *error = "Executable not found."; return false; }
    if (app.terminal != "builtin" || !QColor(app.color).isValid()) { if (error) *error = "Invalid terminal or color. Windows supports the built-in terminal."; return false; }
    if (!app.image.isEmpty() && QImage(app.image).isNull()) { if (error) *error = "Could not read icon image."; return false; }
    const QString dir = paths.app(app.id);
    // 이미지 원본이 사라져도 다시 만들 수 있게 앱 폴더에 보관한다.
    if (!app.image.isEmpty()) {
        QSaveFile f(dir + "/image.png"); QDir().mkpath(dir); QImage image(app.image);
        if (!f.open(QIODevice::WriteOnly) || !image.save(&f, "PNG") || !f.commit()) { if (error) *error = "Could not save icon image."; return false; }
        app.image = dir + "/image.png";
    }
    QString text = "# TUIDock app definition. Terminal preferences belong in config.toml.\n";
    for (const auto &pair : QList<QPair<QString, QString>>{{"name",app.name},{"command",app.command},{"terminal",app.terminal},{"emoji",app.emoji},{"image",app.image},{"color",app.color}}) text += pair.first + " = " + tomlString(pair.second) + '\n';
    QStringList quoted; for (const auto &arg : app.args) quoted << tomlString(arg);
    text += "args = [" + quoted.join(", ") + "]\n";
    for (const auto &key : configKeys()) { auto v = styleValue(app.defaults, key.key); text += key.key + " = " + (v.metaType().id() == QMetaType::QString ? tomlString(v.toString()) : QString::number(v.toDouble())) + '\n'; }
    QStringList problems; parseConfig(text.mid(text.indexOf("font_family")), {}, &problems);
    if (!problems.isEmpty()) { if (error) *error = problems.join('\n'); return false; }
    // 이름 정규화 충돌로 다른 앱의 바로가기를 덮어쓰지 않는다.
    for (const auto &id : QDir(paths.root).entryList(QDir::Dirs | QDir::NoDotAndDotDot)) { AppSpec other; if (id != app.id && loadApp(paths, id, other, nullptr) && shortcutName(other.name).compare(shortcutName(app.name), Qt::CaseInsensitive) == 0) { if (error) *error = "Shortcut name already belongs to another app."; return false; } }
    if (!writeText(dir + "/app.toml", text, error)) return false;
    QSaveFile ico(dir + "/icon.ico"); const QByteArray bytes = iconData(renderIcon(app, 1024));
    if (!ico.open(QIODevice::WriteOnly) || ico.write(bytes) != bytes.size() || !ico.commit()) { if (error) *error = "Could not save icon."; return false; }
    Config config(dir + "/config.toml", app.defaults); if (!config.ensure(error)) return false;
    if (options.shortcut) {
        QString target = paths.installed + "/tuidock.exe";
        if (!QFileInfo::exists(target)) { target = QCoreApplication::applicationFilePath(); if (warning) *warning = "TUIDock is not installed. Run 'tuidock.exe install', then remake shortcuts before moving this folder."; }
        if (!saveLink(QDir(paths.shortcuts).filePath(shortcutName(app.name)), target, "run --app " + app.id, dir + "/icon.ico", app.id, error)) return false;
        if (!old.name.isEmpty() && shortcutName(old.name) != shortcutName(app.name)) QFile::remove(QDir(paths.shortcuts).filePath(shortcutName(old.name)));
    }
    LocalSocket::send(Paths::socketDir(app.id)+"/launcher.sock","reload");
    result = app; return true;
}
bool removeApp(const Paths &paths, const QString &nameOrId, QString *error) {
    QString id = nameOrId; AppSpec app;
    if (!loadApp(paths, id, app, nullptr)) {
        id.clear(); for (const auto &candidate : QDir(paths.root).entryList(QDir::Dirs | QDir::NoDotAndDotDot)) { AppSpec existing; if (loadApp(paths,candidate,existing,nullptr) && existing.name.compare(nameOrId,Qt::CaseInsensitive)==0) { id=candidate; break; } }
        if (id.isEmpty() || !loadApp(paths,id,app,error)) { if (error && id.isEmpty()) *error="App not found: "+nameOrId; return false; }
    }
    HANDLE mutex = OpenMutexW(SYNCHRONIZE, FALSE, ("Local\\tuidock." + id).toStdWString().c_str());
    if (mutex) { CloseHandle(mutex); if (error) *error = "Close the running app before removing it."; return false; }
    QFile::remove(QDir(paths.shortcuts).filePath(shortcutName(app.name)));
    if (!QDir(paths.app(id)).removeRecursively()) { if (error) *error = "Could not remove app folder."; return false; } return true;
}
bool installApp(const Paths &paths, const QString &source, QString *error) {
    if (QDir(source).canonicalPath() == QDir(paths.installed).canonicalPath()) return true;
    for (const auto &file : {"tuidock.exe", "Qt6Core.dll", "Qt6Gui.dll", "Qt6Widgets.dll", "platforms/qwindows.dll", "msvcp140.dll", "vcruntime140.dll"}) {
        if (!QFileInfo::exists(QDir(source).filePath(file))) { if (error) *error="Install from the extracted Windows package. Missing: "+QString(file); return false; }
    }
    QDir().mkpath(paths.installed);
    QDirIterator it(source, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString file = it.next(), relative = QDir(source).relativeFilePath(file);
        // 배포 폴더만 설치한다. 개발 빌드 트리·테스트 실행 파일은 복사하지 않는다.
        if (!(relative == "tuidock.exe" || relative.endsWith(".dll", Qt::CaseInsensitive) || relative.startsWith("fonts/") || relative.startsWith("licenses/") || relative.startsWith("LICENSE"))) continue;
        const QString target = QDir(paths.installed).filePath(relative); QDir().mkpath(QFileInfo(target).absolutePath());
        QFile input(file); QSaveFile output(target);
        if (!input.open(QIODevice::ReadOnly) || !output.open(QIODevice::WriteOnly)) { if (error) *error = "Could not install " + relative + ". Close running TUIDock windows before updating."; return false; }
        while (!input.atEnd()) { QByteArray bytes = input.read(1024 * 1024); if (output.write(bytes) != bytes.size()) { if (error) *error = "Could not install " + relative; return false; } }
        if (!output.commit()) { if (error) *error = "Could not replace " + relative + ". Close running TUIDock windows before updating."; return false; }
    }
    return saveLink(QDir(paths.shortcuts).filePath("TUIDock.lnk"), paths.installed + "/tuidock.exe", {}, {}, "generator", error);
}
bool setWindowIdentity(void *window, const Paths &paths, const AppSpec &app, QString *error) {
    Com com; IPropertyStore *store = nullptr; HRESULT hr = SHGetPropertyStoreForWindow(HWND(window), IID_PPV_ARGS(&store));
    QString target = paths.installed + "/tuidock.exe"; if (!QFileInfo::exists(target)) target = QCoreApplication::applicationFilePath();
    if (SUCCEEDED(hr)) hr = property(store, PKEY_AppUserModel_ID, "tuidock." + app.id);
    if (SUCCEEDED(hr)) hr = property(store, PKEY_AppUserModel_RelaunchCommand, quoteWindows(QDir::toNativeSeparators(target)) + " run --app " + app.id);
    if (SUCCEEDED(hr)) hr = property(store, PKEY_AppUserModel_RelaunchDisplayNameResource, app.name);
    if (SUCCEEDED(hr)) hr = property(store, PKEY_AppUserModel_RelaunchIconResource, QDir::toNativeSeparators(paths.app(app.id) + "/icon.ico") + ",0");
    if (SUCCEEDED(hr)) hr = store->Commit(); if (store) store->Release();
    if (FAILED(hr) && error) *error = QString("Window identity failed (0x%1)").arg(quint32(hr), 8, 16, QLatin1Char('0')); return SUCCEEDED(hr);
}
