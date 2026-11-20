#pragma once

#include <memory>

#include <libcamera/camera_manager.h>

std::shared_ptr<libcamera::CameraManager> libcamera_manager_acquire(int &res);
