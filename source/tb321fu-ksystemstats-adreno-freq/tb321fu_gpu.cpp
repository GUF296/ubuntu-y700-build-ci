/*
    SPDX-FileCopyrightText: 2026 TB321FU Ubuntu rootfs project

    SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
*/

#include <KLocalizedString>
#include <KPluginFactory>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStringList>
#include <QVariant>
#include <QVariantList>

#include <systemstats/SensorContainer.h>
#include <systemstats/SensorObject.h>
#include <systemstats/SensorPlugin.h>
#include <systemstats/SensorProperty.h>

#include <algorithm>

namespace
{
constexpr double hzPerMhz = 1000000.0;

QString readTrimmedFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    return QString::fromLatin1(file.readAll()).trimmed();
}

QString discoverGpuDevfreqDirectory()
{
    const QDir devfreqClass(QStringLiteral("/sys/class/devfreq"));
    const QFileInfoList devices = devfreqClass.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable, QDir::Name);
    for (const QFileInfo &device : devices) {
        const QString directory = device.absoluteFilePath();
        if (!QFileInfo::exists(directory + QStringLiteral("/cur_freq"))) {
            continue;
        }

        const QString identity = device.fileName() + QLatin1Char(' ') + device.canonicalFilePath() + QLatin1Char(' ')
            + readTrimmedFile(directory + QStringLiteral("/name"));
        if (identity.contains(QStringLiteral("gpu"), Qt::CaseInsensitive)
            || identity.contains(QStringLiteral("adreno"), Qt::CaseInsensitive)
            || identity.contains(QStringLiteral("kgsl"), Qt::CaseInsensitive)) {
            return directory;
        }
    }
    return {};
}

double readGpuFrequencyMhz(QString &deviceDirectory, bool &ok)
{
    ok = false;
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (deviceDirectory.isEmpty()) {
            deviceDirectory = discoverGpuDevfreqDirectory();
        }
        if (deviceDirectory.isEmpty()) {
            return 0.0;
        }

        bool parsed = false;
        const qulonglong hz = readTrimmedFile(deviceDirectory + QStringLiteral("/cur_freq")).toULongLong(&parsed);
        if (parsed) {
            ok = true;
            return static_cast<double>(hz) / hzPerMhz;
        }
        deviceDirectory.clear();
    }
    return 0.0;
}

QPair<double, double> readGpuFrequencyRangeMhz(const QString &deviceDirectory)
{
    QFile file(deviceDirectory + QStringLiteral("/available_frequencies"));
    if (!file.open(QIODevice::ReadOnly)) {
        return {0.0, 0.0};
    }

    double minMhz = 0.0;
    double maxMhz = 0.0;
    const QStringList entries = QString::fromLatin1(file.readAll()).simplified().split(QLatin1Char(' '), Qt::SkipEmptyParts);
    for (const QString &entry : entries) {
        bool ok = false;
        const qulonglong hz = entry.toULongLong(&ok);
        if (!ok) {
            continue;
        }

        const double mhz = static_cast<double>(hz) / hzPerMhz;
        minMhz = minMhz == 0.0 ? mhz : std::min(minMhz, mhz);
        maxMhz = std::max(maxMhz, mhz);
    }

    return {minMhz, maxMhz};
}
}

