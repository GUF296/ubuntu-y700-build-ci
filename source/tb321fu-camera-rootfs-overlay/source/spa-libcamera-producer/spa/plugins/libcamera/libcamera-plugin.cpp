#include <errno.h>
#include <stdint.h>

#include <spa/support/plugin.h>

#include "libcamera.h"

struct spa_log_topic libcamera_log_topic = SPA_LOG_TOPIC(0, "spa.libcamera");

extern "C" int spa_handle_factory_enum(const struct spa_handle_factory **factory,
				       uint32_t *index)
{
	static const struct spa_handle_factory *factories[] = {
		&spa_libcamera_manager_factory,
		&spa_libcamera_device_factory,
		&spa_libcamera_source_factory,
	};

	if (!factory || !index)
		return -EINVAL;

	if (*index >= sizeof(factories) / sizeof(factories[0]))
		return 0;

	*factory = factories[(*index)++];
	return 1;
}
