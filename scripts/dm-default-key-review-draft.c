// SPDX-License-Identifier: GPL-2.0-only
/*
 * Standalone dm-default-key target (v2.0.0) for Linux 4.9.59.
 *
 * Implements Android 11 MetadataCrypt default-key v2 table semantics
 * (AES-256-XTS, sector_size:4096, iv_large_sectors, optional allow_discards)
 * over the Linux 4.9 crypto_skcipher API using mempool bounce pages and
 * workqueue completion without modifying struct bio or dm-crypt.
 */

#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/completion.h>
#include <linux/crypto.h>
#include <linux/device-mapper.h>
#include <linux/err.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mempool.h>
#include <linux/module.h>
#include <linux/scatterlist.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/workqueue.h>
#include <crypto/skcipher.h>
#include <asm/unaligned.h>

#define DM_MSG_PREFIX "default-key"

#define DK_MIN_IOS		64
#define DK_AES_256_XTS_KEY_SIZE	64
#define DK_AES_XTS_IV_SIZE	16
#define DK_UNIT_SIZE		4096U
#define DK_UNIT_SHIFT		12U
#define DK_UNIT_SECTORS		(DK_UNIT_SIZE >> SECTOR_SHIFT)

struct default_key_c {
	struct dm_dev *dev;
	sector_t start;
	sector_t iv_offset;

	unsigned int sector_size;
	unsigned int sector_shift;

	bool iv_large_sectors;
	bool allow_discards;

	struct crypto_skcipher *tfm;
	struct bio_set *bs;
	mempool_t *page_pool;
	struct workqueue_struct *io_queue;
};

struct dk_io {
	struct default_key_c *cc;
	struct bio *base_bio;
	struct bio *clone_bio;
	sector_t rel_sector;
	struct work_struct work;
};

struct dk_crypto_wait {
	struct completion completion;
	int err;
};

static void dk_crypto_complete(struct crypto_async_request *req, int err)
{
	struct dk_crypto_wait *wait = req->data;

	/*
	 * With CRYPTO_TFM_REQ_MAY_BACKLOG, the crypto subsystem invokes this
	 * callback with -EINPROGRESS when a backlogged request transitions to
	 * active execution. Ignore intermediate backlog notifications and
	 * complete only when the request reaches terminal status.
	 */
	if (err == -EINPROGRESS)
		return;

	wait->err = err;
	complete(&wait->completion);
}

static int dk_do_skcipher_unit(struct default_key_c *cc,
			       struct skcipher_request *req,
			       struct scatterlist *src_sg,
			       struct scatterlist *dst_sg,
			       u64 dun, bool encrypt)
{
	struct dk_crypto_wait wait;
	u8 iv[DK_AES_XTS_IV_SIZE];
	int err;

	memset(iv, 0, sizeof(iv));
	put_unaligned_le64(dun, iv);

	init_completion(&wait.completion);
	wait.err = 0;

	skcipher_request_set_callback(req,
				      CRYPTO_TFM_REQ_MAY_BACKLOG |
				      CRYPTO_TFM_REQ_MAY_SLEEP,
				      dk_crypto_complete, &wait);
	skcipher_request_set_crypt(req, src_sg, dst_sg, cc->sector_size, iv);

	err = encrypt ? crypto_skcipher_encrypt(req) :
			crypto_skcipher_decrypt(req);

	if (err == -EINPROGRESS || err == -EBUSY) {
		wait_for_completion_io(&wait.completion);
		err = wait.err;
	}

	memzero_explicit(iv, sizeof(iv));
	return err;
}

/*
 * Android 11 MetadataCrypt / ACK dm-default-key IV formula:
 * iv_offset is added in 512-byte sectors prior to shifting into 4096-byte
 * encryption data units.
 */
static u64 dk_compute_dun(struct default_key_c *cc, sector_t rel_sector,
			  unsigned int unit_idx)
{
	sector_t total_sector = cc->iv_offset + rel_sector;
	unsigned int shift_diff = cc->sector_shift - SECTOR_SHIFT;

	return ((u64)total_sector >> shift_diff) + unit_idx;
}

/*
 * Count the actual bio fragments in each encryption unit.  A 4 KiB unit
 * can cross more than eight short bvecs, so a fixed scatterlist is unsafe.
 * The table stays alive until the (possibly asynchronous) crypto request
 * has completed.
 */
#define DK_STACK_SEGS 8

struct dk_unit_sg {
	struct scatterlist stack[DK_STACK_SEGS];
	struct sg_table dynamic;
	struct scatterlist *sg;
	bool allocated;
};

