// SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
#pragma once

#include <algorithm>
#include <optional>

namespace Tb321fu {
struct FrequencyReading {
    double chartMaximumMhz;
    std::optional<double> percentage;
};

class FrequencyRange {
public:
    void reset() { *this = {}; }

    // maxFromTable is zero when available_frequencies supplied no positive OPP.
    // A plotted clock can enlarge the MHz axis but cannot establish hardware capacity.
    [[nodiscard]] FrequencyReading sample(double currentMhz, double maxFromTable)
    {
        if (maxFromTable > 0.0) {
            m_advertisedMax = maxFromTable;
            m_chartMax = maxFromTable;
        }
        m_chartMax = std::max(m_chartMax, currentMhz);
        if (m_advertisedMax <= 0.0) {
            return {m_chartMax, std::nullopt};
        }
        return {m_chartMax, std::clamp(100.0 * (currentMhz / m_advertisedMax), 0.0, 100.0)};
    }

private:
    double m_advertisedMax = 0.0;
    double m_chartMax = 0.0;
};
}
