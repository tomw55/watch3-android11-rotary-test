/*
 * Copyright (c) 2016 Samsung Electronics Co., Ltd.
 *		http://www.samsung.com
 *
 * Helper file for Samsung EXYNOS DPU driver
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
*/


/* Samsung source-derived test oracles. Not a kernel execution test. */
#include <errno.h>
#include "watch3_decon_abi.h"
#define decon_err(...) ((void)0)
/* helper.c:69: verbatim format translation */
u32 dpu_translate_fmt_to_dpp(u32 format)
{
	switch (format) {
	case DECON_PIXEL_FORMAT_NV12:
		return DECON_PIXEL_FORMAT_NV21;
	case DECON_PIXEL_FORMAT_NV21:
		return DECON_PIXEL_FORMAT_NV12;
	case DECON_PIXEL_FORMAT_NV12N_10B:
		return DECON_PIXEL_FORMAT_NV12N_10B;
	case DECON_PIXEL_FORMAT_NV12M:
		return DECON_PIXEL_FORMAT_NV21M;
	case DECON_PIXEL_FORMAT_NV21M:
		return DECON_PIXEL_FORMAT_NV12M;
	case DECON_PIXEL_FORMAT_NV12N:
		return DECON_PIXEL_FORMAT_NV12N;
	case DECON_PIXEL_FORMAT_YUV420:
		return DECON_PIXEL_FORMAT_YVU420;
	case DECON_PIXEL_FORMAT_YVU420:
		return DECON_PIXEL_FORMAT_YUV420;
	case DECON_PIXEL_FORMAT_YUV420M:
		return DECON_PIXEL_FORMAT_YVU420M;
	case DECON_PIXEL_FORMAT_YVU420M:
		return DECON_PIXEL_FORMAT_YUV420M;
	case DECON_PIXEL_FORMAT_ARGB_8888:
		return DECON_PIXEL_FORMAT_BGRA_8888;
	case DECON_PIXEL_FORMAT_ABGR_8888:
		return DECON_PIXEL_FORMAT_RGBA_8888;
	case DECON_PIXEL_FORMAT_RGBA_8888:
		return DECON_PIXEL_FORMAT_ABGR_8888;
	case DECON_PIXEL_FORMAT_BGRA_8888:
		return DECON_PIXEL_FORMAT_ARGB_8888;
	case DECON_PIXEL_FORMAT_XRGB_8888:
		return DECON_PIXEL_FORMAT_BGRX_8888;
	case DECON_PIXEL_FORMAT_XBGR_8888:
		return DECON_PIXEL_FORMAT_RGBX_8888;
	case DECON_PIXEL_FORMAT_RGBX_8888:
		return DECON_PIXEL_FORMAT_XBGR_8888;
	case DECON_PIXEL_FORMAT_BGRX_8888:
		return DECON_PIXEL_FORMAT_XRGB_8888;
	default:
		return format;
	}
}
/* decon_core.c:1404: body copied; unused device arg/logging removed. */
int source_check_limitation(int idx, struct decon_win_config *config)
{
	(void)idx;
	if (config->format >= DECON_PIXEL_FORMAT_MAX) {
		decon_err("unknown pixel format %u\n", config->format);
		return -EINVAL;
	}

	switch (config->format) {
		/* RGB 10bit display */
		case DECON_PIXEL_FORMAT_ARGB_2101010:
		case DECON_PIXEL_FORMAT_ABGR_2101010:
		case DECON_PIXEL_FORMAT_RGBA_1010102:
		case DECON_PIXEL_FORMAT_BGRA_1010102:
		/* YUV 10bit display */
		case DECON_PIXEL_FORMAT_NV12M_P010:
		case DECON_PIXEL_FORMAT_NV21M_P010:
		case DECON_PIXEL_FORMAT_NV12M_S10B:
		case DECON_PIXEL_FORMAT_NV21M_S10B:
		/* YUV422 2P */
		case DECON_PIXEL_FORMAT_NV16:
		case DECON_PIXEL_FORMAT_NV61:
		/* YUV422 3P */
		case DECON_PIXEL_FORMAT_YVU422_3P:
		/* YUV420 3P */
		case DECON_PIXEL_FORMAT_YUV420:
		case DECON_PIXEL_FORMAT_YVU420:
		case DECON_PIXEL_FORMAT_YUV420M:
		case DECON_PIXEL_FORMAT_YVU420M:
			decon_err("not supported pixel format\n");
			return -EINVAL;
		default:
			break;
	}

	if (config->blending >= DECON_BLENDING_MAX) {
		decon_err("unknown blending %u\n", config->blending);
		return -EINVAL;
	}

	if ((config->plane_alpha < 0) || (config->plane_alpha > 0xff)) {
		decon_err("plane alpha value(%d) is out of range(0~255)\n",
				config->plane_alpha);
		return -EINVAL;
	}

	if (config->dst.w == 0 || config->dst.h == 0 ||
			config->dst.x < 0 || config->dst.y < 0) {
		decon_err("win[%d] size is abnormal (w:%d, h:%d, x:%d, y:%d)\n",
				idx, config->dst.w, config->dst.h,
				config->dst.x, config->dst.y);
		return -EINVAL;
	}

	if (config->dst.w < 16) {
		decon_err("window wide < 16pixels, width = %u)\n",
				config->dst.w);
		return -EINVAL;
	}

	if ((config->dst.w > config->dst.f_w) ||
			(config->dst.h > config->dst.f_h)) {
		decon_err("dst coordinate is out of range(%d %d %d %d %d %d)\n",
				config->dst.x, config->dst.w, config->dst.f_w,
				config->dst.y, config->dst.h, config->dst.f_h);
		return -EINVAL;
	}

	if (config->idma_type < IDMA_G0 || config->idma_type > IDMA_VG0) {
		decon_err("idma_type(%d) is wrong\n", config->idma_type);
		return -EINVAL;
	}

	if (config->compression) {
		decon_err("compression is not supported\n");
		return -EINVAL;
	}

	if (config->dpp_parm.rot > DPP_ROT_180) {
		decon_err("dpp_parm.rot(%d) is wrong\n", config->dpp_parm.rot);
		return -EINVAL;
	}

	if (config->dpp_parm.comp_src || config->dpp_parm.hdr_std
			|| config->dpp_parm.min_luminance || config->dpp_parm.max_luminance) {
		decon_err("dpp_parm.comp_src(%d)\n", config->dpp_parm.comp_src);
		decon_err("dpp_parm.hdr_std(%d)\n", config->dpp_parm.hdr_std);
		decon_err("dpp_parm.min_luminance(%d)\n", config->dpp_parm.min_luminance);
		decon_err("dpp_parm.max_luminance(%d)\n", config->dpp_parm.max_luminance);
		return -EINVAL;
	}

	return 0;
}