static int dk_make_unit_sg(struct bio *bio, struct bvec_iter *iter,
			   unsigned int unit_size, struct dk_unit_sg *out)
{
	struct bvec_iter scan = *iter;
	struct scatterlist *sg;
	unsigned int remaining = unit_size, n = 0, i = 0;
	int ret;

	memset(out, 0, sizeof(*out));
	while (remaining) {
		struct bio_vec bv;
		unsigned int len;

		if (!scan.bi_size)
			return -EIO;
		bv = bio_iter_iovec(bio, scan);
		if (!bv.bv_len)
			return -EIO;
		len = min(remaining, bv.bv_len);
		n++;
		bio_advance_iter(bio, &scan, len);
		remaining -= len;
	}
	if (n <= DK_STACK_SEGS) {
		out->sg = out->stack;
		sg_init_table(out->sg, n);
	} else {
		ret = sg_alloc_table(&out->dynamic, n, GFP_NOIO);
		if (ret)
			return ret;
		out->allocated = true;
		out->sg = out->dynamic.sgl;
	}
	remaining = unit_size;
	sg = out->sg;
	while (remaining) {
		struct bio_vec bv = bio_iter_iovec(bio, *iter);
		unsigned int len = min(remaining, bv.bv_len);

		sg_set_page(sg, bv.bv_page, len, bv.bv_offset);
		bio_advance_iter(bio, iter, len);
		remaining -= len;
		if (++i < n)
			sg = sg_next(sg);
	}
	return 0;
}

static void dk_release_unit_sg(struct dk_unit_sg *unit)
{
	if (unit->allocated)
		sg_free_table(&unit->dynamic);
}

/* Both scatterlists remain valid until async crypto completion. */
static int dk_crypt_bio(struct default_key_c *cc, struct bio *src_bio,
			struct bio *dst_bio, sector_t rel_sector, bool encrypt)
{
	struct skcipher_request *req;
	struct bvec_iter src_iter = src_bio->bi_iter;
	struct bvec_iter dst_iter = dst_bio->bi_iter;
	unsigned int unit_size = cc->sector_size;
	unsigned int unit_idx = 0;
	int err = 0;

	if (src_iter.bi_size != dst_iter.bi_size ||
	    (src_iter.bi_size & (unit_size - 1)) != 0)
		return -EIO;

	req = skcipher_request_alloc(cc->tfm, GFP_NOIO);
	if (!req)
		return -ENOMEM;

	while (src_iter.bi_size >= unit_size) {
		struct dk_unit_sg src, dst;
		u64 dun;

		err = dk_make_unit_sg(src_bio, &src_iter, unit_size, &src);
		if (err)
			goto out;
		if (src_bio == dst_bio) {
			/* In-place decryption uses the same scatterlist. */
			dst_iter = src_iter;
			dun = dk_compute_dun(cc, rel_sector, unit_idx);
			err = dk_do_skcipher_unit(cc, req, src.sg, src.sg,
						  dun, encrypt);
		} else {
			err = dk_make_unit_sg(dst_bio, &dst_iter,
					      unit_size, &dst);
			if (!err) {
				dun = dk_compute_dun(cc, rel_sector, unit_idx);
				err = dk_do_skcipher_unit(cc, req, src.sg,
							  dst.sg, dun, encrypt);
				dk_release_unit_sg(&dst);
			}
		}
		dk_release_unit_sg(&src);
		if (err)
			goto out;
		unit_idx++;
	}

	if (src_iter.bi_size || dst_iter.bi_size)
		err = -EIO;
out:
	skcipher_request_free(req);
	return err;
}

static void dk_free_bounce_bio(struct default_key_c *cc, struct bio *clone)
{
	struct bio_vec *bvec;
	int i;

	if (!clone)
		return;

	bio_for_each_segment_all(bvec, clone, i) {
		if (bvec->bv_page)
			mempool_free(bvec->bv_page, cc->page_pool);
	}
	bio_put(clone);
}

static void dk_finish_base_bio(struct dk_io *io, int err)
{
	struct bio *base_bio = io->base_bio;

	if (err && !base_bio->bi_error)
		base_bio->bi_error = err;

	kfree(io);
	bio_endio(base_bio);
}

static void dk_write_endio(struct bio *clone)
{
	struct dk_io *io = clone->bi_private;
	struct default_key_c *cc = io->cc;
	int err = clone->bi_error;

	dk_free_bounce_bio(cc, clone);
	dk_finish_base_bio(io, err);
}

