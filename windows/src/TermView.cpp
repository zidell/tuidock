// Gifiles TerminalWidget에서 그리기·입력 경로를 가져왔다(GPLv3).
#include "TermView.h"
#include "Pty.h"

#include <QApplication>
#include <QClipboard>
#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <QInputMethod>
#include <QInputMethodEvent>
#include <QMenu>
#include <QPainter>
#include <QPainterPath>
#include <QStyleHints>
#include <QtMath>
#include <algorithm>
#include <cmath>


namespace {
constexpr int kPad = 6;

constexpr Qt::KeyboardModifier kCtrl = Qt::ControlModifier;
constexpr uint32_t kWideContinuation = 0xFFFFFFFFu;

bool isContinuation(const VTermScreenCell &cell)
{
    return cell.width == 0 || cell.chars[0] == kWideContinuation;
}
QString cellText(const VTermScreenCell &cell)
{
    QString s;
    for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i] && cell.chars[i] != kWideContinuation; ++i)
        s += QString::fromUcs4(reinterpret_cast<const char32_t *>(&cell.chars[i]), 1);
    return s.normalized(QString::NormalizationForm_C);
}
constexpr uint8_t arms(int up, int right, int down, int left) { return uint8_t(up | right << 2 | down << 4 | left << 6); }
constexpr uint8_t kLines[] = {
    arms(0, 1, 0, 1), arms(0, 2, 0, 2), arms(1, 0, 1, 0), arms(2, 0, 2, 0), 0, 0, 0, 0, 0, 0, 0, 0, // ─━│┃ 및 점선
    arms(0, 1, 1, 0), arms(0, 2, 1, 0), arms(0, 1, 2, 0), arms(0, 2, 2, 0), // ┌┍┎┏
    arms(0, 0, 1, 1), arms(0, 0, 1, 2), arms(0, 0, 2, 1), arms(0, 0, 2, 2), // ┐┑┒┓
    arms(1, 1, 0, 0), arms(1, 2, 0, 0), arms(2, 1, 0, 0), arms(2, 2, 0, 0), // └┕┖┗
    arms(1, 0, 0, 1), arms(1, 0, 0, 2), arms(2, 0, 0, 1), arms(2, 0, 0, 2), // ┘┙┚┛
    arms(1, 1, 1, 0), arms(1, 2, 1, 0), arms(2, 1, 1, 0), arms(1, 1, 2, 0), // ├┝┞┟
    arms(2, 1, 2, 0), arms(2, 2, 1, 0), arms(1, 2, 2, 0), arms(2, 2, 2, 0), // ┠┡┢┣
    arms(1, 0, 1, 1), arms(1, 0, 1, 2), arms(2, 0, 1, 1), arms(1, 0, 2, 1), // ┤┥┦┧
    arms(2, 0, 2, 1), arms(2, 0, 1, 2), arms(1, 0, 2, 2), arms(2, 0, 2, 2), // ┨┩┪┫
    arms(0, 1, 1, 1), arms(0, 1, 1, 2), arms(0, 2, 1, 1), arms(0, 2, 1, 2), // ┬┭┮┯
    arms(0, 1, 2, 1), arms(0, 1, 2, 2), arms(0, 2, 2, 1), arms(0, 2, 2, 2), // ┰┱┲┳
    arms(1, 1, 0, 1), arms(1, 1, 0, 2), arms(1, 2, 0, 1), arms(1, 2, 0, 2), // ┴┵┶┷
    arms(2, 1, 0, 1), arms(2, 1, 0, 2), arms(2, 2, 0, 1), arms(2, 2, 0, 2), // ┸┹┺┻
    arms(1, 1, 1, 1), arms(1, 1, 1, 2), arms(1, 2, 1, 1), arms(1, 2, 1, 2), // ┼┽┾┿
    arms(2, 1, 1, 1), arms(1, 1, 2, 1), arms(2, 1, 2, 1), arms(2, 1, 1, 2), // ╀╁╂╃
    arms(2, 2, 1, 1), arms(1, 1, 2, 2), arms(1, 2, 2, 1), arms(2, 2, 1, 2), // ╄╅╆╇
    arms(1, 2, 2, 2), arms(2, 1, 2, 2), arms(2, 2, 2, 1), arms(2, 2, 2, 2), // ╈╉╊╋
};
constexpr uint8_t kHalfLines[] = {
    arms(0, 0, 0, 1), arms(1, 0, 0, 0), arms(0, 1, 0, 0), arms(0, 0, 1, 0), // ╴╵╶╷
    arms(0, 0, 0, 2), arms(2, 0, 0, 0), arms(0, 2, 0, 0), arms(0, 0, 2, 0), // ╸╹╺╻
    arms(0, 2, 0, 1), arms(1, 0, 2, 0), arms(0, 1, 0, 2), arms(2, 0, 1, 0), // ╼╽╾╿
};
constexpr uint8_t kQuadrants[] = {4, 8, 1, 1 | 4 | 8, 1 | 8, 1 | 2 | 4, 1 | 2 | 8, 2, 2 | 4, 2 | 4 | 8};

} // namespace

