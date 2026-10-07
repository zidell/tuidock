#pragma once
#include "Config.h"
#include <QDialog>
class Settings : public QDialog {
    Q_OBJECT
public:
    Settings(Config *config, QWidget *parent = nullptr);
signals:
    void preview(const Style &style);
private:
    Config *config;
};