static void dk_write_work(struct work_struct *work)
{
	struct dk_io *io = container_of(work, struct dk_io, work);
	struct default_key_c *cc = io->cc;
	struct bio *base_bio = io->base_bio;
	struct bio *clone;
	unsigned int total_bytes = base_bio->bi_iter.bi_size;
	unsigned int nr_pages = DIV_ROUND_UP(total_bytes, PAGE_SIZE);
	unsigned int rem = total_bytes;
	int err;

	clone = bio_alloc_bioset(GFP_NOIO, nr_pages, cc->bs);
	if (!clone) {
		dk_finish_base_bio(io, -ENOMEM);
		return;
	}

	clone->bi_bdev = cc->dev->bdev;
	clone->bi_iter.bi_sector = cc->start + io->rel_sector;
	clone->bi_opf = base_bio->bi_opf;
	clone->bi_private = io;
	clone->bi_end_io = dk_write_endio;

	while (rem > 0) {
		struct page *page = mempool_alloc(cc->page_pool, GFP_NOIO);
		unsigned int len = min_t(unsigned int, rem, PAGE_SIZE);

		if (!page) {
			dk_free_bounce_bio(cc, clone);
			dk_finish_base_bio(io, -ENOMEM);
			return;
		}

		if (bio_add_page(clone, page, len, 0) != len) {
			mempool_free(page, cc->page_pool);
			dk_free_bounce_bio(cc, clone);
			dk_finish_base_bio(io, -EIO);
			return;
		}
		rem -= len;
	}

	err = dk_crypt_bio(cc, base_bio, clone, io->rel_sector, true);
	if (err) {
		dk_free_bounce_bio(cc, clone);
		dk_finish_base_bio(io, err);
		return;
	}

	generic_make_request(clone);
}

static void dk_read_work(struct work_struct *work)
{
	struct dk_io *io = container_of(work, struct dk_io, work);
	struct default_key_c *cc = io->cc;
	struct bio *base_bio = io->base_bio;
	int err;

	err = dk_crypt_bio(cc, base_bio, base_bio, io->rel_sector, false);
	dk_finish_base_bio(io, err);
}

static void dk_read_endio(struct bio *clone)
{
	struct dk_io *io = clone->bi_private;
	struct default_key_c *cc = io->cc;
	int err = clone->bi_error;

	bio_put(clone);

	if (err) {
		dk_finish_base_bio(io, err);
		return;
	}

	INIT_WORK(&io->work, dk_read_work);
	queue_work(cc->io_queue, &io->work);
}

