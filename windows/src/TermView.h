#pragma once
#include <QElapsedTimer>
#include <QFont>
#include <QHash>
#include <QWidget>
#include "Config.h"
extern "C" {
#include <vterm.h>
}
class Pty;
class QPainter;

// Gifiles TerminalWidget에서 셸·탭·스크롤백을 뺀 단일 TUI 화면(GPLv3).
class TermView : public QWidget {
    Q_OBJECT
public:
    explicit TermView(QWidget *parent = nullptr);
    ~TermView() override;
    bool start(const QString &program, const QStringList &args = {}, const QString &cwd = {}, const QString &socketDir = {});
    bool isRunning() const;
    QString screenText() const;
    void feedOutput(const QByteArray &chunk);
    static bool drawBoxGlyph(QPainter &p, const QRectF &cell, char32_t ch, const QColor &color);
    static int incompleteUtf8Tail(const QByteArray &data);
    void applyStyle(const Style &style);
    QSize cells() const { return {m_cols, m_rows}; }
    QSize sizeForCells(QSize cells) const { return {cells.width() * m_cellW + 12, cells.height() * m_cellH + 12}; }
    static QColor adjustedColor(QColor fg, const QColor &bg, double contrast, bool dark, bool dim);
    bool isDark() const { return m_bg.lightness() < 128; }
signals:
    void closeRequested();
    void programFinished(quint32 code);
    void fontRequested(int delta);
    void settingsRequested();
    void themeReply(const QByteArray &bytes);
protected:
    bool event(QEvent *e) override;
    void paintEvent(QPaintEvent *e) override;
    void resizeEvent(QResizeEvent *e) override;
    void keyPressEvent(QKeyEvent *e) override;
    void inputMethodEvent(QInputMethodEvent *e) override;
    QVariant inputMethodQuery(Qt::InputMethodQuery q) const override;
    void mousePressEvent(QMouseEvent *e) override;
    void mouseMoveEvent(QMouseEvent *e) override;
    void mouseReleaseEvent(QMouseEvent *e) override;
    void mouseDoubleClickEvent(QMouseEvent *e) override;
    void wheelEvent(QWheelEvent *e) override;
    void focusInEvent(QFocusEvent *e) override;
    void focusOutEvent(QFocusEvent *e) override;
private:
    friend struct TerminalCallbacks;
    void applyTheme();
    void watchLightDark(const QByteArray &chunk);
    void replyTheme();
    void updateFont();
    void recomputeSize();
    void sendBytes(const QByteArray &bytes, bool userTyped);
    void sendText(const QString &text, bool userTyped);
    void sendKey(VTermKey key, VTermModifier mod);
    void paste(const QString &text);
    void onUserInput();
    bool handleShortcut(QKeyEvent *e, bool dryRun);
    void flushOutput();
    bool cellAt(int row, int col, VTermScreenCell *cell) const;
    QPoint cellFromPos(const QPoint &pos) const;
    const VTermLineInfo *lineInfo(int row) const;
    QString textBetween(QPoint a, QPoint b) const;
    QString selectedText() const;
    bool isSelected(int row, int col) const;
    int mouseMods(Qt::KeyboardModifiers m) const;
    void sendMouse(QPoint cell, int button, bool pressed, int mods);
    void commitPreedit();
    VTerm *m_vt = nullptr;
    VTermScreen *m_screen = nullptr;
    Pty *m_pty = nullptr;
    int m_rows = 24, m_cols = 80;
    QFont m_font, m_bold;
    int m_cellW = 8, m_cellH = 16, m_ascent = 12;
    qreal m_wheelAccum = 0;
    VTermPos m_cursor{0, 0}, m_markedAt{0, 0};
    bool m_cursorVisible = true;
    int m_cursorShape = VTERM_PROP_CURSORSHAPE_BLOCK;
    bool m_altScreen = false, m_exited = false;
    int m_mouseMode = VTERM_PROP_MOUSE_NONE;
    QString m_preedit, m_committedByClick;
    QElapsedTimer m_committedAt;
    QColor m_fg, m_bg;
    QHash<char32_t, qreal> m_wideScale;
    QPoint m_selStart{-1, -1}, m_selEnd{-1, -1};
    bool m_selecting = false, m_pendingPress = false;
    QPoint m_pressCell;
    int m_pressMods = 0, m_buttonToProgram = 0;
    QByteArray m_outBuf, m_utf8Carry;
    QByteArray m_csi;
    Style m_style;
    bool m_themeNotify = false, m_lastDark = false;
};