int TermView::incompleteUtf8Tail(const QByteArray &data)
{
    const int n = int(data.size());
    int i = n - 1;
    while (i >= 0 && i >= n - 4 && (uchar(data[i]) & 0xC0) == 0x80) // 이어지는 바이트를 건너 첫 바이트까지
        --i;
    if (i < 0 || i < n - 4)
        return 0;
    const uchar lead = uchar(data[i]);
    const int need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
    return n - i < need ? n - i : 0;
}

bool TermView::drawBoxGlyph(QPainter &p, const QRectF &cell, char32_t ch, const QColor &color)
{
    const qreal x = cell.x(), y = cell.y(), w = cell.width(), h = cell.height();
    const qreal light = qMax<qreal>(1, std::round(w / 8)), heavy = 2 * light;
    const qreal cx = x + std::floor(w / 2), cy = y + std::floor(h / 2);
    uint8_t a = 0;
    if (ch >= 0x2500 && ch <= 0x254B)
        a = kLines[ch - 0x2500];
    else if (ch >= 0x2574 && ch <= 0x257F)
        a = kHalfLines[ch - 0x2574];
    if (a) {
        auto thick = [&](int shift) { const int k = (a >> shift) & 3; return k == 0 ? 0.0 : k == 1 ? light : heavy; };
        const qreal up = thick(0), right = thick(2), down = thick(4), left = thick(6);
        const qreal hMax = qMax(left, right), vMax = qMax(up, down);
        if (up)
            p.fillRect(QRectF(cx - up / 2, y, up, cy - y + qMax(hMax, up) / 2), color);
        if (down)
            p.fillRect(QRectF(cx - down / 2, cy - qMax(hMax, down) / 2, down, y + h - cy + qMax(hMax, down) / 2), color);
        if (left)
            p.fillRect(QRectF(x, cy - left / 2, cx - x + qMax(vMax, left) / 2, left), color);
        if (right)
            p.fillRect(QRectF(cx - qMax(vMax, right) / 2, cy - right / 2, x + w - cx + qMax(vMax, right) / 2, right), color);
        return true;
    }
    if (ch >= 0x256D && ch <= 0x2570) { // ╭╮╯╰
        const bool goesDown = ch == 0x256D || ch == 0x256E, goesRight = ch == 0x256D || ch == 0x2570;
        const qreal r = qMin(w, h) / 2;
        const qreal vy = goesDown ? y + h : y, hx = goesRight ? x + w : x;
        const qreal ry = goesDown ? cy + r : cy - r, rx = goesRight ? cx + r : cx - r;
        QPainterPath path(QPointF(cx, vy));
        path.lineTo(cx, ry);
        path.quadTo(cx, cy, rx, cy);
        path.lineTo(hx, cy);
        p.save();
        p.setRenderHint(QPainter::Antialiasing);
        p.setBrush(Qt::NoBrush);
        p.setPen(QPen(color, light, Qt::SolidLine, Qt::FlatCap));
        p.drawPath(path); // 직선과 같은 cx/cy 중심을 쓴다.
        p.restore();
        return true;
    }
    if (ch >= 0x2580 && ch <= 0x259F) {
        auto eighths = [&](int n) { return std::round(h * n / 8); };
        auto columns = [&](int n) { return std::round(w * n / 8); };
        if (ch == 0x2580) // ▀
            p.fillRect(QRectF(x, y, w, eighths(4)), color);
        else if (ch <= 0x2588) // ▁…█
            p.fillRect(QRectF(x, y + h - eighths(int(ch - 0x2580)), w, eighths(int(ch - 0x2580))), color);
        else if (ch <= 0x258F) // ▉…▏
            p.fillRect(QRectF(x, y, columns(int(0x2590 - ch)), h), color);
        else if (ch == 0x2590) // ▐
            p.fillRect(QRectF(x + columns(4), y, w - columns(4), h), color);
        else if (ch <= 0x2593) { // ░▒▓
            QColor c = color;
            c.setAlphaF(color.alphaF() * (ch - 0x2590) / 4.0);
            p.fillRect(cell, c);
        } else if (ch == 0x2594) // ▔
            p.fillRect(QRectF(x, y, w, eighths(1)), color);
        else if (ch == 0x2595) // ▕
            p.fillRect(QRectF(x + w - columns(1), y, columns(1), h), color);
        else {
            const uint8_t q = kQuadrants[ch - 0x2596];
            const qreal mx = columns(4), my = eighths(4);
            if (q & 1)
                p.fillRect(QRectF(x, y, mx, my), color);
            if (q & 2)
                p.fillRect(QRectF(x + mx, y, w - mx, my), color);
            if (q & 4)
                p.fillRect(QRectF(x, y + my, mx, h - my), color);
            if (q & 8)
                p.fillRect(QRectF(x + mx, y + my, w - mx, h - my), color);
        }
        return true;
    }
    return false;
}
struct TerminalCallbacks {
    static TermView *w(void *u) { return static_cast<TermView *>(u); }

