/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2020, Google Inc.
 *
 * Image Processing Algorithm interface for soft
 *
 * This file is auto-generated. Do not edit.
 */

#pragma once


#include <string>
#include <type_traits>
#include <utility>


#include <libcamera/base/flags.h>
#include <libcamera/base/signal.h>

#include <libcamera/controls.h>
#include <libcamera/framebuffer.h>
#include <libcamera/geometry.h>

#include <libcamera/ipa/core_ipa_interface.h>
#include <libcamera/ipa/ipa_interface.h>

namespace libcamera {

namespace ipa {

namespace soft {




enum class _SoftCmd {
	Exit = 0,
	Init = 1,
	Start = 2,
	Stop = 3,
	Configure = 4,
	QueueRequest = 5,
	ComputeParams = 6,
	ProcessStats = 7,
};

enum class _SoftEventCmd {
	SetSensorControls = 1,
	SetIspParams = 2,
	MetadataReady = 3,
};


struct IPAConfigInfo
{
public:
#ifndef __DOXYGEN__
	IPAConfigInfo() = default;

	template<
		typename T1 = ControlInfoMap,
		std::enable_if_t<std::is_convertible_v<T1&&, ControlInfoMap>> * = nullptr
	>
	IPAConfigInfo(T1 &&_sensorControls)
		: sensorControls(std::forward<T1>(_sensorControls))
	{
	}
#endif


	ControlInfoMap sensorControls;
};

class IPASoftInterface : public IPAInterface
{
public:

	virtual int32_t init(
		const IPASettings &settings,
		const SharedFD &fdStats,
		const SharedFD &fdParams,
		const IPACameraSensorInfo &sensorInfo,
		const ControlInfoMap &sensorControls,
		ControlInfoMap *ipaControls,
		bool *ccmEnabled) = 0;

	virtual int32_t start() = 0;

	virtual void stop() = 0;

	virtual int32_t configure(
		const IPAConfigInfo &configInfo) = 0;

	virtual void queueRequest(
		const uint32_t frame,
		const ControlList &sensorControls) = 0;

	virtual void computeParams(
		const uint32_t frame) = 0;

	virtual void processStats(
		const uint32_t frame,
		const uint32_t bufferId,
		const ControlList &sensorControls) = 0;

	Signal<const ControlList &> setSensorControls;

	Signal<> setIspParams;

	Signal<uint32_t, const ControlList &> metadataReady;
};

} /* namespace soft */

} /* namespace ipa */

} /* namespace libcamera */