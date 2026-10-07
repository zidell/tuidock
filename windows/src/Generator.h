#pragma once
#include "Maker.h"
#include <QWidget>
class QLineEdit; class QLabel; class QPushButton; class QComboBox; class QTimer; class QCheckBox;
class Generator : public QWidget {
    Q_OBJECT
public:
    explicit Generator(Paths destinations = Paths::system(), const QString &language = {});
    void setEmoji(const QString &text);
    static QString lastEmoji(const QString &text);
protected:
    void dragEnterEvent(QDragEnterEvent *) override;
    void dropEvent(QDropEvent *) override;
private:
    bool make(); void refreshIcon(); void setProgram(const QString &file);
    Paths paths; AppSpec spec;
    QLineEdit *emoji; QPushButton *icon, *drop; QComboBox *terminal; QLabel *status, *memory; QTimer *remake;
    QPushButton *create; QCheckBox *launch;
    bool made = false, korean = false;
};