class Tb321fuGpuObject : public KSysGuard::SensorObject
{
public:
    explicit Tb321fuGpuObject(KSysGuard::SensorContainer *parent)
        : KSysGuard::SensorObject(QStringLiteral("adreno"), i18nc("@title", "Adreno GPU"), parent)
    {
        m_name = new KSysGuard::SensorProperty(QStringLiteral("name"), i18nc("@title", "Name"), name(), this);
        m_name->setVariantType(QVariant::String);

        m_device = new KSysGuard::SensorProperty(QStringLiteral("device"), i18nc("@title", "Device"), this);
        m_device->setVariantType(QVariant::String);

        m_frequency = new KSysGuard::SensorProperty(QStringLiteral("frequency"), i18nc("@title", "Frequency"), this);
        m_frequency->setPrefix(name());
        m_frequency->setShortName(i18nc("@title, Short for GPU frequency", "GPU Frequency"));
        m_frequency->setDescription(i18nc("@info", "Current Adreno GPU devfreq frequency; unavailable while the GPU devfreq device is absent"));
        m_frequency->setVariantType(QVariant::Double);
        m_frequency->setUnit(KSysGuard::UnitMegaHertz);
        m_frequency->setMin(0.0);

        m_frequencyPercent = new KSysGuard::SensorProperty(QStringLiteral("usage"), i18nc("@title", "Frequency Usage"), this);
        m_frequencyPercent->setPrefix(name());
        m_frequencyPercent->setShortName(i18nc("@title, Short for GPU frequency percentage", "GPU Frequency %"));
        m_frequencyPercent->setDescription(i18nc("@info", "Current Adreno GPU clock as a percentage of the maximum devfreq frequency; this is not GPU busy utilization"));
        m_frequencyPercent->setVariantType(QVariant::Double);
        m_frequencyPercent->setUnit(KSysGuard::UnitPercent);
        m_frequencyPercent->setMin(0.0);
        m_frequencyPercent->setMax(100.0);

        update();
    }

    void update()
    {
        bool ok = false;
        const QString previousDeviceDirectory = m_deviceDirectory;
        const double mhz = readGpuFrequencyMhz(m_deviceDirectory, ok);
        if (!ok) {
            m_maxFrequencyMhz = 0.0;
            m_device->setValue(QVariant());
            m_frequency->setValue(QVariant());
            m_frequencyPercent->setValue(QVariant());
            return;
        }

        if (m_deviceDirectory != previousDeviceDirectory) {
            m_maxFrequencyMhz = 0.0;
        }
        m_device->setValue(QFileInfo(m_deviceDirectory).fileName());
        refreshFrequencyRange(mhz);
        m_frequency->setValue(mhz);
        if (m_maxFrequencyMhz > 0.0) {
            m_frequencyPercent->setValue(std::clamp((mhz / m_maxFrequencyMhz) * 100.0, 0.0, 100.0));
        } else {
            m_frequencyPercent->setValue(QVariant());
        }
    }

private:
    void refreshFrequencyRange(double observedMhz)
    {
        const auto range = readGpuFrequencyRangeMhz(m_deviceDirectory);
        if (range.second > 0.0) {
            m_maxFrequencyMhz = range.second;
        }
        m_maxFrequencyMhz = std::max(m_maxFrequencyMhz, observedMhz);
        if (m_maxFrequencyMhz > 0.0) {
            m_frequency->setMax(m_maxFrequencyMhz);
        }
    }

    KSysGuard::SensorProperty *m_name = nullptr;
    KSysGuard::SensorProperty *m_device = nullptr;
    KSysGuard::SensorProperty *m_frequency = nullptr;
    KSysGuard::SensorProperty *m_frequencyPercent = nullptr;
    QString m_deviceDirectory;
    double m_maxFrequencyMhz = 0.0;
};

class Tb321fuGpuPlugin : public KSysGuard::SensorPlugin
{
    Q_OBJECT

public:
    explicit Tb321fuGpuPlugin(QObject *parent, const QVariantList &args)
        : KSysGuard::SensorPlugin(parent, args)
    {
        m_container = new KSysGuard::SensorContainer(QStringLiteral("gpu"), i18nc("@title", "GPU"), this);

        // Register the sensors even when devfreq probes after KSystemStats starts.
        m_gpu = new Tb321fuGpuObject(m_container);
    }

    void update() override
    {
        if (m_gpu) {
            m_gpu->update();
        }
    }

private:
    KSysGuard::SensorContainer *m_container = nullptr;
    Tb321fuGpuObject *m_gpu = nullptr;
};

K_PLUGIN_CLASS_WITH_JSON(Tb321fuGpuPlugin, "metadata.json")

#include "tb321fu_gpu.moc"