    static int damage(VTermRect, void *u)
    {
        w(u)->update();
        return 1;
    }
    static int moverect(VTermRect, VTermRect, void *u)
    {
        w(u)->update();
        return 1;
    }
    static int movecursor(VTermPos pos, VTermPos, int visible, void *u)
    {
        w(u)->m_cursor = pos;
        w(u)->m_cursorVisible = visible;
        if (visible)
            w(u)->m_markedAt = pos;
        w(u)->update();
        return 1;
    }
    static int settermprop(VTermProp prop, VTermValue *val, void *u)
    {
        TermView *t = w(u);
        switch (prop) {
        case VTERM_PROP_CURSORVISIBLE:
            t->m_cursorVisible = val->boolean;
            if (t->m_cursorVisible)
                t->m_markedAt = t->m_cursor;
            break;
        case VTERM_PROP_CURSORSHAPE: t->m_cursorShape = val->number; break;
        case VTERM_PROP_ALTSCREEN: t->m_altScreen = val->boolean; break;
        case VTERM_PROP_MOUSE: t->m_mouseMode = val->number; break;
        default: break;
        }
        t->update();
        return 1;
    }
    static int bell(void *)
    {
        return 1;
    }
    static int pushline(int, const VTermScreenCell *, void *) { return 1; }
    static int popline(int, VTermScreenCell *, void *) { return 0; }
    static int sbclear(void *) { return 1; }
    static int osc(int command, VTermStringFragment frag, void *u)
    {
        if ((command == 10 || command == 11) && frag.initial && frag.final && frag.len == 1 && frag.str[0] == '?') {
            const QColor c = command == 10 ? w(u)->m_fg : w(u)->m_bg;
            w(u)->m_outBuf += QStringLiteral("\x1b]%1;rgb:%2/%3/%4\x1b\\")
                                  .arg(command)
                                  .arg(c.red() * 257, 4, 16, QLatin1Char('0'))
                                  .arg(c.green() * 257, 4, 16, QLatin1Char('0'))
                                  .arg(c.blue() * 257, 4, 16, QLatin1Char('0'))
                                  .toLatin1();
            return 1;
        }
        return 0;
    }
    static void output(const char *s, size_t len, void *u) { w(u)->m_outBuf.append(s, qsizetype(len)); }
};

TermView::TermView(QWidget *parent) : QWidget(parent)
{
    setFocusPolicy(Qt::StrongFocus);
    setAttribute(Qt::WA_InputMethodEnabled);
    setAttribute(Qt::WA_OpaquePaintEvent);
    setCursor(Qt::IBeamCursor);
    setMinimumHeight(60);

    m_vt = vterm_new(m_rows, m_cols);
    vterm_set_utf8(m_vt, 1);
    vterm_output_set_callback(m_vt, &TerminalCallbacks::output, this);
    m_screen = vterm_obtain_screen(m_vt);
    static const VTermScreenCallbacks cbs = {
        &TerminalCallbacks::damage, &TerminalCallbacks::moverect, &TerminalCallbacks::movecursor,
        &TerminalCallbacks::settermprop, &TerminalCallbacks::bell, nullptr,
        &TerminalCallbacks::pushline, &TerminalCallbacks::popline, &TerminalCallbacks::sbclear,
    };
    vterm_screen_set_callbacks(m_screen, &cbs, this);
    static const VTermStateFallbacks fallbacks = {nullptr, nullptr, &TerminalCallbacks::osc, nullptr, nullptr, nullptr, nullptr};
    vterm_screen_set_unrecognised_fallbacks(m_screen, &fallbacks, this);
    vterm_screen_enable_altscreen(m_screen, 1);
    vterm_screen_enable_reflow(m_screen, true);
    vterm_screen_set_damage_merge(m_screen, VTERM_DAMAGE_SCROLL);
    vterm_screen_reset(m_screen, 1);

    updateFont();
    applyTheme();
    connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, [this] { applyTheme(); });
}

TermView::~TermView()
{
    delete m_pty; // libvterm을 해제하기 전에 프로그램과 출력 스레드를 끝낸다.
    m_pty = nullptr;
    vterm_free(m_vt);
}

void TermView::applyTheme()
{
    const bool dark = m_style.theme == "dark" || (m_style.theme == "auto" && QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark);
    m_fg = dark ? QColor(229, 229, 229) : QColor(0, 0, 0);
    m_bg = dark ? QColor(0, 0, 0) : QColor(255, 255, 255);
    VTermColor fg, bg;
    vterm_color_rgb(&fg, m_fg.red(), m_fg.green(), m_fg.blue());
    vterm_color_rgb(&bg, m_bg.red(), m_bg.green(), m_bg.blue());
    vterm_screen_set_default_colors(m_screen, &fg, &bg);
    const char *colors[16] = {"#000000", "#990000", "#00a600", "#999900", "#0000b2", "#b200b2", "#00a6b2", "#bfbfbf",
                               "#666666", "#e50000", "#00d900", "#e5e500", "#0000ff", "#e500e5", "#00e5e5", "#e5e5e5"};
    VTermState *state = vterm_obtain_state(m_vt);
    vterm_state_set_bold_highbright(state, 1);
    for (int i = 0; i < 16; ++i) {
        const QColor q(QString::fromLatin1(colors[i]));
        VTermColor col;
        vterm_color_rgb(&col, q.red(), q.green(), q.blue());
        vterm_state_set_palette_color(state, i, &col);
    }
    if (m_themeNotify && dark != m_lastDark) replyTheme();
    update();
}

