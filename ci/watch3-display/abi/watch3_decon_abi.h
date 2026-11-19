/*
 * Copyright (c) 2016 Samsung Electronics Co., Ltd.
 *		http://www.samsung.com
 *
 * Header file for Exynos DECON driver
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
*/


/* Generated host fixture, not an installed UAPI header or a device driver.
 * dma_addr_t is 64-bit in the pinned ARM64 Noblesse defconfig, line 29.
 * No packed attribute: preserve natural AAPCS64 alignment.
 */
#ifndef WATCH3_DECON_ABI_H
#define WATCH3_DECON_ABI_H
#include <stdbool.h>
#include <stdint.h>
#include <sys/ioctl.h>
typedef uint32_t u32;
typedef uint32_t __u32;
typedef uint64_t dma_addr_t;
#define MAX_PLANE_CNT		3
#define MAX_DECON_WIN		3

/* decon.h:272 */
enum decon_idma_type {
	IDMA_G0 = 0,
	IDMA_G1,
	IDMA_VG0,
	IDMA_VG1,
	IDMA_VGF0,
	IDMA_VGF1, /* VGRF in case of Exynos9810 */
	MAX_DECON_DMA_TYPE,
};

/* decon.h:375 */
enum decon_pixel_format {
	/* RGB 8bit display */
	/* 4byte */
	DECON_PIXEL_FORMAT_ARGB_8888 = 0,
	DECON_PIXEL_FORMAT_ABGR_8888,
	DECON_PIXEL_FORMAT_RGBA_8888,
	DECON_PIXEL_FORMAT_BGRA_8888,
	DECON_PIXEL_FORMAT_XRGB_8888,
	DECON_PIXEL_FORMAT_XBGR_8888,
	DECON_PIXEL_FORMAT_RGBX_8888,
	DECON_PIXEL_FORMAT_BGRX_8888,
	/* 2byte */
	DECON_PIXEL_FORMAT_RGBA_5551,
	DECON_PIXEL_FORMAT_BGRA_5551,
	DECON_PIXEL_FORMAT_ABGR_4444,
	DECON_PIXEL_FORMAT_RGBA_4444,
	DECON_PIXEL_FORMAT_BGRA_4444,
	DECON_PIXEL_FORMAT_RGB_565,
	DECON_PIXEL_FORMAT_BGR_565,

	/* RGB 10bit display */
	/* 4byte */
	DECON_PIXEL_FORMAT_ARGB_2101010,
	DECON_PIXEL_FORMAT_ABGR_2101010,
	DECON_PIXEL_FORMAT_RGBA_1010102,
	DECON_PIXEL_FORMAT_BGRA_1010102,

	/* YUV 8bit display */
	/* YUV422 2P */
	DECON_PIXEL_FORMAT_NV16,
	DECON_PIXEL_FORMAT_NV61,
	/* YUV422 3P */
	DECON_PIXEL_FORMAT_YVU422_3P,
	/* YUV420 2P */
	DECON_PIXEL_FORMAT_NV12,
	DECON_PIXEL_FORMAT_NV21,
	DECON_PIXEL_FORMAT_NV12M,
	DECON_PIXEL_FORMAT_NV21M,
	/* YUV420 3P */
	DECON_PIXEL_FORMAT_YUV420,
	DECON_PIXEL_FORMAT_YVU420,
	DECON_PIXEL_FORMAT_YUV420M,
	DECON_PIXEL_FORMAT_YVU420M,
	/* YUV - 2 planes but 1 buffer */
	DECON_PIXEL_FORMAT_NV12N,
	DECON_PIXEL_FORMAT_NV12N_10B,

	/* YUV 10bit display */
	/* YUV420 2P */
	DECON_PIXEL_FORMAT_NV12M_P010,
	DECON_PIXEL_FORMAT_NV21M_P010,

	/* YUV420(P8+2) 4P */
	DECON_PIXEL_FORMAT_NV12M_S10B,
	DECON_PIXEL_FORMAT_NV21M_S10B,

	DECON_PIXEL_FORMAT_MAX,
};

/* decon.h:434 */
enum decon_blending {
	DECON_BLENDING_NONE = 0,
	DECON_BLENDING_PREMULT = 1,
	DECON_BLENDING_COVERAGE = 2,
	DECON_BLENDING_MAX = 3,
};

/* decon.h:441 */
enum dpp_rotate {
	DPP_ROT_NORMAL = 0x0,
	DPP_ROT_XFLIP,
	DPP_ROT_YFLIP,
	DPP_ROT_180,
	DPP_ROT_90,
	DPP_ROT_90_XFLIP,
	DPP_ROT_90_YFLIP,
	DPP_ROT_270,
};

/* decon.h:452 */
enum dpp_csc_eq {
	/* eq_mode : 6bits [5:0] */
	CSC_STANDARD_SHIFT = 0,
	CSC_BT_601 = 0,
	CSC_BT_709 = 1,
	CSC_BT_2020 = 2,
	CSC_DCI_P3 = 3,
	/* eq_mode : 3bits [8:6] */
	CSC_RANGE_SHIFT = 6,
	CSC_RANGE_LIMITED = 0x0,
	CSC_RANGE_FULL = 0x1,
};

/* decon.h:465 */
enum dpp_comp_src {
	DPP_COMP_SRC_NONE = 0,
	DPP_COMP_SRC_G2D,
	DPP_COMP_SRC_GPU
};

/* decon.h:471 */
enum dpp_hdr_standard {
	DPP_HDR_OFF = 0,
	DPP_HDR_ST2084,
	DPP_HDR_HLG,
};

/* decon.h:527 */
struct decon_win_rect {
	int x;
	int y;
	u32 w;
	u32 h;
};

/* decon.h:541 */
struct dpp_params {
	dma_addr_t addr[MAX_PLANE_CNT];
	enum dpp_rotate rot;
	enum dpp_csc_eq eq_mode;
	enum dpp_comp_src comp_src;
	enum dpp_hdr_standard hdr_std;
	u32 min_luminance;
	u32 max_luminance;
};

/* decon.h:551 */
struct decon_frame {
	int x;
	int y;
	u32 w;
	u32 h;
	u32 f_w;
	u32 f_h;
};

/* decon.h:560 */
struct decon_win_config {
	enum {
		DECON_WIN_STATE_DISABLED = 0,
		DECON_WIN_STATE_COLOR,
		DECON_WIN_STATE_BUFFER,
		DECON_WIN_STATE_UPDATE,
		DECON_WIN_STATE_CURSOR,
	} state;

	/* Reusability:This struct is used for IDMA and ODMA */
	union {
		__u32 color;
		struct {
			int				fd_idma[3];
			int				acq_fence;
			int				rel_fence;
			int				plane_alpha;
			enum decon_blending		blending;
			enum decon_idma_type		idma_type;
			enum decon_pixel_format		format;
			struct dpp_params		dpp_parm;
			/* no read area of IDMA */
			struct decon_win_rect		block_area;
			struct decon_win_rect		transparent_area;
			struct decon_win_rect		opaque_area;
			/* source framebuffer coordinates */
			struct decon_frame		src;
		};
	};

	/* destination OSD coordinates */
	struct decon_frame dst;
	bool protection;
	bool compression;
};

/* decon.h:625 */
struct decon_win_config_data {
	int	retire_fence;
	int	fd_odma;
	struct decon_win_config config[MAX_DECON_WIN + 1];
};

#define S3CFB_WIN_CONFIG		_IOW('F', 209, \
						struct decon_win_config_data)
#endif
