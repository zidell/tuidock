#include "Settings.h"
#include <QComboBox>
#include <QDesktopServices>
#include <QDoubleSpinBox>
#include <QFontDatabase>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLocale>
#include <QMessageBox>
#include <QPushButton>
#include <QSlider>
#include <QSignalBlocker>
#include <QUrl>

Settings::Settings(Config *model, QWidget *parent) : QDialog(parent), config(model) {
    const bool ko = QLocale::system().language() == QLocale::Korean;
    setWindowTitle(ko ? "터미널 설정" : "Terminal settings"); setAttribute(Qt::WA_DeleteOnClose);
    auto *layout = new QFormLayout(this); layout->setContentsMargins(24, 24, 24, 24); layout->setSpacing(18);
    auto commit = [this](const QString &key, const QVariant &value) { QString error; if (!config->set(key, value, &error)) QMessageBox::warning(this, "TUIDock", error); };
    auto *family = new QComboBox(this); family->addItem(ko ? "기본 (D2Coding)" : "Default (D2Coding)", QString());
    for (const auto &name : QFontDatabase::families()) if (name == "D2Coding" || QFontDatabase::isFixedPitch(name)) family->addItem(name, name);
    layout->addRow(ko ? "글꼴" : "Font", family);
    connect(family, &QComboBox::activated, this, [=] { commit("font_family", family->currentData()); });
    auto *size = new QDoubleSpinBox(this); const auto sizeSpec = configKeys()[1]; size->setRange(sizeSpec.min, sizeSpec.max); size->setSuffix(" pt"); size->setDecimals(1);
    layout->addRow(ko ? "크기" : "Size", size); connect(size, &QDoubleSpinBox::valueChanged, this, [=](double n) { commit("font_size", n); });
    auto slider = [=](const QString &key, const QString &label, int min, int max, double scale) {
        auto *container = new QWidget(this); auto *row = new QHBoxLayout(container); row->setContentsMargins(0,0,0,0);
        auto *control = new QSlider(Qt::Horizontal, container); control->setRange(min,max); auto *value = new QLabel(container); value->setMinimumWidth(55);
        row->addWidget(control,1); row->addWidget(value); layout->addRow(label,container);
        connect(control, &QSlider::valueChanged, this, [=](int n) {
            value->setText(key == "contrast" ? QString::number(n) + "%" : QString::number(n/scale,'f',2));
            if (control->isSliderDown()) { Style live = config->current; setStyleValue(live,key,double(n)/scale); emit preview(live); }
            else if (!control->property("refreshing").toBool()) commit(key,double(n)/scale);
        });
        connect(control, &QSlider::sliderReleased, this, [=] { commit(key,double(control->value())/scale); });
        auto refresh = [=] { control->setProperty("refreshing",true); control->setValue(qRound(styleValue(config->current,key).toDouble()*scale)); value->setText(key == "contrast" ? QString::number(control->value()) + "%" : QString::number(control->value()/scale,'f',2)); control->setProperty("refreshing",false); };
        connect(config,&Config::changed,control,refresh); refresh();
    };
    slider("line_height", ko ? "줄간격" : "Line height",100,200,100); slider("contrast",ko ? "대비" : "Contrast",-100,100,1);
    auto *theme = new QComboBox(this); for (int i=0;i<3;++i) theme->addItem(ko ? QStringList{"자동","다크","라이트"}[i] : QStringList{"Automatic","Dark","Light"}[i], configKeys()[3].choices[i]);
    layout->addRow(ko ? "모양" : "Appearance",theme); connect(theme,&QComboBox::activated,this,[=] { commit("theme",theme->currentData()); });
    auto refresh = [=] { QSignalBlocker a(family),b(size),c(theme); int i=family->findData(config->current.family); if (i<0) { family->addItem(config->current.family,config->current.family); i=family->count()-1; } family->setCurrentIndex(i); size->setValue(config->current.size); theme->setCurrentIndex(theme->findData(config->current.theme)); };
    connect(config,&Config::changed,this,refresh); refresh();
    auto *open = new QPushButton(ko ? "파일 열기…" : "Open file…",this); layout->addRow(open); connect(open,&QPushButton::clicked,this,[=] { config->ensure(); QDesktopServices::openUrl(QUrl::fromLocalFile(config->path)); });
    connect(this,&QDialog::finished,this,[this] { emit preview(config->current); }); resize(460,sizeHint().height());
}