void TermView::applyStyle(const Style &style) { m_style = style; updateFont(); applyTheme(); }
QColor TermView::adjustedColor(QColor fg, const QColor &bg, double contrast, bool dark, bool dim) {
    auto blend = [](QColor a, QColor b, double f) { return QColor(qRound(a.red() * (1-f) + b.red()*f), qRound(a.green()*(1-f) + b.green()*f), qRound(a.blue()*(1-f) + b.blue()*f)); };
    if (dim) fg = blend(fg, bg, .5);
    if (contrast > 0) return blend(fg, dark ? QColor(Qt::white) : QColor(Qt::black), contrast / 100);
    if (contrast < 0) return blend(fg, bg, -contrast / 100 * .8);
    return fg;
}
void TermView::replyTheme() {
    m_lastDark = isDark(); const QByteArray reply = m_lastDark ? "\x1b[?997;1n" : "\x1b[?997;2n";
    emit themeReply(reply); sendBytes(reply, false);
}
void TermView::watchLightDark(const QByteArray &chunk) {
    for (char byte : chunk) {
        if (byte == '\x1b') { m_csi = QByteArray(1, byte); continue; }
        if (m_csi.isEmpty()) continue;
        m_csi += byte;
        if (m_csi.size() == 2) { if (byte != '[') m_csi.clear(); continue; }
        if (byte >= '@' && byte <= '~') {
            if (m_csi == "\x1b[?2031h") { m_themeNotify = true; m_lastDark = isDark(); }
            else if (m_csi == "\x1b[?2031l") m_themeNotify = false;
            else if (m_csi == "\x1b[?996n") replyTheme();
            m_csi.clear();
        } else if (m_csi.size() > 32) m_csi.clear();
    }
}

void TermView::updateFont()
{
    m_font = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    const QString family = m_style.family.isEmpty() ? QStringLiteral("D2Coding") : m_style.family;
    if (QFontDatabase::families().contains(family)) m_font.setFamily(family);
    m_font.setPointSizeF(m_style.size);
    m_font.setStyleHint(QFont::Monospace);
    m_bold = m_font;
    m_bold.setBold(true);
    const QFontMetricsF fm(m_font);
    m_cellW = qCeil(fm.horizontalAdvance(QLatin1Char('M')));
    m_cellH = qRound(fm.height() * m_style.lineHeight);
    m_ascent = qRound(fm.ascent() + (m_cellH - fm.height()) / 2);
    m_wideScale.clear();
    recomputeSize();
    update();
}

void TermView::recomputeSize()
{
    const int cols = qMax(10, (width() - 2 * kPad) / m_cellW);
    const int rows = qMax(2, (height() - 2 * kPad) / m_cellH);
    if (cols == m_cols && rows == m_rows)
        return;
    m_cols = cols;
    m_rows = rows;
    vterm_set_size(m_vt, rows, cols);
    vterm_screen_flush_damage(m_screen);
    if (m_pty)
        m_pty->resize(cols, rows);
}

void TermView::resizeEvent(QResizeEvent *)
{
    recomputeSize();
}

bool TermView::start(const QString &program, const QStringList &args, const QString &cwd, const QString &socketDir)
{
    if (m_pty) return false;
    m_pty = new Pty(this);
    connect(m_pty, &Pty::dataReceived, this, &TermView::feedOutput);
    connect(m_pty, &Pty::finished, this, [this](quint32 code) {
        m_exited = true;
        if (!m_utf8Carry.isEmpty()) { m_utf8Carry.clear(); feedOutput(QByteArray("\xef\xbf\xbd")); }
        if (code == 0) emit closeRequested();
        else {
            const QByteArray msg = QStringLiteral("\r\n\x1b[0m\x1b[?25l[Process exited with code %1. Press any key to close.]\r\n").arg(code).toUtf8();
            feedOutput(msg);
        }
        emit programFinished(code);
    });
    QStringList env{QStringLiteral("TERM=xterm-256color"), QStringLiteral("COLORTERM=truecolor"), QStringLiteral("TERM_PROGRAM=tuidock")};
    if (!socketDir.isEmpty()) env << "TUIDOCK=" + socketDir;
    if (m_pty->start(program, args, cwd, m_cols, m_rows, env)) return true;
    m_exited = true;
    feedOutput((QStringLiteral("Could not start %1: %2\r\nPress any key to close.").arg(program, m_pty->errorString())).toUtf8());
    return false;
}

void TermView::feedOutput(const QByteArray &chunk)
{
    watchLightDark(chunk);
    const QByteArray data = m_utf8Carry + chunk;
    const int keep = incompleteUtf8Tail(data);
    m_utf8Carry = data.right(keep);
    vterm_input_write(m_vt, data.constData(), size_t(data.size() - keep));
    vterm_screen_flush_damage(m_screen);
    flushOutput();
}

bool TermView::isRunning() const { return m_pty && m_pty->isRunning(); }

void TermView::flushOutput()
{
    if (m_outBuf.isEmpty() || !m_pty)
        return;
    m_pty->write(m_outBuf);
    m_outBuf.clear();
}

void TermView::onUserInput()
{
    m_selStart = m_selEnd = QPoint(-1, -1);
}

void TermView::sendBytes(const QByteArray &bytes, bool userTyped)
{
    if (userTyped)
        onUserInput();
    if (m_pty)
        m_pty->write(bytes);
}

void TermView::sendText(const QString &text, bool userTyped)
{
    if (userTyped) {
        onUserInput();
    }
    for (char32_t c : text.toUcs4())
        vterm_keyboard_unichar(m_vt, c, VTERM_MOD_NONE);
    flushOutput();
}

