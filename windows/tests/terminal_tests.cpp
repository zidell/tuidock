#include "TermView.h"
#include "Pty.h"
#include <QApplication>
#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QInputMethodEvent>
#include <QMimeData>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QPainter>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

// 클립보드 시험 전후에는 사용자 데이터의 모든 MIME 형식을 그대로 돌려놓는다.
struct ClipboardGuard {
    QMimeData *saved = new QMimeData;
    ClipboardGuard() {
        const QMimeData *current = QGuiApplication::clipboard()->mimeData();
        if (current) for (const QString &format : current->formats()) saved->setData(format, current->data(format));
    }
    ~ClipboardGuard() { QGuiApplication::clipboard()->setMimeData(saved); }
};

class TerminalTests : public QObject {
    Q_OBJECT
    QString fixture() const { return QCoreApplication::applicationDirPath() + QStringLiteral("/terminal_fixture.exe"); }
private slots:
    void initTestCase() {
        const QDir fonts(QCoreApplication::applicationDirPath() + QStringLiteral("/fonts"));
        for (const QString &name : fonts.entryList({QStringLiteral("*.ttf")}, QDir::Files))
            QFontDatabase::addApplicationFont(fonts.filePath(name));
    }
    void splitUtf8() {
        const QByteArray bytes = QStringLiteral("\x1b[31m한글 ← 🗓️").toUtf8();
        for (int split = 0; split <= bytes.size(); ++split) {
            TermView term;
            term.feedOutput(bytes.left(split));
            term.feedOutput(bytes.mid(split));
            QVERIFY2(term.screenText().startsWith(QStringLiteral("한글 ← 🗓️")), qPrintable(term.screenText()));
            QVERIFY(!term.screenText().contains(QChar::ReplacementCharacter));
        }
    }
    void boxGlyphs() {
        for (char32_t ch : {U'│', U'─', U'█'}) {
            QImage img(8, 24, QImage::Format_ARGB32); img.fill(Qt::transparent);
            QPainter painter(&img);
            QVERIFY(TermView::drawBoxGlyph(painter, QRectF(0, 0, 8, 24), ch, Qt::black));
            if (ch == U'│') QVERIFY(qAlpha(img.pixel(4, 0)) && qAlpha(img.pixel(4, 23)));
            if (ch == U'─') QVERIFY(qAlpha(img.pixel(0, 12)) && qAlpha(img.pixel(7, 12)));
            if (ch == U'█') QVERIFY(qAlpha(img.pixel(0, 0)) && qAlpha(img.pixel(7, 23)));
        }
    }
    void argumentsAndEnvironment() {
        QTemporaryDir temp; QVERIFY(temp.isValid());
        const QStringList args{QString(), QStringLiteral("hello world"), QStringLiteral("a\"b"),
                               QStringLiteral("C:\\space dir\\"), QStringLiteral("before\\\"after"), QStringLiteral("한글"), QStringLiteral("a\tb")};
        Pty p; QByteArray received;
        connect(&p, &Pty::dataReceived, this, [&](const QByteArray &data) { received += data; });
        QSignalSpy done(&p, &Pty::finished);
        QVERIFY2(p.start(fixture(), QStringList{QStringLiteral("args")} + args, temp.path(), 500, 24,
                         {QStringLiteral("TERM=xterm-256color"), QStringLiteral("COLORTERM=truecolor"), QStringLiteral("TERM_PROGRAM=tuidock")}), qPrintable(p.errorString()));
        QTRY_COMPARE_WITH_TIMEOUT(done.size(), 1, 10000);
        QCOMPARE(done[0][0].toUInt(), 0u);
        QVERIFY2(received.contains("FINAL-MARKER"), received.constData());
        const int start = received.indexOf('{'), end = received.lastIndexOf('}');
        const QJsonObject result = QJsonDocument::fromJson(received.mid(start, end - start + 1)).object();
        QCOMPARE(result.value(QStringLiteral("args")).toArray(), QJsonArray::fromStringList(args));
        QCOMPARE(result.value(QStringLiteral("cwd")).toString(), QDir::cleanPath(temp.path()));
        QCOMPARE(result.value(QStringLiteral("term")).toString(), QStringLiteral("xterm-256color"));
        QCOMPARE(result.value(QStringLiteral("color")).toString(), QStringLiteral("truecolor"));
        QCOMPARE(result.value(QStringLiteral("program")).toString(), QStringLiteral("tuidock"));
    }
    void exitCodes_data() {
        QTest::addColumn<QStringList>("args"); QTest::addColumn<quint32>("code");
        QTest::newRow("normal") << QStringList{QStringLiteral("exit"), QStringLiteral("0")} << quint32(0);
        QTest::newRow("error") << QStringList{QStringLiteral("exit"), QStringLiteral("7")} << quint32(7);
        QTest::newRow("descendant") << QStringList{QStringLiteral("descendant")} << quint32(0);
    }
    void exitCodes() {
        QFETCH(QStringList, args); QFETCH(quint32, code);
        TermView term; term.resize(800, 300); term.show();
        QSignalSpy finished(&term, &TermView::programFinished), closed(&term, &TermView::closeRequested);
        QVERIFY(term.start(fixture(), args));
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 10000);
        QCOMPARE(finished[0][0].toUInt(), code);
        QVERIFY(term.screenText().contains(QStringLiteral("FINAL-MARKER")));
        if (code == 0) QCOMPARE(closed.size(), 1);
        else {
            QCOMPARE(closed.size(), 0);
            QVERIFY(term.screenText().contains(QStringLiteral("Process exited with code 7")));
            QTest::keyClick(&term, Qt::Key_Space);
            QCOMPARE(closed.size(), 1);
        }
    }
    void failedStart() {
        for (int i = 0; i < 3; ++i) {
            Pty p;
            QVERIFY(!p.start(QStringLiteral("C:/nonexistent/tuidock-missing.exe"), {}, {}, 80, 24));
            QVERIFY(!p.isRunning()); QVERIFY(!p.errorString().isEmpty());
        }
    }
    void closeDuringOutput() {
        for (int i = 0; i < 3; ++i) {
            auto p = std::make_unique<Pty>();
            QSignalSpy data(p.get(), &Pty::dataReceived);
            QVERIFY(p->start(fixture(), {QStringLiteral("flood")}, {}, 80, 24));
            QTRY_VERIFY_WITH_TIMEOUT(!data.isEmpty(), 5000);
            p->resize(120, 40);
            QElapsedTimer timer; timer.start();
            p.reset();
            QVERIFY(timer.elapsed() < 5000);
        }
    }
    void inputAndIme() {
        ClipboardGuard clipboard;
        TermView term; term.resize(800, 300); term.show();
        QVERIFY(term.start(fixture(), {QStringLiteral("input")}));
        QTRY_VERIFY_WITH_TIMEOUT(term.screenText().contains(QStringLiteral("READY")), 10000);
        term.setFocus();
        QTest::keyClick(&term, Qt::Key_C, Qt::ControlModifier);
        QTRY_VERIFY(term.screenText().contains(QStringLiteral("HEX:03")));
        QTest::keyClick(&term, Qt::Key_V, Qt::ControlModifier);
        QTRY_VERIFY(term.screenText().contains(QStringLiteral("HEX:16")));
        QInputMethodEvent commit; commit.setCommitString(QStringLiteral("가나다"));
        QApplication::sendEvent(&term, &commit);
        QTRY_VERIFY(term.screenText().contains(QString::fromLatin1(QStringLiteral("가나다").toUtf8().toHex())));
        QGuiApplication::clipboard()->setText(QStringLiteral("PASTE"));
        QTest::keyClick(&term, Qt::Key_V, Qt::ControlModifier | Qt::ShiftModifier);
        QTRY_VERIFY(term.screenText().contains(QStringLiteral("5041535445")));
        QTest::keyClick(&term, Qt::Key_Q);
        QTRY_VERIFY(!term.isRunning());
    }
    void selectionCopyAndMouse() {
        ClipboardGuard clipboard;
        TermView term; term.resize(800, 300); term.show(); term.setFocus();
        QVERIFY(term.start(fixture(), {QStringLiteral("input")}));
        QTRY_VERIFY_WITH_TIMEOUT(term.screenText().contains(QStringLiteral("READY")), 10000);
        term.feedOutput("\x1b[HSELECT\x1b[?1000h\x1b[?1006h");
        // 실제 데스크톱에 키/마우스를 게시하지 않고 이 위젯으로만 보낸다.
        const QPoint first(7, 7), last(75, 7);
        QTest::mousePress(&term, Qt::LeftButton, Qt::NoModifier, first);
        QTest::mouseRelease(&term, Qt::LeftButton, Qt::NoModifier, last);
        QGuiApplication::clipboard()->setText(QStringLiteral("old clipboard"));
        QTest::keyClick(&term, Qt::Key_C, Qt::ControlModifier);
        QVERIFY(QGuiApplication::clipboard()->text().startsWith(QStringLiteral("SELECT")));
        QVERIFY(!term.screenText().contains(QStringLiteral("HEX:")));
        QTest::mouseClick(&term, Qt::LeftButton, Qt::ShiftModifier, first);
        QTRY_VERIFY(term.screenText().contains(QStringLiteral("1b5b3c343b313b314d")));
        QTest::keyClick(&term, Qt::Key_Q);
        QTRY_VERIFY(!term.isRunning());
    }
    void vtProbe() {
        Pty p; QByteArray received;
        connect(&p, &Pty::dataReceived, this, [&](const QByteArray &data) { received += data; });
        QVERIFY(p.start(fixture(), {QStringLiteral("probe")}, {}, 120, 30));
        QTRY_VERIFY_WITH_TIMEOUT(received.contains("READY"), 10000);
        qInfo("ConPTY output: OSC10=%d OSC11=%d mode2031=%d query996=%d SGRmouse=%d",
              received.contains("\x1b]10;?"), received.contains("\x1b]11;?"), received.contains("\x1b[?2031h"),
              received.contains("\x1b[?996n"), received.contains("\x1b[?1006h"));
        p.write("\x1b[?997;1n");
        QTest::qWait(300);
        p.write("\x1b[<0;2;2M\x1b[<0;2;2m");
        QTest::qWait(300);
        p.write("q");
        QTRY_VERIFY_WITH_TIMEOUT(!p.isRunning(), 10000);
        qInfo().noquote() << "ConPTY input hex replies:" << received.mid(received.indexOf("READY"));
        QVERIFY(received.contains("HEX:"));
    }
    void editSmoke() {
        const QString edit = qEnvironmentVariable("SystemRoot") + QStringLiteral("/System32/edit.exe");
        if (!QFile::exists(edit)) QSKIP("Microsoft Edit is not installed on this Windows image");
        QTemporaryDir temp;
        QFile file(temp.filePath(QStringLiteral("한글.txt")));
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write(QStringLiteral("한글 입력과 화면 확인\nTUIDock Windows terminal\n").toUtf8()); file.close();
        TermView term; term.resize(1000, 650); term.show(); term.setFocus();
        QSignalSpy finished(&term, &TermView::programFinished);
        QVERIFY(term.start(edit, {file.fileName()}, temp.path()));
        QTRY_VERIFY_WITH_TIMEOUT(term.screenText().contains(QStringLiteral("TUIDock Windows terminal")), 10000);
        QVERIFY2(term.screenText().contains(QStringLiteral("한글 입력과 화면 확인")), qPrintable(term.screenText()));
        term.resize(1100, 700);
        QTRY_VERIFY(term.screenText().contains(QStringLiteral("TUIDock Windows terminal")));
        const QString capture = qEnvironmentVariable("TUIDOCK_TEST_CAPTURE");
        if (!capture.isEmpty()) { QTest::qWait(200); QVERIFY(term.grab().save(capture)); }
        QTest::keyClick(&term, Qt::Key_Q, Qt::ControlModifier);
        QTRY_COMPARE_WITH_TIMEOUT(finished.size(), 1, 10000);
        QCOMPARE(finished[0][0].toUInt(), 0u);
    }
    void cliHelpAndErrors() {
        QProcess proc;
        auto env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("no-such-plugin"));
        proc.setProcessEnvironment(env);
        const QString exe = QCoreApplication::applicationDirPath() + QStringLiteral("/tuidock.exe");
        proc.start(exe, {QStringLiteral("--help")}); QVERIFY(proc.waitForFinished());
        QCOMPARE(proc.exitCode(), 0); QVERIFY(proc.readAllStandardOutput().contains("run --command"));
        proc.start(exe, {QStringLiteral("run"), QStringLiteral("--arg")}); QVERIFY(proc.waitForFinished());
        QCOMPARE(proc.exitCode(), 2); QVERIFY(proc.readAllStandardOutput().contains("missing option value"));
    }
};
QTEST_MAIN(TerminalTests)
#include "terminal_tests.moc"
