#include "Maker.h"
#include <QCoreApplication>
#include <QSaveFile>
int main(int argc, char **argv) {
    QCoreApplication app(argc,argv); if (app.arguments().size()!=3) return 2;
    QImage source(app.arguments()[1]); if (source.isNull()) return 2;
    QSaveFile file(app.arguments()[2]); auto data=iconData(fitWindowsIcon(source));
    return file.open(QIODevice::WriteOnly) && file.write(data)==data.size() && file.commit() ? 0 : 1;
}