void TermView::sendKey(VTermKey key, VTermModifier mod)
{
    vterm_keyboard_key(m_vt, key, mod);
    flushOutput();
}

void TermView::paste(const QString &text)
{
    if (text.isEmpty())
        return;
    onUserInput();
    vterm_keyboard_start_paste(m_vt);
    for (char32_t c : text.toUcs4())
        vterm_keyboard_unichar(m_vt, c == '\n' ? '\r' : c, VTERM_MOD_NONE);
    vterm_keyboard_end_paste(m_vt);
    flushOutput();
}

bool TermView::handleShortcut(QKeyEvent *e, bool dryRun)
{
    const auto mods = e->modifiers() & ~Qt::KeypadModifier;
    const bool copy = e->key() == Qt::Key_C &&
        (mods == (Qt::ControlModifier | Qt::ShiftModifier) || (mods == Qt::ControlModifier && !selectedText().isEmpty()));
    const bool doPaste = e->key() == Qt::Key_V && mods == (Qt::ControlModifier | Qt::ShiftModifier);
    if (mods == Qt::ControlModifier && (e->key() == Qt::Key_Equal || e->key() == Qt::Key_Minus || e->key() == Qt::Key_0 || e->key() == Qt::Key_Comma)) {
        if (!dryRun) { if (e->key() == Qt::Key_Comma) emit settingsRequested(); else emit fontRequested(e->key() == Qt::Key_0 ? 0 : e->key() == Qt::Key_Minus ? -1 : 1); } return true;
    }
    if (mods == (Qt::ControlModifier | Qt::ShiftModifier) && e->key() == Qt::Key_Plus) { if (!dryRun) emit fontRequested(1); return true; }
    if (!copy && !doPaste) return false;
    if (!dryRun) {
        if (copy) {
            if (!selectedText().isEmpty()) QGuiApplication::clipboard()->setText(selectedText());
            onUserInput();
            update();
        } else paste(QGuiApplication::clipboard()->text());
    }
    return true;
}

bool TermView::event(QEvent *e)
{
    if (e->type() == QEvent::ShortcutOverride) {
        const auto *key = static_cast<QKeyEvent *>(e);
        if (key->key() != Qt::Key_F4 || !(key->modifiers() & Qt::AltModifier)) { e->accept(); return true; }
    }
    if (e->type() == QEvent::PaletteChange) applyTheme();
    if (e->type() == QEvent::KeyPress) {
        auto *key = static_cast<QKeyEvent *>(e);
        if (key->key() == Qt::Key_Tab || key->key() == Qt::Key_Backtab) { keyPressEvent(key); return true; }
    }
    return QWidget::event(e);
}

void TermView::keyPressEvent(QKeyEvent *e)
{
    if (handleShortcut(e, false))
        return;
    if (m_exited) { emit closeRequested(); return; }
    if (!isRunning()) return;
    const Qt::KeyboardModifiers m = e->modifiers() & ~Qt::KeypadModifier;
    int vm = VTERM_MOD_NONE;
    if (m & Qt::ShiftModifier)
        vm |= VTERM_MOD_SHIFT;
    if (m & kCtrl)
        vm |= VTERM_MOD_CTRL;
    if (m & Qt::AltModifier)
        vm |= VTERM_MOD_ALT;
    const auto mod = VTermModifier(vm);

    VTermKey key = VTERM_KEY_NONE;
    switch (e->key()) {
    case Qt::Key_Return:
    case Qt::Key_Enter: key = VTERM_KEY_ENTER; break;
    case Qt::Key_Tab: key = VTERM_KEY_TAB; break;
    case Qt::Key_Backtab: key = VTERM_KEY_TAB; break;
    case Qt::Key_Backspace: key = VTERM_KEY_BACKSPACE; break;
    case Qt::Key_Escape: key = VTERM_KEY_ESCAPE; break;
    case Qt::Key_Up: key = VTERM_KEY_UP; break;
    case Qt::Key_Down: key = VTERM_KEY_DOWN; break;
    case Qt::Key_Left: key = VTERM_KEY_LEFT; break;
    case Qt::Key_Right: key = VTERM_KEY_RIGHT; break;
    case Qt::Key_Insert: key = VTERM_KEY_INS; break;
    case Qt::Key_Delete: key = VTERM_KEY_DEL; break;
    case Qt::Key_Home: key = VTERM_KEY_HOME; break;
    case Qt::Key_End: key = VTERM_KEY_END; break;
    case Qt::Key_PageUp: key = VTERM_KEY_PAGEUP; break;
    case Qt::Key_PageDown: key = VTERM_KEY_PAGEDOWN; break;
    default:
        if (e->key() >= Qt::Key_F1 && e->key() <= Qt::Key_F12)
            key = VTermKey(VTERM_KEY_FUNCTION(e->key() - Qt::Key_F1 + 1));
    }
    if (key != VTERM_KEY_NONE) {
        onUserInput();
        sendKey(e->key() == Qt::Key_Backtab ? VTERM_KEY_TAB : key,
                e->key() == Qt::Key_Backtab ? VTermModifier(mod | VTERM_MOD_SHIFT) : mod);
        return;
    }
    if (m & kCtrl) {
        const int k = e->key();
        char32_t c = 0;
        if (k >= Qt::Key_A && k <= Qt::Key_Z)
            c = char32_t('a' + (k - Qt::Key_A));
        else if (k == Qt::Key_Space || k == Qt::Key_At)
            c = ' ';
        else if (k == Qt::Key_BracketLeft || k == Qt::Key_Backslash || k == Qt::Key_BracketRight || k == Qt::Key_Underscore)
            c = char32_t(k);
        if (c) {
            onUserInput();
            vterm_keyboard_unichar(m_vt, c, VTermModifier(vm & ~VTERM_MOD_SHIFT));
            flushOutput();
            return;
        }
    }
    if (!e->text().isEmpty())
        sendText(e->text(), true);
}