static int default_key_map(struct dm_target *ti, struct bio *bio)
{
	struct default_key_c *cc = ti->private;
	sector_t rel_sector = dm_target_offset(ti, bio->bi_iter.bi_sector);
	struct dk_io *io;

	/* Empty flush control bio */
	if (unlikely((bio->bi_opf & REQ_PREFLUSH) && bio->bi_iter.bi_size == 0)) {
		bio->bi_bdev = cc->dev->bdev;
		bio->bi_iter.bi_sector = cc->start + rel_sector;
		return DM_MAPIO_REMAPPED;
	}

	/* Discard control bio */
	if (unlikely(bio_op(bio) == REQ_OP_DISCARD)) {
		if (!cc->allow_discards) {
			bio->bi_error = -EOPNOTSUPP;
			bio_endio(bio);
			return DM_MAPIO_SUBMITTED;
		}
		bio->bi_bdev = cc->dev->bdev;
		bio->bi_iter.bi_sector = cc->start + rel_sector;
		return DM_MAPIO_REMAPPED;
	}

	/* Reject misaligned or zero-length data bios via DM completion path */
	if (unlikely((rel_sector & (DK_UNIT_SECTORS - 1)) != 0 ||
		     bio->bi_iter.bi_size == 0 ||
		     (bio->bi_iter.bi_size & (DK_UNIT_SIZE - 1)) != 0)) {
		bio->bi_error = -EIO;
		bio_endio(bio);
		return DM_MAPIO_SUBMITTED;
	}

	io = kmalloc(sizeof(*io), GFP_NOIO);
	if (!io) {
		bio->bi_error = -ENOMEM;
		bio_endio(bio);
		return DM_MAPIO_SUBMITTED;
	}

	io->cc = cc;
	io->base_bio = bio;
	io->clone_bio = NULL;
	io->rel_sector = rel_sector;

	if (bio_op(bio) != REQ_OP_READ && bio_op(bio) != REQ_OP_WRITE) {
		kfree(io);
		bio->bi_error = -EOPNOTSUPP;
		bio_endio(bio);
		return DM_MAPIO_SUBMITTED;
	}

	if (bio_op(bio) == REQ_OP_WRITE) {
		INIT_WORK(&io->work, dk_write_work);
		queue_work(cc->io_queue, &io->work);
		return DM_MAPIO_SUBMITTED;
	}

	/* READ path: clone bio, issue to backing device, decrypt in worker */
	io->clone_bio = bio_clone_fast(bio, GFP_NOIO, cc->bs);
	if (!io->clone_bio) {
		kfree(io);
		bio->bi_error = -ENOMEM;
		bio_endio(bio);
		return DM_MAPIO_SUBMITTED;
	}

	io->clone_bio->bi_bdev = cc->dev->bdev;
	io->clone_bio->bi_iter.bi_sector = cc->start + rel_sector;
	io->clone_bio->bi_private = io;
	io->clone_bio->bi_end_io = dk_read_endio;

generic_make_request(io->clone_bio);
return DM_MAPIO_SUBMITTED;
}
static void default_key_dtr(struct dm_target *ti)
{
struct default_key_c *cc = ti->private;
if (!cc)
return;
if (cc->io_queue)
destroy_workqueue(cc->io_queue);
if (cc->page_pool)
mempool_destroy(cc->page_pool);
if (cc->bs)
bioset_free(cc->bs);
if (cc->tfm && !IS_ERR(cc->tfm))
crypto_free_skcipher(cc->tfm);
if (cc->dev)
dm_put_device(ti, cc->dev);
kfree(cc);
}
static int dk_parse_optional_args(struct dm_target *ti,
struct default_key_c *cc,
unsigned int argc, char **argv)
{
unsigned int num_opts, i;
char dummy;
if (argc == 0) {
ti->error = "Missing optional parameters for v2 interface";
return -EINVAL;
}
if (sscanf(argv[0], "%u%c", &num_opts, &dummy) != 1 ||
num_opts != argc - 1) {
ti->error = "Invalid optional parameter count";
return -EINVAL;
}
for (i = 1; i <= num_opts; i++) {
const char *opt = argv[i];
if (!strcmp(opt, "iv_large_sectors")) {
cc->iv_large_sectors = true;
} else if (!strcmp(opt, "allow_discards")) {
cc->allow_discards = true;
} else if (!strncmp(opt, "sector_size:", 12)) {
unsigned int sz;
if (sscanf(opt + 12, "%u%c", &sz, &dummy) != 1 ||
sz != DK_UNIT_SIZE) {
ti->error = "Only sector_size:4096 is supported";
return -EINVAL;
}
cc->sector_size = sz;
cc->sector_shift = DK_UNIT_SHIFT;
} else {
ti->error = "Unknown optional parameter";
return -EINVAL;
}
}
if (cc->sector_size != DK_UNIT_SIZE || !cc->iv_large_sectors) {
ti->error = "Requires sector_size:4096 and iv_large_sectors";
return -EINVAL;
}
return 0;
}
/*
 * Constructor table format (Android 11 MetadataCrypt v2):
 * AES-256-XTS <128-hex-key> <iv_offset> <dev_path> <start_sector>
 * <num_opt_params> sector_size:4096 iv_large_sectors [allow_discards]
*/
static int default_key_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
struct default_key_c *cc;
u8 raw_key[DK_AES_256_XTS_KEY_SIZE];
unsigned long long tmpll;
char dummy;
int ret;
if (argc < 6) {
ti->error = "Not enough arguments";
return -EINVAL;
}
if (strcmp(argv[0], "AES-256-XTS") != 0) {
ti->error = "Unsupported cipher (requires AES-256-XTS)";
return -EINVAL;
}
if (strlen(argv[1]) != DK_AES_256_XTS_KEY_SIZE * 2 ||
hex2bin(raw_key, argv[1], DK_AES_256_XTS_KEY_SIZE) < 0) {
memzero_explicit(raw_key, sizeof(raw_key));
ti->error = "Invalid AES-256-XTS hex key";
return -EINVAL;
}
cc = kzalloc(sizeof(*cc), GFP_KERNEL);
if (!cc) {
memzero_explicit(raw_key, sizeof(raw_key));
ti->error = "Cannot allocate context";
return -ENOMEM;
}
ti->private = cc;
if (sscanf(argv[2], "%llu%c", &tmpll, &dummy) != 1) {
ti->error = "Invalid iv_offset";
ret = -EINVAL;
goto bad;
}
cc->iv_offset = tmpll;
if (sscanf(argv[4], "%llu%c", &tmpll, &dummy) != 1) {
ti->error = "Invalid start sector";
ret = -EINVAL;
goto bad;
}
cc->start = tmpll;
ret = dk_parse_optional_args(ti, cc, argc - 5, argv + 5);
if (ret)
goto bad;
if ((ti->begin & (DK_UNIT_SECTORS - 1)) != 0 ||
(ti->len & (DK_UNIT_SECTORS - 1)) != 0 ||
(cc->iv_offset & (DK_UNIT_SECTORS - 1)) != 0 ||
(cc->start & (DK_UNIT_SECTORS - 1)) != 0) {
ti->error = "Target geometry, start, or iv_offset not 4096-byte aligned";
ret = -EINVAL;
goto bad;
}
cc->tfm = crypto_alloc_skcipher("xts(aes)", 0, 0);
if (IS_ERR(cc->tfm)) {
ti->error = "Error allocating xts(aes) skcipher";
ret = PTR_ERR(cc->tfm);
cc->tfm = NULL;
goto bad;
}
ret = crypto_skcipher_setkey(cc->tfm, raw_key, sizeof(raw_key));
memzero_explicit(raw_key, sizeof(raw_key));
if (ret) {
ti->error = "Error setting xts(aes) key";
goto bad;
}
ret = dm_get_device(ti, argv[3], dm_table_get_mode(ti->table), &cc->dev);
if (ret) {
ti->error = "Device lookup failed";
goto bad;
}
cc->bs = bioset_create(DK_MIN_IOS, 0);
if (!cc->bs) {
ti->error = "Cannot allocate bioset";
ret = -ENOMEM;
goto bad;
}
cc->page_pool = mempool_create_page_pool(DK_MIN_IOS, 0);
if (!cc->page_pool) {
ti->error = "Cannot allocate bounce page pool";
ret = -ENOMEM;
goto bad;
}
cc->io_queue = alloc_workqueue("kdefaultkeyd",
WQ_MEM_RECLAIM | WQ_UNBOUND, 0);
if (!cc->io_queue) {
ti->error = "Cannot allocate workqueue";
ret = -ENOMEM;
goto bad;
}
ret = dm_set_target_max_io_len(ti,
round_down(BIO_MAX_PAGES << (PAGE_SHIFT - SECTOR_SHIFT),
DK_UNIT_SECTORS));
if (ret) {
ti->error = "Failed setting max_io_len";
goto bad;
}
if (cc->allow_discards) {
ti->discards_supported = true;
ti->num_discard_bios = 1;
}
ti->num_flush_bios = 1;
return 0;
bad:
memzero_explicit(raw_key, sizeof(raw_key));
default_key_dtr(ti);
return ret;
}
static void default_key_status(struct dm_target *ti, status_type_t type,
unsigned int status_flags, char *result,
unsigned int maxlen)
{
struct default_key_c *cc = ti->private;
unsigned int sz = 0;
unsigned int num_opts = 2 + (cc->allow_discards ? 1 : 0);
switch (type) {
case STATUSTYPE_INFO:
result[0] = '\0';
break;
case STATUSTYPE_TABLE:
DMEMIT("AES-256-XTS - %llu %s %llu %u sector_size:%u iv_large_sectors%s",
(unsigned long long)cc->iv_offset,
cc->dev->name,
(unsigned long long)cc->start,
num_opts,
cc->sector_size,
cc->allow_discards ? " allow_discards" : "");
break;
}
}
static int default_key_iterate_devices(struct dm_target *ti,
iterate_devices_callout_fn fn,
void *data)
{
struct default_key_c *cc = ti->private;
return fn(ti, cc->dev, cc->start, ti->len, data);
}
static void default_key_io_hints(struct dm_target *ti,
struct queue_limits *limits)
{
struct default_key_c *cc = ti->private;
limits->logical_block_size = cc->sector_size;
limits->physical_block_size = cc->sector_size;
limits->io_min = cc->sector_size;
}
static struct target_type default_key_target = {
.name			= "default-key",
.version		= {2, 0, 0},
.module			= THIS_MODULE,
.ctr			= default_key_ctr,
.dtr			= default_key_dtr,
.map			= default_key_map,
.status			= default_key_status,
.iterate_devices	= default_key_iterate_devices,
.io_hints		= default_key_io_hints,
};
static int __init dm_default_key_init(void)
{
int r = dm_register_target(&default_key_target);
if (r < 0)
DMERR("register failed %d", r);
return r;
}
static void __exit dm_default_key_exit(void)
{
dm_unregister_target(&default_key_target);
}
module_init(dm_default_key_init);
module_exit(dm_default_key_exit);
MODULE_AUTHOR("QEMU Android 11 Port");
MODULE_DESCRIPTION(DM_NAME " default-key metadata encryption target");
MODULE_LICENSE("GPL");

