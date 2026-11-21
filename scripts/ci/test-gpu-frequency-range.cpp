// SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
#include "../../source/tb321fu-ksystemstats-adreno-freq/tb321fu_frequency_range.h"

#include <cmath>
#include <cstdlib>
#include <iostream>

static void check(const char *name, Tb321fu::FrequencyReading actual, double chart, std::optional<double> percentage)
{
    if (actual.chartMaximumMhz != chart || actual.percentage.has_value() != percentage.has_value()
        || (percentage && !(std::abs(*actual.percentage - *percentage) < 0.0001))) {
        std::cerr << "Wrong frequency scale: " << name << '\n';
        std::exit(1);
    }
}

int main()
{
    Tb321fu::FrequencyRange s;
    check("historical TB321FU 231/834 MHz", s.sample(231, 834), 834, 27.6978);
    check("valid zero with OPPs", s.sample(0, 834), 834, 0);
    s.reset(); // no clock / different devfreq device; neither previous scale may survive
    check("first observation cannot establish capacity", s.sample(300, 0), 300, std::nullopt);
    check("lower clock preserves only the MHz chart high water", s.sample(150, 0), 300, std::nullopt);
    check("OPPs become available", s.sample(300, 600), 600, 50);
    check("transient unavailable table on same device", s.sample(150, 0), 600, 25);
    check("out-of-table clock may enlarge only the chart", s.sample(750, 600), 750, 100);
    check("last published maximum is still 600", s.sample(300, 0), 750, 50);
    check("new advertised maximum", s.sample(300, 500), 500, 60);
    s.reset();
    check("new device has no known range", s.sample(125, 0), 125, std::nullopt);
    std::cout << "GPU_FREQUENCY_RANGE=PASS (clock percentage, not busy utilization)\n";
}