void TermView::inputMethodEvent(QInputMethodEvent *e)
{
    const bool clickCommitted = e->commitString() == m_committedByClick && m_committedAt.isValid() && m_committedAt.elapsed() < 1000;
    if (!e->commitString().isEmpty() && !clickCommitted)
        sendText(e->commitString(), true);
    m_preedit = e->preeditString();
    update();
    e->accept();
}

QVariant TermView::inputMethodQuery(Qt::InputMethodQuery q) const
{
    switch (q) {
    case Qt::ImEnabled: return true;
    case Qt::ImFont: return m_font;
    case Qt::ImCursorRectangle:
        return QRect(kPad + m_markedAt.col * m_cellW, kPad + m_markedAt.row * m_cellH, m_cellW, m_cellH);
    default: return QWidget::inputMethodQuery(q);
    }
}

void TermView::focusInEvent(QFocusEvent *e)
{
    QWidget::focusInEvent(e);
    update();
}

void TermView::focusOutEvent(QFocusEvent *e)
{
    QWidget::focusOutEvent(e);
    update();
}

bool TermView::cellAt(int line, int col, VTermScreenCell *cell) const
{
    if (line < 0 || line >= m_rows || col < 0 || col >= m_cols) return false;
    return vterm_screen_get_cell(m_screen, VTermPos{line, col}, cell);
}

QPoint TermView::cellFromPos(const QPoint &pos) const
{
    const int row = qBound(0, (pos.y() - kPad) / m_cellH, m_rows - 1);
    const int line = row;
    int col = (pos.x() - kPad) / m_cellW;
    if (const VTermLineInfo *info = lineInfo(line); info && info->doublewidth)
        col /= 2; // 두 배 폭으로 그린 줄
    return QPoint(qBound(0, col, m_cols - 1), line);
}

const VTermLineInfo *TermView::lineInfo(int line) const
{
    const int row = line;
    return row >= 0 && row < m_rows ? vterm_state_get_lineinfo(vterm_obtain_state(m_vt), row) : nullptr;
}

QString TermView::textBetween(QPoint a, QPoint b) const
{
    if (b.y() < a.y() || (b.y() == a.y() && b.x() < a.x()))
        std::swap(a, b);
    QStringList lines;
    for (int line = a.y(); line <= b.y(); ++line) {
        QString s;
        const int from = line == a.y() ? a.x() : 0;
        const int to = line == b.y() ? b.x() : m_cols - 1;
        VTermScreenCell cell;
        for (int col = from; col <= to; ++col) {
            if (!cellAt(line, col, &cell))
                break;
            if (isContinuation(cell))
                continue;
            s += cell.chars[0] == 0 ? QStringLiteral(" ") : cellText(cell);
        }
        while (s.endsWith(QLatin1Char(' ')))
            s.chop(1);
        lines << s;
    }
    return lines.join(QLatin1Char('\n'));
}

QString TermView::selectedText() const
{
    if (m_selStart.y() < 0 || m_selStart == m_selEnd)
        return {};
    return textBetween(m_selStart, m_selEnd);
}

bool TermView::isSelected(int line, int col) const
{
    if (m_selStart.y() < 0 || m_selStart == m_selEnd)
        return false;
    QPoint a = m_selStart, b = m_selEnd;
    if (b.y() < a.y() || (b.y() == a.y() && b.x() < a.x()))
        std::swap(a, b);
    if (line < a.y() || line > b.y())
        return false;
    if (line == a.y() && col < a.x())
        return false;
    if (line == b.y() && col > b.x())
        return false;
    return true;
}

QString TermView::screenText() const
{
    return textBetween(QPoint(0, 0), QPoint(m_cols - 1, m_rows - 1));
}

