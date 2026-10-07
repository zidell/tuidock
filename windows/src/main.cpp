#include "Generator.h"
#include "Launcher.h"
#include "Maker.h"
#include <QApplication>
#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <windows.h>
#include <cstdio>

namespace {
void print(const QString &text) {
    if (!GetStdHandle(STD_OUTPUT_HANDLE) || GetStdHandle(STD_OUTPUT_HANDLE)==INVALID_HANDLE_VALUE) {
        AttachConsole(ATTACH_PARENT_PROCESS); FILE *stream=nullptr; freopen_s(&stream,"CONOUT$","w",stdout);
    }
    const QByteArray bytes=text.toUtf8(); DWORD written; HANDLE out=GetStdHandle(STD_OUTPUT_HANDLE); DWORD mode;
    if (GetConsoleMode(out,&mode)) { auto wide=text.toStdWString(); WriteConsoleW(out,wide.c_str(),DWORD(wide.size()),&written,nullptr); }
    else { std::fwrite(bytes.constData(),1,bytes.size(),stdout); std::fflush(stdout); }
}
int fail(const QString &text) { print("Error: "+text+"\n"); return 2; }
constexpr auto help=
    "TUIDock for Windows\n"
    "Usage: tuidock.exe                         Open generator\n"
    "       tuidock.exe install                 Install in user programs\n"
    "       tuidock.exe gui [--emoji <emoji>] [--language ko|en]\n"
    "       tuidock.exe <program> [emoji] [options]\n"
    "       tuidock.exe make --command <program> [--name <name>] [options]\n"
    "       tuidock.exe run --app <id>\n"
    "       tuidock.exe run --command <program> [--arg <argument>]...\n"
    "       tuidock.exe remove <name-or-id>\n"
    "       tuidock.exe --app <id> --config-path|--print-default-config|--init-config|--check-config\n"
    "Options: --arg, --emoji, --icon, --color, --terminal builtin,\n"
    "         --font, --font-size, --line-height, --id, --no-shortcut\n"
    "Shortcuts are created in Start. Right-click to pin to the taskbar.\n"
    "Copy: Ctrl+Shift+C (Ctrl+C with selection). Paste: Ctrl+Shift+V.\n"
    "Font: Ctrl+= / Ctrl+- / Ctrl+0. Settings: Ctrl+, .\n";
}
int main(int argc,char **argv) {
    QStringList args;
    { QCoreApplication core(argc,argv); args=core.arguments().mid(1);
      if (args==QStringList{"--help"} || args==QStringList{"-h"}) { print(help); return 0; }
      if (args==QStringList{"install"}) { QString error; if (!installApp(Paths::system(),core.applicationDirPath(),&error)) return fail(error); print("Installed in "+Paths::system().installed+"\n"); return 0; }
      if (!args.isEmpty() && args.first()=="remove") { if (args.size()!=2) return fail("remove expects one app name or id."); QString error; if (!removeApp(Paths::system(),args[1],&error)) return fail(error); print("Removed app.\n"); return 0; }
    }
    // 옵션 검사와 설정 명령은 GUI 플랫폼 플러그인을 초기화하기 전에 한다.
    const bool generator=args.isEmpty() || args.first()=="gui", run=!generator && args.first()=="run", configMode=!generator && args.first()=="--app";
    MakeOptions options; QString id,action,error,language; bool direct=!generator && !run && !configMode && args.first()!="make";
    int index=generator ? (args.isEmpty() ? 0 : 1) : (run || args.first()=="make" ? 1 : 0);
    if (direct) { options.spec.command=args[0]; index=1; if (index<args.size() && !args[index].startsWith('-')) { options.spec.emoji=args[index++]; options.supplied.insert("emoji"); } }
    for (int i=index;i<args.size();++i) {
        const QString key=args[i];
        if (key=="--no-shortcut" && !run && !configMode) { options.shortcut=false; continue; }
        if (QStringList{"--config-path","--print-default-config","--init-config","--check-config"}.contains(key) && configMode && action.isEmpty()) { action=key; continue; }
        const QStringList accepted=generator ? QStringList{"--emoji","--language"} : configMode ? QStringList{"--app"} : run ? QStringList{"--app","--command","--arg"} : QStringList{"--command","--name","--arg","--emoji","--icon","--color","--terminal","--font","--font-size","--line-height","--id"};
        if (!accepted.contains(key)) return fail("unknown option: "+key+". Use --help.");
        if (++i>=args.size()) return fail("missing option value."); const QString value=args[i];
        if (key!="--arg" && options.supplied.contains(key)) return fail("option may only be specified once: "+key); options.supplied.insert(key);
        if (key=="--command") options.spec.command=value;
        else if (key=="--name") options.spec.name=value;
        else if (key=="--arg") options.spec.args<<value;
        else if (key=="--app") id=value;
        else if (key=="--id") options.spec.id=value;
        else if (key=="--emoji") { options.spec.emoji=value; options.supplied.insert("emoji"); }
        else if (key=="--language") { if (value!="ko" && value!="en") return fail("language must be ko or en."); language=value; }
        else if (key=="--icon") { options.spec.image=QFileInfo(value).absoluteFilePath(); options.supplied.insert("icon"); }
        else if (key=="--color") { options.spec.color=value; options.supplied.insert("color"); }
        else if (key=="--terminal") { options.spec.terminal=value; options.supplied.insert("terminal"); }
        else if (key=="--font") { options.spec.defaults.family=value; options.supplied.insert("font_family"); }
        else { bool ok; double number=value.toDouble(&ok); if (!ok) return fail("invalid number: "+value); const QString setting=key=="--font-size" ? "font_size" : "line_height"; setStyleValue(options.spec.defaults,setting,number); options.supplied.insert(setting); }
    }
    Paths paths=Paths::system(); AppSpec app;
    if (configMode || (run && !id.isEmpty())) {
        if (!loadApp(paths,id,app,&error)) return fail(error);
        if (run && (!options.spec.command.isEmpty() || !options.spec.args.isEmpty())) return fail("--app cannot be combined with --command or --arg.");
    } else if (!generator) {
        if (options.spec.command.isEmpty()) return fail("--command is required.");
        options.spec.command=resolveProgram(options.spec.command); if (options.spec.command.isEmpty()) return fail("executable not found.");
        if (run) { app=options.spec; app.name=QFileInfo(app.command).completeBaseName(); app.id=Paths::idFor(app.command+app.args.join('\n')); }
    }
    if (configMode) {
        QCoreApplication core(argc,argv); Config config(paths.app(id)+"/config.toml",app.defaults);
        if (action=="--config-path") print(config.path+"\n");
        else if (action=="--print-default-config") print(configTemplate(app.defaults));
        else if (action=="--init-config") { if (!config.ensure(&error)) return fail(error); print(config.path+"\n"); }
        else if (action=="--check-config") { if (!QFileInfo::exists(config.path)) return fail("config file does not exist."); QStringList errors; parseConfig(readText(config.path),app.defaults,&errors); if (!errors.isEmpty()) return fail(errors.join('\n')); print("Configuration is valid.\n"); }
        else return fail("choose a config command. Use --help."); return 0;
    }
    QApplication application(argc,argv); application.setApplicationName("TUIDock");
    QDir fonts(application.applicationDirPath()+"/fonts"); for (const auto &file : fonts.entryList({"*.ttf"},QDir::Files)) QFontDatabase::addApplicationFont(fonts.filePath(file));
    if (generator) { Generator window(paths,language); window.setEmoji(options.spec.emoji); window.show(); return application.exec(); }
    if (!run) { QString warning; if (!makeApp(paths,options,app,&error,&warning)) return fail(error); print("Created "+app.name+" ("+app.id+").\nRight-click its Start shortcut to pin to the taskbar.\n"); if (!warning.isEmpty()) print("Warning: "+warning+"\n"); return 0; }
    Launcher launcher(paths,app); int status=launcher.start(&error); if (status<0) return fail(error); if (status==1) return 0; return application.exec();
}
