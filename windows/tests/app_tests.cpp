#include "Config.h"
#include "Generator.h"
#include "Launcher.h"
#include "LocalSocket.h"
#include "Maker.h"
#include "Settings.h"
#include "TermView.h"
#include <QApplication>
#include <QClipboard>
#include <QDataStream>
#include <QFile>
#include <QFontDatabase>
#include <QProcess>
#include <QMimeData>
#include <QDropEvent>
#include <QDragEnterEvent>
#include <QLineEdit>
#include <QLabel>
#include <QCheckBox>
#include <QPushButton>
#include <QInputMethodEvent>
#include <QSettings>
#include <QUrl>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <propkey.h>
#include <propvarutil.h>

class AppTests : public QObject {
    Q_OBJECT
    QString fixture() { return QCoreApplication::applicationDirPath()+"/terminal_fixture.exe"; }
    Paths paths(const QTemporaryDir &temp) { return {temp.filePath("apps"),temp.filePath("Start"),temp.filePath("installed")}; }
private slots:
    void initTestCase() {
        QDir fonts(QCoreApplication::applicationDirPath()+"/fonts"); for (const auto &file : fonts.entryList({"*.ttf"},QDir::Files)) QFontDatabase::addApplicationFont(fonts.filePath(file));
    }
    void configParsing() {
        QStringList errors; Style defaults; defaults.size=17;
        auto s=parseConfig("font_family = '한글 # font'\nfont_size = 999\nline_height=1.6 # comment\ntheme='dark'\ncontrast=-22\nunknown=1",defaults,&errors);
        QCOMPARE(s.family,QString("한글 # font")); QCOMPARE(s.size,17.); QCOMPARE(s.lineHeight,1.6); QCOMPARE(s.theme,QString("dark")); QCOMPARE(s.contrast,-22.); QCOMPARE(errors.size(),2);
        s=parseConfig("font_size=20\nfont_size=21\ncontrast='10'",defaults,&errors); QCOMPARE(s.size,17.); QCOMPARE(s.contrast,0.); QCOMPARE(errors.size(),2);
        QCOMPARE(parseConfig(configTemplate(defaults),{}),defaults);
        const QString text="quotes \" \\ 한글\n"; QCOMPARE(parseToml("name="+tomlString(text)).values["name"].toString(),text);
    }
    void configAtomicSave() {
        QTemporaryDir temp; Config config(temp.filePath("config.toml"),{}); QString error; QVERIFY(config.ensure(&error));
        QVERIFY(writeText(config.path,"# kept\nfont_size = 14 # inline\ntheme='dark'\n")); config.reload(); QVERIFY(config.set("font_size",16.));
        QVERIFY(readText(config.path).contains("# inline")); QVERIFY(readText(config.path).startsWith("# kept")); QCOMPARE(config.current.size,16.);
        QSignalSpy changed(&config,&Config::changed); QVERIFY(writeText(config.path,"font_size=20\ncontrast=9\n")); QTRY_VERIFY(changed.size()>0); QCOMPARE(config.current.size,20.);
        changed.clear(); QVERIFY(writeText(config.path,"font_size=21\n")); QTRY_VERIFY(changed.size()>0); QCOMPARE(config.current.size,21.);
    }
    void contrastAndMode() {
        QCOMPARE(TermView::adjustedColor({100,120,140},{20,40,60},0,true,false),QColor(100,120,140));
        QCOMPARE(TermView::adjustedColor({100,120,140},{20,40,60},100,true,false),QColor(Qt::white));
        QCOMPARE(TermView::adjustedColor({100,120,140},{20,40,60},-100,true,false),QColor(36,56,76));
        QCOMPARE(TermView::adjustedColor({100,120,140},{20,40,60},0,true,true),QColor(60,80,100));
        const QByteArray enabled="\x1b[?2031h",query="\x1b[?996n",disabled="\x1b[?2031l";
        for (int split=0;split<=enabled.size();++split) {
            TermView term; Style style; style.theme="dark"; term.applyStyle(style); QSignalSpy replies(&term,&TermView::themeReply);
            term.feedOutput(enabled.left(split)); term.feedOutput(enabled.mid(split)); QCOMPARE(replies.size(),0);
            style.theme="light"; term.applyStyle(style); QCOMPARE(replies.size(),1); QCOMPARE(replies[0][0].toByteArray(),QByteArray("\x1b[?997;2n")); term.applyStyle(style); QCOMPARE(replies.size(),1);
            term.feedOutput(disabled); style.theme="dark"; term.applyStyle(style); QCOMPARE(replies.size(),1);
            for (char c:query) term.feedOutput(QByteArray(1,c)); QCOMPARE(replies.size(),2); QCOMPARE(replies[1][0].toByteArray(),QByteArray("\x1b[?997;1n"));
        }
    }
    void makeIconShortcut() {
        QTemporaryDir temp; Paths p=paths(temp); MakeOptions o; o.spec.name="한글 Calendar"; o.spec.command=fixture(); o.spec.emoji="🗓️"; o.spec.defaults.size=16; o.supplied={"emoji","font_size"}; QString error; AppSpec app;
        QVERIFY2(makeApp(p,o,app,&error),qPrintable(error)); QVERIFY(Paths::validId(app.id)); QVERIFY(!Paths::validId("../escape"));
        AppSpec loaded; QVERIFY(loadApp(p,app.id,loaded,&error)); QCOMPARE(loaded.name,o.spec.name); QCOMPARE(loaded.defaults.size,16.); QCOMPARE(loaded.emoji,o.spec.emoji);
        QFile ico(p.app(app.id)+"/icon.ico"); QVERIFY(ico.open(QIODevice::ReadOnly)); QByteArray bytes=ico.readAll(); ico.close(); QDataStream stream(bytes); stream.setByteOrder(QDataStream::LittleEndian); quint16 a,b,count; stream>>a>>b>>count; QCOMPARE(a,0); QCOMPARE(b,1); QCOMPARE(count,6);
        for (int size : {16,24,32,48,64,256}) { quint8 w,h,c,r; quint16 planes,bits; quint32 length,offset; stream>>w>>h>>c>>r>>planes>>bits>>length>>offset; QCOMPARE(w,size==256 ? 0 : size); QImage png; QVERIFY(png.loadFromData(bytes.mid(offset,length),"PNG")); QCOMPARE(png.size(),QSize(size,size)); }
        CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED); IShellLinkW *link=nullptr; QVERIFY(SUCCEEDED(CoCreateInstance(CLSID_ShellLink,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&link)))); IPersistFile *file=nullptr; link->QueryInterface(IID_PPV_ARGS(&file)); QVERIFY(SUCCEEDED(file->Load(QDir(p.shortcuts).filePath(shortcutName(app.name)).toStdWString().c_str(),STGM_READ)));
        wchar_t arguments[1024]; link->GetArguments(arguments,1024); QCOMPARE(QString::fromWCharArray(arguments),"run --app "+app.id);
        IPropertyStore *store=nullptr; link->QueryInterface(IID_PPV_ARGS(&store)); PROPVARIANT value; PropVariantInit(&value); QVERIFY(SUCCEEDED(store->GetValue(PKEY_AppUserModel_ID,&value))); QCOMPARE(QString::fromWCharArray(value.pwszVal),"tuidock."+app.id); PropVariantClear(&value); store->Release(); file->Release(); link->Release(); CoUninitialize();
        QVERIFY(writeText(p.app(app.id)+"/config.toml","font_size=22\n")); o.supplied.clear(); o.spec.emoji.clear(); o.spec.defaults={}; AppSpec remake; QVERIFY2(makeApp(p,o,remake,&error),qPrintable(error)); QCOMPARE(remake.emoji,app.emoji); QCOMPARE(remake.defaults.size,16.); QCOMPARE(readText(p.app(app.id)+"/config.toml"),QString("font_size=22\n"));
        QVERIFY(removeApp(p,app.name,&error)); QVERIFY(!QFileInfo::exists(p.app(app.id))); QVERIFY(!QFileInfo::exists(QDir(p.shortcuts).filePath(shortcutName(app.name))));
    }
    void socketFraming() {
        QTemporaryDir temp; LocalSocket socket; QString error; QVERIFY2(socket.listen(temp.filePath("socket"),&error),qPrintable(error)); QSignalSpy messages(&socket,&LocalSocket::message);
        QVERIFY(LocalSocket::send(temp.filePath("socket"),"hello 123")); QTRY_COMPARE(messages.size(),1); QCOMPARE(messages[0][0].toByteArray(),QByteArray("hello 123"));
        QVERIFY(LocalSocket::send(temp.filePath("socket"),"focus")); QTRY_COMPARE(messages.size(),2); QVERIFY(!LocalSocket::send(temp.filePath("socket"),QByteArray(257,'x')));
    }
    void goIntegration() {
        QString exe=QCoreApplication::applicationDirPath()+"/go_fixture.exe"; if (!QFileInfo::exists(exe)) QSKIP("Build go_fixture.exe to test Go interop");
        QTemporaryDir temp; LocalSocket socket; QString error; QVERIFY(socket.listen(temp.filePath("launcher.sock"),&error)); QSignalSpy messages(&socket,&LocalSocket::message);
        auto *clipboard=QGuiApplication::clipboard(); auto *saved=new QMimeData;
        if (const auto *source=clipboard->mimeData()) for (const auto &type:source->formats()) saved->setData(type,source->data(type));
        struct Restore { QClipboard *clipboard; QMimeData *data; ~Restore() { clipboard->setMimeData(data); } } restore{clipboard,saved};
        QProcess process; auto env=QProcessEnvironment::systemEnvironment(); env.insert("TUIDOCK",temp.path()); process.setProcessEnvironment(env); process.start(exe,{"clipboard"}); QVERIFY(process.waitForStarted());
        QTRY_VERIFY(messages.size()>=5); QCOMPARE(messages[0][0].toByteArray().left(6),QByteArray("hello ")); QVERIFY(LocalSocket::send(temp.filePath("app.sock"),"key cmd+q"));
        QTRY_VERIFY(messages.size()>=6); QCOMPARE(messages.last()[0].toByteArray(),QByteArray("bye")); QVERIFY(LocalSocket::send(temp.filePath("app.sock"),"ok")); QTRY_COMPARE(process.state(),QProcess::NotRunning); QCOMPARE(process.exitCode(),0); auto output=process.readAllStandardOutput(); QVERIFY(output.contains("CLOSED")); QVERIFY2(output.contains(QString("CLIPBOARD:한글 clipboard 🗓️").toUtf8()),output.constData());
    }
    void generatorDrop() {
        QTemporaryDir temp; Paths p=paths(temp); QVERIFY(writeText(p.installed+"/tuidock.exe","test"));
        auto oldFormat=QSettings::defaultFormat(); QSettings::setDefaultFormat(QSettings::IniFormat); QSettings::setPath(QSettings::IniFormat,QSettings::UserScope,temp.path());
        Generator generator(p); generator.show(); auto *edit=generator.findChild<QLineEdit *>(); edit->setText("🗓️");
        QMimeData mime; mime.setUrls({QUrl::fromLocalFile(fixture())}); QDragEnterEvent enter({100,100},Qt::CopyAction,&mime,Qt::LeftButton,Qt::NoModifier); QCoreApplication::sendEvent(&generator,&enter); QVERIFY(enter.isAccepted());
        QDropEvent drop({100,100},Qt::CopyAction,&mime,Qt::LeftButton,Qt::NoModifier); QCoreApplication::sendEvent(&generator,&drop); QVERIFY(drop.isAccepted());
        QVERIFY(QDir(p.root).entryList(QDir::Dirs|QDir::NoDotAndDotDot).isEmpty()); generator.findChild<QCheckBox *>()->setChecked(false); auto *create=generator.findChild<QPushButton *>("createButton"); QVERIFY(create->isEnabled()); QTest::mouseClick(create,Qt::LeftButton);
        QStringList ids=QDir(p.root).entryList(QDir::Dirs|QDir::NoDotAndDotDot); QCOMPARE(ids.size(),1); AppSpec app; QString error; QVERIFY(loadApp(p,ids[0],app,&error)); QCOMPARE(app.emoji,QString("🗓️"));
        edit->setText("🦊"); QTRY_VERIFY_WITH_TIMEOUT(loadApp(p,ids[0],app,&error) && app.emoji=="🦊",2000);
        QInputMethodEvent input; input.setCommitString("📝"); QCoreApplication::sendEvent(edit,&input); QCOMPARE(edit->text(),QString("📝"));
        QInputMethodEvent family; family.setCommitString("👨‍👩‍👧‍👦"); QCoreApplication::sendEvent(edit,&family); QCOMPARE(edit->text(),QString("👨‍👩‍👧‍👦"));
        QTRY_VERIFY_WITH_TIMEOUT(loadApp(p,ids[0],app,&error) && app.emoji=="👨‍👩‍👧‍👦",2000);
        QCOMPARE(Generator::lastEmoji("📝🇰🇷"),QString("🇰🇷")); QCOMPARE(Generator::lastEmoji("📝👍🏽"),QString("👍🏽"));
        if (!qEnvironmentVariableIsEmpty("TUIDOCK_GENERATOR_CAPTURE")) QVERIFY(generator.grab().save(qEnvironmentVariable("TUIDOCK_GENERATOR_CAPTURE")));
        QSettings::setDefaultFormat(oldFormat);
    }
    void launcherStateAndClose() {
        QTemporaryDir temp; Paths p=paths(temp); MakeOptions o; o.spec.name="Launcher test"; o.spec.command=fixture(); AppSpec app; QString error; QVERIFY(makeApp(p,o,app,&error));
        Launcher launcher(p,app); QVERIFY2(launcher.start(&error)==0,qPrintable(error)); auto *term=launcher.findChild<TermView *>(); QVERIFY(term); QTRY_VERIFY(term->screenText().contains("READY"));
        Config *config=launcher.findChild<Config *>(); QVERIFY(config); QSize cells=term->cells(); QVERIFY(config->set("font_size",18.)); QCOMPARE(term->cells(),cells); QTest::keyClick(term,Qt::Key_Equal,Qt::ControlModifier); QCOMPARE(config->current.size,19.); QTest::keyClick(term,Qt::Key_0,Qt::ControlModifier); QCOMPARE(config->current.size,13.);
        QTest::keyClick(term,Qt::Key_Comma,Qt::ControlModifier); QTRY_VERIFY(launcher.findChild<Settings *>()); auto *settings=launcher.findChild<Settings *>(); QTest::keyClick(settings,Qt::Key_Escape); QTRY_VERIFY(!launcher.findChild<Settings *>());
        LocalSocket appSocket; QVERIFY(appSocket.listen(Paths::socketDir(app.id)+"/app.sock",&error)); QSignalSpy keys(&appSocket,&LocalSocket::message); QVERIFY(LocalSocket::send(Paths::socketDir(app.id)+"/launcher.sock","hello 123")); QTest::qWait(50); launcher.close(); QTRY_COMPARE(keys.size(),1); QCOMPARE(keys[0][0].toByteArray(),QByteArray("key cmd+q")); QVERIFY(launcher.isVisible());
        launcher.close(); QVERIFY(!launcher.isVisible()); QVERIFY(QFileInfo::exists(p.app(app.id)+"/state.ini"));
    }
};
QTEST_MAIN(AppTests)
#include "app_tests.moc"