void TermView::paintEvent(QPaintEvent *)
{
    QPainter p(this);
    p.fillRect(rect(), m_bg);
    const QColor selBg = [&] { QColor a = QColor(50, 120, 220); a.setAlpha(110); return a; }();
    auto color = [this](VTermColor c, bool fg) {
        if (fg && VTERM_COLOR_IS_DEFAULT_FG(&c))
            return m_fg;
        if (!fg && VTERM_COLOR_IS_DEFAULT_BG(&c))
            return m_bg;
        vterm_screen_convert_color_to_rgb(m_screen, &c);
        return QColor(c.rgb.red, c.rgb.green, c.rgb.blue);
    };
    const int firstLine = 0;
    VTermScreenCell cell;
    for (int r = 0; r < m_rows; ++r) {
        const int line = firstLine + r;
        const int y = kPad + r * m_cellH;
        const VTermLineInfo *info = lineInfo(line);
        const bool dwl = info && info->doublewidth;
        if (dwl) {
            p.save();
            p.setClipRect(0, y, width(), m_cellH);
            p.translate(kPad, info->doubleheight == 2 ? y - m_cellH : y);
            p.scale(2, info->doubleheight ? 2 : 1);
            p.translate(-kPad, -y);
        }
        for (int col = 0; col < (dwl ? m_cols / 2 : m_cols); ++col) {
            if (!cellAt(line, col, &cell) || isContinuation(cell))
                continue;
            QColor fg = color(cell.fg, true), bg = color(cell.bg, false);
            if (cell.attrs.reverse)
                std::swap(fg, bg);
            fg = adjustedColor(fg, bg, m_style.contrast, isDark(), cell.attrs.dim);
            const int x = kPad + col * m_cellW;
            const int w = m_cellW * qMax(1, int(cell.width));
            if (isSelected(line, col))
                bg = selBg;
            if (bg != m_bg)
                p.fillRect(x, y, w, m_cellH, bg);
            if (cell.chars[0] && cell.chars[0] != ' ') {
                if (cell.chars[1] || !drawBoxGlyph(p, QRectF(x, y, w, m_cellH), cell.chars[0], fg)) {
                    QFont f = cell.attrs.bold ? m_bold : m_font;
                    const QString text = cellText(cell);
                    int tx = x;
                    if (cell.width > 1) {
                        auto it = m_wideScale.constFind(cell.chars[0]);
                        if (it == m_wideScale.cend()) {
                            const QFontMetricsF fm(f);
                            const qreal adv = fm.horizontalAdvance(text);
                            const qreal s = adv > 0 && adv < w * 0.9 ? std::min({w * 0.95 / adv, 1.4, m_cellH / fm.height()}) : 1.0;
                            it = m_wideScale.insert(cell.chars[0], qMax(1.0, s));
                        }
                        if (*it > 1.0)
                            f.setPointSizeF(f.pointSizeF() * *it);
                        tx = x + qMax(0, int((w - QFontMetricsF(f).horizontalAdvance(text)) / 2));
                    }
                    p.setFont(f);
                    p.setPen(fg);
                    p.drawText(tx, y + m_ascent, text);
                }
            }
            if (cell.attrs.underline)
                p.fillRect(x, y + m_ascent + 2, w, 1, fg);
            if (cell.attrs.strike)
                p.fillRect(x, y + m_cellH / 2, w, 1, fg);
        }
        if (dwl)
            p.restore();
    }
    if (isRunning() && !m_preedit.isEmpty()) {
        const QRect cr(kPad + m_markedAt.col * m_cellW, kPad + m_markedAt.row * m_cellH, m_cellW, m_cellH);
        const int pw = QFontMetrics(m_font).horizontalAdvance(m_preedit) + 2;
        p.fillRect(QRect(cr.topLeft(), QSize(pw, m_cellH)), m_bg);
        p.setFont(m_font);
        p.setPen(m_fg);
        p.drawText(cr.left(), cr.top() + m_ascent, m_preedit);
        p.fillRect(cr.left(), cr.bottom() - 1, pw, 2, QColor(50, 120, 220));
    } else if (m_cursorVisible && isRunning()) {
        const QRect cr(kPad + m_cursor.col * m_cellW, kPad + m_cursor.row * m_cellH, m_cellW, m_cellH);
        QColor cc = QColor(50, 120, 220);
        if (!hasFocus()) {
            p.setPen(QPen(cc, 1));
            p.drawRect(cr.adjusted(0, 0, -1, -1));
        } else if (m_cursorShape == VTERM_PROP_CURSORSHAPE_BAR_LEFT) {
            p.fillRect(cr.left(), cr.top(), 2, cr.height(), cc);
        } else if (m_cursorShape == VTERM_PROP_CURSORSHAPE_UNDERLINE) {
            p.fillRect(cr.left(), cr.bottom() - 1, cr.width(), 2, cc);
        } else {
            cc.setAlpha(200);
            p.fillRect(cr, cc);
            if (cellAt(m_cursor.row, m_cursor.col, &cell) && !isContinuation(cell) &&
                cell.chars[0] && cell.chars[0] != ' ') {
                if (cell.chars[1] || !drawBoxGlyph(p, cr, cell.chars[0], m_bg)) {
                    p.setFont(m_font);
                    p.setPen(m_bg);
                    p.drawText(cr.left(), cr.top() + m_ascent, cellText(cell));
                }
            }
        }
    }
}
int TermView::mouseMods(Qt::KeyboardModifiers m) const
{
    int vm = VTERM_MOD_NONE;
    if (m & Qt::ShiftModifier)
        vm |= VTERM_MOD_SHIFT;
    if (m & Qt::AltModifier)
        vm |= VTERM_MOD_ALT;
    if (m & kCtrl)
        vm |= VTERM_MOD_CTRL;
    return vm;
}

void TermView::sendMouse(QPoint cell, int button, bool pressed, int mods)
{
    vterm_mouse_move(m_vt, cell.y(), cell.x(), VTermModifier(mods));
    vterm_mouse_button(m_vt, button, pressed, VTermModifier(mods));
    flushOutput();
}
void TermView::commitPreedit()
{
    if (m_preedit.isEmpty())
        return;
    const QString text = m_preedit;
    m_preedit.clear();
    sendText(text, true);
    m_committedByClick = text;
    m_committedAt.start();
    QGuiApplication::inputMethod()->reset();
    update();
}

