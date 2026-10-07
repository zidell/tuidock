#include "Generator.h"
#include <QApplication>
#include <QColorDialog>
#include <QCheckBox>
#include <QProcess>
#include <QComboBox>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QFileDialog>
#include <QFileInfo>
#include <QGraphicsOpacityEffect>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QLocale>
#include <QMenu>
#include <QMessageBox>
#include <QMimeData>
#include <QPushButton>
#include <QSettings>
#include <QSignalBlocker>
#include <QTextBoundaryFinder>
#include <QTimer>
#include <QVBoxLayout>
#include <windows.h>

Generator::Generator(Paths destinations, const QString &language) : paths(std::move(destinations)) {
    korean=language.isEmpty() ? QLocale::system().language()==QLocale::Korean : language=="ko";
    setWindowTitle("TUIDock"); setWindowIcon(QPixmap::fromImage(fitWindowsIcon(QImage(":/AppIcon.png")))); setAcceptDrops(true); setFixedWidth(470);
    auto *layout=new QVBoxLayout(this); layout->setContentsMargins(16,24,16,24); layout->setSpacing(10);
    auto *mainRow=new QHBoxLayout; mainRow->setSpacing(16); layout->addLayout(mainRow);
    spec.name="T"; icon=new QPushButton(this); icon->setFixedSize(128,128); icon->setIconSize({128,128}); icon->setFlat(true); icon->setContextMenuPolicy(Qt::CustomContextMenu); icon->setToolTip(korean ? "눌러서 이모지 선택 · 오른쪽 클릭으로 이미지와 배경색" : "Click to choose an emoji; right-click for image and background color"); mainRow->addWidget(icon);
    // macOS와 같이 입력 칸은 아이콘 뒤에 둔다. 이모지 패널이 이 칸으로 입력한다.
    emoji=new QLineEdit(icon); emoji->setMaxLength(128); emoji->setFixedSize(1,1); emoji->move(64,64);
    auto *transparent=new QGraphicsOpacityEffect(emoji); transparent->setOpacity(0); emoji->setGraphicsEffect(transparent);
    connect(emoji,&QLineEdit::textEdited,this,[this](const QString &text) {
        // Windows 이모지 패널은 열린 채 여러 번 입력한다. 마지막 grapheme 하나로 교체한다.
        const QString selected=lastEmoji(text); if (selected!=text) { QSignalBlocker block(emoji); emoji->setText(selected); }
    });
    connect(icon,&QPushButton::clicked,this,[this] {
        emoji->setFocus(); emoji->selectAll(); INPUT input[4]{}; input[0].type=input[1].type=input[2].type=input[3].type=INPUT_KEYBOARD;
        input[0].ki.wVk=VK_LWIN; input[1].ki.wVk=VK_OEM_PERIOD; input[2].ki.wVk=VK_OEM_PERIOD; input[2].ki.dwFlags=KEYEVENTF_KEYUP; input[3].ki.wVk=VK_LWIN; input[3].ki.dwFlags=KEYEVENTF_KEYUP; SendInput(4,input,sizeof(INPUT));
    });
    connect(icon,&QPushButton::customContextMenuRequested,this,[this](QPoint pos) {
        QMenu menu; auto *color=menu.addAction(korean ? "배경색…" : "Background color…"); auto *image=menu.addAction(korean ? "이미지…" : "Image…"); auto *action=menu.exec(icon->mapToGlobal(pos));
        if (action==color) { QColor c=QColorDialog::getColor(QColor(spec.color),this); if (c.isValid()) { spec.color=c.name(); spec.image.clear(); spec.emoji.clear(); emoji->clear(); refreshIcon(); } }
        if (action==image) { QString path=QFileDialog::getOpenFileName(this,{}, {},"Images (*.png *.jpg *.jpeg *.bmp *.ico)"); if (!path.isEmpty()) { spec.image=path; refreshIcon(); } }
    });
    drop=new QPushButton(korean ? "터미널 프로그램을 여기에\n끌어다 놓거나 눌러서 고르기" : "Drop a terminal program here\nor click to choose",this); drop->setObjectName("dropZone"); drop->setFixedHeight(128); drop->setSizePolicy(QSizePolicy::Expanding,QSizePolicy::Fixed); drop->setStyleSheet("QPushButton { border: 1.5px dashed palette(mid); border-radius: 10px; background: transparent; padding: 10px; } QPushButton:hover { background: palette(alternate-base); }"); mainRow->addWidget(drop,1);
    connect(drop,&QPushButton::clicked,this,[this] { QString file=QFileDialog::getOpenFileName(this,{}, {},"Programs (*.exe)"); if (!file.isEmpty()) setProgram(file); });
    auto *runRow=new QHBoxLayout; runRow->setSpacing(8); runRow->addStretch(); runRow->addWidget(new QLabel(korean ? "실행기" : "Run in",this));
    terminal=new QComboBox(this); terminal->addItem(korean ? "자체 터미널" : "Built-in terminal","builtin");
    QSettings prefs("TUIDock","Generator"); int initial=terminal->findData(prefs.value("terminal","builtin")); terminal->setCurrentIndex(initial<0 ? 0 : initial); runRow->addWidget(terminal); runRow->addStretch(); layout->addLayout(runRow);
    memory=new QLabel(this); memory->setAlignment(Qt::AlignCenter); QFont caption=memory->font(); caption.setPointSizeF(qMax(8.,caption.pointSizeF()-1)); memory->setFont(caption); layout->addWidget(memory);
    auto *actions=new QHBoxLayout; actions->addStretch();
    launch=new QCheckBox(korean ? "제작 후 실행" : "Run after creating",this); launch->setChecked(true); actions->addWidget(launch); actions->addSpacing(12);
    create=new QPushButton(korean ? "제작" : "Create",this); create->setObjectName("createButton"); create->setEnabled(false); create->setMinimumSize(80,30); actions->addWidget(create); actions->addStretch(); layout->addLayout(actions);
    status=new QLabel(this); status->setWordWrap(true); status->setTextInteractionFlags(Qt::TextSelectableByMouse); status->hide(); layout->addWidget(status);
    connect(create,&QPushButton::clicked,this,[this] {
        if (!make() || !launch->isChecked()) return;
        QString exe=paths.installed+"/tuidock.exe"; if (!QFileInfo::exists(exe)) exe=QCoreApplication::applicationFilePath();
        if (!QProcess::startDetached(exe,{"run","--app",spec.id})) { status->setText(korean ? "앱은 제작됐지만 실행하지 못했습니다. 시작 메뉴에서 열어 주세요." : "App created, but could not launch. Open it from Start."); status->show(); }
    });
    remake=new QTimer(this); remake->setSingleShot(true); remake->setInterval(800); connect(remake,&QTimer::timeout,this,[this] { make(); });
    connect(emoji,&QLineEdit::textChanged,this,[this] { spec.emoji=emoji->text(); spec.image.clear(); refreshIcon(); });
    connect(terminal,&QComboBox::currentIndexChanged,this,[this] { QSettings prefs("TUIDock","Generator"); prefs.setValue("terminal",terminal->currentData()); spec.terminal=terminal->currentData().toString(); memory->setText(korean ? "앱당 메모리: 실행 파일과 창 크기에 따라 달라집니다." : "Memory per app depends on the program and window size."); if (made) remake->start(); });
    spec.terminal=terminal->currentData().toString(); memory->setText(korean ? "자체 터미널: Edit 실행 시 약 64 MB (이 PC 실측)." : "Built-in terminal: about 64 MB running Edit (measured on this PC)."); refreshIcon();
    if (!QFileInfo::exists(paths.installed+"/tuidock.exe")) QTimer::singleShot(0,this,[this] {
        if (QMessageBox::question(this,"TUIDock",korean ? "TUIDock을 사용자 프로그램 폴더에 설치할까요? 바로가기는 설치본을 사용합니다." : "Install TUIDock in your user programs folder? Shortcuts will use the installed copy.") == QMessageBox::Yes) {
            QString error; if (!installApp(paths,QCoreApplication::applicationDirPath(),&error)) QMessageBox::warning(this,"TUIDock",error);
        }
    });
}
void Generator::refreshIcon() { icon->setIcon(QPixmap::fromImage(renderIcon(spec))); if (made) remake->start(); }
QString Generator::lastEmoji(const QString &text) {
    const QString trimmed=text.trimmed(); if (trimmed.isEmpty()) return {};
    QTextBoundaryFinder boundary(QTextBoundaryFinder::Grapheme,trimmed); boundary.toStart(); int start=0,position=0,next;
    while ((next=boundary.toNextBoundary())>=0) { start=position; position=next; }
    // 일부 Qt 버전은 지역 표시자 쌍을 나눈다. 국기는 두 표시자로 한 아이콘이다.
    const auto scalars=trimmed.toUcs4(); int regional=0;
    for (auto it=scalars.crbegin();it!=scalars.crend() && *it>=0x1f1e6 && *it<=0x1f1ff;++it) ++regional;
    if (regional>=2 && regional%2==0) return trimmed.right(4);
    return trimmed.mid(start);
}
void Generator::setEmoji(const QString &text) { emoji->setText(lastEmoji(text)); }
void Generator::setProgram(const QString &file) {
    remake->stop(); made=false; spec.command=file; spec.name=QFileInfo(file).completeBaseName(); if (!spec.name.isEmpty()) spec.name[0]=spec.name[0].toUpper(); spec.id.clear(); drop->setText(spec.name); create->setEnabled(true); status->clear(); status->hide(); refreshIcon(); adjustSize();
}
bool Generator::make() {
    if (spec.command.isEmpty()) return false; MakeOptions options; options.spec=spec; options.supplied={"emoji","icon","color","terminal"}; QString error,warning; AppSpec result;
    if (!makeApp(paths,options,result,&error,&warning)) { status->setText(error); status->show(); return false; }
    spec=result; made=true; drop->setText(spec.name); icon->setIcon(QPixmap::fromImage(renderIcon(spec))); remake->stop();
    status->setText((korean ? "시작 메뉴에 만들었습니다. 바로가기를 오른쪽 클릭해 작업 표시줄에 고정하세요." : "Created in Start. Right-click the shortcut to pin it to the taskbar.") + (warning.isEmpty() ? QString() : "\n"+warning));
    status->show(); adjustSize(); return true;
}
void Generator::dragEnterEvent(QDragEnterEvent *e) { if (e->mimeData()->hasUrls() && e->mimeData()->urls().size()==1 && e->mimeData()->urls()[0].isLocalFile()) e->acceptProposedAction(); }
void Generator::dropEvent(QDropEvent *e) {
    const QString file=e->mimeData()->urls().value(0).toLocalFile();
    if (QFileInfo(file).suffix().compare("exe",Qt::CaseInsensitive)==0) setProgram(file);
    else if (!QImage(file).isNull()) { spec.image=file; refreshIcon(); }
    e->acceptProposedAction();
}
