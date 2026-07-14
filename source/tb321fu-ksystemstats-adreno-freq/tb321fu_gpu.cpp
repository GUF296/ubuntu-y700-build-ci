/*
    SPDX-FileCopyrightText: 2026 TB321FU Ubuntu rootfs project

    SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
*/

#include <KLocalizedString>
#include <KPluginFactory>

#include <QFile>
#include <QStringList>
#include <QVariantList>

#include <systemstats/SensorContainer.h>
#include <systemstats/SensorObject.h>
#include <systemstats/SensorPlugin.h>
#include <systemstats/SensorProperty.h>

#include <algorithm>

namespace
{
constexpr auto gpuFreqPath = "/sys/devices/platform/soc@0/3d00000.gpu/devfreq/3d00000.gpu/cur_freq";
constexpr auto gpuAvailableFreqPath = "/sys/devices/platform/soc@0/3d00000.gpu/devfreq/3d00000.gpu/available_frequencies";
constexpr double hzPerMhz = 1000000.0;

double readGpuFrequencyMhz(bool &ok)
{
    ok = false;

    QFile file(QString::fromLatin1(gpuFreqPath));
    if (!file.open(QIODevice::ReadOnly)) {
        return 0.0;
    }

    bool parsed = false;
    const qulonglong hz = QString::fromLatin1(file.readAll()).trimmed().toULongLong(&parsed);
    if (!parsed) {
        return 0.0;
    }

    ok = true;
    return static_cast<double>(hz) / hzPerMhz;
}

QPair<double, double> readGpuFrequencyRangeMhz()
{
    QFile file(QString::fromLatin1(gpuAvailableFreqPath));
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

        m_frequency = new KSysGuard::SensorProperty(QStringLiteral("frequency"), i18nc("@title", "Frequency"), this);
        m_frequency->setPrefix(name());
        m_frequency->setShortName(i18nc("@title, Short for GPU frequency", "GPU Frequency"));
        m_frequency->setDescription(i18nc("@info", "Current Adreno GPU devfreq frequency; zero while the sysfs value is unavailable"));
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
        const double mhz = readGpuFrequencyMhz(ok);
        if (!ok) {
            m_frequency->setValue(0.0);
            m_frequencyPercent->setValue(0.0);
            return;
        }

        refreshFrequencyRange(mhz);
        m_frequency->setValue(mhz);
        if (m_maxFrequencyMhz > 0.0) {
            m_frequencyPercent->setValue(std::clamp((mhz / m_maxFrequencyMhz) * 100.0, 0.0, 100.0));
        } else {
            m_frequencyPercent->setValue(0.0);
        }
    }

private:
    void refreshFrequencyRange(double observedMhz)
    {
        const auto range = readGpuFrequencyRangeMhz();
        if (range.second > 0.0) {
            m_maxFrequencyMhz = range.second;
        }
        m_maxFrequencyMhz = std::max(m_maxFrequencyMhz, observedMhz);
        if (m_maxFrequencyMhz > 0.0) {
            m_frequency->setMax(m_maxFrequencyMhz);
        }
    }

    KSysGuard::SensorProperty *m_name = nullptr;
    KSysGuard::SensorProperty *m_frequency = nullptr;
    KSysGuard::SensorProperty *m_frequencyPercent = nullptr;
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