void TermView::mousePressEvent(QMouseEvent *e)
{
    setFocus();
    commitPreedit();
    if (e->button() == Qt::LeftButton) {
        m_selStart = m_selEnd = QPoint(-1, -1);
        update();
    }
    const int button = e->button() == Qt::RightButton ? 3 : e->button() == Qt::MiddleButton ? 2 : 1;
    if (m_mouseMode != VTERM_PROP_MOUSE_NONE && !(button == 3 && (e->modifiers() & Qt::ShiftModifier))) {
        const QPoint c = cellFromPos(e->position().toPoint());
        if (button == 1 && !(e->modifiers() & Qt::AltModifier)) {
            m_pendingPress = true;
            m_pressCell = c;
            m_pressMods = mouseMods(e->modifiers());
            return;
        }
        m_buttonToProgram = button;
        sendMouse(c, button, true, mouseMods(e->modifiers()));
        return;
    }
    if (e->button() == Qt::RightButton) {
        QMenu menu(this);
        menu.addAction(QStringLiteral("Copy"), this, [this] { QGuiApplication::clipboard()->setText(selectedText()); })
            ->setEnabled(!selectedText().isEmpty());
        menu.addAction(QStringLiteral("Paste"), this, [this] { paste(QGuiApplication::clipboard()->text()); });
        menu.exec(e->globalPosition().toPoint());
        return;
    }
    if (e->button() == Qt::LeftButton) {
        m_selStart = m_selEnd = cellFromPos(e->position().toPoint());
        m_selecting = true;
        update();
    }
}

void TermView::mouseMoveEvent(QMouseEvent *e)
{
    const QPoint c = cellFromPos(e->position().toPoint());
    if (m_buttonToProgram) {
        if (m_mouseMode >= VTERM_PROP_MOUSE_DRAG) {
            vterm_mouse_move(m_vt, c.y(), c.x(), VTermModifier(mouseMods(e->modifiers())));
            flushOutput();
        }
        return;
    }
    if (m_pendingPress) {
        if (c == m_pressCell)
            return;
        m_pendingPress = false; // 다른 칸으로 끌었으므로 화면 선택을 시작한다.
        m_selStart = m_pressCell;
        m_selecting = true;
    }
    if (m_selecting) {
        m_selEnd = cellFromPos(e->position().toPoint());
        update();
    }
}

void TermView::mouseReleaseEvent(QMouseEvent *e)
{
    if (m_buttonToProgram) {
        sendMouse(cellFromPos(e->position().toPoint()), m_buttonToProgram, false, mouseMods(e->modifiers()));
        m_buttonToProgram = 0;
        return;
    }
    if (m_pendingPress) {
        m_pendingPress = false;
        const QPoint released = cellFromPos(e->position().toPoint());
        if (released != m_pressCell) {
            m_selStart = m_pressCell;
            m_selEnd = released;
            m_selecting = false;
            update();
            return;
        }
        sendMouse(m_pressCell, 1, true, m_pressMods);
        sendMouse(m_pressCell, 1, false, m_pressMods);
        return;
    }
    m_selecting = false;
}

void TermView::mouseDoubleClickEvent(QMouseEvent *e)
{
    if (m_mouseMode != VTERM_PROP_MOUSE_NONE)
        return mousePressEvent(e);
    const QPoint c = cellFromPos(e->position().toPoint());
    VTermScreenCell cell;
    auto isWord = [&](int col) {
        return cellAt(c.y(), col, &cell) && (isContinuation(cell) || (cell.chars[0] && cell.chars[0] != ' '));
    };
    if (!isWord(c.x()))
        return;
    int a = c.x(), b = c.x();
    while (a > 0 && isWord(a - 1))
        --a;
    while (b < m_cols - 1 && isWord(b + 1))
        ++b;
    m_selStart = QPoint(a, c.y());
    m_selEnd = QPoint(b, c.y());
    m_selecting = false;
    update();
}

void TermView::wheelEvent(QWheelEvent *e)
{
    const qreal lines = !e->pixelDelta().isNull() ? qreal(e->pixelDelta().y()) / m_cellH
                                                  : e->angleDelta().y() / 120.0 * 3;
    m_wheelAccum += lines;
    const int whole = int(m_wheelAccum);
    m_wheelAccum -= whole;
    if (whole == 0)
        return;
    if (m_mouseMode != VTERM_PROP_MOUSE_NONE || m_altScreen) {
        for (int i = 0; i < qAbs(whole); ++i) {
            if (m_mouseMode != VTERM_PROP_MOUSE_NONE) {
                vterm_mouse_button(m_vt, whole > 0 ? 4 : 5, true, VTERM_MOD_NONE);
                vterm_mouse_button(m_vt, whole > 0 ? 4 : 5, false, VTERM_MOD_NONE);
            } else {
                vterm_keyboard_key(m_vt, whole > 0 ? VTERM_KEY_UP : VTERM_KEY_DOWN, VTERM_MOD_NONE);
            }
        }
        flushOutput();
        return;
    }
}

